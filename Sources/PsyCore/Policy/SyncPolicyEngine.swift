import Foundation

public enum SyncTrigger: String, Codable, CaseIterable, Sendable {
    case user
    case foreground
    case backgroundRefresh
    case backgroundProcessing
    case fileProvider
    case appIntent

    public var isUserInitiated: Bool {
        self == .user || self == .fileProvider || self == .appIntent
    }
}

public enum SyncAction: String, Codable, CaseIterable, Hashable, Sendable {
    case discover
    case exchangeIndex
    case upload
    case download
    case scan
    case hash
    case databaseMaintenance
    /// Removes only the system-managed File Provider cache copy. This is a
    /// local storage action, not a Syncthing delete or a network transfer.
    case evictLocalCopy
}

public enum NetworkKind: String, Codable, CaseIterable, Sendable {
    case unavailable
    case wifi
    case cellular
    case ethernet
    case other
}

public enum CellularAccess: String, Codable, CaseIterable, Sendable {
    case denied
    case uploadOnly
    case downloadOnly
    case smallFiles
    case allowed
}

public enum LowPowerBehavior: String, Codable, CaseIterable, Sendable {
    case pauseAutomatic
    case indexOnly
    case userRequestsOnly
    case allowed
}

public enum ThermalLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    private var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct NetworkState: Codable, Hashable, Sendable {
    public var kind: NetworkKind
    public var isExpensive: Bool
    public var isConstrained: Bool

    public init(kind: NetworkKind, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.kind = kind
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

public struct PowerState: Codable, Hashable, Sendable {
    public var batteryLevel: Double?
    public var isExternalPowerConnected: Bool
    public var isLowPowerModeEnabled: Bool
    public var thermalLevel: ThermalLevel

    public init(
        batteryLevel: Double?,
        isExternalPowerConnected: Bool,
        isLowPowerModeEnabled: Bool,
        thermalLevel: ThermalLevel
    ) {
        self.batteryLevel = batteryLevel
        self.isExternalPowerConnected = isExternalPowerConnected
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalLevel = thermalLevel
    }
}

public struct TransferEstimate: Codable, Hashable, Sendable {
    public var largestFileBytes: Int64
    public var totalBytes: Int64
    /// Exact pending bytes that may allocate local storage. `nil` preserves
    /// conservative behavior for legacy producers that only know total bytes.
    public var pendingDownloadBytes: Int64?
    /// `nil` means the embedded core did not provide an accurate daily byte
    /// counter. A daily limit must not be treated as enforced in that case.
    public var alreadyTransferredTodayBytes: Int64?

    public init(
        largestFileBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        pendingDownloadBytes: Int64? = nil,
        alreadyTransferredTodayBytes: Int64? = nil
    ) {
        self.largestFileBytes = max(0, largestFileBytes)
        self.totalBytes = max(0, totalBytes)
        self.pendingDownloadBytes = pendingDownloadBytes.map { max(0, $0) }
        self.alreadyTransferredTodayBytes = alreadyTransferredTodayBytes.map { max(0, $0) }
    }
}

public struct SyncSafetyState: Codable, Hashable, Sendable {
    public var hasConflict: Bool
    public var hasUnuploadedChanges: Bool
    public var isDatabaseMaintenanceActive: Bool
    public var isCoreOwnedByAnotherProcess: Bool
    public var availableDiskBytes: Int64

    public init(
        hasConflict: Bool = false,
        hasUnuploadedChanges: Bool = false,
        isDatabaseMaintenanceActive: Bool = false,
        isCoreOwnedByAnotherProcess: Bool = false,
        availableDiskBytes: Int64 = .max
    ) {
        self.hasConflict = hasConflict
        self.hasUnuploadedChanges = hasUnuploadedChanges
        self.isDatabaseMaintenanceActive = isDatabaseMaintenanceActive
        self.isCoreOwnedByAnotherProcess = isCoreOwnedByAnotherProcess
        self.availableDiskBytes = availableDiskBytes
    }
}

public struct TimeWindow: Codable, Hashable, Sendable {
    public var weekdays: Set<Int>
    public var startMinute: Int
    public var endMinute: Int

    public init(weekdays: Set<Int> = Set(1...7), startMinute: Int = 0, endMinute: Int = 24 * 60) {
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.startMinute = min(max(startMinute, 0), 24 * 60)
        self.endMinute = min(max(endMinute, 0), 24 * 60)
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        if startMinute <= endMinute {
            return weekdays.contains(weekday) && minute >= startMinute && minute < endMinute
        }

        if minute >= startMinute {
            return weekdays.contains(weekday)
        }
        guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { return false }
        return weekdays.contains(calendar.component(.weekday, from: previous)) && minute < endMinute
    }
}

public enum AutomaticBackgroundMode: String, Codable, CaseIterable, Sendable {
    /// Do not submit refresh or processing requests. Already-submitted requests
    /// also re-check this value before doing any application work.
    case disabled
    /// Submit only a short, local snapshot-validation refresh.
    case refreshOnly
    /// Submit both the short refresh and the longer policy-checked processing task.
    case refreshAndProcessing
}

public struct SyncPolicy: Codable, Hashable, Sendable {
    public var automaticallyAllowedNetworks: Set<NetworkKind>
    public var cellularAccess: CellularAccess
    public var allowExpensive: Bool
    public var allowConstrained: Bool
    public var maxCellularFileBytes: Int64?
    public var maxExpensiveRunBytes: Int64?
    public var dailyExpensiveBytes: Int64?
    public var requirePowerForAllAutomaticWork: Bool
    public var requirePowerForLargeTransferBytes: Int64?
    public var requirePowerForMaintenance: Bool
    public var minimumBatteryLevel: Double?
    public var lowPowerBehavior: LowPowerBehavior
    public var pauseTransfersAtThermalLevel: ThermalLevel
    public var minimumFreeDiskBytes: Int64
    public var automaticTimeWindows: [TimeWindow]
    public var automaticBackgroundMode: AutomaticBackgroundMode
    public var allowBackgroundUpload: Bool
    public var allowBackgroundDownload: Bool
    public var allowBackgroundScan: Bool
    public var allowTemporaryUserOverride: Bool

    public init(
        automaticallyAllowedNetworks: Set<NetworkKind> = [.wifi, .ethernet],
        cellularAccess: CellularAccess = .denied,
        allowExpensive: Bool = false,
        allowConstrained: Bool = false,
        maxCellularFileBytes: Int64? = 10 * 1_024 * 1_024,
        maxExpensiveRunBytes: Int64? = 100 * 1_024 * 1_024,
        dailyExpensiveBytes: Int64? = nil,
        requirePowerForAllAutomaticWork: Bool = false,
        requirePowerForLargeTransferBytes: Int64? = 500 * 1_024 * 1_024,
        requirePowerForMaintenance: Bool = true,
        minimumBatteryLevel: Double? = 0.20,
        lowPowerBehavior: LowPowerBehavior = .indexOnly,
        pauseTransfersAtThermalLevel: ThermalLevel = .serious,
        minimumFreeDiskBytes: Int64 = 512 * 1_024 * 1_024,
        automaticTimeWindows: [TimeWindow] = [],
        automaticBackgroundMode: AutomaticBackgroundMode = .refreshAndProcessing,
        allowBackgroundUpload: Bool = true,
        allowBackgroundDownload: Bool = true,
        allowBackgroundScan: Bool = true,
        allowTemporaryUserOverride: Bool = true
    ) {
        self.automaticallyAllowedNetworks = automaticallyAllowedNetworks
        self.cellularAccess = cellularAccess
        self.allowExpensive = allowExpensive
        self.allowConstrained = allowConstrained
        self.maxCellularFileBytes = maxCellularFileBytes
        self.maxExpensiveRunBytes = maxExpensiveRunBytes
        self.dailyExpensiveBytes = dailyExpensiveBytes
        self.requirePowerForAllAutomaticWork = requirePowerForAllAutomaticWork
        self.requirePowerForLargeTransferBytes = requirePowerForLargeTransferBytes
        self.requirePowerForMaintenance = requirePowerForMaintenance
        self.minimumBatteryLevel = minimumBatteryLevel
        self.lowPowerBehavior = lowPowerBehavior
        self.pauseTransfersAtThermalLevel = pauseTransfersAtThermalLevel
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
        self.automaticTimeWindows = automaticTimeWindows
        self.automaticBackgroundMode = automaticBackgroundMode
        self.allowBackgroundUpload = allowBackgroundUpload
        self.allowBackgroundDownload = allowBackgroundDownload
        self.allowBackgroundScan = allowBackgroundScan
        self.allowTemporaryUserOverride = allowTemporaryUserOverride
    }

    private enum CodingKeys: String, CodingKey {
        case automaticallyAllowedNetworks
        case cellularAccess
        case allowExpensive
        case allowConstrained
        case maxCellularFileBytes
        case maxExpensiveRunBytes
        case dailyExpensiveBytes
        case requirePowerForAllAutomaticWork
        case requirePowerForLargeTransferBytes
        case requirePowerForMaintenance
        case minimumBatteryLevel
        case lowPowerBehavior
        case pauseTransfersAtThermalLevel
        case minimumFreeDiskBytes
        case automaticTimeWindows
        case automaticBackgroundMode
        case allowBackgroundUpload
        case allowBackgroundDownload
        case allowBackgroundScan
        case allowTemporaryUserOverride
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automaticallyAllowedNetworks = try values.decode(
            Set<NetworkKind>.self,
            forKey: .automaticallyAllowedNetworks
        )
        cellularAccess = try values.decode(CellularAccess.self, forKey: .cellularAccess)
        allowExpensive = try values.decode(Bool.self, forKey: .allowExpensive)
        allowConstrained = try values.decode(Bool.self, forKey: .allowConstrained)
        maxCellularFileBytes = try values.decodeIfPresent(Int64.self, forKey: .maxCellularFileBytes)
        maxExpensiveRunBytes = try values.decodeIfPresent(Int64.self, forKey: .maxExpensiveRunBytes)
        dailyExpensiveBytes = try values.decodeIfPresent(Int64.self, forKey: .dailyExpensiveBytes)
        requirePowerForAllAutomaticWork = try values.decode(
            Bool.self,
            forKey: .requirePowerForAllAutomaticWork
        )
        requirePowerForLargeTransferBytes = try values.decodeIfPresent(
            Int64.self,
            forKey: .requirePowerForLargeTransferBytes
        )
        requirePowerForMaintenance = try values.decode(Bool.self, forKey: .requirePowerForMaintenance)
        minimumBatteryLevel = try values.decodeIfPresent(Double.self, forKey: .minimumBatteryLevel)
        lowPowerBehavior = try values.decode(LowPowerBehavior.self, forKey: .lowPowerBehavior)
        pauseTransfersAtThermalLevel = try values.decode(
            ThermalLevel.self,
            forKey: .pauseTransfersAtThermalLevel
        )
        minimumFreeDiskBytes = try values.decode(Int64.self, forKey: .minimumFreeDiskBytes)
        automaticTimeWindows = try values.decode([TimeWindow].self, forKey: .automaticTimeWindows)
        allowBackgroundUpload = try values.decode(Bool.self, forKey: .allowBackgroundUpload)
        allowBackgroundDownload = try values.decode(Bool.self, forKey: .allowBackgroundDownload)
        allowBackgroundScan = try values.decode(Bool.self, forKey: .allowBackgroundScan)
        if let explicitMode = try values.decodeIfPresent(
            AutomaticBackgroundMode.self,
            forKey: .automaticBackgroundMode
        ) {
            automaticBackgroundMode = explicitMode
        } else {
            // The old scheduler submitted processing only when all three
            // background directions were enabled; refresh stayed independent.
            automaticBackgroundMode =
                allowBackgroundUpload && allowBackgroundDownload && allowBackgroundScan
                ? .refreshAndProcessing : .refreshOnly
        }
        allowTemporaryUserOverride = try values.decode(Bool.self, forKey: .allowTemporaryUserOverride)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(automaticallyAllowedNetworks, forKey: .automaticallyAllowedNetworks)
        try values.encode(cellularAccess, forKey: .cellularAccess)
        try values.encode(allowExpensive, forKey: .allowExpensive)
        try values.encode(allowConstrained, forKey: .allowConstrained)
        try values.encodeIfPresent(maxCellularFileBytes, forKey: .maxCellularFileBytes)
        try values.encodeIfPresent(maxExpensiveRunBytes, forKey: .maxExpensiveRunBytes)
        try values.encodeIfPresent(dailyExpensiveBytes, forKey: .dailyExpensiveBytes)
        try values.encode(requirePowerForAllAutomaticWork, forKey: .requirePowerForAllAutomaticWork)
        try values.encodeIfPresent(
            requirePowerForLargeTransferBytes,
            forKey: .requirePowerForLargeTransferBytes
        )
        try values.encode(requirePowerForMaintenance, forKey: .requirePowerForMaintenance)
        try values.encodeIfPresent(minimumBatteryLevel, forKey: .minimumBatteryLevel)
        try values.encode(lowPowerBehavior, forKey: .lowPowerBehavior)
        try values.encode(pauseTransfersAtThermalLevel, forKey: .pauseTransfersAtThermalLevel)
        try values.encode(minimumFreeDiskBytes, forKey: .minimumFreeDiskBytes)
        try values.encode(automaticTimeWindows, forKey: .automaticTimeWindows)
        try values.encode(automaticBackgroundMode, forKey: .automaticBackgroundMode)
        try values.encode(allowBackgroundUpload, forKey: .allowBackgroundUpload)
        try values.encode(allowBackgroundDownload, forKey: .allowBackgroundDownload)
        try values.encode(allowBackgroundScan, forKey: .allowBackgroundScan)
        try values.encode(allowTemporaryUserOverride, forKey: .allowTemporaryUserOverride)
    }
}

public struct SyncPolicyInput: Codable, Hashable, Sendable {
    public var trigger: SyncTrigger
    public var requestedActions: Set<SyncAction>
    public var network: NetworkState
    public var power: PowerState
    public var transfer: TransferEstimate
    public var safety: SyncSafetyState
    /// Bytes that a download still needs to allocate on the destination
    /// volume. `nil` derives a conservative value from `transfer.totalBytes`;
    /// zero means the caller has already reserved the destination storage.
    public var additionalDiskBytes: Int64?
    public var now: Date
    public var requestedTemporaryOverride: Bool
    /// Distinguishes a destructive/item-specific download decision from the
    /// broad capability envelope of an already-authorized Syncthing run. The
    /// latter must be able to start so it can upload dirty bytes and let the
    /// core form/resolve conflicts; it does not authorize materialization or
    /// cache eviction of any specific item.
    public var safetyScope: SyncPolicySafetyScope

    public init(
        trigger: SyncTrigger,
        requestedActions: Set<SyncAction>,
        network: NetworkState,
        power: PowerState,
        transfer: TransferEstimate = .init(),
        safety: SyncSafetyState = .init(),
        additionalDiskBytes: Int64? = nil,
        now: Date = .now,
        requestedTemporaryOverride: Bool = false,
        safetyScope: SyncPolicySafetyScope = .operationSpecific
    ) {
        self.trigger = trigger
        self.requestedActions = requestedActions
        self.network = network
        self.power = power
        self.transfer = transfer
        self.safety = safety
        self.additionalDiskBytes = additionalDiskBytes.map { max(0, $0) }
        self.now = now
        self.requestedTemporaryOverride = requestedTemporaryOverride
        self.safetyScope = safetyScope
    }

    private enum CodingKeys: String, CodingKey {
        case trigger
        case requestedActions
        case network
        case power
        case transfer
        case safety
        case additionalDiskBytes
        case now
        case requestedTemporaryOverride
        case safetyScope
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try values.decode(SyncTrigger.self, forKey: .trigger)
        requestedActions = try values.decode(Set<SyncAction>.self, forKey: .requestedActions)
        network = try values.decode(NetworkState.self, forKey: .network)
        power = try values.decode(PowerState.self, forKey: .power)
        transfer = try values.decode(TransferEstimate.self, forKey: .transfer)
        safety = try values.decode(SyncSafetyState.self, forKey: .safety)
        additionalDiskBytes = try values.decodeIfPresent(Int64.self, forKey: .additionalDiskBytes).map {
            max(0, $0)
        }
        now = try values.decode(Date.self, forKey: .now)
        requestedTemporaryOverride = try values.decode(
            Bool.self,
            forKey: .requestedTemporaryOverride
        )
        safetyScope =
            try values.decodeIfPresent(
                SyncPolicySafetyScope.self,
                forKey: .safetyScope
            ) ?? .operationSpecific
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(trigger, forKey: .trigger)
        try values.encode(requestedActions, forKey: .requestedActions)
        try values.encode(network, forKey: .network)
        try values.encode(power, forKey: .power)
        try values.encode(transfer, forKey: .transfer)
        try values.encode(safety, forKey: .safety)
        try values.encodeIfPresent(additionalDiskBytes, forKey: .additionalDiskBytes)
        try values.encode(now, forKey: .now)
        try values.encode(requestedTemporaryOverride, forKey: .requestedTemporaryOverride)
        try values.encode(safetyScope, forKey: .safetyScope)
    }
}

public enum SyncPolicySafetyScope: String, Codable, Hashable, Sendable {
    case operationSpecific
    case networkCoreRuntime
}

public enum PolicyBlockReason: String, Codable, CaseIterable, Sendable {
    case noRequestedAction
    case coreBusy
    case databaseMaintenance
    case networkUnavailable
    case networkTypeDenied
    case cellularDirectionDenied
    case cellularFileTooLarge
    case expensiveNetworkDenied
    case constrainedNetworkDenied
    case runTransferLimit
    case dailyTransferLimit
    case dailyTransferAccountingUnavailable
    case outsideTimeWindow
    case externalPowerRequired
    case batteryTooLow
    case lowPowerMode
    case thermalPressure
    case insufficientDisk
    case backgroundActionDisabled
    case unresolvedConflict
    case unuploadedChanges
}

public struct PolicyExplanation: Codable, Hashable, Sendable {
    public var reason: PolicyBlockReason
    public var messageKey: String
    public var remedyKey: String
    public var canTemporarilyOverride: Bool

    public init(reason: PolicyBlockReason, canTemporarilyOverride: Bool) {
        self.reason = reason
        messageKey = "policy.block.\(reason.rawValue)"
        remedyKey = "policy.remedy.\(reason.rawValue)"
        self.canTemporarilyOverride = canTemporarilyOverride
    }
}

public struct SyncPolicyDecision: Codable, Hashable, Sendable {
    public var allowedActions: Set<SyncAction>
    public var blockedActions: Set<SyncAction>
    public var explanations: [PolicyExplanation]

    public var isAllowed: Bool { !allowedActions.isEmpty && blockedActions.isEmpty }
    public var primaryBlockReason: PolicyBlockReason? { explanations.first?.reason }

    public init(
        allowedActions: Set<SyncAction>,
        blockedActions: Set<SyncAction>,
        explanations: [PolicyExplanation]
    ) {
        self.allowedActions = allowedActions
        self.blockedActions = blockedActions
        self.explanations = explanations
    }
}

public struct SyncPolicyEngine: Sendable {
    public init() {}

    public func evaluate(
        _ input: SyncPolicyInput,
        policy: SyncPolicy,
        calendar: Calendar = .autoupdatingCurrent
    ) -> SyncPolicyDecision {
        guard !input.requestedActions.isEmpty else {
            return blocked(input.requestedActions, .noRequestedAction, overrideable: false)
        }

        var allowed = input.requestedActions
        var explanations: [PolicyExplanation] = []
        let override =
            input.requestedTemporaryOverride && input.trigger.isUserInitiated && policy.allowTemporaryUserOverride

        func deny(_ actions: Set<SyncAction>, _ reason: PolicyBlockReason, overrideable: Bool) {
            let affected = allowed.intersection(actions)
            guard !affected.isEmpty, !(override && overrideable) else { return }
            allowed.subtract(affected)
            explanations.append(
                .init(reason: reason, canTemporarilyOverride: overrideable && policy.allowTemporaryUserOverride))
        }

        let all = Set(SyncAction.allCases)
        let transfers: Set<SyncAction> = [.upload, .download]
        let networkActions: Set<SyncAction> = [.discover, .exchangeIndex, .upload, .download]
        let automatic = !input.trigger.isUserInitiated

        if input.safety.isCoreOwnedByAnotherProcess {
            deny(all, .coreBusy, overrideable: false)
        }
        if input.safety.isDatabaseMaintenanceActive {
            deny(all.subtracting([.databaseMaintenance]), .databaseMaintenance, overrideable: false)
        }
        if input.trigger == .backgroundProcessing,
            policy.automaticBackgroundMode != .refreshAndProcessing
        {
            deny(all, .backgroundActionDisabled, overrideable: false)
        } else if input.trigger == .backgroundRefresh,
            policy.automaticBackgroundMode == .disabled
        {
            deny(all, .backgroundActionDisabled, overrideable: false)
        }
        if input.safety.hasConflict, input.safetyScope == .operationSpecific {
            deny([.download], .unresolvedConflict, overrideable: false)
        }
        if input.safety.hasUnuploadedChanges, input.safetyScope == .operationSpecific {
            deny([.download], .unuploadedChanges, overrideable: false)
        }
        let unreservedDownloadBytes =
            input.requestedActions.contains(.download)
            ? max(
                0,
                input.additionalDiskBytes
                    ?? input.transfer.pendingDownloadBytes
                    ?? input.transfer.totalBytes
            )
            : 0
        let (requiredFreeDiskBytes, diskRequirementOverflowed) =
            max(0, policy.minimumFreeDiskBytes).addingReportingOverflow(unreservedDownloadBytes)
        if diskRequirementOverflowed || input.safety.availableDiskBytes < requiredFreeDiskBytes {
            deny([.download, .scan, .databaseMaintenance], .insufficientDisk, overrideable: false)
        }

        if !allowed.intersection(networkActions).isEmpty {
            if input.network.kind == .unavailable {
                deny(networkActions, .networkUnavailable, overrideable: false)
            } else if automatic, !policy.automaticallyAllowedNetworks.contains(input.network.kind),
                input.network.kind != .cellular
            {
                deny(networkActions, .networkTypeDenied, overrideable: true)
            }

            if input.network.kind == .cellular {
                switch policy.cellularAccess {
                case .denied:
                    deny(networkActions, .networkTypeDenied, overrideable: true)
                case .uploadOnly:
                    deny([.download], .cellularDirectionDenied, overrideable: true)
                case .downloadOnly:
                    deny([.upload], .cellularDirectionDenied, overrideable: true)
                case .smallFiles:
                    if let limit = policy.maxCellularFileBytes, input.transfer.largestFileBytes > limit {
                        deny(transfers, .cellularFileTooLarge, overrideable: true)
                    }
                case .allowed:
                    break
                }
            }

            if input.network.isExpensive, !policy.allowExpensive {
                deny(networkActions, .expensiveNetworkDenied, overrideable: true)
            }
            if input.network.isConstrained, !policy.allowConstrained {
                deny(networkActions, .constrainedNetworkDenied, overrideable: true)
            }
            if input.network.isExpensive {
                if let limit = policy.maxExpensiveRunBytes, input.transfer.totalBytes > limit {
                    deny(transfers, .runTransferLimit, overrideable: false)
                }
                if let limit = policy.dailyExpensiveBytes {
                    if let alreadyTransferredTodayBytes = input.transfer.alreadyTransferredTodayBytes {
                        let (projected, overflowed) = alreadyTransferredTodayBytes.addingReportingOverflow(
                            input.transfer.totalBytes
                        )
                        if overflowed || projected > limit {
                            deny(transfers, .dailyTransferLimit, overrideable: false)
                        }
                    } else {
                        deny(transfers, .dailyTransferAccountingUnavailable, overrideable: false)
                    }
                }
            }
        }

        if automatic, !policy.automaticTimeWindows.isEmpty,
            !policy.automaticTimeWindows.contains(where: { $0.contains(input.now, calendar: calendar) })
        {
            deny(all, .outsideTimeWindow, overrideable: true)
        }

        if automatic, policy.requirePowerForAllAutomaticWork, !input.power.isExternalPowerConnected {
            deny(all, .externalPowerRequired, overrideable: true)
        }
        if policy.requirePowerForMaintenance, !input.power.isExternalPowerConnected {
            deny([.databaseMaintenance], .externalPowerRequired, overrideable: true)
        }
        if let threshold = policy.requirePowerForLargeTransferBytes,
            input.transfer.totalBytes >= threshold,
            !input.power.isExternalPowerConnected
        {
            deny(transfers.union([.hash]), .externalPowerRequired, overrideable: true)
        }
        if let minimum = policy.minimumBatteryLevel,
            let battery = input.power.batteryLevel,
            battery < minimum,
            !input.power.isExternalPowerConnected
        {
            deny(all, .batteryTooLow, overrideable: true)
        }

        if input.power.isLowPowerModeEnabled {
            switch policy.lowPowerBehavior {
            case .pauseAutomatic where automatic:
                deny(all, .lowPowerMode, overrideable: true)
            case .indexOnly:
                deny(all.subtracting([.discover, .exchangeIndex]), .lowPowerMode, overrideable: true)
            case .userRequestsOnly where automatic:
                deny(all, .lowPowerMode, overrideable: true)
            case .pauseAutomatic, .userRequestsOnly, .allowed:
                break
            }
        }

        if input.power.thermalLevel >= policy.pauseTransfersAtThermalLevel {
            deny(transfers.union([.hash, .scan, .databaseMaintenance]), .thermalPressure, overrideable: true)
        }

        if input.trigger == .backgroundRefresh || input.trigger == .backgroundProcessing {
            if !policy.allowBackgroundUpload { deny([.upload], .backgroundActionDisabled, overrideable: false) }
            if !policy.allowBackgroundDownload { deny([.download], .backgroundActionDisabled, overrideable: false) }
            if !policy.allowBackgroundScan { deny([.scan], .backgroundActionDisabled, overrideable: false) }
        }

        return SyncPolicyDecision(
            allowedActions: allowed,
            blockedActions: input.requestedActions.subtracting(allowed),
            explanations: explanations
        )
    }

    private func blocked(
        _ actions: Set<SyncAction>,
        _ reason: PolicyBlockReason,
        overrideable: Bool
    ) -> SyncPolicyDecision {
        SyncPolicyDecision(
            allowedActions: [],
            blockedActions: actions,
            explanations: [.init(reason: reason, canTemporarilyOverride: overrideable)]
        )
    }
}
