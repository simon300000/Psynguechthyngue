import Foundation

public struct SyncEnvironmentSnapshot: Codable, Hashable, Sendable {
    public var network: NetworkState
    public var power: PowerState
    public var transfer: TransferEstimate
    public var safety: SyncSafetyState
    public var capturedAt: Date

    public init(
        network: NetworkState,
        power: PowerState,
        transfer: TransferEstimate = .init(),
        safety: SyncSafetyState = .init(),
        capturedAt: Date = .now
    ) {
        self.network = network
        self.power = power
        self.transfer = transfer
        self.safety = safety
        self.capturedAt = capturedAt
    }

    public func policyInput(
        trigger: SyncTrigger,
        requestedActions: Set<SyncAction>,
        additionalDiskBytes: Int64? = nil,
        requestedTemporaryOverride: Bool = false,
        safetyScope: SyncPolicySafetyScope = .operationSpecific
    ) -> SyncPolicyInput {
        SyncPolicyInput(
            trigger: trigger,
            requestedActions: requestedActions,
            network: network,
            power: power,
            transfer: transfer,
            safety: safety,
            additionalDiskBytes: additionalDiskBytes,
            now: capturedAt,
            requestedTemporaryOverride: requestedTemporaryOverride,
            safetyScope: safetyScope
        )
    }

    public static var permissiveForTesting: SyncEnvironmentSnapshot {
        SyncEnvironmentSnapshot(
            network: .init(kind: .wifi),
            power: .init(
                batteryLevel: 1,
                isExternalPowerConnected: true,
                isLowPowerModeEnabled: false,
                thermalLevel: .nominal
            ),
            safety: .init(availableDiskBytes: .max)
        )
    }
}

extension CoreCommandKind {
    public var requestedSyncActions: Set<SyncAction> {
        switch self {
        case .sync:
            [.discover, .exchangeIndex, .upload, .download, .scan]
        case .upload:
            [.exchangeIndex, .upload, .scan]
        case .download, .materialize, .pin:
            [.exchangeIndex, .download]
        case .exchangeIndex:
            [.discover, .exchangeIndex]
        case .rescan:
            [.exchangeIndex, .scan, .hash]
        case .create, .modify, .move, .delete:
            [.scan, .hash]
        case .disposeRecovery, .disposeRecoveryReviewed:
            [.scan, .hash]
        case .evict:
            [.evictLocalCopy]
        case .addDevice, .editDevice, .removeDevice, .acceptDevice,
            .ignorePendingDevice, .unignorePendingDevice,
            .addFolder, .editFolder, .removeFolder, .acceptFolder,
            .ignorePendingFolder, .unignorePendingFolder,
            .pause, .resume:
            // The embedded Syncthing App starts its connection service even for
            // local configuration work, so these operations still require the
            // network/index policy gate until the bridge has a database-only mode.
            [.exchangeIndex]
        }
    }

    public var networkCorePolicyActions: Set<SyncAction> {
        requestedSyncActions.union(networkSessionOperation.runtimePolicyActions)
    }

    public var networkSessionOperation: CoreNetworkSessionOperation {
        switch self {
        case .upload:
            .upload
        case .create, .modify, .move, .delete:
            .localMutation
        case .download:
            .download
        case .materialize, .pin:
            .materialize
        case .evict:
            .localContent
        case .exchangeIndex, .rescan:
            .exchangeIndex
        default:
            .sync
        }
    }
}

extension CoreNetworkSessionOperation {
    public var runtimePolicyActions: Set<SyncAction> {
        switch self {
        case .sync:
            [.discover, .exchangeIndex, .upload, .download]
        case .upload:
            [.discover, .exchangeIndex, .upload]
        case .download:
            [.discover, .exchangeIndex, .download]
        case .materialize:
            [.discover, .exchangeIndex, .download]
        case .exchangeIndex:
            [.discover, .exchangeIndex]
        case .localMutation, .localContent:
            []
        }
    }
}

extension SyncAction {
    /// Conservative envelope retained for legacy callers that do not carry a
    /// v3 operation-bound network session plan.
    public static let networkCoreRuntimeEnvelope: Set<SyncAction> = [
        .discover,
        .exchangeIndex,
        .upload,
        .download,
    ]
}

#if os(iOS)
    import Network
    import UIKit

    extension SyncEnvironmentSnapshot {
        public static func captureSystemState(paths: SharedContainerPaths) async -> SyncEnvironmentSnapshot {
            #if DEBUG
                // App-hosted XCTest must not become nondeterministic when a
                // stress test warms the physical device. Dedicated policy
                // tests still inject explicit serious/critical snapshots.
                if ProcessInfo.processInfo.environment["PSY_XCTEST_PERMISSIVE_ENVIRONMENT"] == "1" {
                    return .permissiveForTesting
                }
            #endif
            let network = await OneShotNetworkPathProbe.capture()
            let power = await MainActor.run { capturePowerState() }
            let snapshot = try? SharedSnapshotStore(snapshotURL: paths.snapshot).read()
            let startOfDay = Calendar.autoupdatingCurrent.startOfDay(for: .now)
            let measuredToday: Int64?
            do {
                measuredToday = try SyncRunHistory(url: paths.history).measuredNetworkBytes(
                    since: startOfDay
                )
            } catch {
                measuredToday = nil
            }
            let transfer = TransferEstimate(
                largestFileBytes: snapshot?.items
                    .filter { $0.availability == .remoteOnly || $0.availability == .downloading }
                    .map(\.size)
                    .max() ?? 0,
                totalBytes: snapshot?.folders.reduce(0) {
                    $0 + $1.pendingUploadBytes + $1.pendingDownloadBytes
                } ?? 0,
                pendingDownloadBytes: snapshot?.folders.reduce(0) {
                    $0 + $1.pendingDownloadBytes
                } ?? 0,
                alreadyTransferredTodayBytes: measuredToday
            )
            let availableDisk =
                (try? paths.root.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]
                ))?.volumeAvailableCapacityForImportantUsage ?? 0
            let safety = SyncSafetyState(
                hasConflict: snapshot?.items.contains(where: { $0.availability == .conflict }) ?? false,
                hasUnuploadedChanges: snapshot?.items.contains(where: { $0.hasUnuploadedChanges }) ?? false,
                availableDiskBytes: availableDisk
            )
            return SyncEnvironmentSnapshot(network: network, power: power, transfer: transfer, safety: safety)
        }

        @MainActor
        private static func capturePowerState() -> PowerState {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let rawBattery = UIDevice.current.batteryLevel
            let battery = rawBattery < 0 ? nil : Double(rawBattery)
            let thermal: ThermalLevel
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: thermal = .nominal
            case .fair: thermal = .fair
            case .serious: thermal = .serious
            case .critical: thermal = .critical
            @unknown default: thermal = .serious
            }
            return PowerState(
                batteryLevel: battery,
                isExternalPowerConnected: UIDevice.current.batteryState == .charging
                    || UIDevice.current.batteryState == .full,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalLevel: thermal
            )
        }
    }

    private final class OneShotNetworkPathProbe: @unchecked Sendable {
        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "io.psynguechthyngue.policy-path-probe")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<NetworkState, Never>?
        private var finished = false

        static func capture() async -> NetworkState {
            await withCheckedContinuation { continuation in
                OneShotNetworkPathProbe().start(continuation)
            }
        }

        private func start(_ continuation: CheckedContinuation<NetworkState, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            monitor.pathUpdateHandler = { [self] path in finish(Self.state(for: path)) }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { [self] in
                finish(NetworkState(kind: .unavailable))
            }
        }

        private func finish(_ state: NetworkState) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            monitor.cancel()
            continuation?.resume(returning: state)
        }

        private static func state(for path: NWPath) -> NetworkState {
            let kind: NetworkKind
            if path.status != .satisfied {
                kind = .unavailable
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = .ethernet
            } else if path.usesInterfaceType(.wifi) {
                kind = .wifi
            } else if path.usesInterfaceType(.cellular) {
                kind = .cellular
            } else {
                kind = .other
            }
            return NetworkState(
                kind: kind,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
        }
    }
#endif
