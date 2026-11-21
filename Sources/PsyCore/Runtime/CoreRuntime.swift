import CryptoKit
import Darwin
import Foundation

public enum CoreRunOutcome: Hashable, Sendable {
    case completed(processedCommands: Int, snapshotGeneration: UInt64)
    case coreBusy
    case configurationUnavailable
    case policyDenied(reasons: [PolicyBlockReason])
    case failed(code: String)

    public var completedSuccessfully: Bool {
        if case .completed = self { return true }
        return false
    }
}

public enum CoreMaterializationOutcome: Hashable, Sendable {
    case completed(transferredBytes: Int64, snapshotGeneration: UInt64)
    case coreBusy
    case configurationUnavailable
    case policyDenied(reasons: [PolicyBlockReason])
    case failed(code: String)

    public var completedSuccessfully: Bool {
        if case .completed = self { return true }
        return false
    }
}

public enum CoreMutationRecoveryQueryOutcome: Hashable, Sendable {
    case completed(CoreMutationRecoveryPage)
    case coreBusy
    case configurationUnavailable
    case policyDenied(reasons: [PolicyBlockReason])
    case failed(code: String)
}

public enum CorePendingFolderObservationOutcome: Hashable, Sendable {
    case completed(
        proof: PendingFolderObservationProof,
        transferredBytes: Int64,
        snapshotGeneration: UInt64
    )
    case coreBusy
    case configurationUnavailable
    case policyDenied(reasons: [PolicyBlockReason])
    case failed(code: String)

    public var completedSuccessfully: Bool {
        if case .completed = self { return true }
        return false
    }
}

public enum CorePendingFolderDiscoveryOutcome: Hashable, Sendable {
    case completed(
        capture: PendingFolderDiscoveryCaptureReceipt,
        transferredBytes: Int64,
        snapshotGeneration: UInt64
    )
    case coreBusy
    case configurationUnavailable
    case policyDenied(reasons: [PolicyBlockReason])
    case failed(code: String)

    public var completedSuccessfully: Bool {
        if case .completed = self { return true }
        return false
    }
}

/// Internal clock seam for deterministic tests. The public runtime surface
/// always uses the production clock and fixed cadence/deadline.
struct PendingFolderObservationClock: Sendable {
    var now: @Sendable () -> Date
    var sleep: @Sendable (_ interval: TimeInterval) async throws -> Void

    init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (_ interval: TimeInterval) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    static let continuous = Self(
        now: { .now },
        sleep: { interval in
            let nanoseconds = UInt64((interval * 1_000_000_000).rounded(.up))
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    )
}

public actor CoreRunCancellationContext {
    public private(set) var endReason: SyncRunEndReason

    public init(endReason: SyncRunEndReason = .cancelled) {
        self.endReason = endReason
    }

    public func markExpired() {
        endReason = .expired
    }
}

public actor CoreRuntime {
    public static let shared = CoreRuntime()

    private var clientFactory: @Sendable () -> any CoreClient
    private let wallClock: @Sendable () -> Date

    public init(
        clientFactory: @escaping @Sendable () -> any CoreClient = { UnavailableCoreClient() },
        wallClock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.clientFactory = clientFactory
        self.wallClock = wallClock
    }

    public func installClientFactory(_ clientFactory: @escaping @Sendable () -> any CoreClient) {
        self.clientFactory = clientFactory
    }

    /// Publishes the authoritative offline configuration snapshot needed to
    /// bootstrap a new App container before its first durable configuration
    /// command can be revision-fenced. This never opens a network session,
    /// evaluates transfer policy, or consumes the command queue.
    @discardableResult
    public func refreshConfigurationSnapshot(
        trigger: SyncTrigger,
        paths requestedPaths: SharedContainerPaths? = nil
    ) async -> CoreRunOutcome {
        guard let paths = requestedPaths ?? (try? SharedContainerPaths.resolve()) else {
            return .configurationUnavailable
        }
        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let lease: CoreOwnerLease
        do {
            lease = try await coordinator.acquire(as: Self.role(for: trigger))
        } catch let error as CoreOwnershipError {
            if error == .ownedByAnotherProcess || error == .alreadyOwnedByThisInstance {
                return .coreBusy
            }
            return .failed(code: Self.failureCode(for: error))
        } catch {
            return .failed(code: "coreOwnershipFailed")
        }

        let client = clientFactory()
        do {
            let configuration = try await withTaskCancellationHandler {
                try await Self.refreshCanonicalConfiguration(
                    client: client,
                    paths: paths,
                    lease: lease,
                    coordinator: coordinator,
                    ownerMetadataURL: CoreProcessCoordinator.ownerMetadataURL(
                        for: paths.coreLock
                    ),
                    requireCanonicalDeviceIdentity: true
                )
            } onCancel: {
                client.requestCancellation()
            }
            await coordinator.release()
            return .completed(
                processedCommands: 0,
                snapshotGeneration: configuration.snapshot.generation
            )
        } catch {
            await coordinator.release()
            return .failed(code: Self.failureCode(for: error))
        }
    }

    /// Discovers a bounded batch of pending-folder summaries from one
    /// configured peer. The returned capture is display evidence only; every
    /// accept or ignore still requires a separate live observation proof.
    public func discoverPendingFolderOffers(
        offeringDeviceID: DeviceID,
        taskID: UUID = UUID(),
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: (@Sendable () async -> SyncEnvironmentSnapshot)? = nil,
        requestedTemporaryOverride: Bool = false
    ) async -> CorePendingFolderDiscoveryOutcome {
        await discoverPendingFolderOffers(
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: trigger,
            paths: paths,
            environment: environment,
            currentEnvironment: currentEnvironment,
            requestedTemporaryOverride: requestedTemporaryOverride,
            clock: .continuous
        )
    }

    func discoverPendingFolderOffers(
        offeringDeviceID: DeviceID,
        taskID: UUID = UUID(),
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: (@Sendable () async -> SyncEnvironmentSnapshot)? = nil,
        requestedTemporaryOverride: Bool = false,
        clock: PendingFolderObservationClock
    ) async -> CorePendingFolderDiscoveryOutcome {
        let startedAt = clock.now()
        guard startedAt.timeIntervalSince1970.isFinite else {
            return .failed(code: "discoveryClockInvalid")
        }
        guard let paths = paths ?? (try? SharedContainerPaths.resolve()) else {
            return .configurationUnavailable
        }
        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let lease: CoreOwnerLease
        do {
            lease = try await coordinator.acquire(as: Self.role(for: trigger))
        } catch let error as CoreOwnershipError {
            if error == .ownedByAnotherProcess || error == .alreadyOwnedByThisInstance {
                try? SyncRunHistory(url: paths.history).append(
                    .init(
                        trigger: trigger,
                        startedAt: startedAt,
                        endedAt: clock.now(),
                        transferredBytes: 0,
                        networkReceivedBytes: 0,
                        networkSentBytes: 0,
                        endReason: .coreBusy,
                        failureCode: "coreBusy"
                    )
                )
                return .coreBusy
            }
            return .failed(code: Self.failureCode(for: error))
        } catch {
            return .failed(code: "coreOwnershipFailed")
        }

        let client = clientFactory()
        let liveEnvironment: @Sendable () async -> SyncEnvironmentSnapshot =
            currentEnvironment ?? { environment }
        let ownerMetadataURL = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        var prepared: PreparedPendingFolderDiscovery?
        var sessionOpen = false
        var settled = false
        var networkTotals: CoreNetworkTransferTotals?

        do {
            let configuration = try await Self.refreshCanonicalConfiguration(
                client: client,
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
            guard let localDeviceID = configuration.snapshot.localDeviceID,
                localDeviceID != offeringDeviceID
            else {
                throw CoreClientError.coreRejected("offering_device_not_configured")
            }
            guard
                let targetDevice = configuration.snapshot.devices.first(where: {
                    $0.id == offeringDeviceID
                })
            else {
                throw CoreClientError.coreRejected("offering_device_not_configured")
            }
            guard !targetDevice.isPaused, targetDevice.state != .paused else {
                throw CoreClientError.coreRejected("offering_device_paused")
            }

            try Self.recoverStaleAccounting(
                paths: paths,
                activeOwnerID: lease.instanceID,
                trigger: trigger,
                at: startedAt
            )
            let sessionID = UUID()
            let discoveryPreparation = try Self.preparePendingFolderDiscovery(
                taskID: taskID,
                sessionID: sessionID,
                offeringDeviceID: offeringDeviceID,
                configurationRevision: configuration.revision,
                ownerID: lease.instanceID,
                paths: paths,
                environment: await liveEnvironment(),
                trigger: trigger,
                requestedTemporaryOverride: requestedTemporaryOverride,
                at: startedAt
            )
            prepared = discoveryPreparation

            let checkpoint: @Sendable () async throws -> Void = {
                try Task.checkCancellation()
                try await Self.validatePendingFolderDiscoveryCheckpoint(
                    discoveryPreparation,
                    paths: paths,
                    lease: lease,
                    coordinator: coordinator,
                    expectedConfigurationRevision: configuration.revision,
                    expectedLocalDeviceID: localDeviceID,
                    offeringDeviceID: offeringDeviceID,
                    environment: await liveEnvironment(),
                    trigger: trigger,
                    requestedTemporaryOverride: requestedTemporaryOverride,
                    at: clock.now()
                )
            }

            try await checkpoint()
            _ = try discoveryPreparation.accountingStore.begin(
                reservationID: discoveryPreparation.reservation.id,
                ownerID: lease.instanceID,
                binding: discoveryPreparation.binding,
                at: startedAt
            )
            try await checkpoint()

            let opened = try await withTaskCancellationHandler {
                try await client.openPendingFolderDiscoverySession(
                    configurationDirectory: paths.coreConfiguration,
                    dataDirectory: paths.coreData,
                    sessionID: sessionID,
                    plan: discoveryPreparation.plan
                )
            } onCancel: {
                client.requestCancellation()
            }
            sessionOpen = true
            let expectedBinding = CoreExplicitSessionBinding.pendingFolderDiscovery(
                sessionID: sessionID,
                plan: discoveryPreparation.plan
            )
            guard opened.binding == expectedBinding,
                opened.configurationRevision == configuration.revision,
                opened.deviceID == localDeviceID
            else {
                throw CoreClientError.coreRejected("pending_folder_discovery_scope")
            }

            let deadline = clock.now().addingTimeInterval(Self.pendingDiscoveryTimeout)
            var capture: PendingFolderDiscoveryCaptureReceipt?
            var terminalFailure: Error?
            for attempt in 1...Self.pendingDiscoveryMaximumCaptureAttempts {
                try await checkpoint()
                do {
                    capture = try await withTaskCancellationHandler {
                        try await client.capturePendingFolderDiscovery()
                    } onCancel: {
                        client.requestCancellation()
                    }
                    break
                } catch let error as CoreClientError
                    where error == .coreRejected("pending_folder_discovery_pending")
                {
                    if attempt == Self.pendingDiscoveryMaximumCaptureAttempts
                        || clock.now() >= deadline
                    {
                        terminalFailure = CoreClientError.coreRejected(
                            "pending_folder_discovery_timeout"
                        )
                        break
                    }
                    try await clock.sleep(Self.pendingDiscoveryPollInterval)
                }
            }

            if let capture {
                try Self.validatePendingFolderDiscoveryCapture(
                    capture,
                    configuration: configuration.snapshot,
                    configurationRevision: configuration.revision,
                    offeringDeviceID: offeringDeviceID,
                    now: clock.now()
                )
            } else if terminalFailure == nil {
                throw CoreClientError.invalidResponse("pending_folder_discovery_missing")
            }

            try await checkpoint()
            let closed = try await withTaskCancellationHandler {
                try await client.closeExplicitSession()
            } onCancel: {
                client.requestCancellation()
            }
            sessionOpen = false
            guard closed.binding == expectedBinding,
                closed.configurationRevision == configuration.revision,
                closed.deviceID == localDeviceID
            else {
                throw CoreClientError.coreRejected("pending_folder_discovery_scope")
            }
            try Task.checkCancellation()
            networkTotals = try await client.networkTransferTotals()
            let exactBytes = try Self.validatedPendingDiscoveryBytes(
                networkTotals,
                prepared: discoveryPreparation
            )
            try await checkpoint()

            let settledAt = clock.now()
            let settlementUsage = try discoveryPreparation.accountingStore.usage(
                for: discoveryPreparation.binding,
                at: settledAt
            )
            guard settlementUsage.dayKey == discoveryPreparation.reservation.dayKey else {
                throw CoreClientError.coreRejected("budget_day_changed")
            }
            let projection = try discoveryPreparation.accountingStore.settleAndFinalizeRun(
                reservationID: discoveryPreparation.reservation.id,
                ownerID: lease.instanceID,
                binding: discoveryPreparation.binding,
                outcome: .exact(bytes: exactBytes),
                at: settledAt
            )
            settled = true
            let failureCode = terminalFailure.map { Self.failureCode(for: $0) }
            let record = SyncRunRecord(
                id: projection.id,
                trigger: trigger,
                startedAt: startedAt,
                endedAt: settledAt,
                transferredBytes: exactBytes,
                networkReceivedBytes: networkTotals?.receivedBytes,
                networkSentBytes: networkTotals?.sentBytes,
                endReason: terminalFailure == nil ? .completed : .failed,
                failureCode: failureCode
            )
            try Self.projectPendingAccountingHistory(
                store: discoveryPreparation.accountingStore,
                paths: paths,
                trigger: trigger,
                exactRecord: record
            )

            if let terminalFailure {
                try await coordinator.validate(lease)
                await coordinator.release()
                return .failed(code: Self.failureCode(for: terminalFailure))
            }
            guard let capture else {
                throw CoreClientError.invalidResponse("pending_folder_discovery_missing")
            }

            let refreshed = try await Self.refreshCanonicalConfiguration(
                client: client,
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
            guard refreshed.revision == configuration.revision,
                refreshed.snapshot.localDeviceID == localDeviceID
            else {
                throw CoreClientError.coreRejected("configuration_revision_changed")
            }
            guard
                let refreshedTarget = refreshed.snapshot.devices.first(where: {
                    $0.id == offeringDeviceID
                })
            else {
                throw CoreClientError.coreRejected("offering_device_not_configured")
            }
            guard !refreshedTarget.isPaused, refreshedTarget.state != .paused else {
                throw CoreClientError.coreRejected("offering_device_paused")
            }
            try Self.validatePendingFolderDiscoveryProjection(
                capture,
                snapshot: refreshed.snapshot
            )
            try await coordinator.validate(lease)
            await coordinator.release()
            return .completed(
                capture: capture,
                transferredBytes: exactBytes,
                snapshotGeneration: refreshed.snapshot.generation
            )
        } catch {
            let primaryError = error
            if sessionOpen { client.requestCancellation() }
            let drained = sessionOpen ? await Self.drainExplicitSession(client) : true
            sessionOpen = false
            var accountingFailed = false
            if let prepared, !settled {
                do {
                    let projection = try prepared.accountingStore.settleAndFinalizeRun(
                        reservationID: prepared.reservation.id,
                        ownerID: lease.instanceID,
                        binding: prepared.binding,
                        outcome: .conservative,
                        at: clock.now()
                    )
                    settled = true
                    let disposition = Self.historyDisposition(for: primaryError)
                    let failureCode = drained ? disposition.failureCode : "coreStopFailed"
                    let record = SyncRunRecord(
                        id: projection.id,
                        trigger: trigger,
                        startedAt: startedAt,
                        endedAt: clock.now(),
                        transferredBytes: projection.chargedBytes,
                        networkReceivedBytes: nil,
                        networkSentBytes: nil,
                        endReason: drained ? disposition.endReason : .failed,
                        failureCode: failureCode
                    )
                    try Self.projectPendingAccountingHistory(
                        store: prepared.accountingStore,
                        paths: paths,
                        trigger: trigger,
                        exactRecord: record
                    )
                } catch {
                    accountingFailed = true
                }
            } else if prepared == nil {
                let disposition = Self.historyDisposition(for: primaryError)
                try? SyncRunHistory(url: paths.history).append(
                    .init(
                        trigger: trigger,
                        startedAt: startedAt,
                        endedAt: clock.now(),
                        transferredBytes: 0,
                        networkReceivedBytes: 0,
                        networkSentBytes: 0,
                        endReason: disposition.endReason,
                        failureCode: disposition.failureCode
                    )
                )
            }
            await coordinator.release()
            if !drained { return .failed(code: "coreStopFailed") }
            if accountingFailed { return .failed(code: "transferAccountingFailed") }
            if let policyError = primaryError as? NetworkCorePolicyError {
                switch policyError {
                case .denied(let reasons): return .policyDenied(reasons: reasons)
                case .configurationUnavailable:
                    return .failed(code: "policyConfigurationUnavailable")
                }
            }
            return .failed(code: Self.failureCode(for: primaryError))
        }
    }

    /// Revalidates one pending-folder offer in a target-device, zero-folder
    /// native lifetime. This is deliberately not a normal folder sync: policy
    /// authorizes only discovery and index exchange, while every protocol byte
    /// is still covered by a finite durable global reservation.
    public func observePendingFolderOffer(
        folderID: FolderID,
        offeringDeviceID: DeviceID,
        taskID: UUID = UUID(),
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: (@Sendable () async -> SyncEnvironmentSnapshot)? = nil,
        requestedTemporaryOverride: Bool = false
    ) async -> CorePendingFolderObservationOutcome {
        await observePendingFolderOffer(
            folderID: folderID,
            offeringDeviceID: offeringDeviceID,
            taskID: taskID,
            trigger: trigger,
            paths: paths,
            environment: environment,
            currentEnvironment: currentEnvironment,
            requestedTemporaryOverride: requestedTemporaryOverride,
            clock: .continuous
        )
    }

    func observePendingFolderOffer(
        folderID: FolderID,
        offeringDeviceID: DeviceID,
        taskID: UUID = UUID(),
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: (@Sendable () async -> SyncEnvironmentSnapshot)? = nil,
        requestedTemporaryOverride: Bool = false,
        clock: PendingFolderObservationClock
    ) async -> CorePendingFolderObservationOutcome {
        let startedAt = clock.now()
        guard startedAt.timeIntervalSince1970.isFinite else {
            return .failed(code: "observationClockInvalid")
        }
        guard let paths = paths ?? (try? SharedContainerPaths.resolve()) else {
            return .configurationUnavailable
        }
        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let lease: CoreOwnerLease
        do {
            lease = try await coordinator.acquire(as: Self.role(for: trigger))
        } catch let error as CoreOwnershipError {
            if error == .ownedByAnotherProcess || error == .alreadyOwnedByThisInstance {
                try? SyncRunHistory(url: paths.history).append(
                    .init(
                        trigger: trigger,
                        startedAt: startedAt,
                        endedAt: clock.now(),
                        transferredBytes: 0,
                        networkReceivedBytes: 0,
                        networkSentBytes: 0,
                        endReason: .coreBusy,
                        failureCode: "coreBusy"
                    )
                )
                return .coreBusy
            }
            return .failed(code: Self.failureCode(for: error))
        } catch {
            return .failed(code: "coreOwnershipFailed")
        }

        let client = clientFactory()
        let liveEnvironment: @Sendable () async -> SyncEnvironmentSnapshot =
            currentEnvironment ?? { environment }
        let ownerMetadataURL = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        var prepared: PreparedPendingFolderObservation?
        var sessionOpen = false
        var settled = false
        var networkTotals: CoreNetworkTransferTotals?
        var configurationGeneration: UInt64 = 0

        do {
            let configuration = try await Self.refreshCanonicalConfiguration(
                client: client,
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
            configurationGeneration = configuration.snapshot.generation
            guard let localDeviceID = configuration.snapshot.localDeviceID,
                localDeviceID != offeringDeviceID,
                configuration.snapshot.devices.contains(where: { $0.id == offeringDeviceID })
            else {
                throw CoreClientError.coreRejected("offering_device_not_configured")
            }
            guard !configuration.snapshot.folders.contains(where: { $0.id == folderID }) else {
                throw CoreClientError.coreRejected("pending_folder_already_configured")
            }

            try Self.recoverStaleAccounting(
                paths: paths,
                activeOwnerID: lease.instanceID,
                trigger: trigger,
                at: startedAt
            )
            let sessionID = UUID()
            let latestEnvironment = await liveEnvironment()
            let observationPreparation = try Self.preparePendingFolderObservation(
                taskID: taskID,
                sessionID: sessionID,
                folderID: folderID,
                offeringDeviceID: offeringDeviceID,
                configurationRevision: configuration.revision,
                ownerID: lease.instanceID,
                paths: paths,
                environment: latestEnvironment,
                trigger: trigger,
                requestedTemporaryOverride: requestedTemporaryOverride,
                at: startedAt
            )
            prepared = observationPreparation

            let checkpoint: @Sendable () async throws -> Void = {
                try Task.checkCancellation()
                try await Self.validatePendingFolderObservationCheckpoint(
                    observationPreparation,
                    paths: paths,
                    lease: lease,
                    coordinator: coordinator,
                    expectedConfigurationRevision: configuration.revision,
                    expectedLocalDeviceID: localDeviceID,
                    folderID: folderID,
                    offeringDeviceID: offeringDeviceID,
                    environment: await liveEnvironment(),
                    trigger: trigger,
                    requestedTemporaryOverride: requestedTemporaryOverride,
                    at: clock.now()
                )
            }

            try await checkpoint()
            _ = try observationPreparation.accountingStore.begin(
                reservationID: observationPreparation.reservation.id,
                ownerID: lease.instanceID,
                binding: observationPreparation.binding,
                at: startedAt
            )
            try await checkpoint()

            let opened = try await withTaskCancellationHandler {
                try await client.openPendingFolderObservationSession(
                    configurationDirectory: paths.coreConfiguration,
                    dataDirectory: paths.coreData,
                    sessionID: sessionID,
                    plan: observationPreparation.plan
                )
            } onCancel: {
                client.requestCancellation()
            }
            sessionOpen = true
            let expectedBinding = CoreExplicitSessionBinding.pendingFolderObservation(
                sessionID: sessionID,
                plan: observationPreparation.plan
            )
            guard opened.binding == expectedBinding,
                opened.configurationRevision == configuration.revision,
                opened.deviceID == localDeviceID
            else {
                throw CoreClientError.coreRejected("pending_folder_observation_scope")
            }

            let deadline = startedAt.addingTimeInterval(Self.pendingObservationTimeout)
            var capture: PendingFolderObservationCaptureReceipt?
            var terminalFailure: Error?
            for attempt in 1...Self.pendingObservationMaximumCaptureAttempts {
                try await checkpoint()
                do {
                    capture = try await withTaskCancellationHandler {
                        try await client.capturePendingFolderObservation()
                    } onCancel: {
                        client.requestCancellation()
                    }
                    break
                } catch let error as CoreClientError
                    where error == .coreRejected("pending_folder_observation_pending")
                {
                    if attempt == Self.pendingObservationMaximumCaptureAttempts
                        || clock.now() >= deadline
                    {
                        terminalFailure = CoreClientError.coreRejected(
                            "pending_folder_observation_timeout"
                        )
                        break
                    }
                    try await clock.sleep(Self.pendingObservationPollInterval)
                }
            }

            if let capture {
                try Self.validatePendingFolderObservationCapture(
                    capture,
                    expectedBinding: expectedBinding,
                    configurationRevision: configuration.revision,
                    folderID: folderID,
                    offeringDeviceID: offeringDeviceID,
                    now: clock.now()
                )
            } else if terminalFailure == nil {
                throw CoreClientError.invalidResponse("pending_folder_observation_missing")
            }

            try await checkpoint()
            let closed = try await withTaskCancellationHandler {
                try await client.closeExplicitSession()
            } onCancel: {
                client.requestCancellation()
            }
            sessionOpen = false
            guard closed.binding == expectedBinding,
                closed.configurationRevision == configuration.revision,
                closed.deviceID == localDeviceID
            else {
                throw CoreClientError.coreRejected("pending_folder_observation_scope")
            }
            try Task.checkCancellation()
            networkTotals = try await client.networkTransferTotals()
            let exactBytes = try Self.validatedPendingObservationBytes(
                networkTotals,
                prepared: observationPreparation
            )
            try await checkpoint()

            let settledAt = clock.now()
            let settlementUsage = try observationPreparation.accountingStore.usage(
                for: observationPreparation.binding,
                at: settledAt
            )
            guard settlementUsage.dayKey == observationPreparation.reservation.dayKey else {
                throw CoreClientError.coreRejected("budget_day_changed")
            }
            let projection = try observationPreparation.accountingStore.settleAndFinalizeRun(
                reservationID: observationPreparation.reservation.id,
                ownerID: lease.instanceID,
                binding: observationPreparation.binding,
                outcome: .exact(bytes: exactBytes),
                at: settledAt
            )
            settled = true
            let failureCode = terminalFailure.map { Self.failureCode(for: $0) }
            let record = SyncRunRecord(
                id: projection.id,
                trigger: trigger,
                startedAt: startedAt,
                endedAt: settledAt,
                transferredBytes: exactBytes,
                networkReceivedBytes: networkTotals?.receivedBytes,
                networkSentBytes: networkTotals?.sentBytes,
                endReason: terminalFailure == nil ? .completed : .failed,
                failureCode: failureCode
            )
            try Self.projectPendingAccountingHistory(
                store: observationPreparation.accountingStore,
                paths: paths,
                trigger: trigger,
                exactRecord: record
            )
            try await coordinator.validate(lease)
            await coordinator.release()

            if let terminalFailure {
                return .failed(code: Self.failureCode(for: terminalFailure))
            }
            guard let proof = capture?.proof else {
                return .failed(code: "pending_folder_observation_missing")
            }
            return .completed(
                proof: proof,
                transferredBytes: exactBytes,
                snapshotGeneration: configurationGeneration
            )
        } catch {
            let primaryError = error
            if sessionOpen { client.requestCancellation() }
            let drained = sessionOpen ? await Self.drainExplicitSession(client) : true
            sessionOpen = false
            var accountingFailed = false
            if let prepared, !settled {
                do {
                    let projection = try prepared.accountingStore.settleAndFinalizeRun(
                        reservationID: prepared.reservation.id,
                        ownerID: lease.instanceID,
                        binding: prepared.binding,
                        outcome: .conservative,
                        at: clock.now()
                    )
                    settled = true
                    let disposition = Self.historyDisposition(for: primaryError)
                    let failureCode = drained ? disposition.failureCode : "coreStopFailed"
                    let record = SyncRunRecord(
                        id: projection.id,
                        trigger: trigger,
                        startedAt: startedAt,
                        endedAt: clock.now(),
                        transferredBytes: projection.chargedBytes,
                        networkReceivedBytes: nil,
                        networkSentBytes: nil,
                        endReason: drained ? disposition.endReason : .failed,
                        failureCode: failureCode
                    )
                    try Self.projectPendingAccountingHistory(
                        store: prepared.accountingStore,
                        paths: paths,
                        trigger: trigger,
                        exactRecord: record
                    )
                } catch {
                    accountingFailed = true
                }
            } else if prepared == nil {
                let disposition = Self.historyDisposition(for: primaryError)
                try? SyncRunHistory(url: paths.history).append(
                    .init(
                        trigger: trigger,
                        startedAt: startedAt,
                        endedAt: clock.now(),
                        transferredBytes: 0,
                        networkReceivedBytes: 0,
                        networkSentBytes: 0,
                        endReason: disposition.endReason,
                        failureCode: disposition.failureCode
                    )
                )
            }
            await coordinator.release()
            if !drained { return .failed(code: "coreStopFailed") }
            if accountingFailed { return .failed(code: "transferAccountingFailed") }
            if let policyError = primaryError as? NetworkCorePolicyError {
                switch policyError {
                case .denied(let reasons): return .policyDenied(reasons: reasons)
                case .configurationUnavailable:
                    return .failed(code: "policyConfigurationUnavailable")
                }
            }
            return .failed(code: Self.failureCode(for: primaryError))
        }
    }

    /// Reviews App-owned File Provider mutation recoveries through the offline
    /// configuration control plane. Recovery metadata is App-owned and does not
    /// require Syncthing's database, listeners, discovery, or transfer services.
    public func mutationRecoveries(
        after cursor: String? = nil,
        limit: Int = 100,
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: (@Sendable () async -> SyncEnvironmentSnapshot)? = nil,
        requestedTemporaryOverride: Bool = false
    ) async -> CoreMutationRecoveryQueryOutcome {
        do {
            _ = try CoreMutationRecoveryQueryRequest(
                requestID: "runtime-query-validation",
                cursor: cursor,
                limit: limit
            )
        } catch {
            return .failed(code: CoreMutationRecoveryStableCode.invalidQuery.rawValue)
        }
        guard let paths = paths ?? (try? SharedContainerPaths.resolve()) else {
            return .configurationUnavailable
        }
        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let ownerLease: CoreOwnerLease
        do {
            ownerLease = try await coordinator.acquire(as: Self.role(for: trigger))
        } catch let error as CoreOwnershipError {
            if error == .ownedByAnotherProcess || error == .alreadyOwnedByThisInstance {
                return .coreBusy
            }
            return .failed(code: Self.failureCode(for: error))
        } catch {
            return .failed(code: "coreOwnershipFailed")
        }

        // Kept in the public signature for source compatibility. Neither value
        // may gate an offline configuration-only recovery query.
        _ = environment
        _ = currentEnvironment
        _ = requestedTemporaryOverride
        let client = clientFactory()
        var sessionOpen = false
        do {
            try await coordinator.validate(ownerLease)
            let snapshotStore = SharedSnapshotStore(snapshotURL: paths.snapshot)
            let previous = try snapshotStore.read()
            let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
            let incarnationBefore = try incarnationStore.snapshot()
            let sessionID = UUID()
            let opened = try await client.openConfigurationSession(
                configurationDirectory: paths.coreConfiguration,
                dataDirectory: paths.coreData,
                sessionID: sessionID
            )
            sessionOpen = true
            let page = try await withTaskCancellationHandler {
                try await client.mutationRecoveries(after: cursor, limit: limit)
            } onCancel: {
                client.requestCancellation()
            }
            let proposed = try await client.snapshot()
            let closed = try await client.closeExplicitSession()
            sessionOpen = false
            guard let snapshotRevision = proposed.configurationRevision,
                opened.configurationRevision == snapshotRevision,
                snapshotRevision == closed.configurationRevision
            else {
                throw CoreClientError.invalidResponse("configuration_revision_changed")
            }
            try await coordinator.validate(ownerLease)
            _ = try incarnationStore.ensureLegacyConfiguredFolders(
                proposed.folders.map(\.id),
                authoritativeReconciliation: true
            )
            let incarnationAfter = try incarnationStore.snapshot()
            let configurationIdentityUnchanged =
                previous?.configurationRevision == snapshotRevision
                && incarnationBefore == incarnationAfter
            let preservingFolderIDs =
                configurationIdentityUnchanged
                ? Set(proposed.folders.map(\.id)) : []
            let snapshot = Self.mergedConfigurationSnapshot(
                proposed,
                preservingRuntimeFrom: previous,
                preservingFolderIDs: preservingFolderIDs,
                preserveDeviceRuntime: configurationIdentityUnchanged
            )
            let persisted = try await Self.persist(
                snapshot,
                paths: paths,
                lease: ownerLease,
                coordinator: coordinator,
                ownerMetadataURL: CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
            )
            _ = persisted
            await coordinator.release()
            return .completed(page)
        } catch {
            let primaryError = error
            let drained = sessionOpen ? await Self.drainExplicitSession(client) : true
            await coordinator.release()
            guard drained else { return .failed(code: "coreStopFailed") }
            return .failed(code: Self.recoveryFailureCode(for: primaryError))
        }
    }

    /// Creates a native, content-verified snapshot of one exact mutation
    /// recovery payload. The native storage locator remains inside the bridge;
    /// only the App-owned export container is returned.
    public func prepareMutationRecoveryExport(
        _ summary: CoreMutationRecoverySummary,
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil
    ) async -> CoreMutationRecoveryExportOutcome {
        guard let paths = paths ?? (try? SharedContainerPaths.resolve()) else {
            return .configurationUnavailable
        }
        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let ownerLease: CoreOwnerLease
        do {
            ownerLease = try await coordinator.acquire(as: Self.role(for: trigger))
        } catch let error as CoreOwnershipError {
            if error == .ownedByAnotherProcess || error == .alreadyOwnedByThisInstance {
                return .coreBusy
            }
            return .failed(code: Self.recoveryFailureCode(for: error))
        } catch {
            return .failed(code: "coreOwnershipFailed")
        }

        let client = clientFactory()
        let exportID = UUID()
        var sessionOpen = false
        var nativeExportCreated = false
        do {
            try await coordinator.validate(ownerLease)
            let snapshotStore = SharedSnapshotStore(snapshotURL: paths.snapshot)
            let previous = try snapshotStore.read()
            let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
            let incarnationBefore = try incarnationStore.snapshot()
            let opened = try await client.openConfigurationSession(
                configurationDirectory: paths.coreConfiguration,
                dataDirectory: paths.coreData,
                sessionID: UUID()
            )
            sessionOpen = true
            let outputName = CoreMutationRecoveryExportBuilder.outputName(
                for: summary,
                exportID: exportID
            )
            try await withTaskCancellationHandler {
                try await client.exportMutationRecovery(
                    summary,
                    exportID: exportID,
                    outputName: outputName
                )
            } onCancel: {
                client.requestCancellation()
            }
            nativeExportCreated = true
            try await client.acknowledgeCommand(exportID)
            let export = try CoreMutationRecoveryExportBuilder.export(
                for: summary,
                exportID: exportID,
                paths: paths
            )
            try Self.validateMutationRecoveryExport(export)
            #if os(iOS)
                let container = export.url.deletingLastPathComponent()
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableContainer = container
                try mutableContainer.setResourceValues(values)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: container.path
                )
            #endif
            let proposed = try await client.snapshot()
            let closed = try await client.closeExplicitSession()
            sessionOpen = false
            try await Self.finishConfigurationSession(
                opened: opened,
                proposed: proposed,
                closed: closed,
                previous: previous,
                incarnationBefore: incarnationBefore,
                incarnationStore: incarnationStore,
                paths: paths,
                ownerLease: ownerLease,
                coordinator: coordinator
            )
            sessionOpen = false
            await coordinator.release()
            return .completed(export)
        } catch {
            let primaryError = error
            if nativeExportCreated {
                if !sessionOpen,
                    (try? await client.openConfigurationSession(
                        configurationDirectory: paths.coreConfiguration,
                        dataDirectory: paths.coreData,
                        sessionID: UUID()
                    )) != nil
                {
                    sessionOpen = true
                }
                if sessionOpen {
                    let cleanupRequestID = UUID()
                    if (try? await client.discardMutationRecoveryExport(
                        exportID,
                        requestID: cleanupRequestID
                    )) != nil {
                        try? await client.acknowledgeCommand(cleanupRequestID)
                    }
                }
                try? await client.acknowledgeCommand(exportID)
            }
            let drained = sessionOpen ? await Self.drainExplicitSession(client) : true
            await coordinator.release()
            guard drained else { return .failed(code: "coreStopFailed") }
            return .failed(code: Self.recoveryFailureCode(for: primaryError))
        }
    }

    /// Deletes only the native export container. The retained recovery source
    /// is a separate object and is never selected by this identifier.
    public func discardMutationRecoveryExport(
        _ export: CoreMutationRecoveryExport,
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil
    ) async -> CoreMutationRecoveryExportCleanupOutcome {
        guard let paths = paths ?? (try? SharedContainerPaths.resolve()) else {
            return .configurationUnavailable
        }
        let expectedContainer = paths.coreMutationRecoveryExports.appendingPathComponent(
            ".psy-core-recovery-export-" + export.exportID.uuidString.lowercased(),
            isDirectory: true
        ).standardizedFileURL
        guard export.url.standardizedFileURL.deletingLastPathComponent() == expectedContainer else {
            return .failed(code: CoreMutationRecoveryStableCode.invalidRecoveryExport.rawValue)
        }
        return await discardMutationRecoveryExport(
            exportID: export.exportID,
            trigger: trigger,
            paths: paths
        )
    }

    /// Reclaims an orphaned export after process termination. The ID is
    /// accepted only after the caller has parsed the exact private container
    /// naming contract; native cleanup still revalidates every path component.
    public func discardMutationRecoveryExport(
        exportID: UUID,
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil
    ) async -> CoreMutationRecoveryExportCleanupOutcome {
        guard let paths = paths ?? (try? SharedContainerPaths.resolve()) else {
            return .configurationUnavailable
        }
        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let ownerLease: CoreOwnerLease
        do {
            ownerLease = try await coordinator.acquire(as: Self.role(for: trigger))
        } catch let error as CoreOwnershipError {
            if error == .ownedByAnotherProcess || error == .alreadyOwnedByThisInstance {
                return .coreBusy
            }
            return .failed(code: Self.recoveryFailureCode(for: error))
        } catch {
            return .failed(code: "coreOwnershipFailed")
        }

        let client = clientFactory()
        let cleanupRequestID = UUID()
        var sessionOpen = false
        do {
            try await coordinator.validate(ownerLease)
            let snapshotStore = SharedSnapshotStore(snapshotURL: paths.snapshot)
            let previous = try snapshotStore.read()
            let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
            let incarnationBefore = try incarnationStore.snapshot()
            let opened = try await client.openConfigurationSession(
                configurationDirectory: paths.coreConfiguration,
                dataDirectory: paths.coreData,
                sessionID: UUID()
            )
            sessionOpen = true
            try await client.discardMutationRecoveryExport(
                exportID,
                requestID: cleanupRequestID
            )
            try await client.acknowledgeCommand(cleanupRequestID)
            let proposed = try await client.snapshot()
            let closed = try await client.closeExplicitSession()
            sessionOpen = false
            try await Self.finishConfigurationSession(
                opened: opened,
                proposed: proposed,
                closed: closed,
                previous: previous,
                incarnationBefore: incarnationBefore,
                incarnationStore: incarnationStore,
                paths: paths,
                ownerLease: ownerLease,
                coordinator: coordinator
            )
            sessionOpen = false
            await coordinator.release()
            return .completed
        } catch {
            let primaryError = error
            if sessionOpen {
                try? await client.acknowledgeCommand(cleanupRequestID)
            }
            let drained = sessionOpen ? await Self.drainExplicitSession(client) : true
            await coordinator.release()
            guard drained else { return .failed(code: "coreStopFailed") }
            return .failed(code: Self.recoveryFailureCode(for: primaryError))
        }
    }

    private static func validateMutationRecoveryExport(
        _ export: CoreMutationRecoveryExport
    ) throws {
        var status = stat()
        guard export.url.path.withCString({ lstat($0, &status) }) == 0 else {
            throw CoreMutationRecoveryValidationError.invalidExport
        }
        let kind = status.st_mode & mode_t(S_IFMT)
        guard
            (export.payloadKind == .file && kind == mode_t(S_IFREG))
                || (export.payloadKind == .directory && kind == mode_t(S_IFDIR))
        else {
            throw CoreMutationRecoveryValidationError.invalidExport
        }
    }

    private static func finishConfigurationSession(
        opened: CoreExplicitSessionReceipt,
        proposed: CoreSnapshot,
        closed: CoreExplicitSessionReceipt,
        previous: CoreSnapshot?,
        incarnationBefore: FolderIncarnationDocument,
        incarnationStore: FolderIncarnationStore,
        paths: SharedContainerPaths,
        ownerLease: CoreOwnerLease,
        coordinator: CoreProcessCoordinator
    ) async throws {
        guard let snapshotRevision = proposed.configurationRevision,
            opened.configurationRevision == snapshotRevision,
            snapshotRevision == closed.configurationRevision
        else {
            throw CoreClientError.invalidResponse("configuration_revision_changed")
        }
        try await coordinator.validate(ownerLease)
        _ = try incarnationStore.ensureLegacyConfiguredFolders(
            proposed.folders.map(\.id),
            authoritativeReconciliation: true
        )
        let incarnationAfter = try incarnationStore.snapshot()
        let configurationIdentityUnchanged =
            previous?.configurationRevision == snapshotRevision
            && incarnationBefore == incarnationAfter
        let preservingFolderIDs =
            configurationIdentityUnchanged ? Set(proposed.folders.map(\.id)) : []
        let snapshot = mergedConfigurationSnapshot(
            proposed,
            preservingRuntimeFrom: previous,
            preservingFolderIDs: preservingFolderIDs,
            preserveDeviceRuntime: configurationIdentityUnchanged
        )
        _ = try await persist(
            snapshot,
            paths: paths,
            lease: ownerLease,
            coordinator: coordinator,
            ownerMetadataURL: CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        )
    }

    /// Materializes one exact globally indexed regular-file version into the
    /// managed folder, publishes that verified version as a local source, then
    /// copies it into a caller-owned, previously nonexistent File Provider
    /// destination. The specialized native session prevents the ordinary puller
    /// from fetching unrelated files while preserving the normal policy, owner,
    /// byte-budget, and crash-replay fences.
    @discardableResult
    public func materialize(
        _ item: IndexedItem,
        to destination: URL,
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: (@Sendable () async -> SyncEnvironmentSnapshot)? = nil,
        destinationAvailableCapacity: @escaping @Sendable (URL) -> Int64? = { url in
            try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        },
        requestedTemporaryOverride: Bool = false,
        progress: @escaping @Sendable (_ completedBytes: Int64, _ totalBytes: Int64) -> Void = { _, _ in }
    ) async -> CoreMaterializationOutcome {
        guard !item.isDirectory, item.size >= 0, !item.contentVersion.isEmpty else {
            return .failed(code: "invalidMaterializationItem")
        }
        let (requiredDiskBytes, diskBytesOverflowed) = item.size.multipliedReportingOverflow(by: 2)
        guard !diskBytesOverflowed else {
            return .failed(code: "materializationSizeOverflow")
        }
        guard let paths = paths ?? (try? SharedContainerPaths.resolve()) else {
            return .configurationUnavailable
        }
        let started = Date()
        if let persistedSnapshot = try? SharedSnapshotStore(snapshotURL: paths.snapshot).readProviderMetadata(),
            persistedSnapshot.folders.contains(where: { $0.id == item.folderID }),
            UniqueFolderIdentityIndex(persistedSnapshot.folders).folder(item.folderID) == nil
        {
            return .failed(code: "duplicate_folder")
        }
        if item.availability == .local || item.availability == .uploading || item.availability == .conflict,
            let local = await materializeLocalCopy(
                item, to: destination, trigger: trigger, paths: paths,
                destinationAvailableCapacity: destinationAvailableCapacity, progress: progress)
        {
            return local
        }
        // A File Provider request for an item with local, unuploaded bytes is
        // operation-specific destructive state: downloading the remote copy
        // could replace those bytes. This proof is carried by the exact indexed
        // item, so reject it before opening even the configuration control plane.
        if item.hasUnuploadedChanges {
            return Self.recordMaterializationPolicyFailure(
                .denied([.unuploadedChanges]),
                trigger: trigger,
                startedAt: started,
                paths: paths,
                networkTotals: nil
            )
        }
        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let lease: CoreOwnerLease
        do {
            lease = try await coordinator.acquire(as: Self.role(for: trigger))
        } catch let error as CoreOwnershipError {
            let isBusy = error == .ownedByAnotherProcess || error == .alreadyOwnedByThisInstance
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: started,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: isBusy ? .coreBusy : .failed,
                    failureCode: isBusy ? nil : Self.failureCode(for: error)
                )
            )
            return isBusy ? .coreBusy : .failed(code: Self.failureCode(for: error))
        } catch {
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: started,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: .failed,
                    failureCode: "coreOwnershipFailed"
                )
            )
            return .failed(code: "coreOwnershipFailed")
        }

        let liveEnvironment: @Sendable () async -> SyncEnvironmentSnapshot
        if let currentEnvironment {
            liveEnvironment = currentEnvironment
        } else {
            #if os(iOS)
                liveEnvironment = {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            #else
                liveEnvironment = { environment }
            #endif
        }
        let ownerMetadataURL = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        let client = clientFactory()
        var temporaryURL: URL?
        var sessionOpen = false
        var networkTotals: CoreNetworkTransferTotals?
        var validatedClosedBudgetBytes: Int64?
        var prepared: PreparedNetworkSession?
        let policyMonitorState = NetworkCorePolicyMonitorState()
        var policyMonitor: Task<Void, Never>?
        let expensiveObservation = NetworkExpenseObservation()
        do {
            let configuration = try await Self.refreshCanonicalConfiguration(
                client: client,
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
            let folderIndex = UniqueFolderIdentityIndex(configuration.snapshot.folders)
            guard folderIndex.folder(item.folderID) != nil else {
                let code =
                    configuration.snapshot.folders.contains(where: { $0.id == item.folderID })
                    ? "duplicate_folder" : "folder_not_found"
                throw CoreClientError.coreRejected(code)
            }
            try Self.recoverStaleAccounting(
                paths: paths,
                activeOwnerID: lease.instanceID,
                trigger: trigger
            )
            let folderContext = try FolderIncarnationStore(url: paths.folderIncarnations)
                .policyContext(for: item.folderID)
            let initialEnvironment = Self.materializationEnvironment(
                await liveEnvironment(),
                item: item,
                destination: destination,
                availableCapacity: destinationAvailableCapacity
            )
            expensiveObservation.observe(initialEnvironment.network.isExpensive)
            let sessionID = UUID()
            let taskID = Self.materializationCommandID(for: item, kind: .materialize)
            let networkPreparation = try Self.prepareNetworkSession(
                taskID: taskID,
                sessionID: sessionID,
                folderContext: folderContext,
                configurationRevision: configuration.revision,
                ownerID: lease.instanceID,
                paths: paths,
                environment: initialEnvironment,
                trigger: trigger,
                requestedActions: [.download],
                requestedTemporaryOverride: requestedTemporaryOverride,
                operation: .materialize,
                // Native materialization publishes one managed-root copy, then
                // File Provider receives a second caller-owned copy. Budget for
                // both before either write starts.
                additionalDiskBytes: requiredDiskBytes
            )
            prepared = networkPreparation
            let revalidatePolicy: @Sendable (_ additionalDiskBytes: Int64) async throws -> Void = {
                additionalDiskBytes in
                try Task.checkCancellation()
                let latestEnvironment = Self.materializationEnvironment(
                    await liveEnvironment(),
                    item: item,
                    destination: destination,
                    availableCapacity: destinationAvailableCapacity
                )
                expensiveObservation.observe(latestEnvironment.network.isExpensive)
                try Self.revalidatePreparedNetwork(
                    networkPreparation,
                    paths: paths,
                    environment: latestEnvironment,
                    trigger: trigger,
                    requestedActions: [.download],
                    requestedTemporaryOverride: requestedTemporaryOverride,
                    additionalDiskBytes: additionalDiskBytes
                )
            }
            try await revalidatePolicy(requiredDiskBytes)
            try await coordinator.validate(lease)
            _ = try await client.openNetworkSession(
                configurationDirectory: paths.coreConfiguration,
                dataDirectory: paths.coreData,
                sessionID: sessionID,
                plan: networkPreparation.plan
            )
            sessionOpen = true
            try Self.beginAccounting(networkPreparation, ownerID: lease.instanceID)
            policyMonitor = Self.startNetworkCorePolicyMonitor(
                client: client,
                state: policyMonitorState,
                validate: { try await revalidatePolicy(0) }
            )
            let materializeCommand = CoreCommand(
                id: taskID,
                kind: .materialize,
                folderID: item.folderID,
                itemID: item.id,
                arguments: ["contentVersion": item.contentVersion.base64EncodedString()],
                folderIncarnationDigest: folderContext.folderIncarnationDigest,
                trigger: trigger,
                createdAt: started
            )
            try await withTaskCancellationHandler {
                try await client.execute(materializeCommand)
                try Task.checkCancellation()
                try await client.acknowledgeCommand(materializeCommand.id)
            } onCancel: {
                client.requestCancellation()
            }
            temporaryURL = try await withTaskCancellationHandler {
                try await Self.streamMaterialization(
                    item,
                    destination: destination,
                    client: client,
                    revalidatePolicy: revalidatePolicy,
                    progress: progress
                )
            } onCancel: {
                client.requestCancellation()
            }
            try Task.checkCancellation()
            try policyMonitorState.validate()
            let proposedSnapshot = try await client.snapshot()
            _ = try await client.closeExplicitSession()
            sessionOpen = false
            networkTotals = try await client.networkTransferTotals()
            validatedClosedBudgetBytes = try Self.validatedBudgetUsedBytes(
                networkTotals,
                prepared: networkPreparation
            )
            await Self.stopNetworkCorePolicyMonitor(policyMonitor)
            policyMonitor = nil
            try policyMonitorState.validate()
            try Task.checkCancellation()
            // This asynchronous checkpoint runs only after the bridge has fully
            // drained, and immediately before fencing plus the synchronous,
            // no-overwrite rename. A live policy change therefore cannot commit
            // bytes that were fetched under an obsolete environment decision.
            try await revalidatePolicy(0)
            try await coordinator.validate(lease)
            try Task.checkCancellation()
            let previous = try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
            _ = try await Self.persist(
                Self.mergedNetworkSnapshot(
                    proposedSnapshot,
                    targetFolderID: item.folderID,
                    preservingSiblingsFrom: previous
                ),
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
            guard let completedTemporaryURL = temporaryURL else {
                throw CoreClientError.invalidResponse("materialization_temporary_missing")
            }
            try Self.commitMaterialization(completedTemporaryURL, to: destination)
            temporaryURL = nil
            guard let exactBudgetBytes = validatedClosedBudgetBytes else {
                throw CoreClientError.invalidResponse("network_transfer_budget")
            }
            if let projection = try Self.settleAccounting(
                networkPreparation,
                ownerID: lease.instanceID,
                exactBytes: expensiveObservation.hasSeenExpensive ? exactBudgetBytes : 0
            ) {
                try Self.projectPendingAccountingHistory(
                    store: networkPreparation.accountingStore,
                    paths: paths,
                    trigger: trigger,
                    exactRecord: .init(
                        id: projection.id,
                        trigger: trigger,
                        startedAt: started,
                        endedAt: .now,
                        transferredBytes: item.size,
                        networkReceivedBytes: networkTotals?.receivedBytes,
                        networkSentBytes: networkTotals?.sentBytes,
                        endReason: .completed
                    )
                )
            } else {
                try SyncRunHistory(url: paths.history).append(
                    .init(
                        trigger: trigger,
                        startedAt: started,
                        endedAt: .now,
                        transferredBytes: item.size,
                        networkReceivedBytes: networkTotals?.receivedBytes,
                        networkSentBytes: networkTotals?.sentBytes,
                        endReason: .completed
                    )
                )
            }
            await coordinator.release()
            return .completed(
                transferredBytes: item.size,
                snapshotGeneration: item.generation
            )
        } catch {
            let primaryError = policyMonitorState.failure() ?? error
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            if sessionOpen { client.requestCancellation() }
            let drained = sessionOpen ? await Self.drainExplicitSession(client) : true
            sessionOpen = false
            if drained {
                networkTotals = try? await client.networkTransferTotals()
                if let prepared {
                    validatedClosedBudgetBytes = try? Self.validatedBudgetUsedBytes(
                        networkTotals,
                        prepared: prepared
                    )
                }
            }
            await Self.stopNetworkCorePolicyMonitor(policyMonitor)
            policyMonitor = nil
            let disposition = Self.historyDisposition(for: primaryError)
            let historyEndReason: SyncRunEndReason = drained ? disposition.endReason : .failed
            let historyFailureCode = drained ? disposition.failureCode : "coreStopFailed"
            var accountingFailure = false
            if let prepared {
                do {
                    try Self.recordNetworkAccountingAndHistory(
                        prepared: prepared,
                        ownerID: lease.instanceID,
                        exactBudgetBytes: validatedClosedBudgetBytes.map {
                            expensiveObservation.hasSeenExpensive ? $0 : 0
                        },
                        networkTotals: networkTotals,
                        trigger: trigger,
                        startedAt: started,
                        paths: paths,
                        endReason: historyEndReason,
                        failureCode: historyFailureCode
                    )
                } catch {
                    accountingFailure = true
                }
            } else {
                try? SyncRunHistory(url: paths.history).append(
                    .init(
                        trigger: trigger,
                        startedAt: started,
                        endedAt: .now,
                        transferredBytes: networkTotals?.totalBytes ?? 0,
                        networkReceivedBytes: networkTotals?.receivedBytes,
                        networkSentBytes: networkTotals?.sentBytes,
                        endReason: historyEndReason,
                        failureCode: historyFailureCode
                    )
                )
            }
            guard drained else {
                await coordinator.release()
                return .failed(code: "coreStopFailed")
            }
            if accountingFailure {
                await coordinator.release()
                return .failed(code: "transferAccountingFailed")
            }
            if let policyError = primaryError as? NetworkCorePolicyError {
                let outcome: CoreMaterializationOutcome
                switch policyError {
                case .denied(let reasons): outcome = .policyDenied(reasons: reasons)
                case .configurationUnavailable:
                    outcome = .failed(code: "policyConfigurationUnavailable")
                }
                await coordinator.release()
                return outcome
            }
            let code = Self.failureCode(for: primaryError)
            await coordinator.release()
            return .failed(code: code)
        }
    }

    /// Local Files delivery is not a transfer opportunity. It never starts
    /// peers or consults network/power gates, while retaining native block
    /// verification, canonical scope, cancellation, disk and owner fences.
    private func materializeLocalCopy(
        _ item: IndexedItem, to destination: URL, trigger: SyncTrigger,
        paths: SharedContainerPaths,
        destinationAvailableCapacity: @escaping @Sendable (URL) -> Int64?,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> CoreMaterializationOutcome? {
        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let lease: CoreOwnerLease
        do { lease = try await coordinator.acquire(as: Self.role(for: trigger)) } catch let error as CoreOwnershipError
        {
            if error == .ownedByAnotherProcess || error == .alreadyOwnedByThisInstance { return .coreBusy }
            return .failed(code: Self.failureCode(for: error))
        } catch { return .failed(code: "coreOwnershipFailed") }
        let client = clientFactory()
        var opened = false
        var temporary: URL?
        do {
            let configuration = try await Self.refreshCanonicalConfiguration(
                client: client, paths: paths,
                lease: lease, coordinator: coordinator,
                ownerMetadataURL: CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock))
            guard UniqueFolderIdentityIndex(configuration.snapshot.folders).folder(item.folderID) != nil else {
                throw CoreClientError.coreRejected("folder_not_found")
            }
            let context = try FolderIncarnationStore(url: paths.folderIncarnations).policyContext(for: item.folderID)
            let policy = try SyncPolicyStore(url: paths.policy).resolvedPolicy(for: context)
            let capacity = destinationAvailableCapacity(destination.deletingLastPathComponent()) ?? 0
            guard item.size <= max(0, capacity - min(capacity, policy.minimumFreeDiskBytes)) else {
                await coordinator.release()
                return .policyDenied(reasons: [.insufficientDisk])
            }
            let plan = try CoreNetworkSessionPlan(
                taskID: UUID(), folderID: item.folderID,
                expectedConfigurationRevision: configuration.revision,
                maximumNetworkBytes: CoreNetworkByteLimit(byteCount: 0), operation: .localContent)
            try Task.checkCancellation()
            _ = try await client.openNetworkSession(
                configurationDirectory: paths.coreConfiguration, dataDirectory: paths.coreData,
                sessionID: UUID(), plan: plan)
            opened = true
            let checkpoint: @Sendable (Int64) async throws -> Void = { _ in
                try Task.checkCancellation()
                try await coordinator.validate(lease)
                guard
                    try FolderIncarnationStore(url: paths.folderIncarnations).policyContext(for: item.folderID)
                        == context
                else {
                    throw CoreClientError.coreRejected("folder_incarnation_mismatch")
                }
                guard
                    try SharedSnapshotStore(snapshotURL: paths.snapshot).readProviderMetadata()?.configurationRevision
                        == configuration.revision
                else {
                    throw CoreClientError.coreRejected("configuration_revision_mismatch")
                }
            }
            temporary = try await withTaskCancellationHandler {
                if item.size == 0 {
                    _ = try await client.readRange(
                        CoreReadRangeRequest(
                            folderID: item.folderID, itemID: item.id,
                            relativePath: item.relativePath, contentVersion: item.contentVersion, offset: 0, length: 0))
                }
                return try await Self.streamMaterialization(
                    item, destination: destination, client: client, revalidatePolicy: checkpoint, progress: progress)
            } onCancel: {
                client.requestCancellation()
            }
            let proposed = try await client.snapshot()
            let receipt = try await client.closeExplicitSession()
            opened = false
            guard receipt.configurationRevision == configuration.revision,
                let totals = try await client.networkTransferTotals(),
                totals.totalBytes == 0, totals.matchesNetworkSessionBudget(maximumNetworkBytes: "0")
            else { throw CoreClientError.invalidResponse("local_read_network_budget") }
            try await checkpoint(0)
            _ = try await Self.persist(
                Self.mergedNetworkSnapshot(
                    proposed, targetFolderID: item.folderID,
                    preservingSiblingsFrom: try SharedSnapshotStore(snapshotURL: paths.snapshot).read()),
                paths: paths, lease: lease, coordinator: coordinator,
                ownerMetadataURL: CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock))
            guard let output = temporary else {
                throw CoreClientError.invalidResponse("materialization_temporary_missing")
            }
            try Self.commitMaterialization(output, to: destination)
            temporary = nil
            await coordinator.release()
            return .completed(transferredBytes: item.size, snapshotGeneration: item.generation)
        } catch {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            let drained = opened ? await Self.drainExplicitSession(client) : true
            await coordinator.release()
            guard drained else { return .failed(code: "coreStopFailed") }
            if case CoreClientError.coreRejected("local_content_unavailable") = error { return nil }
            return .failed(code: Self.failureCode(for: error))
        }
    }

    private static let materializationChunkSize = 1 << 20

    private static func materializationCommandID(
        for item: IndexedItem,
        kind: CoreCommandKind
    ) -> UUID {
        var input = Data("psy-materialization-command-v1".utf8)
        for component in [kind.rawValue, item.folderID.rawValue, item.id] {
            input.append(0)
            input.append(contentsOf: component.utf8)
        }
        input.append(0)
        input.append(item.contentVersion)
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    private static func retentionAwareExecutionKind(
        _ command: CoreCommand,
        snapshot: CoreSnapshot,
        folderContext: FolderPolicyContext,
        paths: SharedContainerPaths
    ) throws -> CoreCommandKind {
        guard command.kind == .sync else { return command.kind }
        let matches = snapshot.folders.filter { $0.id == folderContext.folderID }
        guard matches.count == 1, let folder = matches.first else {
            throw CoreClientError.coreRejected("duplicate_folder")
        }
        if let policy = try ContentRetentionStore(url: paths.contentRetention).folderPolicy(
            folderID: folderContext.folderID,
            folderIncarnationDigest: folderContext.folderIncarnationDigest
        ) {
            return policy.plan.mode == .fullSync || policy.plan.mode == .pinnedOffline
                ? .sync : .upload
        }
        return folder.selectionMode == .full ? .sync : .upload
    }

    private static func streamMaterialization(
        _ item: IndexedItem,
        destination: URL,
        client: any CoreClient,
        revalidatePolicy: @Sendable (_ additionalDiskBytes: Int64) async throws -> Void,
        progress: @escaping @Sendable (_ completedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws -> URL {
        let parent = destination.deletingLastPathComponent()
        var parentStatus = stat()
        guard lstat(parent.path, &parentStatus) == 0,
            parentStatus.st_mode & S_IFMT == S_IFDIR
        else {
            throw CoreClientError.coreRejected("materialization_target_invalid")
        }
        var destinationStatus = stat()
        guard lstat(destination.path, &destinationStatus) != 0, errno == ENOENT else {
            throw CoreClientError.coreRejected("materialization_destination_exists")
        }

        let temporary = parent.appendingPathComponent(
            ".psy-materialize-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        var descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CoreClientError.coreRejected("materialization_write_failed")
        }
        var completed = false
        defer {
            if descriptor >= 0 { close(descriptor) }
            if !completed { try? FileManager.default.removeItem(at: temporary) }
        }

        try reserveMaterializationStorage(item.size, descriptor: descriptor)
        progress(0, item.size)
        var offset: Int64 = 0
        while offset < item.size {
            try Task.checkCancellation()
            // A range is at most 1 MiB, so policy drift is detected before any
            // subsequent bounded read instead of only at the end of a large file.
            // Storage for the entire file was allocated before the first range
            // request. Live checks therefore require only the configured free-
            // space floor; the remaining bytes are already reserved.
            try await revalidatePolicy(0)
            let length = Int(min(Int64(materializationChunkSize), item.size - offset))
            let data = try await client.readRange(
                CoreReadRangeRequest(
                    folderID: item.folderID,
                    itemID: item.id,
                    relativePath: item.relativePath,
                    contentVersion: item.contentVersion,
                    offset: offset,
                    length: length
                )
            )
            try Task.checkCancellation()
            guard data.count == length else {
                throw CoreClientError.invalidResponse("read_range_length")
            }
            do {
                try data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    var written = 0
                    while written < bytes.count {
                        let count = Darwin.write(
                            descriptor,
                            base.advanced(by: written),
                            bytes.count - written
                        )
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else {
                            throw CoreClientError.coreRejected("materialization_write_failed")
                        }
                        written += count
                    }
                }
            } catch let error as CoreClientError {
                throw error
            } catch {
                throw CoreClientError.coreRejected("materialization_write_failed")
            }
            offset += Int64(length)
            progress(offset, item.size)
        }
        try Task.checkCancellation()
        guard fsync(descriptor) == 0 else {
            throw CoreClientError.coreRejected("materialization_write_failed")
        }
        let closeResult = close(descriptor)
        descriptor = -1
        guard closeResult == 0 else {
            throw CoreClientError.coreRejected("materialization_write_failed")
        }
        #if os(iOS)
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: temporary.path
                )
            } catch {
                throw CoreClientError.coreRejected("materialization_protection_failed")
            }
        #endif
        try Task.checkCancellation()
        completed = true
        return temporary
    }

    private static func reserveMaterializationStorage(
        _ size: Int64,
        descriptor: Int32
    ) throws {
        guard size >= 0, size <= Int64(off_t.max) else {
            throw CoreClientError.coreRejected("materialization_reservation_failed")
        }
        guard size > 0 else { return }
        var store = fstore_t(
            fst_flags: UInt32(F_ALLOCATEALL),
            fst_posmode: F_PEOFPOSMODE,
            fst_offset: 0,
            fst_length: off_t(size),
            fst_bytesalloc: 0
        )
        guard fcntl(descriptor, F_PREALLOCATE, &store) == 0 else {
            let code = errno
            if code == ENOSPC || code == EDQUOT {
                throw NetworkCorePolicyError.denied([.insufficientDisk])
            }
            throw CoreClientError.coreRejected("materialization_reservation_failed")
        }
        guard ftruncate(descriptor, off_t(size)) == 0 else {
            let code = errno
            if code == ENOSPC || code == EDQUOT {
                throw NetworkCorePolicyError.denied([.insufficientDisk])
            }
            throw CoreClientError.coreRejected("materialization_reservation_failed")
        }
    }

    private static func materializationEnvironment(
        _ environment: SyncEnvironmentSnapshot,
        item: IndexedItem,
        destination: URL,
        availableCapacity: @Sendable (URL) -> Int64?
    ) -> SyncEnvironmentSnapshot {
        var current = environment
        current.safety.hasConflict = item.availability == .conflict
        current.safety.hasUnuploadedChanges = item.hasUnuploadedChanges
        current.safety.availableDiskBytes = max(
            0,
            availableCapacity(destination.deletingLastPathComponent()) ?? 0
        )
        return current
    }

    /// Cancellation shield for the explicit-session drain boundary. Explicit
    /// runtimes must never fall back to the legacy Stop command.
    private static func drainExplicitSession(_ client: any CoreClient) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            do {
                _ = try await client.closeExplicitSession()
                return true
            } catch {
                return false
            }
        }.value
    }

    private struct CanonicalConfigurationState: Sendable {
        var snapshot: CoreSnapshot
        var revision: String
    }

    /// Opens only the offline configuration wrapper, captures its canonical
    /// devices/folders, fully closes it, then publishes a merged snapshot.
    /// Runtime state is carried forward only when both the canonical revision
    /// and the App-owned exact folder incarnation remained unchanged.
    private static func refreshCanonicalConfiguration(
        client: any CoreClient,
        paths: SharedContainerPaths,
        lease: CoreOwnerLease,
        coordinator: CoreProcessCoordinator,
        ownerMetadataURL: URL,
        requireCanonicalDeviceIdentity: Bool = false
    ) async throws -> CanonicalConfigurationState {
        try Task.checkCancellation()
        try await coordinator.validate(lease)
        var sessionOpen = false
        do {
            let snapshotStore = SharedSnapshotStore(snapshotURL: paths.snapshot)
            let previous = try snapshotStore.read()
            let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
            let incarnationBefore = try incarnationStore.snapshot()
            let opened = try await client.openConfigurationSession(
                configurationDirectory: paths.coreConfiguration,
                dataDirectory: paths.coreData,
                sessionID: UUID()
            )
            sessionOpen = true
            let proposed = try await client.snapshot()
            let receipt = try await client.closeExplicitSession()
            sessionOpen = false
            guard let snapshotRevision = proposed.configurationRevision,
                opened.configurationRevision == snapshotRevision,
                snapshotRevision == receipt.configurationRevision,
                !requireCanonicalDeviceIdentity
                    || (proposed.localDeviceID == opened.deviceID
                        && receipt.deviceID == opened.deviceID)
            else {
                throw CoreClientError.invalidResponse("configuration_revision_changed")
            }
            try Task.checkCancellation()
            try await coordinator.validate(lease)
            _ = try incarnationStore.ensureLegacyConfiguredFolders(
                proposed.folders.map(\.id),
                authoritativeReconciliation: true
            )
            let incarnationAfter = try incarnationStore.snapshot()
            let configurationIdentityUnchanged =
                previous?.configurationRevision == snapshotRevision
                && incarnationBefore == incarnationAfter
            let preservingFolderIDs =
                configurationIdentityUnchanged
                ? Set(proposed.folders.map(\.id)) : []
            let merged = mergedConfigurationSnapshot(
                proposed,
                preservingRuntimeFrom: previous,
                preservingFolderIDs: preservingFolderIDs,
                preserveDeviceRuntime: configurationIdentityUnchanged
            )
            let persisted = try await persist(
                merged,
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
            return CanonicalConfigurationState(
                snapshot: persisted,
                revision: receipt.configurationRevision
            )
        } catch {
            if sessionOpen { _ = await drainExplicitSession(client) }
            throw error
        }
    }

    private static func mergedConfigurationSnapshot(
        _ canonical: CoreSnapshot,
        preservingRuntimeFrom previous: CoreSnapshot?,
        preservingFolderIDs: Set<FolderID>,
        preserveDeviceRuntime: Bool
    ) -> CoreSnapshot {
        guard let previous else { return canonical }
        let previousFolders = Dictionary(uniqueKeysWithValues: previous.folders.map { ($0.id, $0) })
        let previousDevices = Dictionary(uniqueKeysWithValues: previous.devices.map { ($0.id, $0) })
        var merged = canonical
        merged.folders = canonical.folders.map { configured in
            guard preservingFolderIDs.contains(configured.id),
                let runtime = previousFolders[configured.id]
            else { return configured }
            var value = configured
            value.pendingUploadBytes = runtime.pendingUploadBytes
            value.pendingDownloadBytes = runtime.pendingDownloadBytes
            value.error = runtime.error
            return value
        }
        merged.devices = canonical.devices.map { configured in
            guard preserveDeviceRuntime,
                let runtime = previousDevices[configured.id]
            else { return configured }
            var value = configured
            value.state = runtime.state
            value.lastSeen = runtime.lastSeen
            // A configuration session has no network runtime. Transfer rates
            // are interval samples, not durable device attributes, so carrying
            // them across this offline refresh would publish stale activity.
            value.pendingBytes = runtime.pendingBytes
            value.blockingReason = runtime.blockingReason
            return value
        }
        merged.items = previous.items.filter { preservingFolderIDs.contains($0.folderID) }
        // Tombstones carry no folder identity. Preserve them only when every
        // previously configured folder is proven to be the exact same
        // incarnation; otherwise a remove/re-add could resurrect stale state.
        let previousFolderIDs = Set(previous.folders.map(\.id))
        let canonicalFolderIDs = Set(canonical.folders.map(\.id))
        if previousFolderIDs == canonicalFolderIDs,
            preservingFolderIDs == canonicalFolderIDs
        {
            merged.tombstones = previous.tombstones
        }
        return merged
    }

    private static func mergedNetworkSnapshot(
        _ targetSnapshot: CoreSnapshot,
        targetFolderID: FolderID,
        preservingSiblingsFrom previous: CoreSnapshot?
    ) -> CoreSnapshot {
        guard let previous else { return targetSnapshot }
        let configuredFolderIDs = Set(targetSnapshot.folders.map(\.id))
        let previousFolders = Dictionary(uniqueKeysWithValues: previous.folders.map { ($0.id, $0) })
        let previousDevices = Dictionary(uniqueKeysWithValues: previous.devices.map { ($0.id, $0) })
        var merged = targetSnapshot
        merged.folders = targetSnapshot.folders.map { configured in
            guard configured.id != targetFolderID,
                let runtime = previousFolders[configured.id]
            else { return configured }
            var value = configured
            value.pendingUploadBytes = runtime.pendingUploadBytes
            value.pendingDownloadBytes = runtime.pendingDownloadBytes
            value.error = runtime.error
            return value
        }
        merged.devices = targetSnapshot.devices.map { configured in
            guard let runtime = previousDevices[configured.id] else { return configured }
            var value = configured
            value.state = runtime.state
            value.lastSeen = runtime.lastSeen
            // Keep the rates from the just-closed network snapshot. Devices
            // outside that scoped runtime are projected as zero by the bridge;
            // never resurrect an older interval sample from persisted state.
            value.pendingBytes = runtime.pendingBytes
            value.blockingReason = runtime.blockingReason
            return value
        }
        merged.items =
            previous.items.filter {
                $0.folderID != targetFolderID && configuredFolderIDs.contains($0.folderID)
            } + targetSnapshot.items.filter { $0.folderID == targetFolderID }
        merged.tombstones = Array(Set(previous.tombstones + targetSnapshot.tombstones))
        let siblingPendingFolders = previous.pendingFolders.filter {
            $0.folderID != targetFolderID && configuredFolderIDs.contains($0.folderID)
        }
        merged.pendingFolders =
            siblingPendingFolders
            + targetSnapshot.pendingFolders.filter { $0.folderID == targetFolderID }
        return merged
    }

    private struct PreparedPendingFolderDiscovery: Sendable {
        var plan: PendingFolderDiscoveryPlan
        var binding: TransferAccountingGrantBinding
        var policyDocument: SyncPolicyDocumentV2
        var accountingStore: TransferAccountingStore
        var reservation: TransferAccountingReservation
    }

    private static let pendingDiscoveryPollInterval: TimeInterval = 0.1
    private static let pendingDiscoveryTimeout: TimeInterval = 15
    private static let pendingDiscoveryMaximumCaptureAttempts = 151
    private static let pendingDiscoveryAccountingDigestDomain =
        "psy-pending-folder-discovery-accounting-v1"
    private static let pendingDiscoveryRequestedActions: Set<SyncAction> = [
        .discover, .exchangeIndex,
    ]

    private static func preparePendingFolderDiscovery(
        taskID: UUID,
        sessionID: UUID,
        offeringDeviceID: DeviceID,
        configurationRevision: String,
        ownerID: UUID,
        paths: SharedContainerPaths,
        environment: SyncEnvironmentSnapshot,
        trigger: SyncTrigger,
        requestedTemporaryOverride: Bool,
        at date: Date
    ) throws -> PreparedPendingFolderDiscovery {
        let document: SyncPolicyDocumentV2
        do {
            document = try SyncPolicyStore(url: paths.policy).loadDocument()
        } catch {
            throw NetworkCorePolicyError.configurationUnavailable
        }
        let accountingStore = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
        let accountingScopeID = pendingDiscoveryAccountingScopeID(
            offeringDeviceID: offeringDeviceID
        )
        let accountingScopeDigest = pendingDiscoveryAccountingDigest(
            offeringDeviceID: offeringDeviceID,
            configurationRevision: configurationRevision
        )
        let provisionalBinding = TransferAccountingGrantBinding(
            folderID: accountingScopeID,
            folderIncarnationDigest: accountingScopeDigest,
            taskID: taskID,
            sessionID: sessionID,
            planDigest: String(repeating: "0", count: 64)
        )
        let usage = try accountingStore.usage(for: provisionalBinding, at: date)
        try validatePendingFolderDiscoveryPolicy(
            document: document,
            environment: environment,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            globalAlreadyTransferredBytes: usage.effectiveBytes
        )

        let grant = pendingDiscoveryGrant(
            policy: document.global,
            globalAlreadyTransferredBytes: usage.effectiveBytes
        )
        guard grant > 0 else {
            if document.global.maxExpensiveRunBytes == 0 {
                throw NetworkCorePolicyError.denied([.runTransferLimit])
            }
            throw NetworkCorePolicyError.denied([.dailyTransferLimit])
        }
        let plan = try PendingFolderDiscoveryPlan(
            taskID: taskID,
            offeringDeviceID: offeringDeviceID,
            expectedConfigurationRevision: configurationRevision,
            maximumNetworkBytes: grant
        )
        let binding = TransferAccountingGrantBinding(
            folderID: accountingScopeID,
            folderIncarnationDigest: accountingScopeDigest,
            taskID: taskID,
            sessionID: sessionID,
            planDigest: plan.planDigest
        )
        let reservation: TransferAccountingReservation
        do {
            reservation = try accountingStore.reserve(
                ownerID: ownerID,
                binding: binding,
                grantBytes: grant,
                runLimitBytes: document.global.maxExpensiveRunBytes,
                globalDailyLimitBytes: document.global.dailyExpensiveBytes,
                folderDailyLimitBytes: nil,
                expiresAt: date.addingTimeInterval(networkReservationLifetime),
                at: date
            )
        } catch let error as TransferAccountingError {
            switch error {
            case .dailyLimitExceeded:
                throw NetworkCorePolicyError.denied([.dailyTransferLimit])
            case .runLimitExceeded:
                throw NetworkCorePolicyError.denied([.runTransferLimit])
            default:
                throw error
            }
        }
        return PreparedPendingFolderDiscovery(
            plan: plan,
            binding: binding,
            policyDocument: document,
            accountingStore: accountingStore,
            reservation: reservation
        )
    }

    private static func validatePendingFolderDiscoveryCheckpoint(
        _ prepared: PreparedPendingFolderDiscovery,
        paths: SharedContainerPaths,
        lease: CoreOwnerLease,
        coordinator: CoreProcessCoordinator,
        expectedConfigurationRevision: String,
        expectedLocalDeviceID: DeviceID,
        offeringDeviceID: DeviceID,
        environment: SyncEnvironmentSnapshot,
        trigger: SyncTrigger,
        requestedTemporaryOverride: Bool,
        at date: Date
    ) async throws {
        guard date.timeIntervalSince1970.isFinite else {
            throw CoreClientError.invalidResponse("discovery_clock")
        }
        try Task.checkCancellation()
        try await coordinator.validate(lease)
        guard let snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read(),
            snapshot.configurationRevision == expectedConfigurationRevision,
            snapshot.localDeviceID == expectedLocalDeviceID
        else {
            throw CoreClientError.coreRejected("configuration_revision_mismatch")
        }
        guard let targetDevice = snapshot.devices.first(where: { $0.id == offeringDeviceID }) else {
            throw CoreClientError.coreRejected("offering_device_not_configured")
        }
        guard !targetDevice.isPaused, targetDevice.state != .paused else {
            throw CoreClientError.coreRejected("offering_device_paused")
        }

        let document: SyncPolicyDocumentV2
        do {
            document = try SyncPolicyStore(url: paths.policy).loadDocument()
        } catch {
            throw NetworkCorePolicyError.configurationUnavailable
        }
        guard
            document.budgetTimeZoneIdentifier
                == prepared.policyDocument.budgetTimeZoneIdentifier
        else {
            throw NetworkCorePolicyError.configurationUnavailable
        }
        let runUsage = try prepared.accountingStore.runUsage(for: prepared.binding)
        guard !runUsage.isFinished,
            runUsage.committedBytes == 0,
            runUsage.activeReservedBytes == prepared.reservation.grantBytes
        else {
            throw CoreClientError.invalidResponse("pending_discovery_accounting_binding")
        }
        let usage = try prepared.accountingStore.usage(for: prepared.binding, at: date)
        guard usage.dayKey == prepared.reservation.dayKey else {
            throw CoreClientError.coreRejected("budget_day_changed")
        }
        let baseline = max(0, usage.effectiveBytes - prepared.reservation.grantBytes)
        try validatePendingFolderDiscoveryPolicy(
            document: document,
            environment: environment,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            globalAlreadyTransferredBytes: baseline
        )
        let currentGrant = pendingDiscoveryGrant(
            policy: document.global,
            globalAlreadyTransferredBytes: baseline
        )
        guard currentGrant >= prepared.reservation.grantBytes else {
            if let runLimit = document.global.maxExpensiveRunBytes,
                runLimit < prepared.reservation.grantBytes
            {
                throw NetworkCorePolicyError.denied([.runTransferLimit])
            }
            throw NetworkCorePolicyError.denied([.dailyTransferLimit])
        }
        try await coordinator.validate(lease)
    }

    private static func validatePendingFolderDiscoveryPolicy(
        document: SyncPolicyDocumentV2,
        environment: SyncEnvironmentSnapshot,
        trigger: SyncTrigger,
        requestedTemporaryOverride: Bool,
        globalAlreadyTransferredBytes: Int64
    ) throws {
        var current = environment
        current.transfer.alreadyTransferredTodayBytes = globalAlreadyTransferredBytes
        let decision = SyncPolicyEngine().evaluate(
            current.policyInput(
                trigger: trigger,
                requestedActions: pendingDiscoveryRequestedActions,
                requestedTemporaryOverride: requestedTemporaryOverride,
                safetyScope: .networkCoreRuntime
            ),
            policy: document.global,
            calendar: try document.fixedBudgetCalendar()
        )
        guard decision.blockedActions.isEmpty else {
            var reasons: [PolicyBlockReason] = []
            for reason in decision.explanations.map(\.reason) where !reasons.contains(reason) {
                reasons.append(reason)
            }
            throw NetworkCorePolicyError.denied(reasons)
        }
    }

    private static func pendingDiscoveryGrant(
        policy: SyncPolicy,
        globalAlreadyTransferredBytes: Int64
    ) -> Int64 {
        var limits = [PendingFolderDiscoveryPlan.maximumAllowedNetworkBytes]
        if let runLimit = policy.maxExpensiveRunBytes {
            limits.append(max(0, runLimit))
        }
        if let dailyLimit = policy.dailyExpensiveBytes {
            limits.append(
                max(0, dailyLimit - min(dailyLimit, globalAlreadyTransferredBytes))
            )
        }
        return limits.min() ?? 0
    }

    /// TransferAccountingStore is intentionally folder-keyed. This synthetic,
    /// device-scoped key is only a durable accounting namespace: discovery
    /// never resolves a folder override or claims an App folder incarnation.
    private static func pendingDiscoveryAccountingScopeID(
        offeringDeviceID: DeviceID
    ) -> FolderID {
        let digest = SHA256.hash(data: Data(offeringDeviceID.rawValue.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return FolderID(rawValue: "pending-discovery-\(digest.prefix(46))")!
    }

    private static func pendingDiscoveryAccountingDigest(
        offeringDeviceID: DeviceID,
        configurationRevision: String
    ) -> String {
        var material = Data(pendingDiscoveryAccountingDigestDomain.utf8)
        for value in [offeringDeviceID.rawValue, configurationRevision] {
            material.append(0)
            material.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private static func validatePendingFolderDiscoveryCapture(
        _ capture: PendingFolderDiscoveryCaptureReceipt,
        configuration: CoreSnapshot,
        configurationRevision: String,
        offeringDeviceID: DeviceID,
        now: Date
    ) throws {
        guard capture.generation > 0,
            capture.configurationRevision == configurationRevision,
            capture.offeringDeviceID == offeringDeviceID,
            CoreSessionDigest.isCanonicalStableVersion(capture.connectionEpoch),
            capture.observedAt.timeIntervalSince1970.isFinite,
            capture.observedAt.timeIntervalSince(now) <= 1,
            now.timeIntervalSince(capture.observedAt)
                <= PendingFolderDiscoveryCaptureReceipt.maximumObservationAge + 1,
            capture.offers.count <= PendingFolderDiscoveryCaptureReceipt.maximumOffers
        else {
            throw CoreClientError.coreRejected("pending_folder_discovery_scope")
        }
        let configuredFolderIDs = Set(configuration.folders.map(\.id))
        var folderIDs = Set<FolderID>()
        for offer in capture.offers {
            guard folderIDs.insert(offer.folderID).inserted,
                !configuredFolderIDs.contains(offer.folderID),
                offer.offeringDeviceID == offeringDeviceID,
                offer.connectionEpoch == capture.connectionEpoch,
                offer.observedAt == capture.observedAt,
                offer.lastSeen.timeIntervalSince1970.isFinite
            else {
                throw CoreClientError.coreRejected("pending_folder_discovery_scope")
            }
            do {
                _ = try PendingFolderOffer(
                    folderID: offer.folderID,
                    label: offer.label,
                    offeringDeviceID: offer.offeringDeviceID,
                    lastSeen: offer.lastSeen,
                    offerVersion: offer.offerVersion,
                    receiveEncrypted: offer.receiveEncrypted,
                    remoteEncrypted: offer.remoteEncrypted,
                    requiresManagedLocalPath: true,
                    requiresExplicitDeviceSelection: true
                )
            } catch {
                throw CoreClientError.coreRejected("pending_folder_discovery_scope")
            }
        }
    }

    private static func validatePendingFolderDiscoveryProjection(
        _ capture: PendingFolderDiscoveryCaptureReceipt,
        snapshot: CoreSnapshot
    ) throws {
        let projected = snapshot.pendingFolders.filter {
            $0.offeringDeviceID == capture.offeringDeviceID
        }
        guard projected.count == capture.offers.count else {
            throw CoreClientError.coreRejected("pending_folder_discovery_snapshot_scope")
        }
        for offer in capture.offers {
            guard let summary = projected.first(where: { $0.folderID == offer.folderID }),
                summary.label == offer.label,
                summary.lastSeen == offer.lastSeen,
                summary.offerVersion == offer.offerVersion,
                summary.receiveEncrypted == offer.receiveEncrypted,
                summary.remoteEncrypted == offer.remoteEncrypted,
                summary.requiresManagedLocalPath,
                summary.requiresExplicitDeviceSelection,
                summary.evidenceSource == .durableSummary,
                summary.requiresNetworkRevalidation
            else {
                throw CoreClientError.coreRejected("pending_folder_discovery_snapshot_scope")
            }
        }
        if !capture.offers.isEmpty, !snapshot.pendingFoldersAvailable {
            throw CoreClientError.coreRejected("pending_folder_discovery_snapshot_scope")
        }
        if capture.truncated,
            !snapshot.pendingFoldersAvailable || !snapshot.pendingFoldersTruncated
        {
            throw CoreClientError.coreRejected("pending_folder_discovery_snapshot_scope")
        }
    }

    private static func validatedPendingDiscoveryBytes(
        _ totals: CoreNetworkTransferTotals?,
        prepared: PreparedPendingFolderDiscovery
    ) throws -> Int64 {
        guard let totals,
            totals.matchesNetworkSessionBudget(
                maximumNetworkBytes: prepared.plan.maximumNetworkBytesWireValue
            ),
            totals.budgetLimited,
            totals.budgetLimitBytes == prepared.reservation.grantBytes
        else {
            throw CoreClientError.invalidResponse("network_transfer_budget")
        }
        return totals.budgetUsedBytes
    }

    private struct PreparedPendingFolderObservation: Sendable {
        var plan: PendingFolderObservationPlan
        var binding: TransferAccountingGrantBinding
        var policyDocument: SyncPolicyDocumentV2
        var accountingStore: TransferAccountingStore
        var reservation: TransferAccountingReservation
    }

    private static let pendingObservationPollInterval: TimeInterval = 0.1
    private static let pendingObservationTimeout: TimeInterval = 15
    private static let pendingObservationMaximumCaptureAttempts = 151
    private static let pendingObservationAccountingDigestDomain =
        "psy-pending-folder-observation-accounting-v1"
    private static let pendingObservationRequestedActions: Set<SyncAction> = [
        .discover, .exchangeIndex,
    ]

    private static func preparePendingFolderObservation(
        taskID: UUID,
        sessionID: UUID,
        folderID: FolderID,
        offeringDeviceID: DeviceID,
        configurationRevision: String,
        ownerID: UUID,
        paths: SharedContainerPaths,
        environment: SyncEnvironmentSnapshot,
        trigger: SyncTrigger,
        requestedTemporaryOverride: Bool,
        at date: Date
    ) throws -> PreparedPendingFolderObservation {
        let document: SyncPolicyDocumentV2
        do {
            document = try SyncPolicyStore(url: paths.policy).loadDocument()
        } catch {
            throw NetworkCorePolicyError.configurationUnavailable
        }
        let accountingStore = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
        let syntheticDigest = pendingObservationAccountingDigest(
            folderID: folderID,
            offeringDeviceID: offeringDeviceID,
            configurationRevision: configurationRevision
        )
        let provisionalBinding = TransferAccountingGrantBinding(
            folderID: folderID,
            folderIncarnationDigest: syntheticDigest,
            taskID: taskID,
            sessionID: sessionID,
            planDigest: String(repeating: "0", count: 64)
        )
        let usage = try accountingStore.usage(for: provisionalBinding, at: date)
        try validatePendingFolderObservationPolicy(
            document: document,
            environment: environment,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            globalAlreadyTransferredBytes: usage.effectiveBytes
        )

        let grant = pendingObservationGrant(
            policy: document.global,
            globalAlreadyTransferredBytes: usage.effectiveBytes
        )
        guard grant > 0 else {
            if document.global.maxExpensiveRunBytes == 0 {
                throw NetworkCorePolicyError.denied([.runTransferLimit])
            }
            throw NetworkCorePolicyError.denied([.dailyTransferLimit])
        }
        let plan = try PendingFolderObservationPlan(
            taskID: taskID,
            folderID: folderID,
            offeringDeviceID: offeringDeviceID,
            expectedConfigurationRevision: configurationRevision,
            maximumNetworkBytes: grant
        )
        let binding = TransferAccountingGrantBinding(
            folderID: folderID,
            folderIncarnationDigest: syntheticDigest,
            taskID: taskID,
            sessionID: sessionID,
            planDigest: plan.planDigest
        )
        let reservation: TransferAccountingReservation
        do {
            reservation = try accountingStore.reserve(
                ownerID: ownerID,
                binding: binding,
                grantBytes: grant,
                runLimitBytes: document.global.maxExpensiveRunBytes,
                globalDailyLimitBytes: document.global.dailyExpensiveBytes,
                folderDailyLimitBytes: nil,
                expiresAt: date.addingTimeInterval(networkReservationLifetime),
                at: date
            )
        } catch let error as TransferAccountingError {
            switch error {
            case .dailyLimitExceeded:
                throw NetworkCorePolicyError.denied([.dailyTransferLimit])
            case .runLimitExceeded:
                throw NetworkCorePolicyError.denied([.runTransferLimit])
            default:
                throw error
            }
        }
        return PreparedPendingFolderObservation(
            plan: plan,
            binding: binding,
            policyDocument: document,
            accountingStore: accountingStore,
            reservation: reservation
        )
    }

    private static func validatePendingFolderObservationCheckpoint(
        _ prepared: PreparedPendingFolderObservation,
        paths: SharedContainerPaths,
        lease: CoreOwnerLease,
        coordinator: CoreProcessCoordinator,
        expectedConfigurationRevision: String,
        expectedLocalDeviceID: DeviceID,
        folderID: FolderID,
        offeringDeviceID: DeviceID,
        environment: SyncEnvironmentSnapshot,
        trigger: SyncTrigger,
        requestedTemporaryOverride: Bool,
        at date: Date
    ) async throws {
        guard date.timeIntervalSince1970.isFinite else {
            throw CoreClientError.invalidResponse("observation_clock")
        }
        try Task.checkCancellation()
        try await coordinator.validate(lease)
        guard let snapshot = try SharedSnapshotStore(snapshotURL: paths.snapshot).read(),
            snapshot.configurationRevision == expectedConfigurationRevision,
            snapshot.localDeviceID == expectedLocalDeviceID,
            snapshot.devices.contains(where: { $0.id == offeringDeviceID }),
            !snapshot.folders.contains(where: { $0.id == folderID })
        else {
            throw CoreClientError.coreRejected("configuration_revision_mismatch")
        }

        let document: SyncPolicyDocumentV2
        do {
            document = try SyncPolicyStore(url: paths.policy).loadDocument()
        } catch {
            throw NetworkCorePolicyError.configurationUnavailable
        }
        guard
            document.budgetTimeZoneIdentifier
                == prepared.policyDocument.budgetTimeZoneIdentifier
        else {
            throw NetworkCorePolicyError.configurationUnavailable
        }
        let runUsage = try prepared.accountingStore.runUsage(for: prepared.binding)
        guard !runUsage.isFinished,
            runUsage.committedBytes == 0,
            runUsage.activeReservedBytes == prepared.reservation.grantBytes
        else {
            throw CoreClientError.invalidResponse("pending_observation_accounting_binding")
        }
        let usage = try prepared.accountingStore.usage(for: prepared.binding, at: date)
        guard usage.dayKey == prepared.reservation.dayKey else {
            throw CoreClientError.coreRejected("budget_day_changed")
        }
        let baseline = max(0, usage.effectiveBytes - prepared.reservation.grantBytes)
        try validatePendingFolderObservationPolicy(
            document: document,
            environment: environment,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            globalAlreadyTransferredBytes: baseline
        )
        let currentGrant = pendingObservationGrant(
            policy: document.global,
            globalAlreadyTransferredBytes: baseline
        )
        guard currentGrant >= prepared.reservation.grantBytes else {
            if let runLimit = document.global.maxExpensiveRunBytes,
                runLimit < prepared.reservation.grantBytes
            {
                throw NetworkCorePolicyError.denied([.runTransferLimit])
            }
            throw NetworkCorePolicyError.denied([.dailyTransferLimit])
        }
        try await coordinator.validate(lease)
    }

    private static func validatePendingFolderObservationPolicy(
        document: SyncPolicyDocumentV2,
        environment: SyncEnvironmentSnapshot,
        trigger: SyncTrigger,
        requestedTemporaryOverride: Bool,
        globalAlreadyTransferredBytes: Int64
    ) throws {
        var current = environment
        current.transfer.alreadyTransferredTodayBytes = globalAlreadyTransferredBytes
        let decision = SyncPolicyEngine().evaluate(
            current.policyInput(
                trigger: trigger,
                requestedActions: pendingObservationRequestedActions,
                requestedTemporaryOverride: requestedTemporaryOverride,
                safetyScope: .networkCoreRuntime
            ),
            policy: document.global,
            calendar: try document.fixedBudgetCalendar()
        )
        guard decision.blockedActions.isEmpty else {
            var reasons: [PolicyBlockReason] = []
            for reason in decision.explanations.map(\.reason) where !reasons.contains(reason) {
                reasons.append(reason)
            }
            throw NetworkCorePolicyError.denied(reasons)
        }
    }

    private static func pendingObservationGrant(
        policy: SyncPolicy,
        globalAlreadyTransferredBytes: Int64
    ) -> Int64 {
        var limits = [PendingFolderObservationPlan.maximumAllowedNetworkBytes]
        if let runLimit = policy.maxExpensiveRunBytes {
            limits.append(max(0, runLimit))
        }
        if let dailyLimit = policy.dailyExpensiveBytes {
            limits.append(
                max(0, dailyLimit - min(dailyLimit, globalAlreadyTransferredBytes))
            )
        }
        return limits.min() ?? 0
    }

    private static func pendingObservationAccountingDigest(
        folderID: FolderID,
        offeringDeviceID: DeviceID,
        configurationRevision: String
    ) -> String {
        var material = Data(pendingObservationAccountingDigestDomain.utf8)
        for value in [
            folderID.rawValue,
            offeringDeviceID.rawValue,
            configurationRevision,
        ] {
            material.append(0)
            material.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private static func validatePendingFolderObservationCapture(
        _ capture: PendingFolderObservationCaptureReceipt,
        expectedBinding: CoreExplicitSessionBinding,
        configurationRevision: String,
        folderID: FolderID,
        offeringDeviceID: DeviceID,
        now: Date
    ) throws {
        let proof = capture.proof
        guard capture.generation > 0,
            capture.configurationRevision == configurationRevision,
            proof.configurationRevision == configurationRevision,
            proof.folderID == folderID,
            proof.offeringDeviceID == offeringDeviceID,
            proof.observationSessionID == expectedBinding.sessionIDString,
            proof.observedAt <= proof.expiresAt,
            proof.expiresAt.timeIntervalSince(proof.observedAt)
                == PendingFolderObservationProof.timeToLive,
            proof.expiresAt > now
        else {
            throw CoreClientError.coreRejected("pending_folder_observation_scope")
        }
    }

    private static func validatedPendingObservationBytes(
        _ totals: CoreNetworkTransferTotals?,
        prepared: PreparedPendingFolderObservation
    ) throws -> Int64 {
        guard let totals,
            totals.matchesNetworkSessionBudget(
                maximumNetworkBytes: prepared.plan.maximumNetworkBytesWireValue
            ),
            totals.budgetLimited,
            totals.budgetLimitBytes == prepared.reservation.grantBytes
        else {
            throw CoreClientError.invalidResponse("network_transfer_budget")
        }
        return totals.budgetUsedBytes
    }

    private struct PreparedNetworkSession: Sendable {
        var plan: CoreNetworkSessionPlan
        var folderContext: FolderPolicyContext
        var resolvedPolicy: SyncPolicy
        var policyDocument: SyncPolicyDocumentV2
        var accountingStore: TransferAccountingStore
        var reservation: TransferAccountingReservation?
        var taskMaximumNetworkBytes: Int64?
    }

    private static let networkReservationLifetime: TimeInterval = 30 * 60

    private static func prepareNetworkSession(
        taskID: UUID,
        sessionID: UUID,
        folderContext: FolderPolicyContext,
        configurationRevision: String,
        ownerID: UUID,
        paths: SharedContainerPaths,
        environment: SyncEnvironmentSnapshot,
        trigger: SyncTrigger,
        requestedActions: Set<SyncAction>,
        requestedTemporaryOverride: Bool,
        taskMaximumNetworkBytes: Int64? = nil,
        operation: CoreNetworkSessionOperation,
        additionalDiskBytes: Int64? = nil,
        at date: Date = .now
    ) throws -> PreparedNetworkSession {
        let policyStore = SyncPolicyStore(url: paths.policy)
        let document = try policyStore.loadDocument()
        let resolvedPolicy = try policyStore.resolvedPolicy(for: folderContext)
        let accountingStore = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
        let provisionalBinding = TransferAccountingGrantBinding(
            folderID: folderContext.folderID,
            folderIncarnationDigest: folderContext.folderIncarnationDigest,
            taskID: taskID,
            sessionID: sessionID,
            planDigest: String(repeating: "0", count: 64)
        )
        let usage = try accountingStore.usage(for: provisionalBinding, at: date)
        try validateNetworkPolicy(
            document: document,
            resolvedPolicy: resolvedPolicy,
            environment: environment,
            trigger: trigger,
            requestedActions: requestedActions,
            runtimeActions: operation.runtimePolicyActions,
            requestedTemporaryOverride: requestedTemporaryOverride,
            additionalDiskBytes: additionalDiskBytes,
            globalAlreadyTransferredBytes: usage.effectiveBytes,
            folderAlreadyTransferredBytes: usage.folderEffectiveBytes
        )

        let byteLimit: CoreNetworkByteLimit
        var finiteGrant: Int64?
        let hasPotentialExpensiveCap =
            operation != .localMutation && operation != .localContent
            && (resolvedPolicy.maxExpensiveRunBytes != nil
                || document.global.dailyExpensiveBytes != nil
                || resolvedPolicy.dailyExpensiveBytes != nil
                || taskMaximumNetworkBytes != nil)
        if hasPotentialExpensiveCap {
            var limits: [Int64] = []
            if let taskMaximumNetworkBytes { limits.append(taskMaximumNetworkBytes) }
            if let runLimit = resolvedPolicy.maxExpensiveRunBytes {
                limits.append(runLimit)
            }
            if let globalDailyLimit = document.global.dailyExpensiveBytes {
                limits.append(max(0, globalDailyLimit - min(globalDailyLimit, usage.effectiveBytes)))
            }
            if let folderDailyLimit = resolvedPolicy.dailyExpensiveBytes {
                limits.append(
                    max(
                        0,
                        folderDailyLimit
                            - min(folderDailyLimit, usage.folderEffectiveBytes)
                    )
                )
            }
            finiteGrant = limits.min()
        }
        if operation == .localMutation || operation == .localContent {
            byteLimit = try CoreNetworkByteLimit(byteCount: 0)
        } else if let finiteGrant {
            byteLimit = try CoreNetworkByteLimit(byteCount: finiteGrant)
        } else {
            byteLimit = .unlimited
        }
        let plan = try CoreNetworkSessionPlan(
            taskID: taskID,
            folderID: folderContext.folderID,
            expectedConfigurationRevision: configurationRevision,
            maximumNetworkBytes: byteLimit,
            operation: operation
        )
        let reservation: TransferAccountingReservation?
        if let finiteGrant {
            let binding = TransferAccountingGrantBinding(
                folderID: folderContext.folderID,
                folderIncarnationDigest: folderContext.folderIncarnationDigest,
                taskID: taskID,
                sessionID: sessionID,
                planDigest: plan.planDigest
            )
            reservation = try accountingStore.reserve(
                ownerID: ownerID,
                binding: binding,
                grantBytes: finiteGrant,
                globalDailyLimitBytes: document.global.dailyExpensiveBytes,
                folderDailyLimitBytes: resolvedPolicy.dailyExpensiveBytes,
                expiresAt: date.addingTimeInterval(networkReservationLifetime),
                at: date
            )
        } else {
            reservation = nil
        }
        return PreparedNetworkSession(
            plan: plan,
            folderContext: folderContext,
            resolvedPolicy: resolvedPolicy,
            policyDocument: document,
            accountingStore: accountingStore,
            reservation: reservation,
            taskMaximumNetworkBytes: taskMaximumNetworkBytes
        )
    }

    private static func validateNetworkPolicy(
        document: SyncPolicyDocumentV2,
        resolvedPolicy: SyncPolicy,
        environment: SyncEnvironmentSnapshot,
        trigger: SyncTrigger,
        requestedActions: Set<SyncAction>,
        runtimeActions: Set<SyncAction> = SyncAction.networkCoreRuntimeEnvelope,
        requestedTemporaryOverride: Bool,
        additionalDiskBytes: Int64?,
        globalAlreadyTransferredBytes: Int64,
        folderAlreadyTransferredBytes: Int64
    ) throws {
        let calendar = try document.fixedBudgetCalendar()
        let policiesAndUsage = [
            (document.global, globalAlreadyTransferredBytes),
            (resolvedPolicy, folderAlreadyTransferredBytes),
        ]
        var reasons: [PolicyBlockReason] = []
        for (policy, alreadyTransferred) in policiesAndUsage {
            var current = environment
            current.transfer.alreadyTransferredTodayBytes = alreadyTransferred
            let decision = SyncPolicyEngine().evaluate(
                current.policyInput(
                    trigger: trigger,
                    requestedActions: requestedActions.union(runtimeActions),
                    additionalDiskBytes: additionalDiskBytes,
                    requestedTemporaryOverride: requestedTemporaryOverride,
                    safetyScope: .networkCoreRuntime
                ),
                policy: policy,
                calendar: calendar
            )
            for reason in decision.explanations.map(\.reason) where !reasons.contains(reason) {
                reasons.append(reason)
            }
        }
        guard reasons.isEmpty else { throw NetworkCorePolicyError.denied(reasons) }
    }

    private static func beginAccounting(
        _ prepared: PreparedNetworkSession,
        ownerID: UUID,
        at date: Date = .now
    ) throws {
        guard let reservation = prepared.reservation else { return }
        _ = try prepared.accountingStore.begin(
            reservationID: reservation.id,
            ownerID: ownerID,
            binding: reservation.binding,
            at: date
        )
    }

    private static func validatedBudgetUsedBytes(
        _ totals: CoreNetworkTransferTotals?,
        prepared: PreparedNetworkSession
    ) throws -> Int64 {
        guard let totals,
            totals.matchesNetworkSessionBudget(
                maximumNetworkBytes: prepared.plan.maximumNetworkBytes.wireValue
            )
        else {
            throw CoreClientError.invalidResponse("network_transfer_budget")
        }
        if let reservation = prepared.reservation {
            guard totals.budgetLimited,
                totals.budgetLimitBytes == reservation.grantBytes
            else {
                throw CoreClientError.invalidResponse("network_transfer_budget")
            }
        }
        return totals.budgetUsedBytes
    }

    private static func revalidatePreparedNetwork(
        _ prepared: PreparedNetworkSession,
        paths: SharedContainerPaths,
        environment: SyncEnvironmentSnapshot,
        trigger: SyncTrigger,
        requestedActions: Set<SyncAction>,
        requestedTemporaryOverride: Bool,
        additionalDiskBytes: Int64?
    ) throws {
        let currentContext = try FolderIncarnationStore(url: paths.folderIncarnations)
            .policyContext(for: prepared.folderContext.folderID)
        guard currentContext == prepared.folderContext else {
            throw CoreClientError.coreRejected("folder_incarnation_mismatch")
        }
        let policyStore = SyncPolicyStore(url: paths.policy)
        let document = try policyStore.loadDocument()
        guard document.budgetTimeZoneIdentifier == prepared.policyDocument.budgetTimeZoneIdentifier else {
            throw NetworkCorePolicyError.configurationUnavailable
        }
        let resolvedPolicy = try policyStore.resolvedPolicy(for: prepared.folderContext)
        let provisionalBinding = TransferAccountingGrantBinding(
            folderID: prepared.folderContext.folderID,
            folderIncarnationDigest: prepared.folderContext.folderIncarnationDigest,
            taskID: prepared.plan.taskID,
            sessionID: prepared.reservation?.sessionID ?? UUID(),
            planDigest: prepared.plan.planDigest
        )
        let usage = try prepared.accountingStore.usage(for: provisionalBinding, at: .now)
        let ownGrant = prepared.reservation?.grantBytes ?? 0
        let globalBaseline = max(0, usage.effectiveBytes - ownGrant)
        let folderBaseline = max(0, usage.folderEffectiveBytes - ownGrant)
        try validateNetworkPolicy(
            document: document,
            resolvedPolicy: resolvedPolicy,
            environment: environment,
            trigger: trigger,
            requestedActions: requestedActions,
            runtimeActions: prepared.plan.operation.runtimePolicyActions,
            requestedTemporaryOverride: requestedTemporaryOverride,
            additionalDiskBytes: additionalDiskBytes,
            globalAlreadyTransferredBytes: globalBaseline,
            folderAlreadyTransferredBytes: folderBaseline
        )

        if environment.network.isExpensive,
            let reservation = prepared.reservation
        {
            var currentLimits: [Int64] = []
            if let taskMaximumNetworkBytes = prepared.taskMaximumNetworkBytes {
                currentLimits.append(taskMaximumNetworkBytes)
            }
            if let runLimit = resolvedPolicy.maxExpensiveRunBytes { currentLimits.append(runLimit) }
            if let globalLimit = document.global.dailyExpensiveBytes {
                currentLimits.append(max(0, globalLimit - min(globalLimit, globalBaseline)))
            }
            if let folderLimit = resolvedPolicy.dailyExpensiveBytes {
                currentLimits.append(max(0, folderLimit - min(folderLimit, folderBaseline)))
            }
            guard currentLimits.min().map({ $0 >= reservation.grantBytes }) != false else {
                throw NetworkCorePolicyError.denied([.dailyTransferLimit])
            }
        } else if prepared.reservation == nil, environment.network.isExpensive {
            // An unlimited expensive plan remains valid only while every hard
            // expensive-network cap is still absent. A newly introduced cap
            // cannot be retrofitted into an already-open native limiter.
            if resolvedPolicy.maxExpensiveRunBytes != nil
                || document.global.dailyExpensiveBytes != nil
                || resolvedPolicy.dailyExpensiveBytes != nil
                || prepared.taskMaximumNetworkBytes != nil
            {
                throw NetworkCorePolicyError.denied([.dailyTransferAccountingUnavailable])
            }
        }
    }

    @discardableResult
    private static func settleAccounting(
        _ prepared: PreparedNetworkSession,
        ownerID: UUID,
        exactBytes: Int64?,
        at date: Date = .now
    ) throws -> TransferAccountingHistoryProjection? {
        guard let reservation = prepared.reservation else { return nil }
        return try prepared.accountingStore.settleAndFinalizeRun(
            reservationID: reservation.id,
            ownerID: ownerID,
            binding: reservation.binding,
            outcome: exactBytes.map(TransferAccountingSettlementOutcome.exact)
                ?? .conservative,
            at: date
        )
    }

    private static func recoverStaleAccounting(
        paths: SharedContainerPaths,
        activeOwnerID: UUID,
        trigger: SyncTrigger,
        at date: Date = .now
    ) throws {
        let document = try SyncPolicyStore(url: paths.policy).loadDocument()
        let store = TransferAccountingStore(
            url: paths.transferAccounting,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
        _ = try store.recoverStaleReservations(
            protectedOwnerIDs: [activeOwnerID],
            at: date
        )
        try projectPendingAccountingHistory(store: store, paths: paths, trigger: trigger)
    }

    private static func projectPendingAccountingHistory(
        store: TransferAccountingStore,
        paths: SharedContainerPaths,
        trigger: SyncTrigger,
        exactRecord: SyncRunRecord? = nil
    ) throws {
        let history = SyncRunHistory(url: paths.history)
        let existingIDs = Set(try history.recent(limit: .max).map(\.id))
        for projection in try store.pendingHistoryProjections() {
            if !existingIDs.contains(projection.id) {
                let record: SyncRunRecord
                if let exactRecord, exactRecord.id == projection.id {
                    record = exactRecord
                } else {
                    let conservative = projection.kind != .exact
                    record = SyncRunRecord(
                        id: projection.id,
                        trigger: trigger,
                        startedAt: projection.settledAt,
                        endedAt: projection.settledAt,
                        transferredBytes: projection.chargedBytes,
                        networkReceivedBytes: projection.chargedBytes,
                        networkSentBytes: 0,
                        endReason: conservative ? .failed : .completed,
                        failureCode: conservative ? "transferAccountingConservativeCharge" : nil
                    )
                }
                try history.append(record)
            }
            try store.acknowledgeHistoryProjection(projection.id)
        }
    }

    private nonisolated static func startNetworkCorePolicyMonitor(
        client: any CoreClient,
        state: NetworkCorePolicyMonitorState,
        validate: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    try Task.checkCancellation()
                    try await validate()
                } catch is CancellationError {
                    return
                } catch let error as NetworkCorePolicyError {
                    if state.record(error) { client.requestCancellation() }
                    return
                } catch {
                    if state.record(.configurationUnavailable) {
                        client.requestCancellation()
                    }
                    return
                }
            }
        }
    }

    private nonisolated static func stopNetworkCorePolicyMonitor(
        _ monitor: Task<Void, Never>?
    ) async {
        monitor?.cancel()
        await monitor?.value
    }

    private static func recordMaterializationPolicyFailure(
        _ error: NetworkCorePolicyError,
        trigger: SyncTrigger,
        startedAt: Date,
        paths: SharedContainerPaths,
        networkTotals: CoreNetworkTransferTotals?
    ) -> CoreMaterializationOutcome {
        switch error {
        case .denied(let reasons):
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: startedAt,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: networkTotals?.receivedBytes,
                    networkSentBytes: networkTotals?.sentBytes,
                    endReason: .policyDenied,
                    failureCode: reasons.first?.rawValue
                )
            )
            return .policyDenied(reasons: reasons)
        case .configurationUnavailable:
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: startedAt,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: networkTotals?.receivedBytes,
                    networkSentBytes: networkTotals?.sentBytes,
                    endReason: .failed,
                    failureCode: "policyConfigurationUnavailable"
                )
            )
            return .failed(code: "policyConfigurationUnavailable")
        }
    }

    private static func recordNetworkCorePolicyFailure(
        _ error: NetworkCorePolicyError,
        trigger: SyncTrigger,
        startedAt: Date,
        paths: SharedContainerPaths,
        networkTotals: CoreNetworkTransferTotals?
    ) -> CoreRunOutcome {
        switch error {
        case .denied(let reasons):
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: startedAt,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: networkTotals?.receivedBytes,
                    networkSentBytes: networkTotals?.sentBytes,
                    endReason: .policyDenied,
                    failureCode: reasons.first?.rawValue
                )
            )
            return .policyDenied(reasons: reasons)
        case .configurationUnavailable:
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: startedAt,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: networkTotals?.receivedBytes,
                    networkSentBytes: networkTotals?.sentBytes,
                    endReason: .failed,
                    failureCode: "policyConfigurationUnavailable"
                )
            )
            return .failed(code: "policyConfigurationUnavailable")
        }
    }

    /// Normalizes the externally visible run outcome before accounting can
    /// project a history row. In particular, a live policy monitor failure is
    /// not an unknown Swift error and must never be persisted as the generic
    /// `coreExecutionFailed` code.
    private static func historyDisposition(
        for error: Error,
        cancellationEndReason: SyncRunEndReason = .cancelled
    ) -> (endReason: SyncRunEndReason, failureCode: String) {
        if let policyError = error as? NetworkCorePolicyError {
            switch policyError {
            case .denied(let reasons):
                return (.policyDenied, reasons.first?.rawValue ?? "policyDenied")
            case .configurationUnavailable:
                return (.failed, "policyConfigurationUnavailable")
            }
        }
        if error is CancellationError {
            return (cancellationEndReason, "cancelled")
        }
        return (.failed, failureCode(for: error))
    }

    private static func commitMaterialization(_ temporary: URL, to destination: URL) throws {
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in
                renameatx_np(AT_FDCWD, source, AT_FDCWD, target, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw CoreClientError.coreRejected("materialization_destination_exists")
            }
            throw CoreClientError.coreRejected("materialization_commit_failed")
        }
    }

    @discardableResult
    public func processPending(
        trigger: SyncTrigger,
        paths: SharedContainerPaths? = nil,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: (@Sendable () async -> SyncEnvironmentSnapshot)? = nil,
        requestedTemporaryOverride: Bool = false,
        cancellationContext: CoreRunCancellationContext? = nil
    ) async -> CoreRunOutcome {
        return await processOnePendingExplicitSession(
            trigger: trigger,
            paths: paths,
            environment: environment,
            currentEnvironment: currentEnvironment,
            requestedTemporaryOverride: requestedTemporaryOverride,
            cancellationContext: cancellationContext
        )

    }
    private func processOnePendingExplicitSession(
        trigger: SyncTrigger,
        paths requestedPaths: SharedContainerPaths?,
        environment: SyncEnvironmentSnapshot,
        currentEnvironment: (@Sendable () async -> SyncEnvironmentSnapshot)?,
        requestedTemporaryOverride: Bool,
        cancellationContext: CoreRunCancellationContext?
    ) async -> CoreRunOutcome {
        guard let paths = requestedPaths ?? (try? SharedContainerPaths.resolve()) else {
            return .configurationUnavailable
        }
        let started = wallClock()
        let coordinator = CoreProcessCoordinator(lockURL: paths.coreLock)
        let lease: CoreOwnerLease
        do {
            lease = try await coordinator.acquire(as: Self.role(for: trigger))
        } catch let error as CoreOwnershipError {
            if error == .ownedByAnotherProcess || error == .alreadyOwnedByThisInstance {
                return .coreBusy
            }
            return .failed(code: Self.failureCode(for: error))
        } catch {
            return .failed(code: "coreOwnershipFailed")
        }

        let queue = CoreCommandQueue(root: paths.commandQueue)
        let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
        let policyStore = SyncPolicyStore(url: paths.policy)
        var deniedReasonsByCommand: [UUID: [PolicyBlockReason]] = [:]
        let pendingCommand: CoreCommand?
        do {
            pendingCommand = try queue.nextRunnable(
                at: started,
                folderPriorityResolver: { folderID in
                    guard let context = try? incarnationStore.policyContext(for: folderID),
                        let priority = try? policyStore.queuePriority(for: context)
                    else { return nil }
                    return priority.coreSchedulingPriorityRawValue
                },
                isRunnable: { command in
                    // File Provider callbacks have a much tighter process and disk-write
                    // budget than the App/BGTask owners. They may advance commands created
                    // by File Provider callbacks, but must never opportunistically claim an
                    // unrelated user/background sync from the shared durable queue. App and
                    // BGTask opportunities remain able to drain every trigger class.
                    guard trigger != .fileProvider || command.trigger == .fileProvider else {
                        return false
                    }
                    guard !Self.commandUsesConfigurationSession(command.kind),
                        command.folderID != nil
                    else {
                        // Offline configuration commands and malformed legacy
                        // network commands must be selected so they can either
                        // execute or be terminally retired.
                        return true
                    }
                    guard
                        let reasons = Self.pendingNetworkPolicyDenialReasons(
                            for: command,
                            paths: paths,
                            environment: environment
                        )
                    else {
                        return true
                    }
                    deniedReasonsByCommand[command.id] = reasons
                    return false
                }
            )
        } catch {
            await coordinator.release()
            return .failed(code: "commandQueueUnavailable")
        }
        if pendingCommand == nil, !deniedReasonsByCommand.isEmpty {
            let denied = Set(deniedReasonsByCommand.values.flatMap { $0 })
            let reasons = PolicyBlockReason.allCases.filter { denied.contains($0) }
            let stableReasons = reasons.isEmpty ? [.dailyTransferAccountingUnavailable] : reasons
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: started,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: .policyDenied,
                    failureCode: stableReasons.first?.rawValue
                )
            )
            await coordinator.release()
            return .policyDenied(reasons: stableReasons)
        }
        let cleanupEntry: CompletedCommandCleanupEntry?
        do {
            cleanupEntry =
                pendingCommand == nil
                ? try queue.completedCleanupBatch().first(where: {
                    trigger != .fileProvider || $0.command.trigger == .fileProvider
                }) : nil
        } catch {
            await coordinator.release()
            return .failed(code: "commandQueueUnavailable")
        }
        guard let command = pendingCommand ?? cleanupEntry?.command else {
            let generation = (try? SharedSnapshotStore(snapshotURL: paths.snapshot).read())??.generation ?? 0
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: started,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: .noWork
                )
            )
            await coordinator.release()
            return .completed(processedCommands: 0, snapshotGeneration: generation)
        }
        if !Self.commandUsesConfigurationSession(command.kind), command.folderID == nil {
            let ownerMetadataURL = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
            try? queue.record(
                .init(
                    commandID: command.id,
                    status: .blocked,
                    completedAt: started,
                    ownerEpoch: lease.epoch,
                    instanceID: lease.instanceID,
                    errorCode: "folder_scope_required"
                ),
                at: started,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            try? queue.acknowledge(
                command,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            // This malformed legacy command is rejected before any native
            // session or command ledger write. Retire its App-owned cleanup
            // handoff immediately so it cannot monopolize cleanup-only runs.
            try? queue.retireCompleted(
                command,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: started,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: .failed,
                    failureCode: "folder_scope_required"
                )
            )
            await coordinator.release()
            return .failed(code: "folder_scope_required")
        }

        let liveEnvironment: @Sendable () async -> SyncEnvironmentSnapshot
        if let currentEnvironment {
            liveEnvironment = currentEnvironment
        } else {
            #if os(iOS)
                liveEnvironment = {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            #else
                liveEnvironment = { environment }
            #endif
        }
        let client = clientFactory()
        let outcome: CoreRunOutcome
        if Self.commandUsesConfigurationSession(command.kind) {
            outcome = await Self.runConfigurationCommandExplicit(
                command,
                client: client,
                queue: queue,
                paths: paths,
                trigger: command.trigger,
                startedAt: started,
                retryClock: wallClock,
                lease: lease,
                coordinator: coordinator,
                cleanupEntry: cleanupEntry
            )
        } else {
            outcome = await Self.runNetworkCommandExplicit(
                command,
                client: client,
                queue: queue,
                paths: paths,
                trigger: command.trigger,
                startedAt: started,
                retryClock: wallClock,
                initialEnvironment: environment,
                liveEnvironment: liveEnvironment,
                // A launch opportunity's ambient override is not durable
                // authority for queued work. Until CoreCommand carries a
                // separately audited capability, every replay fails closed.
                requestedTemporaryOverride: false,
                cancellationContext: cancellationContext,
                lease: lease,
                coordinator: coordinator,
                cleanupEntry: cleanupEntry
            )
        }
        await coordinator.release()
        return outcome
    }

    private static func commandUsesConfigurationSession(_ kind: CoreCommandKind) -> Bool {
        switch kind {
        case .addDevice, .editDevice, .removeDevice,
            .acceptDevice, .ignorePendingDevice, .unignorePendingDevice,
            .addFolder, .editFolder, .removeFolder,
            .acceptFolder, .ignorePendingFolder, .unignorePendingFolder,
            .pause, .resume, .disposeRecovery, .disposeRecoveryReviewed:
            return true
        default:
            return false
        }
    }

    /// Read-only scheduler preflight. It resolves policy and accounting for the
    /// exact durable folder incarnation without creating a reservation or
    /// opening either native session mode. A denied high-priority folder can
    /// therefore remain pending without starving an eligible sibling.
    private static func pendingNetworkPolicyDenialReasons(
        for command: CoreCommand,
        paths: SharedContainerPaths,
        environment: SyncEnvironmentSnapshot,
        at date: Date = .now
    ) -> [PolicyBlockReason]? {
        guard let folderID = command.folderID,
            let commandIncarnation = command.folderIncarnationDigest
        else {
            return nil
        }
        let taskPolicyBinding: CoreTaskPolicyBinding?
        do {
            taskPolicyBinding = try command.taskPolicyBinding?.validated(
                commandCreatedAt: command.createdAt,
                trigger: command.trigger,
                now: date
            )
        } catch {
            // Select malformed or expired authority so execution can retire it
            // with a stable terminal result instead of leaving it pending.
            return nil
        }
        do {
            let context = try FolderIncarnationStore(url: paths.folderIncarnations)
                .policyContext(for: folderID)
            guard context.folderIncarnationDigest == commandIncarnation else {
                return [.unresolvedConflict]
            }
            let document = try SyncPolicyStore(url: paths.policy).loadDocument()
            let resolvedPolicy = try document.resolvedPolicy(
                for: folderID,
                folderIncarnationDigest: commandIncarnation
            )
            let accountingStore = TransferAccountingStore(
                url: paths.transferAccounting,
                budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
            )
            let usage = try accountingStore.usage(
                for: TransferAccountingGrantBinding(
                    folderID: folderID,
                    folderIncarnationDigest: commandIncarnation,
                    taskID: command.id,
                    sessionID: command.id,
                    planDigest: String(repeating: "0", count: 64)
                ),
                at: date
            )
            try validateNetworkPolicy(
                document: document,
                resolvedPolicy: resolvedPolicy,
                environment: environment,
                trigger: command.trigger,
                requestedActions: command.kind.requestedSyncActions,
                runtimeActions: command.kind.networkSessionOperation.runtimePolicyActions,
                requestedTemporaryOverride: taskPolicyBinding?.requestsTemporaryOverride ?? false,
                additionalDiskBytes: nil,
                globalAlreadyTransferredBytes: usage.effectiveBytes,
                folderAlreadyTransferredBytes: usage.folderEffectiveBytes
            )
            return nil
        } catch let error as NetworkCorePolicyError {
            switch error {
            case .denied(let reasons): return reasons
            case .configurationUnavailable: return [.dailyTransferAccountingUnavailable]
            }
        } catch {
            return [.dailyTransferAccountingUnavailable]
        }
    }

    private static func commandRequiresExistingFolderIncarnation(_ command: CoreCommand) -> Bool {
        switch command.kind {
        case .editFolder, .removeFolder:
            return true
        case .pause, .resume:
            // Device controls carry itemID and no folder scope. Their stale
            // mutation fence is the canonical configuration revision only.
            return command.folderID != nil
        default:
            return false
        }
    }

    private static func isFolderCreationCommand(_ kind: CoreCommandKind) -> Bool {
        kind == .addFolder || kind == .acceptFolder
    }

    private static func legacyFolderIDs(
        from snapshot: CoreSnapshot,
        excludingCreationTargetOf command: CoreCommand
    ) -> [FolderID] {
        guard isFolderCreationCommand(command.kind), let target = command.folderID else {
            return snapshot.folders.map(\.id)
        }
        // A successful native add may have crashed before Swift wrote its
        // deterministic incarnation. Do not manufacture a random legacy
        // incarnation for that exact target before completed replay.
        return snapshot.folders.map(\.id).filter { $0 != target }
    }

    private static func applySuccessfulFolderIncarnationTransition(
        for command: CoreCommand,
        snapshot: CoreSnapshot,
        store: FolderIncarnationStore
    ) throws {
        guard let folderID = command.folderID else { return }
        if isFolderCreationCommand(command.kind) {
            guard snapshot.folders.contains(where: { $0.id == folderID }) else {
                throw CoreClientError.invalidResponse("created_folder_missing")
            }
            _ = try store.recordSuccessfulCreation(folderID: folderID, commandID: command.id)
            return
        }
        guard command.kind == .removeFolder else { return }
        guard !snapshot.folders.contains(where: { $0.id == folderID }) else {
            throw CoreClientError.invalidResponse("removed_folder_still_present")
        }
        do {
            let current = try store.policyContext(for: folderID)
            guard let expected = command.folderIncarnationDigest,
                expected == current.folderIncarnationDigest
            else {
                throw CoreClientError.coreRejected("folder_incarnation_mismatch")
            }
            _ = try store.removeAfterSuccessfulDeletion(
                folderID: folderID,
                expectedFolderIncarnationDigest: expected
            )
        } catch FolderIncarnationStoreError.missingFolderIncarnation {
            // Idempotent crash replay after Swift already removed the exact
            // registry record.
        }
    }

    private static func runConfigurationCommandExplicit(
        _ command: CoreCommand,
        client: any CoreClient,
        queue: CoreCommandQueue,
        paths: SharedContainerPaths,
        trigger: SyncTrigger,
        startedAt: Date,
        retryClock: @Sendable () -> Date,
        lease: CoreOwnerLease,
        coordinator: CoreProcessCoordinator,
        cleanupEntry: CompletedCommandCleanupEntry?
    ) async -> CoreRunOutcome {
        let ownerMetadataURL = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
        var sessionOpen = false
        do {
            try await coordinator.validate(lease)
            let opened = try await client.openConfigurationSession(
                configurationDirectory: paths.coreConfiguration,
                dataDirectory: paths.coreData,
                sessionID: UUID()
            )
            sessionOpen = true
            let before = try await client.snapshot()
            guard before.configurationRevision == opened.configurationRevision else {
                throw CoreClientError.invalidResponse("configuration_revision_changed")
            }
            _ = try incarnationStore.ensureLegacyConfiguredFolders(
                legacyFolderIDs(from: before, excludingCreationTargetOf: command),
                authoritativeReconciliation: false
            )
            if let cleanupEntry {
                guard let result = try queue.result(for: command.id) else {
                    throw CoreClientError.invalidResponse("completed_result_missing")
                }
                if command.requiresManualReconciliation(for: result),
                    command.isConfigurationReconciliationCommand
                {
                    let persisted = try await persist(
                        before,
                        paths: paths,
                        lease: lease,
                        coordinator: coordinator,
                        ownerMetadataURL: ownerMetadataURL
                    )
                    let reconciliation = try await reconcileConfiguration(
                        command,
                        failedResult: result,
                        completedEntry: cleanupEntry,
                        authoritativeSnapshot: persisted,
                        client: client,
                        queue: queue,
                        paths: paths,
                        lease: lease,
                        coordinator: coordinator,
                        ownerMetadataURL: ownerMetadataURL,
                        policyCheckpoint: { try Task.checkCancellation() },
                        beforeNativeCleanup: { snapshot in
                            try applySuccessfulFolderIncarnationTransition(
                                for: command,
                                snapshot: snapshot,
                                store: incarnationStore
                            )
                        }
                    )
                    let closed = try await client.closeExplicitSession()
                    sessionOpen = false
                    guard before.configurationRevision == closed.configurationRevision else {
                        throw CoreClientError.invalidResponse("configuration_revision_changed")
                    }
                    if reconciliation.verified,
                        !reconciliation.bridgeLedgerCleanupFailed
                    {
                        return .completed(
                            processedCommands: 1,
                            snapshotGeneration: reconciliation.snapshot.generation
                        )
                    }
                    if reconciliation.verified {
                        return .failed(code: "bridgeLedgerCleanupFailed")
                    }
                    try queue.deferCompletedCleanup(
                        cleanupEntry,
                        lease: lease,
                        ownerMetadataURL: ownerMetadataURL
                    )
                    return .failed(code: "configuration_reconciliation_conflict")
                }
                // A durable succeeded result is written only after the exact
                // folder-incarnation transition. Reapplying that transition
                // during later ledger cleanup could delete or overwrite a
                // newer remove-and-readd incarnation.
                let cleaned = try await attemptNativeLedgerCleanup(
                    for: command,
                    result: result,
                    completedEntry: cleanupEntry,
                    client: client,
                    queue: queue,
                    paths: paths,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
                let closed = try await client.closeExplicitSession()
                sessionOpen = false
                guard before.configurationRevision == closed.configurationRevision else {
                    throw CoreClientError.invalidResponse("configuration_revision_changed")
                }
                let persisted = try await persist(
                    before,
                    paths: paths,
                    lease: lease,
                    coordinator: coordinator,
                    ownerMetadataURL: ownerMetadataURL
                )
                return cleaned
                    ? .completed(processedCommands: 0, snapshotGeneration: persisted.generation)
                    : .failed(code: "bridgeLedgerCleanupFailed")
            }
            if command.requiresDurableConfigurationRevisionPrecondition {
                guard let revision = command.commandConfigurationRevision,
                    CoreSessionDigest.isLowercaseSHA256(revision)
                else {
                    throw CoreClientError.coreRejected("invalid_request")
                }
            }
            if commandRequiresExistingFolderIncarnation(command) {
                guard let folderID = command.folderID else {
                    throw CoreClientError.coreRejected("folder_scope_required")
                }
                do {
                    let context = try incarnationStore.policyContext(for: folderID)
                    guard command.folderIncarnationDigest == context.folderIncarnationDigest else {
                        throw CoreClientError.coreRejected("folder_incarnation_mismatch")
                    }
                } catch FolderIncarnationStoreError.missingFolderIncarnation
                    where command.kind == .removeFolder
                {
                    // A successful remove may have crashed after deleting its
                    // registry entry but before Swift persisted the result. Let
                    // the exact request ID reach Go's completed replay. A live
                    // same-ID re-add has an entry and is rejected above.
                }
            }

            if let existing = try queue.result(for: command.id), existing.status != .retryable {
                try queue.acknowledge(
                    command,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
                let requiresManualReconciliation = command.requiresManualReconciliation(for: existing)
                let cleaned: Bool
                if requiresManualReconciliation {
                    // Failed/indeterminate configuration mutations require an
                    // authoritative later-owner proof before their native
                    // ledger record may be retired.
                    cleaned = false
                } else {
                    cleaned = try await attemptNativeLedgerCleanup(
                        for: command,
                        result: existing,
                        client: client,
                        queue: queue,
                        paths: paths,
                        lease: lease,
                        ownerMetadataURL: ownerMetadataURL
                    )
                }
                let proposed = try await client.snapshot()
                let closed = try await client.closeExplicitSession()
                sessionOpen = false
                guard proposed.configurationRevision == closed.configurationRevision else {
                    throw CoreClientError.invalidResponse("configuration_revision_changed")
                }
                let persisted = try await persist(
                    proposed,
                    paths: paths,
                    lease: lease,
                    coordinator: coordinator,
                    ownerMetadataURL: ownerMetadataURL
                )
                if requiresManualReconciliation {
                    try queue.deferCompletedCleanup(
                        command,
                        lease: lease,
                        ownerMetadataURL: ownerMetadataURL
                    )
                    return .failed(code: existing.errorCode ?? "commandFailed")
                }
                try? SyncRunHistory(url: paths.history).append(
                    .init(
                        trigger: trigger,
                        startedAt: startedAt,
                        endedAt: .now,
                        transferredBytes: 0,
                        networkReceivedBytes: 0,
                        networkSentBytes: 0,
                        endReason: cleaned ? .completed : .failed,
                        failureCode: cleaned ? nil : "bridgeLedgerCleanupFailed"
                    )
                )
                return cleaned
                    ? .completed(processedCommands: 0, snapshotGeneration: persisted.generation)
                    : .failed(code: "bridgeLedgerCleanupFailed")
            }

            var commandFailure: Error?
            do {
                try await withTaskCancellationHandler {
                    try await client.execute(command)
                } onCancel: {
                    client.requestCancellation()
                }
            } catch {
                commandFailure = error
            }
            let proposed = try await client.snapshot()
            let closed = try await client.closeExplicitSession()
            sessionOpen = false
            guard proposed.configurationRevision == closed.configurationRevision else {
                throw CoreClientError.invalidResponse("configuration_revision_changed")
            }
            try await coordinator.validate(lease)

            if commandFailure == nil {
                try applySuccessfulFolderIncarnationTransition(
                    for: command,
                    snapshot: proposed,
                    store: incarnationStore
                )
            }
            _ = try incarnationStore.ensureLegacyConfiguredFolders(
                proposed.folders.map(\.id),
                authoritativeReconciliation: commandFailure == nil
            )
            let persisted = try await persist(
                proposed,
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
            if let commandFailure {
                let code = failureCode(for: commandFailure)
                let status = resultStatus(for: commandFailure, command: command)
                let recordedAt = retryClock()
                try queue.record(
                    .init(
                        commandID: command.id,
                        status: status,
                        completedAt: recordedAt,
                        snapshotGeneration: persisted.generation,
                        ownerEpoch: lease.epoch,
                        instanceID: lease.instanceID,
                        errorCode: code
                    ),
                    at: recordedAt,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
                if status != .retryable {
                    try queue.acknowledge(
                        command,
                        lease: lease,
                        ownerMetadataURL: ownerMetadataURL
                    )
                }
                try? SyncRunHistory(url: paths.history).append(
                    .init(
                        trigger: trigger,
                        startedAt: startedAt,
                        endedAt: .now,
                        transferredBytes: 0,
                        networkReceivedBytes: 0,
                        networkSentBytes: 0,
                        endReason: commandFailure is CancellationError ? .cancelled : .failed,
                        failureCode: code
                    )
                )
                return .failed(code: code)
            }

            let recordedAt = retryClock()
            try queue.record(
                .init(
                    commandID: command.id,
                    status: .succeeded,
                    completedAt: recordedAt,
                    snapshotGeneration: persisted.generation,
                    ownerEpoch: lease.epoch,
                    instanceID: lease.instanceID
                ),
                at: recordedAt,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            try queue.acknowledge(
                command,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            try SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: startedAt,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: .completed
                )
            )
            return .completed(processedCommands: 1, snapshotGeneration: persisted.generation)
        } catch {
            if sessionOpen { client.requestCancellation() }
            let drained = sessionOpen ? await drainExplicitSession(client) : true
            if let cleanupEntry {
                try? queue.deferCompletedCleanup(
                    cleanupEntry,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
            }
            let code = drained ? failureCode(for: error) : "coreStopFailed"
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: startedAt,
                    endedAt: .now,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: error is CancellationError ? .cancelled : .failed,
                    failureCode: code
                )
            )
            return .failed(code: code)
        }
    }

    private static func runNetworkCommandExplicit(
        _ command: CoreCommand,
        client: any CoreClient,
        queue: CoreCommandQueue,
        paths: SharedContainerPaths,
        trigger: SyncTrigger,
        startedAt: Date,
        retryClock: @Sendable () -> Date,
        initialEnvironment: SyncEnvironmentSnapshot,
        liveEnvironment: @escaping @Sendable () async -> SyncEnvironmentSnapshot,
        requestedTemporaryOverride: Bool,
        cancellationContext: CoreRunCancellationContext?,
        lease: CoreOwnerLease,
        coordinator: CoreProcessCoordinator,
        cleanupEntry: CompletedCommandCleanupEntry?
    ) async -> CoreRunOutcome {
        guard let folderID = command.folderID else {
            return .failed(code: "folder_scope_required")
        }
        _ = initialEnvironment
        let ownerMetadataURL = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        let incarnationStore = FolderIncarnationStore(url: paths.folderIncarnations)
        var prepared: PreparedNetworkSession?
        var sessionOpen = false
        var networkTotals: CoreNetworkTransferTotals?
        var validatedClosedBudgetBytes: Int64?
        var policyMonitor: Task<Void, Never>?
        let policyMonitorState = NetworkCorePolicyMonitorState()
        let expensiveObservation = NetworkExpenseObservation()
        let taskPolicyBinding: CoreTaskPolicyBinding?
        do {
            taskPolicyBinding = try command.taskPolicyBinding?.validated(
                commandCreatedAt: command.createdAt,
                trigger: command.trigger,
                now: startedAt
            )
        } catch {
            let code =
                (error as? CoreTaskPolicyBindingError) == .expired
                ? "temporary_policy_profile_expired" : "temporary_policy_profile_invalid"
            let recordedAt = retryClock()
            try? queue.record(
                .init(
                    commandID: command.id,
                    status: .blocked,
                    completedAt: recordedAt,
                    ownerEpoch: lease.epoch,
                    instanceID: lease.instanceID,
                    errorCode: code
                ),
                at: recordedAt,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            try? queue.acknowledge(
                command,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            try? queue.retireCompleted(
                command,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            try? SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: startedAt,
                    endedAt: recordedAt,
                    transferredBytes: 0,
                    networkReceivedBytes: 0,
                    networkSentBytes: 0,
                    endReason: .policyDenied,
                    failureCode: code
                )
            )
            return .failed(code: code)
        }
        do {
            let effectiveTemporaryOverride =
                taskPolicyBinding?.requestsTemporaryOverride ?? requestedTemporaryOverride
            let configuration = try await refreshCanonicalConfiguration(
                client: client,
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
            guard configuration.snapshot.folders.contains(where: { $0.id == folderID }) else {
                throw CoreClientError.coreRejected("folder_not_found")
            }
            let folderContext = try incarnationStore.policyContext(for: folderID)
            guard command.folderIncarnationDigest == folderContext.folderIncarnationDigest else {
                throw CoreClientError.coreRejected("folder_incarnation_mismatch")
            }
            if let commandRevision = command.commandConfigurationRevision,
                commandRevision != configuration.revision
            {
                throw CoreClientError.coreRejected("configuration_revision_mismatch")
            }
            let preexistingResult = try queue.result(for: command.id)
            let plannedRescan = preexistingResult.flatMap { result in
                command.requiresManualReconciliation(for: result)
                    ? MutationReconciler(paths: paths).rescanCommand(
                        for: command,
                        ownerEpoch: lease.epoch
                    ) : nil
            }
            try recoverStaleAccounting(
                paths: paths,
                activeOwnerID: lease.instanceID,
                trigger: trigger
            )
            let latestEnvironment = await liveEnvironment()
            expensiveObservation.observe(latestEnvironment.network.isExpensive)
            let sessionID = UUID()
            let executionKind = try retentionAwareExecutionKind(
                command,
                snapshot: configuration.snapshot,
                folderContext: folderContext,
                paths: paths
            )
            let networkPreparation = try prepareNetworkSession(
                taskID: plannedRescan?.id ?? command.id,
                sessionID: sessionID,
                folderContext: folderContext,
                configurationRevision: configuration.revision,
                ownerID: lease.instanceID,
                paths: paths,
                environment: latestEnvironment,
                trigger: trigger,
                requestedActions: executionKind.requestedSyncActions,
                requestedTemporaryOverride: effectiveTemporaryOverride,
                taskMaximumNetworkBytes: taskPolicyBinding?.maximumNetworkBytes,
                operation: executionKind.networkSessionOperation
            )
            prepared = networkPreparation
            let revalidatePolicy: @Sendable () async throws -> Void = {
                try Task.checkCancellation()
                let current = await liveEnvironment()
                expensiveObservation.observe(current.network.isExpensive)
                try ContentEvictionFinalization.validate(
                    command, store: ContentRetentionStore(url: paths.contentRetention))
                try revalidatePreparedNetwork(
                    networkPreparation,
                    paths: paths,
                    environment: current,
                    trigger: trigger,
                    requestedActions: executionKind.requestedSyncActions,
                    requestedTemporaryOverride: effectiveTemporaryOverride,
                    additionalDiskBytes: nil
                )
            }
            try await revalidatePolicy()
            try await coordinator.validate(lease)
            _ = try await client.openNetworkSession(
                configurationDirectory: paths.coreConfiguration,
                dataDirectory: paths.coreData,
                sessionID: sessionID,
                plan: networkPreparation.plan
            )
            sessionOpen = true
            try beginAccounting(networkPreparation, ownerID: lease.instanceID)
            policyMonitor = startNetworkCorePolicyMonitor(
                client: client,
                state: policyMonitorState,
                validate: revalidatePolicy
            )

            var bridgeLedgerCleanupFailed = false
            if let cleanup = try queue.completedCleanupBatch().first(where: {
                !commandUsesConfigurationSession($0.command.kind)
                    && $0.command.folderID == folderID
                    && $0.command.folderIncarnationDigest == command.folderIncarnationDigest
                    && $0.command.id != command.id
            }),
                let result = try queue.result(for: cleanup.command.id),
                !cleanup.command.requiresManualReconciliation(for: result)
            {
                if !(try await attemptNativeLedgerCleanup(
                    for: cleanup.command,
                    result: result,
                    completedEntry: cleanup,
                    client: client,
                    queue: queue,
                    paths: paths,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )) {
                    bridgeLedgerCleanupFailed = true
                }
            }

            if let existing = try queue.result(for: command.id), existing.status != .retryable {
                try queue.acknowledge(
                    command,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
                if command.requiresManualReconciliation(for: existing) {
                    let reconciliation = try await reconcileMutation(
                        command,
                        failedResult: existing,
                        completedEntry: cleanupEntry,
                        client: client,
                        queue: queue,
                        paths: paths,
                        lease: lease,
                        coordinator: coordinator,
                        ownerMetadataURL: ownerMetadataURL,
                        policyCheckpoint: revalidatePolicy
                    )
                    let proposed: CoreSnapshot?
                    if reconciliation.snapshot == nil {
                        proposed = try await client.snapshot()
                    } else {
                        proposed = nil
                    }
                    _ = try await client.closeExplicitSession()
                    sessionOpen = false
                    networkTotals = try await client.networkTransferTotals()
                    let exactBudget = try validatedBudgetUsedBytes(
                        networkTotals,
                        prepared: networkPreparation
                    )
                    validatedClosedBudgetBytes = exactBudget
                    await stopNetworkCorePolicyMonitor(policyMonitor)
                    policyMonitor = nil
                    try policyMonitorState.validate()
                    try await revalidatePolicy()
                    try await coordinator.validate(lease)
                    let persisted: CoreSnapshot
                    if let reconciledSnapshot = reconciliation.snapshot {
                        // reconcileMutation already persisted the authoritative
                        // rescan snapshot before creating and acknowledging its
                        // proof. Publishing the same state again would invent a
                        // generation unrelated to any native observation.
                        persisted = reconciledSnapshot
                    } else if let proposed {
                        let previous = try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
                        persisted = try await persist(
                            mergedNetworkSnapshot(
                                proposed,
                                targetFolderID: folderID,
                                preservingSiblingsFrom: previous
                            ),
                            paths: paths,
                            lease: lease,
                            coordinator: coordinator,
                            ownerMetadataURL: ownerMetadataURL
                        )
                    } else {
                        throw CoreClientError.invalidResponse("reconciliation_snapshot_missing")
                    }
                    let reconciliationFailureCode: String?
                    if !reconciliation.verified {
                        reconciliationFailureCode = "mutation_reconciliation_conflict"
                    } else if reconciliation.stagingCleanupFailed {
                        reconciliationFailureCode = "stagingCleanupFailed"
                    } else if reconciliation.bridgeLedgerCleanupFailed
                        || bridgeLedgerCleanupFailed
                    {
                        reconciliationFailureCode = "bridgeLedgerCleanupFailed"
                    } else {
                        reconciliationFailureCode = nil
                    }
                    try recordNetworkAccountingAndHistory(
                        prepared: networkPreparation,
                        ownerID: lease.instanceID,
                        exactBudgetBytes: expensiveObservation.hasSeenExpensive ? exactBudget : 0,
                        networkTotals: networkTotals,
                        trigger: trigger,
                        startedAt: startedAt,
                        paths: paths,
                        endReason: reconciliationFailureCode == nil ? .completed : .failed,
                        failureCode: reconciliationFailureCode
                    )
                    if let reconciliationFailureCode {
                        if let cleanupEntry {
                            try? queue.deferCompletedCleanup(
                                cleanupEntry,
                                lease: lease,
                                ownerMetadataURL: ownerMetadataURL
                            )
                        } else {
                            try? queue.deferCompletedCleanup(
                                command,
                                lease: lease,
                                ownerMetadataURL: ownerMetadataURL
                            )
                        }
                        return .failed(code: reconciliationFailureCode)
                    }
                    return .completed(
                        processedCommands: cleanupEntry == nil ? 1 : 0,
                        snapshotGeneration: persisted.generation
                    )
                }
                if !(try await attemptNativeLedgerCleanup(
                    for: command,
                    result: existing,
                    client: client,
                    queue: queue,
                    paths: paths,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )) {
                    bridgeLedgerCleanupFailed = true
                }
                let proposed = try await client.snapshot()
                _ = try await client.closeExplicitSession()
                sessionOpen = false
                networkTotals = try await client.networkTransferTotals()
                await stopNetworkCorePolicyMonitor(policyMonitor)
                policyMonitor = nil
                try policyMonitorState.validate()
                let exactBudget = try validatedBudgetUsedBytes(
                    networkTotals,
                    prepared: networkPreparation
                )
                validatedClosedBudgetBytes = exactBudget
                let previous = try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
                let persisted = try await persist(
                    mergedNetworkSnapshot(
                        proposed,
                        targetFolderID: folderID,
                        preservingSiblingsFrom: previous
                    ),
                    paths: paths,
                    lease: lease,
                    coordinator: coordinator,
                    ownerMetadataURL: ownerMetadataURL
                )
                try recordNetworkAccountingAndHistory(
                    prepared: networkPreparation,
                    ownerID: lease.instanceID,
                    exactBudgetBytes: expensiveObservation.hasSeenExpensive ? exactBudget : 0,
                    networkTotals: networkTotals,
                    trigger: trigger,
                    startedAt: startedAt,
                    paths: paths,
                    endReason: bridgeLedgerCleanupFailed ? .failed : .completed,
                    failureCode: bridgeLedgerCleanupFailed ? "bridgeLedgerCleanupFailed" : nil
                )
                return bridgeLedgerCleanupFailed
                    ? .failed(code: "bridgeLedgerCleanupFailed")
                    : .completed(processedCommands: 0, snapshotGeneration: persisted.generation)
            }

            let mutationReconciler = MutationReconciler(paths: paths)
            let reconciliationExpectedIsDirectory = mutationReconciler.expectedIsDirectory(
                for: command,
                baseline: configuration.snapshot
            )
            let reconciliationCreateTargetWasAbsent = mutationReconciler.createTargetWasAbsent(
                for: command,
                baseline: configuration.snapshot
            )
            let reconciliationSourceRelativePath = mutationReconciler.sourceRelativePath(
                for: command,
                baseline: configuration.snapshot
            )
            var commandFailure: Error?
            do {
                try await withTaskCancellationHandler {
                    try await client.execute(command)
                } onCancel: {
                    client.requestCancellation()
                }
            } catch {
                commandFailure = error
            }
            try policyMonitorState.validate()
            let proposed = try await client.snapshot()
            _ = try await client.closeExplicitSession()
            sessionOpen = false
            networkTotals = try await client.networkTransferTotals()
            let exactBudget = try validatedBudgetUsedBytes(
                networkTotals,
                prepared: networkPreparation
            )
            validatedClosedBudgetBytes = exactBudget
            await stopNetworkCorePolicyMonitor(policyMonitor)
            policyMonitor = nil
            try policyMonitorState.validate()
            try await revalidatePolicy()
            try await coordinator.validate(lease)
            let previous = try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
            let persisted = try await persist(
                mergedNetworkSnapshot(
                    proposed,
                    targetFolderID: folderID,
                    preservingSiblingsFrom: previous
                ),
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
            if let commandFailure {
                let code = failureCode(for: commandFailure)
                let status: CoreCommandResultStatus
                if code == "network_byte_limit_reached", expensiveObservation.hasSeenExpensive {
                    // Once any expensive path was observed, reaching the cap
                    // is terminal for this command run. Replaying would reset
                    // maxExpensiveRunBytes at the native-session boundary.
                    status = .blocked
                } else {
                    // Cheap cap hits still obey the command's native replay
                    // classification. In particular, an ambiguous File
                    // Provider mutation must reconcile instead of replaying.
                    status = resultStatus(for: commandFailure, command: command)
                }
                let recordedAt = retryClock()
                let terminalResult = CoreCommandResult(
                    commandID: command.id,
                    status: status,
                    completedAt: recordedAt,
                    snapshotGeneration: persisted.generation,
                    ownerEpoch: lease.epoch,
                    instanceID: lease.instanceID,
                    errorCode: code,
                    reconciliationExpectedIsDirectory: reconciliationExpectedIsDirectory,
                    reconciliationCreateTargetWasAbsent: reconciliationCreateTargetWasAbsent,
                    reconciliationSourceRelativePath: reconciliationSourceRelativePath,
                    mutationFailurePhase: (commandFailure as? CoreMutationFailure)?.phase,
                    mutationFailureAmbiguous: (commandFailure as? CoreMutationFailure)?.ambiguous
                )
                try queue.record(
                    terminalResult,
                    at: recordedAt,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
                if status != .retryable {
                    try queue.acknowledge(
                        command,
                        lease: lease,
                        ownerMetadataURL: ownerMetadataURL
                    )
                    if !command.requiresManualReconciliation(for: terminalResult) {
                        _ = try await attemptNativeLedgerCleanup(
                            for: command,
                            result: terminalResult,
                            client: client,
                            queue: queue,
                            paths: paths,
                            lease: lease,
                            ownerMetadataURL: ownerMetadataURL
                        )
                    }
                }
                try recordNetworkAccountingAndHistory(
                    prepared: networkPreparation,
                    ownerID: lease.instanceID,
                    exactBudgetBytes: expensiveObservation.hasSeenExpensive ? exactBudget : 0,
                    networkTotals: networkTotals,
                    trigger: trigger,
                    startedAt: startedAt,
                    paths: paths,
                    endReason: commandFailure is CancellationError
                        ? (await cancellationContext?.endReason ?? .cancelled)
                        : .failed,
                    failureCode: code
                )
                return .failed(code: code)
            }

            let recordedAt = retryClock()
            let succeededResult = CoreCommandResult(
                commandID: command.id,
                status: .succeeded,
                completedAt: recordedAt,
                snapshotGeneration: persisted.generation,
                ownerEpoch: lease.epoch,
                instanceID: lease.instanceID
            )
            try queue.record(
                succeededResult,
                at: recordedAt,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            try queue.acknowledge(
                command,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            let stagingCleanupSucceeded = try attemptSucceededMutationStagingCleanup(
                for: command,
                queue: queue,
                paths: paths,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            let finalFailureCode: String?
            if !stagingCleanupSucceeded {
                finalFailureCode = "stagingCleanupFailed"
            } else if bridgeLedgerCleanupFailed {
                finalFailureCode = "bridgeLedgerCleanupFailed"
            } else {
                finalFailureCode = nil
            }
            try recordNetworkAccountingAndHistory(
                prepared: networkPreparation,
                ownerID: lease.instanceID,
                exactBudgetBytes: expensiveObservation.hasSeenExpensive ? exactBudget : 0,
                networkTotals: networkTotals,
                trigger: trigger,
                startedAt: startedAt,
                paths: paths,
                endReason: finalFailureCode == nil ? .completed : .failed,
                failureCode: finalFailureCode
            )
            if let finalFailureCode { return .failed(code: finalFailureCode) }
            return .completed(processedCommands: 1, snapshotGeneration: persisted.generation)
        } catch {
            let primaryError = policyMonitorState.failure() ?? error
            if sessionOpen { client.requestCancellation() }
            let drained = sessionOpen ? await drainExplicitSession(client) : true
            sessionOpen = false
            if let cleanupEntry {
                try? queue.deferCompletedCleanup(
                    cleanupEntry,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
            }
            if drained { networkTotals = try? await client.networkTransferTotals() }
            if drained, let prepared {
                validatedClosedBudgetBytes = try? validatedBudgetUsedBytes(
                    networkTotals,
                    prepared: prepared
                )
            }
            await stopNetworkCorePolicyMonitor(policyMonitor)
            policyMonitor = nil
            let cancellationEndReason = await cancellationContext?.endReason ?? .cancelled
            let disposition = historyDisposition(
                for: primaryError,
                cancellationEndReason: cancellationEndReason
            )
            let historyEndReason: SyncRunEndReason = drained ? disposition.endReason : .failed
            let historyFailureCode = drained ? disposition.failureCode : "coreStopFailed"
            var accountingFailed = false
            if let prepared {
                do {
                    try recordNetworkAccountingAndHistory(
                        prepared: prepared,
                        ownerID: lease.instanceID,
                        exactBudgetBytes: validatedClosedBudgetBytes.map {
                            expensiveObservation.hasSeenExpensive ? $0 : 0
                        },
                        networkTotals: networkTotals,
                        trigger: trigger,
                        startedAt: startedAt,
                        paths: paths,
                        endReason: historyEndReason,
                        failureCode: historyFailureCode
                    )
                } catch {
                    accountingFailed = true
                }
            } else {
                try? SyncRunHistory(url: paths.history).append(
                    .init(
                        trigger: trigger,
                        startedAt: startedAt,
                        endedAt: .now,
                        transferredBytes: networkTotals?.totalBytes ?? 0,
                        networkReceivedBytes: networkTotals?.receivedBytes,
                        networkSentBytes: networkTotals?.sentBytes,
                        endReason: historyEndReason,
                        failureCode: historyFailureCode
                    )
                )
            }
            if !drained { return .failed(code: "coreStopFailed") }
            if accountingFailed { return .failed(code: "transferAccountingFailed") }
            if let policyError = primaryError as? NetworkCorePolicyError {
                switch policyError {
                case .denied(let reasons): return .policyDenied(reasons: reasons)
                case .configurationUnavailable:
                    return .failed(code: "policyConfigurationUnavailable")
                }
            }
            return .failed(code: failureCode(for: primaryError))
        }
    }

    private static func recordNetworkAccountingAndHistory(
        prepared: PreparedNetworkSession,
        ownerID: UUID,
        exactBudgetBytes: Int64?,
        networkTotals: CoreNetworkTransferTotals?,
        trigger: SyncTrigger,
        startedAt: Date,
        paths: SharedContainerPaths,
        endReason: SyncRunEndReason,
        failureCode: String?
    ) throws {
        if let projection = try settleAccounting(
            prepared,
            ownerID: ownerID,
            exactBytes: exactBudgetBytes
        ) {
            // The projection owns the durable accounting identity even when a
            // failed drain forced conservative bytes. Preserve the real run
            // disposition on that same row instead of first publishing a
            // generic accounting or execution failure.
            let terminalRecord = SyncRunRecord(
                id: projection.id,
                trigger: trigger,
                startedAt: startedAt,
                endedAt: .now,
                transferredBytes: networkTotals?.totalBytes ?? projection.chargedBytes,
                networkReceivedBytes: networkTotals?.receivedBytes,
                networkSentBytes: networkTotals?.sentBytes,
                endReason: endReason,
                failureCode: failureCode
            )
            try projectPendingAccountingHistory(
                store: prepared.accountingStore,
                paths: paths,
                trigger: trigger,
                exactRecord: terminalRecord
            )
        } else {
            try SyncRunHistory(url: paths.history).append(
                .init(
                    trigger: trigger,
                    startedAt: startedAt,
                    endedAt: .now,
                    transferredBytes: networkTotals?.totalBytes ?? 0,
                    networkReceivedBytes: networkTotals?.receivedBytes,
                    networkSentBytes: networkTotals?.sentBytes,
                    endReason: endReason,
                    failureCode: failureCode
                )
            )
        }
    }

    private struct MutationReconciliationRun {
        var verified: Bool
        var snapshot: CoreSnapshot?
        var bridgeLedgerCleanupFailed: Bool
        var stagingCleanupFailed: Bool
    }

    private struct ConfigurationReconciliationRun {
        var verified: Bool
        var snapshot: CoreSnapshot
        var bridgeLedgerCleanupFailed: Bool
    }

    private static func reconcileConfiguration(
        _ command: CoreCommand,
        failedResult: CoreCommandResult,
        completedEntry: CompletedCommandCleanupEntry? = nil,
        authoritativeSnapshot: CoreSnapshot?,
        client: any CoreClient,
        queue: CoreCommandQueue,
        paths: SharedContainerPaths,
        lease: CoreOwnerLease,
        coordinator: CoreProcessCoordinator,
        ownerMetadataURL: URL,
        policyCheckpoint: @Sendable () async throws -> Void,
        beforeNativeCleanup: (CoreSnapshot) throws -> Void = { _ in }
    ) async throws -> ConfigurationReconciliationRun {
        try await policyCheckpoint()
        try await coordinator.validate(lease)
        let snapshot: CoreSnapshot
        if let authoritativeSnapshot {
            snapshot = authoritativeSnapshot
        } else {
            snapshot = try await persist(
                try await client.snapshot(),
                paths: paths,
                lease: lease,
                coordinator: coordinator,
                ownerMetadataURL: ownerMetadataURL
            )
        }
        try await policyCheckpoint()
        try await coordinator.validate(lease)

        guard
            let proof = ConfigurationReconciler().reconciliationProof(
                of: command,
                failedResult: failedResult,
                snapshot: snapshot,
                ownerEpoch: lease.epoch
            )
        else {
            try queue.record(
                CoreCommandResult(
                    commandID: command.id,
                    status: .failed,
                    snapshotGeneration: snapshot.generation,
                    ownerEpoch: lease.epoch,
                    instanceID: lease.instanceID,
                    errorCode: "configuration_reconciliation_conflict"
                ),
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )
            return ConfigurationReconciliationRun(
                verified: false,
                snapshot: snapshot,
                bridgeLedgerCleanupFailed: false
            )
        }

        let reconciledResult = CoreCommandResult(
            commandID: command.id,
            status: .succeeded,
            snapshotGeneration: snapshot.generation,
            ownerEpoch: lease.epoch,
            instanceID: lease.instanceID,
            reconciliationProofKind: CoreConfigurationReconciliationProof.kind,
            reconciliationProofStateDigest: proof.stateDigest
        )
        try beforeNativeCleanup(snapshot)
        try queue.record(
            reconciledResult,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
        let cleanupSucceeded = try await attemptNativeLedgerCleanup(
            for: command,
            result: reconciledResult,
            completedEntry: completedEntry,
            client: client,
            queue: queue,
            paths: paths,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
        return ConfigurationReconciliationRun(
            verified: true,
            snapshot: snapshot,
            bridgeLedgerCleanupFailed: !cleanupSucceeded
        )
    }

    private static func reconcileMutation(
        _ command: CoreCommand,
        failedResult: CoreCommandResult,
        completedEntry: CompletedCommandCleanupEntry? = nil,
        client: any CoreClient,
        queue: CoreCommandQueue,
        paths: SharedContainerPaths,
        lease: CoreOwnerLease,
        coordinator: CoreProcessCoordinator,
        ownerMetadataURL: URL,
        policyCheckpoint: @Sendable () async throws -> Void
    ) async throws -> MutationReconciliationRun {
        try await policyCheckpoint()
        let reconciler = MutationReconciler(paths: paths)
        guard command.isFileProviderMutation,
            failedResult.status == .failed,
            let rescan = reconciler.rescanCommand(for: command, ownerEpoch: lease.epoch)
        else {
            return MutationReconciliationRun(
                verified: false,
                snapshot: nil,
                bridgeLedgerCleanupFailed: false,
                stagingCleanupFailed: false
            )
        }

        // The rescan has its own deterministic, epoch-fenced UUID. Persist it
        // before crossing into native code so a crash can replay only this
        // idempotent maintenance request, never the original mutation.
        try queue.enqueue(rescan)
        try await coordinator.validate(lease)
        var rescanSucceeded = false
        var rescanFailureCode: String?
        do {
            try await withTaskCancellationHandler {
                try await client.execute(rescan)
            } onCancel: {
                client.requestCancellation()
            }
            rescanSucceeded = true
        } catch {
            try await policyCheckpoint()
            rescanFailureCode = failureCode(for: error)
        }
        try await policyCheckpoint()

        var snapshot: CoreSnapshot?
        if rescanSucceeded {
            do {
                let proposed = try await client.snapshot()
                let previous = try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
                guard let folderID = command.folderID else {
                    throw CoreClientError.coreRejected("folder_scope_required")
                }
                snapshot = try await persist(
                    mergedNetworkSnapshot(
                        proposed,
                        targetFolderID: folderID,
                        preservingSiblingsFrom: previous
                    ),
                    paths: paths,
                    lease: lease,
                    coordinator: coordinator,
                    ownerMetadataURL: ownerMetadataURL
                )
            } catch {
                // Do not convert an owner-fence failure into an ordinary
                // reconciliation miss. A still-valid owner may safely retain
                // the original manual result and try again next epoch.
                try await coordinator.validate(lease)
                snapshot = nil
            }
        }

        try await policyCheckpoint()
        try await coordinator.validate(lease)
        try queue.record(
            CoreCommandResult(
                commandID: rescan.id,
                status: rescanSucceeded ? .succeeded : .failed,
                snapshotGeneration: snapshot?.generation,
                ownerEpoch: lease.epoch,
                instanceID: lease.instanceID,
                errorCode: rescanSucceeded ? nil : (rescanFailureCode ?? "rescan_failed")
            ),
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
        try queue.acknowledge(
            rescan,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
        var cleanupFailed =
            !(try await attemptNativeLedgerCleanup(
                for: rescan,
                result: try queue.result(for: rescan.id),
                client: client,
                queue: queue,
                paths: paths,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            ))
        if Task.isCancelled { throw CancellationError() }

        let expectedIsDirectory =
            failedResult.reconciliationExpectedIsDirectory
            ?? reconciler.expectedIsDirectory(for: command, baseline: nil)
        guard rescanSucceeded,
            let snapshot,
            let proof = reconciler.reconciliationProof(
                of: command,
                expectedIsDirectory: expectedIsDirectory,
                createTargetWasAbsent: failedResult.reconciliationCreateTargetWasAbsent,
                sourceRelativePath: failedResult.reconciliationSourceRelativePath,
                snapshot: snapshot,
                ownerEpoch: lease.epoch
            )
        else {
            return MutationReconciliationRun(
                verified: false,
                snapshot: snapshot,
                bridgeLedgerCleanupFailed: cleanupFailed,
                stagingCleanupFailed: false
            )
        }

        try await coordinator.validate(lease)
        let reconciledResult = CoreCommandResult(
            commandID: command.id,
            status: .succeeded,
            snapshotGeneration: snapshot.generation,
            ownerEpoch: lease.epoch,
            instanceID: lease.instanceID,
            reconciliationExpectedIsDirectory: expectedIsDirectory,
            reconciliationCreateTargetWasAbsent: failedResult.reconciliationCreateTargetWasAbsent,
            reconciliationSourceRelativePath: failedResult.reconciliationSourceRelativePath,
            reconciliationProofKind: CoreMutationReconciliationProof.kind,
            reconciliationProofStateDigest: proof.stateDigest
        )
        try queue.record(
            reconciledResult,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
        let stagedContentReleased = try attemptSucceededMutationStagingCleanup(
            for: command,
            completedEntry: completedEntry,
            queue: queue,
            paths: paths,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
        if stagedContentReleased {
            if !(try await attemptNativeLedgerCleanup(
                for: command,
                result: reconciledResult,
                completedEntry: completedEntry,
                client: client,
                queue: queue,
                paths: paths,
                lease: lease,
                ownerMetadataURL: ownerMetadataURL
            )) {
                cleanupFailed = true
            }
        }
        return MutationReconciliationRun(
            verified: true,
            snapshot: snapshot,
            bridgeLedgerCleanupFailed: cleanupFailed,
            stagingCleanupFailed: !stagedContentReleased
        )
    }

    private static func failureCode(for error: Error) -> String {
        if let error = error as? CoreMutationFailure {
            safeBridgeCode(error.code) ?? "coreRejected"
        } else if let error = error as? CoreClientError {
            switch error {
            case .bridgeUnavailable: "coreBridgeUnavailable"
            case .invalidResponse: "coreInvalidResponse"
            case .coreRejected(let code): safeBridgeCode(code) ?? "coreRejected"
            case .notRunning: "coreNotRunning"
            }
        } else if let error = error as? CoreOwnershipError {
            switch error {
            case .alreadyOwnedByThisInstance, .ownedByAnotherProcess: "coreBusy"
            case .cannotOpenLock, .cannotLock: "coreLockUnavailable"
            case .ownerMetadataMissing: "ownerMetadataMissing"
            case .ownerMetadataUnreadable: "ownerMetadataUnreadable"
            case .ownerMetadataCorrupt: "ownerMetadataCorrupt"
            case .unsupportedOwnerMetadataSchema: "ownerMetadataSchemaUnsupported"
            case .ownerEpochOverflow: "ownerEpochOverflow"
            case .ownerMetadataWriteFailed: "ownerMetadataWriteFailed"
            case .notOwner: "ownerLeaseNotHeld"
            case .staleLease: "ownerLeaseStale"
            }
        } else if error is CancellationError {
            "cancelled"
        } else {
            "coreExecutionFailed"
        }
    }

    private static func recoveryQueryPolicyOutcome(
        _ error: NetworkCorePolicyError
    ) -> CoreMutationRecoveryQueryOutcome {
        switch error {
        case .denied(let reasons): .policyDenied(reasons: reasons)
        case .configurationUnavailable: .configurationUnavailable
        }
    }

    private static func recoveryFailureCode(for error: Error) -> String {
        if error is CancellationError {
            return CoreMutationRecoveryStableCode.cancelled.rawValue
        }
        guard let error = error as? CoreClientError else {
            return CoreMutationRecoveryStableCode.internalError.rawValue
        }
        switch error {
        case .bridgeUnavailable:
            return "coreBridgeUnavailable"
        case .notRunning:
            return CoreMutationRecoveryStableCode.coreNotRunning.rawValue
        case .invalidResponse:
            return "coreInvalidResponse"
        case .coreRejected(let code):
            return CoreMutationRecoveryStableCode.validated(code)
                ?? CoreMutationRecoveryStableCode.internalError.rawValue
        }
    }

    private static func safeBridgeCode(_ code: String) -> String? {
        let bytes = Array(code.utf8)
        guard (1...64).contains(bytes.count),
            let first = bytes.first,
            (97...122).contains(first)
        else {
            return nil
        }
        let allowed = bytes.dropFirst().allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
        }
        return allowed ? code : nil
    }

    private static func resultStatus(
        for error: Error,
        command: CoreCommand
    ) -> CoreCommandResultStatus {
        if let error = error as? CoreMutationFailure {
            return error.phase == .precommit && !error.ambiguous ? .blocked : .failed
        }
        guard let error = error as? CoreClientError else {
            return command.supportsNativeFailureReplay ? .retryable : .failed
        }
        switch error {
        case .bridgeUnavailable, .notRunning:
            return .retryable
        case .invalidResponse:
            return .failed
        case .coreRejected(let code):
            if [
                "invalid_request",
                "invalid_path",
                "invalid_item_id",
                "invalid_folder_root",
                "folder_not_found",
                "version_conflict",
                "offer_version_conflict",
                "suppression_version_conflict",
                "pending_device_not_found",
                "pending_folder_not_found",
                "device_state_conflict",
                "folder_state_conflict",
                "unsafe_path",
                "path_conflict",
                "path_identity_conflict",
                "item_identity_conflict",
                "item_not_found",
                "destination_exists",
                "directory_not_empty",
                "folder_paused",
                "folder_not_writable",
                "invalid_base_version",
                "invalid_parent",
                "protected_path",
                "symlink_rejected",
                "item_type_changed",
                "staged_content_invalid",
                "unuploaded_changes",
                "remote_replica_unavailable",
                "destructive_confirmation_required",
                "delete_must_propagate",
                "unsupported_destructive_option",
                "invalid_recovery_id",
                "invalid_recovery_summary",
                "recovery_not_disposable",
                "recovery_review_required",
                "recovery_confirmation_required",
                "recovery_not_found",
                "recovery_summary_mismatch",
                "recovery_changed",
                "peer_index_proof_unavailable",
                "network_observation_required",
            ].contains(code) {
                return .blocked
            }
            if [
                "core_busy",
                "device_offline",
                "network_unavailable",
                "database_busy",
                "protected_data_unavailable",
                "materialization_pending",
                "propagation_not_indexed",
                "query_failed",
                "remote_read_unavailable",
                "request_cache_full",
                "rescan_failed",
                "cancelled",
                "sync_incomplete",
                "sync_cancelled",
                "pending_state_unavailable",
                "configuration_save_failed",
                "recovery_location_unavailable",
                "recovery_disposal_failed",
                "recovery_disposal_interrupted",
                "core_not_running",
                "internal_error",
                "network_byte_limit_reached",
            ].contains(code) {
                return command.supportsNativeFailureReplay ? .retryable : .failed
            }
            return .failed
        }
    }

    private static func acknowledgeNativeLedger(
        for command: CoreCommand,
        result: CoreCommandResult?,
        client: any CoreClient
    ) async throws {
        if let result,
            let stateDigest = result.reconciliationProofStateDigest,
            let snapshotGeneration = result.snapshotGeneration,
            let ownerEpoch = result.ownerEpoch
        {
            if result.reconciliationProofKind == CoreConfigurationReconciliationProof.kind {
                try await client.acknowledgeReconciledConfigurationCommand(
                    command,
                    proof: CoreConfigurationReconciliationProof(
                        snapshotGeneration: snapshotGeneration,
                        ownerEpoch: ownerEpoch,
                        stateDigest: stateDigest
                    )
                )
            } else if (result.reconciliationProofKind == nil && command.isFileProviderMutation)
                || result.reconciliationProofKind == CoreMutationReconciliationProof.kind
            {
                try await client.acknowledgeReconciledCommand(
                    command,
                    proof: CoreMutationReconciliationProof(
                        snapshotGeneration: snapshotGeneration,
                        ownerEpoch: ownerEpoch,
                        stateDigest: stateDigest
                    )
                )
            } else {
                throw CoreClientError.invalidResponse("reconciliation_proof_kind")
            }
        } else {
            try await client.acknowledgeCommand(command.id)
        }
    }

    /// The completed command handoff is durable authority to discard only the
    /// policy bound to the removed folder's old incarnation. This must finish
    /// before native acknowledgement or queue retirement so a crash cannot
    /// strand stale policy after the removal can no longer be replayed.
    private static func discardSucceededRemovedFolderPolicy(
        for command: CoreCommand,
        result: CoreCommandResult?,
        paths: SharedContainerPaths
    ) throws {
        guard command.kind == .removeFolder,
            let result,
            result.status == .succeeded
        else {
            return
        }
        guard result.commandID == command.id else {
            throw CoreClientError.invalidResponse("completed_result_command_mismatch")
        }
        guard let folderID = command.folderID,
            let digest = command.folderIncarnationDigest,
            CoreSessionDigest.isLowercaseSHA256(digest)
        else {
            throw CoreClientError.invalidResponse("folder_incarnation_mismatch")
        }
        do {
            _ = try SyncPolicyStore(url: paths.policy).discardFolderPolicy(
                for: FolderPolicyContext(
                    folderID: folderID,
                    folderIncarnationDigest: digest
                )
            )
        } catch SyncPolicyDocumentError.staleFolderOverride(let staleFolderID)
            where staleFolderID == folderID.rawValue
        {
            // The store emits this error only after its locked CAS observes a
            // same-ID entry bound to another digest. That is positive proof a
            // replacement incarnation owns the policy, so preserve it and
            // retire only the old command handoff.
        }
    }

    /// Returns true only when native acknowledgement and retirement of the
    /// durable cleanup handoff both succeed. Failures remain durable but move
    /// to the back of the cleanup order so later commands can make progress.
    private static func attemptNativeLedgerCleanup(
        for command: CoreCommand,
        result: CoreCommandResult?,
        completedEntry: CompletedCommandCleanupEntry? = nil,
        client: any CoreClient,
        queue: CoreCommandQueue,
        paths: SharedContainerPaths,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) async throws -> Bool {
        do {
            if command.isFileProviderMutation,
                let result,
                result.status != .retryable,
                !command.requiresManualReconciliation(for: result)
            {
                // The completed App-owned handoff is the authority to discard
                // staged bytes. Release it before retiring the native ledger;
                // any failure below preserves and rotates that handoff.
                try releaseTerminalMutationStaging(command, paths: paths)
            }
            try discardSucceededRemovedFolderPolicy(
                for: command,
                result: result,
                paths: paths
            )
            try await acknowledgeNativeLedger(for: command, result: result, client: client)
            if let completedEntry {
                try queue.retireCompleted(
                    completedEntry,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
            } else {
                try queue.retireCompleted(
                    command,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
            }
            return true
        } catch {
            if let completedEntry {
                try queue.deferCompletedCleanup(
                    completedEntry,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
            } else {
                try queue.deferCompletedCleanup(
                    command,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
            }
            return false
        }
    }

    /// A succeeded result plus the completed queue entry is the durable
    /// handoff proving the File Provider mutation will not execute again.
    /// Release its unique staged upload and destination-space reservation
    /// before retiring the native ledger. If release fails, keep and rotate
    /// the completed handoff so a later owner can retry cleanup without
    /// re-running the mutation.
    private static func attemptSucceededMutationStagingCleanup(
        for command: CoreCommand,
        completedEntry: CompletedCommandCleanupEntry? = nil,
        queue: CoreCommandQueue,
        paths: SharedContainerPaths,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws -> Bool {
        guard command.isFileProviderMutation else { return true }
        do {
            try releaseTerminalMutationStaging(command, paths: paths)
            return true
        } catch {
            if let completedEntry {
                try queue.deferCompletedCleanup(
                    completedEntry,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
            } else {
                try queue.deferCompletedCleanup(
                    command,
                    lease: lease,
                    ownerMetadataURL: ownerMetadataURL
                )
            }
            return false
        }
    }

    private static func releaseTerminalMutationStaging(
        _ command: CoreCommand,
        paths: SharedContainerPaths
    ) throws {
        guard command.isFileProviderMutation else { return }
        try FileProviderStagingStore(root: paths.fileProviderStaging).release(id: command.id)
    }

    private static func persist(
        _ proposed: CoreSnapshot,
        paths: SharedContainerPaths,
        lease: CoreOwnerLease,
        coordinator: CoreProcessCoordinator,
        ownerMetadataURL: URL
    ) async throws -> CoreSnapshot {
        try await coordinator.validate(lease)
        let store = SharedSnapshotStore(snapshotURL: paths.snapshot)
        var snapshot = proposed
        if let current = try store.read(), snapshot.generation <= current.generation {
            guard current.generation < UInt64.max else {
                throw SharedSnapshotError.generationRegression(
                    current: current.generation,
                    proposed: snapshot.generation
                )
            }
            snapshot.generation = current.generation + 1
        }
        snapshot.ownerEpoch = lease.epoch
        snapshot.instanceID = lease.instanceID
        try await coordinator.validate(lease)
        try store.write(
            snapshot,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
        try await coordinator.validate(lease)
        _ = await MetadataIndexProjector(
            databaseURL: paths.metadataIndex,
            statusURL: paths.metadataIndexStatus
        ).project(snapshot)
        try await coordinator.validate(lease)
        return snapshot
    }

    private static func role(for trigger: SyncTrigger) -> CoreProcessRole {
        switch trigger {
        case .backgroundRefresh, .backgroundProcessing: .backgroundTask
        case .fileProvider: .fileProvider
        case .appIntent: .appIntent
        case .user, .foreground: .mainApp
        }
    }
}

private enum NetworkCorePolicyError: Error, Sendable {
    case denied([PolicyBlockReason])
    case configurationUnavailable
}

private final class NetworkCorePolicyMonitorState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: NetworkCorePolicyError?

    @discardableResult
    func record(_ failure: NetworkCorePolicyError) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedFailure == nil else { return false }
        storedFailure = failure
        return true
    }

    func failure() -> NetworkCorePolicyError? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    func validate() throws {
        if let failure = failure() { throw failure }
    }
}

private final class NetworkExpenseObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var seenExpensive = false

    func observe(_ isExpensive: Bool) {
        guard isExpensive else { return }
        lock.lock()
        seenExpensive = true
        lock.unlock()
    }

    var hasSeenExpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return seenExpensive
    }
}

private struct NetworkCorePolicyGate: Sendable {
    let policyURL: URL
    let trigger: SyncTrigger
    let requestedActions: Set<SyncAction>
    let requestedTemporaryOverride: Bool

    func validate(_ environment: SyncEnvironmentSnapshot) throws {
        let policy: SyncPolicy
        do {
            policy = try SyncPolicyStore(url: policyURL).load()
        } catch {
            throw NetworkCorePolicyError.configurationUnavailable
        }
        let decision = SyncPolicyEngine().evaluate(
            environment.policyInput(
                trigger: trigger,
                requestedActions: requestedActions.union(SyncAction.networkCoreRuntimeEnvelope),
                requestedTemporaryOverride: requestedTemporaryOverride,
                safetyScope: .networkCoreRuntime
            ),
            policy: policy
        )
        guard decision.blockedActions.isEmpty else {
            throw NetworkCorePolicyError.denied(decision.explanations.map(\.reason))
        }
    }
}

private struct MaterializationPolicyGate: Sendable {
    let policyURL: URL
    let trigger: SyncTrigger
    let itemSize: Int64
    let requestedTemporaryOverride: Bool

    func validate(
        _ environment: SyncEnvironmentSnapshot,
        additionalDiskBytes: Int64
    ) throws {
        let policy: SyncPolicy
        do {
            // Reload the single shared policy document at every live checkpoint
            // so an in-flight fetch cannot outlive a newly tightened setting.
            policy = try SyncPolicyStore(url: policyURL).load()
        } catch {
            throw NetworkCorePolicyError.configurationUnavailable
        }
        var current = environment
        // Materialization is one bounded read, but the started Syncthing App
        // may also service the active folders. Never replace a larger live
        // estimate with only the requested item's bytes.
        current.transfer.largestFileBytes = max(current.transfer.largestFileBytes, itemSize)
        current.transfer.totalBytes = max(current.transfer.totalBytes, itemSize)
        let decision = SyncPolicyEngine().evaluate(
            current.policyInput(
                trigger: trigger,
                requestedActions: SyncAction.networkCoreRuntimeEnvelope,
                additionalDiskBytes: additionalDiskBytes,
                requestedTemporaryOverride: requestedTemporaryOverride
            ),
            policy: policy
        )
        guard decision.blockedActions.isEmpty else {
            throw NetworkCorePolicyError.denied(decision.explanations.map(\.reason))
        }
    }
}
