import Foundation

public enum SyncPolicyDocumentError: Error, Hashable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidDocument
    case unknownField(String)
    case duplicateField(String)
    case invalidBudgetTimeZoneIdentifier(String)
    case duplicateFolderOverride(folderID: String)
    case duplicateTemporaryProfile(id: UUID)
    case duplicateTemporaryProfileName(String)
    case invalidFolderIncarnationDigest(String)
    case staleFolderOverride(folderID: String)
    case invalidPolicy(String)
    case unrepresentableConservativeMerge(String)
}

/// A reusable, user-authored capability for one durable network task. The
/// profile never replaces global or folder policy. It can request the existing
/// user-only override path and always installs a finite protocol-byte ceiling.
public struct TemporarySyncPolicyProfile: Codable, Hashable, Sendable, Identifiable {
    public static let maximumProfiles = 64
    public static let maximumNetworkBytes = Int64(8 * 1_024 * 1_024 * 1_024)
    public static let minimumValiditySeconds: Int64 = 60
    public static let maximumValiditySeconds: Int64 = 24 * 60 * 60

    public var id: UUID
    public var name: String
    public var maximumNetworkBytes: Int64
    public var validitySeconds: Int64
    public var requestsTemporaryOverride: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        maximumNetworkBytes: Int64 = 100 * 1_024 * 1_024,
        validitySeconds: Int64 = 15 * 60,
        requestsTemporaryOverride: Bool = true
    ) {
        self.id = id
        self.name = name
        self.maximumNetworkBytes = maximumNetworkBytes
        self.validitySeconds = validitySeconds
        self.requestsTemporaryOverride = requestsTemporaryOverride
    }

    public func validated() throws -> Self {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == name,
            Array(name.utf8) == Array(name.precomposedStringWithCanonicalMapping.utf8),
            !name.isEmpty, name.utf8.count <= 64,
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            (1...Self.maximumNetworkBytes).contains(maximumNetworkBytes),
            (Self.minimumValiditySeconds...Self.maximumValiditySeconds).contains(validitySeconds)
        else {
            throw SyncPolicyDocumentError.invalidPolicy("temporaryProfile")
        }
        return self
    }
}

/// An optional byte cap needs three states: use the inherited value, remove a
/// cap explicitly, or install a finite cap. `nil` cannot distinguish the first
/// two states in a folder override.
public enum PolicyByteLimit: Hashable, Sendable {
    case inherit
    case unlimited
    case limit(Int64)

    public func resolved(inheriting inherited: Int64?) throws -> Int64? {
        switch self {
        case .inherit:
            return inherited
        case .unlimited:
            return nil
        case .limit(let bytes):
            guard bytes >= 0 else {
                throw SyncPolicyDocumentError.invalidPolicy("negativeByteLimit")
            }
            return bytes
        }
    }

    /// Produces the strictest representable value for a task spanning several
    /// folders. Inheritance is neutral, any finite cap wins over unlimited,
    /// and the smallest finite cap wins.
    public static func conservativelyMerged(_ values: [PolicyByteLimit]) -> PolicyByteLimit {
        var sawUnlimited = false
        var finite: Int64?
        for value in values {
            switch value {
            case .inherit:
                continue
            case .unlimited:
                sawUnlimited = true
            case .limit(let bytes):
                finite = min(finite ?? bytes, bytes)
            }
        }
        if let finite { return .limit(finite) }
        return sawUnlimited ? .unlimited : .inherit
    }
}

extension PolicyByteLimit: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case bytes
    }

    private enum Mode: String, Codable {
        case inherit
        case unlimited
        case limit
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Mode.self, forKey: .mode) {
        case .inherit:
            guard !values.contains(.bytes) else {
                throw SyncPolicyDocumentError.invalidPolicy("inheritLimitContainsBytes")
            }
            self = .inherit
        case .unlimited:
            guard !values.contains(.bytes) else {
                throw SyncPolicyDocumentError.invalidPolicy("unlimitedLimitContainsBytes")
            }
            self = .unlimited
        case .limit:
            let bytes = try values.decode(Int64.self, forKey: .bytes)
            guard bytes >= 0 else {
                throw SyncPolicyDocumentError.invalidPolicy("negativeByteLimit")
            }
            self = .limit(bytes)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit:
            try values.encode(Mode.inherit, forKey: .mode)
        case .unlimited:
            try values.encode(Mode.unlimited, forKey: .mode)
        case .limit(let bytes):
            guard bytes >= 0 else {
                throw SyncPolicyDocumentError.invalidPolicy("negativeByteLimit")
            }
            try values.encode(Mode.limit, forKey: .mode)
            try values.encode(bytes, forKey: .bytes)
        }
    }
}

/// Sparse policy changes for a single folder incarnation. Optional scalar
/// fields inherit the global value; optional byte caps use `PolicyByteLimit`
/// so an explicit unlimited value remains distinct from inheritance.
public struct SyncPolicyOverride: Codable, Hashable, Sendable {
    public var automaticallyAllowedNetworks: Set<NetworkKind>?
    public var cellularAccess: CellularAccess?
    public var allowExpensive: Bool?
    public var allowConstrained: Bool?
    public var maxCellularFileBytes: PolicyByteLimit
    public var maxExpensiveRunBytes: PolicyByteLimit
    public var dailyExpensiveBytes: PolicyByteLimit
    public var requirePowerForAllAutomaticWork: Bool?
    public var requirePowerForLargeTransferBytes: PolicyByteLimit
    public var requirePowerForMaintenance: Bool?
    public var minimumBatteryLevel: Double?
    public var lowPowerBehavior: LowPowerBehavior?
    public var pauseTransfersAtThermalLevel: ThermalLevel?
    public var minimumFreeDiskBytes: Int64?
    public var automaticTimeWindows: [TimeWindow]?
    public var allowBackgroundUpload: Bool?
    public var allowBackgroundDownload: Bool?
    public var allowBackgroundScan: Bool?
    public var allowTemporaryUserOverride: Bool?

    public init(
        automaticallyAllowedNetworks: Set<NetworkKind>? = nil,
        cellularAccess: CellularAccess? = nil,
        allowExpensive: Bool? = nil,
        allowConstrained: Bool? = nil,
        maxCellularFileBytes: PolicyByteLimit = .inherit,
        maxExpensiveRunBytes: PolicyByteLimit = .inherit,
        dailyExpensiveBytes: PolicyByteLimit = .inherit,
        requirePowerForAllAutomaticWork: Bool? = nil,
        requirePowerForLargeTransferBytes: PolicyByteLimit = .inherit,
        requirePowerForMaintenance: Bool? = nil,
        minimumBatteryLevel: Double? = nil,
        lowPowerBehavior: LowPowerBehavior? = nil,
        pauseTransfersAtThermalLevel: ThermalLevel? = nil,
        minimumFreeDiskBytes: Int64? = nil,
        automaticTimeWindows: [TimeWindow]? = nil,
        allowBackgroundUpload: Bool? = nil,
        allowBackgroundDownload: Bool? = nil,
        allowBackgroundScan: Bool? = nil,
        allowTemporaryUserOverride: Bool? = nil
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
        self.allowBackgroundUpload = allowBackgroundUpload
        self.allowBackgroundDownload = allowBackgroundDownload
        self.allowBackgroundScan = allowBackgroundScan
        self.allowTemporaryUserOverride = allowTemporaryUserOverride
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
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
        case allowBackgroundUpload
        case allowBackgroundDownload
        case allowBackgroundScan
        case allowTemporaryUserOverride
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automaticallyAllowedNetworks = try values.decodeIfPresent(
            Set<NetworkKind>.self,
            forKey: .automaticallyAllowedNetworks
        )
        cellularAccess = try values.decodeIfPresent(CellularAccess.self, forKey: .cellularAccess)
        allowExpensive = try values.decodeIfPresent(Bool.self, forKey: .allowExpensive)
        allowConstrained = try values.decodeIfPresent(Bool.self, forKey: .allowConstrained)
        maxCellularFileBytes =
            try values.decodeIfPresent(
                PolicyByteLimit.self,
                forKey: .maxCellularFileBytes
            ) ?? .inherit
        maxExpensiveRunBytes =
            try values.decodeIfPresent(
                PolicyByteLimit.self,
                forKey: .maxExpensiveRunBytes
            ) ?? .inherit
        dailyExpensiveBytes =
            try values.decodeIfPresent(
                PolicyByteLimit.self,
                forKey: .dailyExpensiveBytes
            ) ?? .inherit
        requirePowerForAllAutomaticWork = try values.decodeIfPresent(
            Bool.self,
            forKey: .requirePowerForAllAutomaticWork
        )
        requirePowerForLargeTransferBytes =
            try values.decodeIfPresent(
                PolicyByteLimit.self,
                forKey: .requirePowerForLargeTransferBytes
            ) ?? .inherit
        requirePowerForMaintenance = try values.decodeIfPresent(
            Bool.self,
            forKey: .requirePowerForMaintenance
        )
        minimumBatteryLevel = try values.decodeIfPresent(Double.self, forKey: .minimumBatteryLevel)
        lowPowerBehavior = try values.decodeIfPresent(LowPowerBehavior.self, forKey: .lowPowerBehavior)
        pauseTransfersAtThermalLevel = try values.decodeIfPresent(
            ThermalLevel.self,
            forKey: .pauseTransfersAtThermalLevel
        )
        minimumFreeDiskBytes = try values.decodeIfPresent(Int64.self, forKey: .minimumFreeDiskBytes)
        automaticTimeWindows = try values.decodeIfPresent([TimeWindow].self, forKey: .automaticTimeWindows)
        allowBackgroundUpload = try values.decodeIfPresent(Bool.self, forKey: .allowBackgroundUpload)
        allowBackgroundDownload = try values.decodeIfPresent(Bool.self, forKey: .allowBackgroundDownload)
        allowBackgroundScan = try values.decodeIfPresent(Bool.self, forKey: .allowBackgroundScan)
        allowTemporaryUserOverride = try values.decodeIfPresent(
            Bool.self,
            forKey: .allowTemporaryUserOverride
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let automaticallyAllowedNetworks {
            try values.encode(
                automaticallyAllowedNetworks.map(\.rawValue).sorted(),
                forKey: .automaticallyAllowedNetworks
            )
        }
        try values.encodeIfPresent(cellularAccess, forKey: .cellularAccess)
        try values.encodeIfPresent(allowExpensive, forKey: .allowExpensive)
        try values.encodeIfPresent(allowConstrained, forKey: .allowConstrained)
        if maxCellularFileBytes != .inherit {
            try values.encode(maxCellularFileBytes, forKey: .maxCellularFileBytes)
        }
        if maxExpensiveRunBytes != .inherit {
            try values.encode(maxExpensiveRunBytes, forKey: .maxExpensiveRunBytes)
        }
        if dailyExpensiveBytes != .inherit {
            try values.encode(dailyExpensiveBytes, forKey: .dailyExpensiveBytes)
        }
        try values.encodeIfPresent(
            requirePowerForAllAutomaticWork,
            forKey: .requirePowerForAllAutomaticWork
        )
        if requirePowerForLargeTransferBytes != .inherit {
            try values.encode(requirePowerForLargeTransferBytes, forKey: .requirePowerForLargeTransferBytes)
        }
        try values.encodeIfPresent(requirePowerForMaintenance, forKey: .requirePowerForMaintenance)
        try values.encodeIfPresent(minimumBatteryLevel, forKey: .minimumBatteryLevel)
        try values.encodeIfPresent(lowPowerBehavior, forKey: .lowPowerBehavior)
        try values.encodeIfPresent(pauseTransfersAtThermalLevel, forKey: .pauseTransfersAtThermalLevel)
        try values.encodeIfPresent(minimumFreeDiskBytes, forKey: .minimumFreeDiskBytes)
        if let automaticTimeWindows {
            try values.encode(
                automaticTimeWindows.map(CanonicalTimeWindow.init).sorted(),
                forKey: .automaticTimeWindows
            )
        }
        try values.encodeIfPresent(allowBackgroundUpload, forKey: .allowBackgroundUpload)
        try values.encodeIfPresent(allowBackgroundDownload, forKey: .allowBackgroundDownload)
        try values.encodeIfPresent(allowBackgroundScan, forKey: .allowBackgroundScan)
        try values.encodeIfPresent(allowTemporaryUserOverride, forKey: .allowTemporaryUserOverride)
    }
}

public struct FolderSyncPolicyOverride: Codable, Hashable, Sendable {
    public var folderID: FolderID
    public var folderIncarnationDigest: String
    public var queuePriority: FolderQueuePriority
    public var policy: SyncPolicyOverride

    public init(
        folderID: FolderID,
        folderIncarnationDigest: String,
        queuePriority: FolderQueuePriority = .normal,
        policy: SyncPolicyOverride = .init()
    ) {
        self.folderID = folderID
        self.folderIncarnationDigest = folderIncarnationDigest
        self.queuePriority = queuePriority
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case folderID
        case folderIncarnationDigest
        case queuePriority
        case policy
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folderID = try values.decode(FolderID.self, forKey: .folderID)
        folderIncarnationDigest = try values.decode(String.self, forKey: .folderIncarnationDigest)
        queuePriority =
            try values.decodeIfPresent(
                FolderQueuePriority.self,
                forKey: .queuePriority
            ) ?? .normal
        policy = try values.decode(SyncPolicyOverride.self, forKey: .policy)
    }
}

/// Policy-owned priority persisted with the trusted folder incarnation. Its
/// raw value maps directly to `CoreFolderSchedulingPriority`; the queue still
/// treats absent or invalid external raw values as normal.
public enum FolderQueuePriority: Int, Codable, CaseIterable, Hashable, Sendable {
    case low = -1
    case normal = 0
    case high = 1

    public var coreSchedulingPriorityRawValue: Int { rawValue }
}

public struct FolderPolicyContext: Hashable, Sendable {
    public var folderID: FolderID
    public var folderIncarnationDigest: String

    public init(folderID: FolderID, folderIncarnationDigest: String) {
        self.folderID = folderID
        self.folderIncarnationDigest = folderIncarnationDigest
    }
}

public struct SyncPolicyDocumentV2: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var budgetTimeZoneIdentifier: String
    public var global: SyncPolicy
    public var folderOverrides: [FolderSyncPolicyOverride]
    public var temporaryProfiles: [TemporarySyncPolicyProfile]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        budgetTimeZoneIdentifier: String,
        global: SyncPolicy = .init(),
        folderOverrides: [FolderSyncPolicyOverride] = [],
        temporaryProfiles: [TemporarySyncPolicyProfile] = []
    ) {
        self.schemaVersion = schemaVersion
        self.budgetTimeZoneIdentifier = budgetTimeZoneIdentifier
        self.global = global
        self.folderOverrides = folderOverrides
        self.temporaryProfiles = temporaryProfiles
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case budgetTimeZoneIdentifier
        case global
        case folderOverrides
        case temporaryProfiles
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SyncPolicyDocumentError.unsupportedSchemaVersion(schemaVersion)
        }
        budgetTimeZoneIdentifier = try values.decode(String.self, forKey: .budgetTimeZoneIdentifier)
        global = try values.decode(SyncPolicy.self, forKey: .global)
        folderOverrides = try values.decode([FolderSyncPolicyOverride].self, forKey: .folderOverrides)
        temporaryProfiles =
            try values.decodeIfPresent(
                [TemporarySyncPolicyProfile].self,
                forKey: .temporaryProfiles
            ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(budgetTimeZoneIdentifier, forKey: .budgetTimeZoneIdentifier)
        try values.encode(CanonicalSyncPolicy(global), forKey: .global)
        try values.encode(
            folderOverrides.sorted(by: Self.overrideSort),
            forKey: .folderOverrides
        )
        try values.encode(
            temporaryProfiles.sorted(by: Self.profileSort),
            forKey: .temporaryProfiles
        )
    }

    public func validated() throws -> SyncPolicyDocumentV2 {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SyncPolicyDocumentError.unsupportedSchemaVersion(schemaVersion)
        }
        try Self.validateTimeZoneIdentifier(budgetTimeZoneIdentifier)
        try Self.validate(global)
        guard folderOverrides.count <= 4_096 else {
            throw SyncPolicyDocumentError.invalidPolicy("tooManyFolderOverrides")
        }
        var seen = Set<FolderID>()
        for entry in folderOverrides {
            guard seen.insert(entry.folderID).inserted else {
                throw SyncPolicyDocumentError.duplicateFolderOverride(folderID: entry.folderID.rawValue)
            }
            guard Self.isCanonicalDigest(entry.folderIncarnationDigest) else {
                throw SyncPolicyDocumentError.invalidFolderIncarnationDigest(
                    entry.folderIncarnationDigest
                )
            }
            try Self.validate(entry.policy)
        }
        guard temporaryProfiles.count <= TemporarySyncPolicyProfile.maximumProfiles else {
            throw SyncPolicyDocumentError.invalidPolicy("tooManyTemporaryProfiles")
        }
        var profileIDs = Set<UUID>()
        var profileNames = Set<String>()
        for profile in temporaryProfiles {
            _ = try profile.validated()
            guard profileIDs.insert(profile.id).inserted else {
                throw SyncPolicyDocumentError.duplicateTemporaryProfile(id: profile.id)
            }
            let foldedName = profile.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).precomposedStringWithCanonicalMapping
            guard profileNames.insert(foldedName).inserted else {
                throw SyncPolicyDocumentError.duplicateTemporaryProfileName(profile.name)
            }
        }
        var value = self
        value.folderOverrides.sort(by: Self.overrideSort)
        value.temporaryProfiles.sort(by: Self.profileSort)
        return value
    }

    /// Validates both the serialized shape and every folder's ability to form
    /// a conservative effective policy from the candidate global policy.
    /// Persistence entry points must call this before replacing on-disk bytes.
    public func validatedForPersistence() throws -> SyncPolicyDocumentV2 {
        let document = try validated()
        for entry in document.folderOverrides {
            _ = try Self.applying(entry.policy, to: document.global)
        }
        return document
    }

    public func fixedBudgetCalendar() throws -> Calendar {
        try Self.validateTimeZoneIdentifier(budgetTimeZoneIdentifier)
        guard let zone = TimeZone(identifier: budgetTimeZoneIdentifier) else {
            throw SyncPolicyDocumentError.invalidBudgetTimeZoneIdentifier(
                budgetTimeZoneIdentifier
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = zone
        return calendar
    }

    public func resolvedPolicy(
        for folderID: FolderID,
        folderIncarnationDigest: String
    ) throws -> SyncPolicy {
        let document = try validated()
        guard let entry = document.folderOverrides.first(where: { $0.folderID == folderID }) else {
            return document.global
        }
        guard entry.folderIncarnationDigest == folderIncarnationDigest else {
            throw SyncPolicyDocumentError.staleFolderOverride(folderID: folderID.rawValue)
        }
        return try Self.applying(entry.policy, to: document.global)
    }

    public func conservativePolicy(for contexts: [FolderPolicyContext]) throws -> SyncPolicy {
        let document = try validated()
        guard !contexts.isEmpty else { return document.global }
        var seen = Set<FolderID>()
        var policies: [SyncPolicy] = []
        for context in contexts.sorted(by: {
            if $0.folderID.rawValue != $1.folderID.rawValue {
                return $0.folderID.rawValue < $1.folderID.rawValue
            }
            return $0.folderIncarnationDigest < $1.folderIncarnationDigest
        }) {
            guard seen.insert(context.folderID).inserted else {
                throw SyncPolicyDocumentError.duplicateFolderOverride(
                    folderID: context.folderID.rawValue
                )
            }
            policies.append(
                try document.resolvedPolicy(
                    for: context.folderID,
                    folderIncarnationDigest: context.folderIncarnationDigest
                )
            )
        }
        return try Self.conservativelyMerge(policies)
    }

    static func validateTimeZoneIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty,
            identifier.utf8.count <= 128,
            !identifier.contains("\0"),
            TimeZone(identifier: identifier) != nil
        else {
            throw SyncPolicyDocumentError.invalidBudgetTimeZoneIdentifier(identifier)
        }
    }

    static func validate(_ policy: SyncPolicy) throws {
        for (name, value) in [
            ("maxCellularFileBytes", policy.maxCellularFileBytes),
            ("maxExpensiveRunBytes", policy.maxExpensiveRunBytes),
            ("dailyExpensiveBytes", policy.dailyExpensiveBytes),
            ("requirePowerForLargeTransferBytes", policy.requirePowerForLargeTransferBytes),
        ] where value.map({ $0 < 0 }) == true {
            throw SyncPolicyDocumentError.invalidPolicy(name)
        }
        guard policy.minimumFreeDiskBytes >= 0 else {
            throw SyncPolicyDocumentError.invalidPolicy("minimumFreeDiskBytes")
        }
        if let battery = policy.minimumBatteryLevel,
            !battery.isFinite || !(0...1).contains(battery)
        {
            throw SyncPolicyDocumentError.invalidPolicy("minimumBatteryLevel")
        }
        try validate(policy.automaticTimeWindows)
    }

    static func validate(_ policy: SyncPolicyOverride) throws {
        for limit in [
            policy.maxCellularFileBytes,
            policy.maxExpensiveRunBytes,
            policy.dailyExpensiveBytes,
            policy.requirePowerForLargeTransferBytes,
        ] {
            _ = try limit.resolved(inheriting: nil)
        }
        if let minimumFreeDiskBytes = policy.minimumFreeDiskBytes,
            minimumFreeDiskBytes < 0
        {
            throw SyncPolicyDocumentError.invalidPolicy("minimumFreeDiskBytes")
        }
        if let battery = policy.minimumBatteryLevel,
            !battery.isFinite || !(0...1).contains(battery)
        {
            throw SyncPolicyDocumentError.invalidPolicy("minimumBatteryLevel")
        }
        if let windows = policy.automaticTimeWindows { try validate(windows) }
    }

    private static func validate(_ windows: [TimeWindow]) throws {
        guard windows.count <= 1_024 else {
            throw SyncPolicyDocumentError.invalidPolicy("tooManyAutomaticTimeWindows")
        }
        for window in windows {
            guard window.weekdays.allSatisfy({ (1...7).contains($0) }),
                (0...1_440).contains(window.startMinute),
                (0...1_440).contains(window.endMinute)
            else {
                throw SyncPolicyDocumentError.invalidPolicy("automaticTimeWindows")
            }
        }
    }

    private static func applying(
        _ override: SyncPolicyOverride,
        to inherited: SyncPolicy
    ) throws -> SyncPolicy {
        try validate(override)
        var result = inherited
        if let value = override.automaticallyAllowedNetworks {
            result.automaticallyAllowedNetworks.formIntersection(value)
        }
        if let value = override.cellularAccess {
            result.cellularAccess = conservativeCellularAccess(inherited.cellularAccess, value)
        }
        if let value = override.allowExpensive {
            result.allowExpensive = inherited.allowExpensive && value
        }
        if let value = override.allowConstrained {
            result.allowConstrained = inherited.allowConstrained && value
        }
        result.maxCellularFileBytes = try tightenedLimit(
            override.maxCellularFileBytes,
            inherited: inherited.maxCellularFileBytes
        )
        result.maxExpensiveRunBytes = try tightenedLimit(
            override.maxExpensiveRunBytes,
            inherited: inherited.maxExpensiveRunBytes
        )
        // Daily accounting is a single cross-folder hard ceiling. A folder may
        // add a tighter ceiling but can never erase or raise the global one.
        switch override.dailyExpensiveBytes {
        case .inherit, .unlimited:
            result.dailyExpensiveBytes = inherited.dailyExpensiveBytes
        case .limit(let bytes):
            guard bytes >= 0 else {
                throw SyncPolicyDocumentError.invalidPolicy("negativeByteLimit")
            }
            result.dailyExpensiveBytes = minimumLimit(
                inherited.dailyExpensiveBytes,
                bytes
            )
        }
        if let value = override.requirePowerForAllAutomaticWork {
            result.requirePowerForAllAutomaticWork =
                inherited.requirePowerForAllAutomaticWork || value
        }
        result.requirePowerForLargeTransferBytes = try tightenedLimit(
            override.requirePowerForLargeTransferBytes,
            inherited: inherited.requirePowerForLargeTransferBytes
        )
        if let value = override.requirePowerForMaintenance {
            result.requirePowerForMaintenance = inherited.requirePowerForMaintenance || value
        }
        if let value = override.minimumBatteryLevel {
            result.minimumBatteryLevel = maximumMinimum(inherited.minimumBatteryLevel, value)
        }
        if let value = override.lowPowerBehavior {
            result.lowPowerBehavior = try conservativeLowPowerBehavior(
                inherited.lowPowerBehavior,
                value
            )
        }
        if let value = override.pauseTransfersAtThermalLevel {
            result.pauseTransfersAtThermalLevel =
                thermalRank(inherited.pauseTransfersAtThermalLevel) <= thermalRank(value)
                ? inherited.pauseTransfersAtThermalLevel : value
        }
        if let value = override.minimumFreeDiskBytes {
            // Free-space reserve is a safety floor, not a preference a folder
            // is allowed to weaken.
            result.minimumFreeDiskBytes = max(inherited.minimumFreeDiskBytes, value)
        }
        if let value = override.automaticTimeWindows {
            result.automaticTimeWindows = intersectTimeWindows(
                inherited.automaticTimeWindows,
                value
            )
        }
        if let value = override.allowBackgroundUpload {
            result.allowBackgroundUpload = inherited.allowBackgroundUpload && value
        }
        if let value = override.allowBackgroundDownload {
            result.allowBackgroundDownload = inherited.allowBackgroundDownload && value
        }
        if let value = override.allowBackgroundScan {
            result.allowBackgroundScan = inherited.allowBackgroundScan && value
        }
        // A folder can disable temporary bypasses but cannot enable one that
        // the global safety policy forbids.
        result.allowTemporaryUserOverride =
            inherited.allowTemporaryUserOverride
            && (override.allowTemporaryUserOverride ?? true)
        try validate(result)
        return result
    }

    /// Folder policy is an additional restriction layer. An explicit
    /// unlimited value can remove a folder-owned limit only when the global
    /// policy is already unlimited; it can never erase or raise a global cap.
    private static func tightenedLimit(
        _ override: PolicyByteLimit,
        inherited: Int64?
    ) throws -> Int64? {
        switch override {
        case .inherit, .unlimited:
            return inherited
        case .limit(let bytes):
            guard bytes >= 0 else {
                throw SyncPolicyDocumentError.invalidPolicy("negativeByteLimit")
            }
            return minimumLimit(inherited, bytes)
        }
    }

    private static func conservativelyMerge(_ policies: [SyncPolicy]) throws -> SyncPolicy {
        guard var result = policies.first else { return SyncPolicy() }
        for policy in policies.dropFirst() {
            result.automaticallyAllowedNetworks.formIntersection(policy.automaticallyAllowedNetworks)
            result.cellularAccess = conservativeCellularAccess(result.cellularAccess, policy.cellularAccess)
            result.allowExpensive = result.allowExpensive && policy.allowExpensive
            result.allowConstrained = result.allowConstrained && policy.allowConstrained
            result.maxCellularFileBytes = minimumLimit(
                result.maxCellularFileBytes,
                policy.maxCellularFileBytes
            )
            result.maxExpensiveRunBytes = minimumLimit(
                result.maxExpensiveRunBytes,
                policy.maxExpensiveRunBytes
            )
            result.dailyExpensiveBytes = minimumLimit(
                result.dailyExpensiveBytes,
                policy.dailyExpensiveBytes
            )
            result.requirePowerForAllAutomaticWork =
                result.requirePowerForAllAutomaticWork || policy.requirePowerForAllAutomaticWork
            result.requirePowerForLargeTransferBytes = minimumLimit(
                result.requirePowerForLargeTransferBytes,
                policy.requirePowerForLargeTransferBytes
            )
            result.requirePowerForMaintenance =
                result.requirePowerForMaintenance || policy.requirePowerForMaintenance
            result.minimumBatteryLevel = maximumMinimum(
                result.minimumBatteryLevel,
                policy.minimumBatteryLevel
            )
            result.lowPowerBehavior = try conservativeLowPowerBehavior(
                result.lowPowerBehavior,
                policy.lowPowerBehavior
            )
            result.pauseTransfersAtThermalLevel =
                thermalRank(result.pauseTransfersAtThermalLevel)
                    <= thermalRank(policy.pauseTransfersAtThermalLevel)
                ? result.pauseTransfersAtThermalLevel
                : policy.pauseTransfersAtThermalLevel
            result.minimumFreeDiskBytes = max(
                result.minimumFreeDiskBytes,
                policy.minimumFreeDiskBytes
            )
            result.automaticTimeWindows = intersectTimeWindows(
                result.automaticTimeWindows,
                policy.automaticTimeWindows
            )
            result.allowBackgroundUpload = result.allowBackgroundUpload && policy.allowBackgroundUpload
            result.allowBackgroundDownload = result.allowBackgroundDownload && policy.allowBackgroundDownload
            result.allowBackgroundScan = result.allowBackgroundScan && policy.allowBackgroundScan
            result.allowTemporaryUserOverride =
                result.allowTemporaryUserOverride && policy.allowTemporaryUserOverride
        }
        try validate(result)
        return result
    }

    private static func minimumLimit(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case (let value?, nil), (nil, let value?): value
        case (let lhs?, let rhs?): min(lhs, rhs)
        }
    }

    private static func maximumMinimum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case (nil, nil): nil
        case (let value?, nil), (nil, let value?): value
        case (let lhs?, let rhs?): max(lhs, rhs)
        }
    }

    private static func conservativeCellularAccess(
        _ lhs: CellularAccess,
        _ rhs: CellularAccess
    ) -> CellularAccess {
        if lhs == rhs { return lhs }
        if lhs == .allowed { return rhs }
        if rhs == .allowed { return lhs }
        return .denied
    }

    private static func conservativeLowPowerBehavior(
        _ lhs: LowPowerBehavior,
        _ rhs: LowPowerBehavior
    ) throws -> LowPowerBehavior {
        if lhs == rhs { return lhs }
        if lhs == .allowed { return rhs }
        if rhs == .allowed { return lhs }
        if (lhs == .pauseAutomatic && rhs == .userRequestsOnly)
            || (lhs == .userRequestsOnly && rhs == .pauseAutomatic)
        {
            // These are behaviorally equivalent in the current policy engine:
            // both deny every automatic action and allow user-initiated work.
            return .pauseAutomatic
        }
        // `pauseAutomatic`, `userRequestsOnly`, and `indexOnly` restrict
        // different action sets. Picking any one for unlike inputs can permit
        // an action denied by another folder, so the merge must fail closed.
        throw SyncPolicyDocumentError.unrepresentableConservativeMerge(
            "lowPowerBehavior"
        )
    }

    private static func thermalRank(_ value: ThermalLevel) -> Int {
        ThermalLevel.allCases.firstIndex(of: value) ?? 0
    }

    private static func intersectTimeWindows(
        _ lhs: [TimeWindow],
        _ rhs: [TimeWindow]
    ) -> [TimeWindow] {
        let left = allowedMinutes(lhs)
        let right = allowedMinutes(rhs)
        let intersection = zip(left, right).map { $0 && $1 }
        if intersection.allSatisfy({ $0 }) { return [] }

        var weekdaysByInterval: [MinuteInterval: Set<Int>] = [:]
        for weekday in 1...7 {
            let offset = (weekday - 1) * 1_440
            var minute = 0
            while minute < 1_440 {
                guard intersection[offset + minute] else {
                    minute += 1
                    continue
                }
                let start = minute
                while minute < 1_440, intersection[offset + minute] { minute += 1 }
                weekdaysByInterval[MinuteInterval(start: start, end: minute), default: []]
                    .insert(weekday)
            }
        }
        if weekdaysByInterval.isEmpty {
            return [TimeWindow(weekdays: [], startMinute: 0, endMinute: 1_440)]
        }
        return weekdaysByInterval.map { interval, weekdays in
            TimeWindow(
                weekdays: weekdays,
                startMinute: interval.start,
                endMinute: interval.end
            )
        }.sorted {
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            if $0.endMinute != $1.endMinute { return $0.endMinute < $1.endMinute }
            return $0.weekdays.sorted().lexicographicallyPrecedes($1.weekdays.sorted())
        }
    }

    private static func allowedMinutes(_ windows: [TimeWindow]) -> [Bool] {
        guard !windows.isEmpty else { return Array(repeating: true, count: 7 * 1_440) }
        var result = Array(repeating: false, count: 7 * 1_440)
        for window in windows {
            for weekday in window.weekdays {
                let day = weekday - 1
                if window.startMinute <= window.endMinute {
                    for minute in window.startMinute..<window.endMinute where minute < 1_440 {
                        result[day * 1_440 + minute] = true
                    }
                } else {
                    for minute in window.startMinute..<1_440 {
                        result[day * 1_440 + minute] = true
                    }
                    let nextDay = (day + 1) % 7
                    for minute in 0..<window.endMinute {
                        result[nextDay * 1_440 + minute] = true
                    }
                }
            }
        }
        return result
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func overrideSort(
        _ lhs: FolderSyncPolicyOverride,
        _ rhs: FolderSyncPolicyOverride
    ) -> Bool {
        if lhs.folderID.rawValue != rhs.folderID.rawValue {
            return lhs.folderID.rawValue < rhs.folderID.rawValue
        }
        return lhs.folderIncarnationDigest < rhs.folderIncarnationDigest
    }

    private static func profileSort(
        _ lhs: TemporarySyncPolicyProfile,
        _ rhs: TemporarySyncPolicyProfile
    ) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct MinuteInterval: Hashable {
    var start: Int
    var end: Int
}

struct CanonicalTimeWindow: Encodable, Comparable {
    var weekdays: [Int]
    var startMinute: Int
    var endMinute: Int

    init(_ window: TimeWindow) {
        weekdays = window.weekdays.sorted()
        startMinute = window.startMinute
        endMinute = window.endMinute
    }

    static func < (lhs: CanonicalTimeWindow, rhs: CanonicalTimeWindow) -> Bool {
        if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
        if lhs.endMinute != rhs.endMinute { return lhs.endMinute < rhs.endMinute }
        return lhs.weekdays.lexicographicallyPrecedes(rhs.weekdays)
    }
}

private struct CanonicalSyncPolicy: Encodable {
    var policy: SyncPolicy

    init(_ policy: SyncPolicy) {
        self.policy = policy
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

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(
            policy.automaticallyAllowedNetworks.map(\.rawValue).sorted(),
            forKey: .automaticallyAllowedNetworks
        )
        try values.encode(policy.cellularAccess, forKey: .cellularAccess)
        try values.encode(policy.allowExpensive, forKey: .allowExpensive)
        try values.encode(policy.allowConstrained, forKey: .allowConstrained)
        try values.encodeIfPresent(policy.maxCellularFileBytes, forKey: .maxCellularFileBytes)
        try values.encodeIfPresent(policy.maxExpensiveRunBytes, forKey: .maxExpensiveRunBytes)
        try values.encodeIfPresent(policy.dailyExpensiveBytes, forKey: .dailyExpensiveBytes)
        try values.encode(policy.requirePowerForAllAutomaticWork, forKey: .requirePowerForAllAutomaticWork)
        try values.encodeIfPresent(
            policy.requirePowerForLargeTransferBytes,
            forKey: .requirePowerForLargeTransferBytes
        )
        try values.encode(policy.requirePowerForMaintenance, forKey: .requirePowerForMaintenance)
        try values.encodeIfPresent(policy.minimumBatteryLevel, forKey: .minimumBatteryLevel)
        try values.encode(policy.lowPowerBehavior, forKey: .lowPowerBehavior)
        try values.encode(policy.pauseTransfersAtThermalLevel, forKey: .pauseTransfersAtThermalLevel)
        try values.encode(policy.minimumFreeDiskBytes, forKey: .minimumFreeDiskBytes)
        try values.encode(
            policy.automaticTimeWindows.map(CanonicalTimeWindow.init).sorted(),
            forKey: .automaticTimeWindows
        )
        try values.encode(policy.automaticBackgroundMode, forKey: .automaticBackgroundMode)
        try values.encode(policy.allowBackgroundUpload, forKey: .allowBackgroundUpload)
        try values.encode(policy.allowBackgroundDownload, forKey: .allowBackgroundDownload)
        try values.encode(policy.allowBackgroundScan, forKey: .allowBackgroundScan)
        try values.encode(policy.allowTemporaryUserOverride, forKey: .allowTemporaryUserOverride)
    }
}
