import CryptoKit
import Foundation

public enum CoreNetworkSessionPlanError: Error, Hashable, Sendable {
    case invalidConfigurationRevision
}

public enum CoreNetworkByteLimitError: Error, Hashable, Sendable {
    case negativeByteCount
}

public enum CoreNetworkSessionOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case sync
    case upload
    case download
    case exchangeIndex
    /// Starts the scoped folder model with all remote devices and connection
    /// services disabled. File Provider mutations commit locally in this mode;
    /// a separately queued sync propagates them when network policy permits.
    case localMutation
    /// Read or explicitly release verified managed content. Native peers,
    /// connection services and both payload directions are disabled.
    case localContent
    /// Explicit single-item block transfer. The native effective folder is
    /// index-only so the ordinary puller cannot download unrelated content.
    case materialize
}

public enum PendingFolderObservationPlanError: Error, Hashable, Sendable {
    case invalidConfigurationRevision
    case invalidMaximumNetworkBytes
}

public enum PendingFolderDiscoveryPlanError: Error, Hashable, Sendable {
    case invalidConfigurationRevision
    case invalidMaximumNetworkBytes
}

/// Canonical hard limit consumed by the native protocol reader/writer budget.
/// `unlimited` is explicit; callers preparing a metered reservation should use
/// the throwing byte-count initializer so a negative grant cannot become wire
/// data.
public struct CoreNetworkByteLimit: Hashable, Sendable {
    public static let unlimited = Self(byteCount: nil)

    public let byteCount: Int64?

    public init(byteCount: Int64) throws {
        guard byteCount >= 0 else {
            throw CoreNetworkByteLimitError.negativeByteCount
        }
        self.byteCount = byteCount
    }

    private init(byteCount: Int64?) {
        self.byteCount = byteCount
    }

    public var wireValue: String {
        byteCount.map(String.init) ?? "unlimited"
    }
}

/// The immutable scope used to start exactly one network-core lifetime.
///
/// The digest is derived here rather than accepted from a caller so a task can
/// never accidentally launch a folder using a plan prepared for a different
/// folder or canonical configuration revision.
public struct CoreNetworkSessionPlan: Hashable, Sendable {
    public static let digestDomain = "psy-network-session-plan-v3"

    public let taskID: UUID
    public let folderID: FolderID
    public let expectedConfigurationRevision: String
    public let maximumNetworkBytes: CoreNetworkByteLimit
    public let operation: CoreNetworkSessionOperation
    public let planDigest: String

    public init(
        taskID: UUID,
        folderID: FolderID,
        expectedConfigurationRevision: String,
        maximumNetworkBytes: CoreNetworkByteLimit,
        operation: CoreNetworkSessionOperation = .sync
    ) throws {
        guard CoreSessionDigest.isLowercaseSHA256(expectedConfigurationRevision) else {
            throw CoreNetworkSessionPlanError.invalidConfigurationRevision
        }
        self.taskID = taskID
        self.folderID = folderID
        self.expectedConfigurationRevision = expectedConfigurationRevision
        self.maximumNetworkBytes = maximumNetworkBytes
        self.operation = operation
        planDigest = CoreSessionDigest.networkPlan(
            taskID: taskID.uuidString.lowercased(),
            folderID: folderID.rawValue,
            configurationRevision: expectedConfigurationRevision,
            maximumNetworkBytes: maximumNetworkBytes.wireValue,
            operation: operation.rawValue
        )
    }
}

/// A target-only networking lifetime used to prove one pending folder offer.
/// Unlike a regular network session, this plan can never be unlimited and is
/// capped by the native bridge at eight MiB of aggregate protocol traffic.
public struct PendingFolderObservationPlan: Hashable, Sendable {
    public static let digestDomain = "psy-pending-folder-observation-plan-v1"
    public static let maximumAllowedNetworkBytes: Int64 = 8 * 1_024 * 1_024

    public let taskID: UUID
    public let folderID: FolderID
    public let offeringDeviceID: DeviceID
    public let expectedConfigurationRevision: String
    public let maximumNetworkBytes: Int64
    public let planDigest: String

    public init(
        taskID: UUID,
        folderID: FolderID,
        offeringDeviceID: DeviceID,
        expectedConfigurationRevision: String,
        maximumNetworkBytes: Int64
    ) throws {
        guard CoreSessionDigest.isLowercaseSHA256(expectedConfigurationRevision) else {
            throw PendingFolderObservationPlanError.invalidConfigurationRevision
        }
        guard (0...Self.maximumAllowedNetworkBytes).contains(maximumNetworkBytes) else {
            throw PendingFolderObservationPlanError.invalidMaximumNetworkBytes
        }
        self.taskID = taskID
        self.folderID = folderID
        self.offeringDeviceID = offeringDeviceID
        self.expectedConfigurationRevision = expectedConfigurationRevision
        self.maximumNetworkBytes = maximumNetworkBytes
        planDigest = CoreSessionDigest.pendingFolderObservationPlan(
            taskID: taskID.uuidString.lowercased(),
            folderID: folderID.rawValue,
            offeringDeviceID: offeringDeviceID.rawValue,
            configurationRevision: expectedConfigurationRevision,
            maximumNetworkBytes: String(maximumNetworkBytes)
        )
    }

    public var maximumNetworkBytesWireValue: String { String(maximumNetworkBytes) }
}

/// A target-device, zero-folder networking lifetime used only to discover
/// pending-folder summaries. The summaries are UI evidence and never replace
/// the separate, short-lived observation proof required to accept or ignore an
/// offer.
public struct PendingFolderDiscoveryPlan: Hashable, Sendable {
    public static let digestDomain = "psy-pending-folder-discovery-plan-v1"
    public static let maximumAllowedNetworkBytes: Int64 = 8 * 1_024 * 1_024

    public let taskID: UUID
    public let offeringDeviceID: DeviceID
    public let expectedConfigurationRevision: String
    public let maximumNetworkBytes: Int64
    public let planDigest: String

    public init(
        taskID: UUID,
        offeringDeviceID: DeviceID,
        expectedConfigurationRevision: String,
        maximumNetworkBytes: Int64
    ) throws {
        guard CoreSessionDigest.isLowercaseSHA256(expectedConfigurationRevision) else {
            throw PendingFolderDiscoveryPlanError.invalidConfigurationRevision
        }
        guard (0...Self.maximumAllowedNetworkBytes).contains(maximumNetworkBytes) else {
            throw PendingFolderDiscoveryPlanError.invalidMaximumNetworkBytes
        }
        self.taskID = taskID
        self.offeringDeviceID = offeringDeviceID
        self.expectedConfigurationRevision = expectedConfigurationRevision
        self.maximumNetworkBytes = maximumNetworkBytes
        planDigest = CoreSessionDigest.pendingFolderDiscoveryPlan(
            taskID: taskID.uuidString.lowercased(),
            offeringDeviceID: offeringDeviceID.rawValue,
            configurationRevision: expectedConfigurationRevision,
            maximumNetworkBytes: String(maximumNetworkBytes)
        )
    }

    public var maximumNetworkBytesWireValue: String { String(maximumNetworkBytes) }
}

public enum CoreExplicitSessionMode: String, Codable, Hashable, Sendable {
    case configuration
    case network
    case pendingFolderObservation
    case pendingFolderDiscovery
}

/// Exact ephemeral fields that every command/query/read in an explicit
/// session must carry. These fields are deliberately separate from durable
/// `CoreCommand` data and must not be persisted in the exactly-once ledger.
public struct CoreExplicitSessionBinding: Hashable, Sendable {
    public let sessionID: UUID
    public let mode: CoreExplicitSessionMode
    public let folderID: FolderID?
    public let offeringDeviceID: DeviceID?
    public let taskID: UUID?
    public let planDigest: String?
    public let expectedConfigurationRevision: String?
    public let maximumNetworkBytes: String?
    public let networkOperation: CoreNetworkSessionOperation?

    public static func configuration(sessionID: UUID) -> Self {
        Self(
            sessionID: sessionID,
            mode: .configuration,
            folderID: nil,
            offeringDeviceID: nil,
            taskID: nil,
            planDigest: nil,
            expectedConfigurationRevision: nil,
            maximumNetworkBytes: nil,
            networkOperation: nil
        )
    }

    public static func network(sessionID: UUID, plan: CoreNetworkSessionPlan) -> Self {
        Self(
            sessionID: sessionID,
            mode: .network,
            folderID: plan.folderID,
            offeringDeviceID: nil,
            taskID: plan.taskID,
            planDigest: plan.planDigest,
            expectedConfigurationRevision: plan.expectedConfigurationRevision,
            maximumNetworkBytes: plan.maximumNetworkBytes.wireValue,
            networkOperation: plan.operation
        )
    }

    public static func pendingFolderObservation(
        sessionID: UUID,
        plan: PendingFolderObservationPlan
    ) -> Self {
        Self(
            sessionID: sessionID,
            mode: .pendingFolderObservation,
            folderID: plan.folderID,
            offeringDeviceID: plan.offeringDeviceID,
            taskID: plan.taskID,
            planDigest: plan.planDigest,
            expectedConfigurationRevision: plan.expectedConfigurationRevision,
            maximumNetworkBytes: plan.maximumNetworkBytesWireValue,
            networkOperation: nil
        )
    }

    public static func pendingFolderDiscovery(
        sessionID: UUID,
        plan: PendingFolderDiscoveryPlan
    ) -> Self {
        Self(
            sessionID: sessionID,
            mode: .pendingFolderDiscovery,
            folderID: nil,
            offeringDeviceID: plan.offeringDeviceID,
            taskID: plan.taskID,
            planDigest: plan.planDigest,
            expectedConfigurationRevision: plan.expectedConfigurationRevision,
            maximumNetworkBytes: plan.maximumNetworkBytesWireValue,
            networkOperation: nil
        )
    }

    private init(
        sessionID: UUID,
        mode: CoreExplicitSessionMode,
        folderID: FolderID?,
        offeringDeviceID: DeviceID?,
        taskID: UUID?,
        planDigest: String?,
        expectedConfigurationRevision: String?,
        maximumNetworkBytes: String?,
        networkOperation: CoreNetworkSessionOperation?
    ) {
        self.sessionID = sessionID
        self.mode = mode
        self.folderID = folderID
        self.offeringDeviceID = offeringDeviceID
        self.taskID = taskID
        self.planDigest = planDigest
        self.expectedConfigurationRevision = expectedConfigurationRevision
        self.maximumNetworkBytes = maximumNetworkBytes
        self.networkOperation = networkOperation
    }

    public var sessionIDString: String { sessionID.uuidString.lowercased() }
    public var taskIDString: String? { taskID?.uuidString.lowercased() }
}

/// A validated bridge lifecycle response. Configuration sessions return a new
/// revision after their final close; network sessions must always return the
/// revision against which their plan was prepared.
public struct CoreExplicitSessionReceipt: Hashable, Sendable {
    public let binding: CoreExplicitSessionBinding
    public let deviceID: DeviceID
    public let generation: UInt64
    public let configurationRevision: String

    public init(
        binding: CoreExplicitSessionBinding,
        deviceID: DeviceID,
        generation: UInt64,
        configurationRevision: String
    ) throws {
        guard generation > 0,
            CoreSessionDigest.isLowercaseSHA256(configurationRevision)
        else {
            throw CoreClientError.invalidResponse("session_receipt")
        }
        if binding.mode != .configuration,
            configurationRevision != binding.expectedConfigurationRevision
        {
            throw CoreClientError.invalidResponse("session_configuration_revision")
        }
        self.binding = binding
        self.deviceID = deviceID
        self.generation = generation
        self.configurationRevision = configurationRevision
    }
}

/// The durable, redacted authority returned by a successful observation
/// capture. `connectionEpoch` is a one-way digest; a raw native connection ID
/// has no representation in this type or anywhere in the public Swift ABI.
public struct PendingFolderObservationProof: Hashable, Sendable {
    public static let timeToLive: TimeInterval = 5 * 60

    public let proofID: String
    public let folderID: FolderID
    public let offeringDeviceID: DeviceID
    public let offerVersion: String
    public let label: String
    public let lastSeen: Date
    public let receiveEncrypted: Bool
    public let remoteEncrypted: Bool
    public let configurationRevision: String
    public let observationSessionID: String
    public let connectionEpoch: String
    public let observedAt: Date
    public let expiresAt: Date

    let lastSeenWireValue: String
    let observedAtWireValue: String
    let expiresAtWireValue: String

    init(
        proofID: String,
        folderID: FolderID,
        offeringDeviceID: DeviceID,
        offerVersion: String,
        label: String,
        lastSeen: Date,
        lastSeenWireValue: String,
        receiveEncrypted: Bool,
        remoteEncrypted: Bool,
        configurationRevision: String,
        observationSessionID: String,
        connectionEpoch: String,
        observedAt: Date,
        observedAtWireValue: String,
        expiresAt: Date,
        expiresAtWireValue: String
    ) {
        self.proofID = proofID
        self.folderID = folderID
        self.offeringDeviceID = offeringDeviceID
        self.offerVersion = offerVersion
        self.label = label
        self.lastSeen = lastSeen
        self.receiveEncrypted = receiveEncrypted
        self.remoteEncrypted = remoteEncrypted
        self.configurationRevision = configurationRevision
        self.observationSessionID = observationSessionID
        self.connectionEpoch = connectionEpoch
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.lastSeenWireValue = lastSeenWireValue
        self.observedAtWireValue = observedAtWireValue
        self.expiresAtWireValue = expiresAtWireValue
    }

    /// Exact arguments required to consume this proof in a later configuration
    /// session. The enqueue-time configuration revision remains a separate,
    /// durable `CoreCommand` field and is never synthesized here.
    public var commandArguments: [String: String] {
        [
            "offeringDeviceID": offeringDeviceID.rawValue,
            "offerVersion": offerVersion,
            "observationProofID": proofID,
        ]
    }
}

public struct PendingFolderObservationCaptureReceipt: Hashable, Sendable {
    public let generation: UInt64
    public let configurationRevision: String
    public let proof: PendingFolderObservationProof
}

/// One redacted offer in an authoritative discovery capture. The connection
/// epoch is a one-way digest; raw connection identifiers, paths, and addresses
/// have no representation in the Swift ABI.
public struct PendingFolderDiscoveryOffer: Hashable, Sendable {
    public let folderID: FolderID
    public let offeringDeviceID: DeviceID
    public let label: String
    public let lastSeen: Date
    public let offerVersion: String
    public let receiveEncrypted: Bool
    public let remoteEncrypted: Bool
    public let connectionEpoch: String
    public let observedAt: Date
}

public struct PendingFolderDiscoveryCaptureReceipt: Hashable, Sendable {
    public static let maximumOffers = 512
    public static let maximumObservationAge: TimeInterval = 5 * 60

    public let generation: UInt64
    public let configurationRevision: String
    public let offeringDeviceID: DeviceID
    public let connectionEpoch: String
    public let observedAt: Date
    public let offers: [PendingFolderDiscoveryOffer]
    public let truncated: Bool
}

/// Selects the only folders whose runtime/index fields are authoritative in a
/// snapshot. Configuration sessions intentionally have no index database;
/// single-folder network sessions must never query canonical sibling folders.
public enum CoreSessionSnapshotScope {
    public static func itemFolderIDs(
        configuredFolderIDs: [FolderID],
        binding: CoreExplicitSessionBinding?
    ) throws -> [FolderID] {
        guard let binding else { return configuredFolderIDs }
        switch binding.mode {
        case .configuration:
            return []
        case .network:
            guard let target = binding.folderID,
                configuredFolderIDs.contains(target)
            else {
                throw CoreClientError.invalidResponse("session_snapshot_folder_scope")
            }
            return [target]
        case .pendingFolderObservation:
            return []
        case .pendingFolderDiscovery:
            return []
        }
    }

    public static func hasRuntimeStatus(
        folderID: FolderID,
        binding: CoreExplicitSessionBinding?
    ) -> Bool {
        guard let binding else { return true }
        switch binding.mode {
        case .configuration:
            return false
        case .network:
            return binding.folderID == folderID
        case .pendingFolderObservation:
            return false
        case .pendingFolderDiscovery:
            return false
        }
    }
}

enum CoreSessionDigest {
    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }

    static func networkPlan(
        taskID: String,
        folderID: String,
        configurationRevision: String,
        maximumNetworkBytes: String,
        operation: String
    ) -> String {
        var material = Data(CoreNetworkSessionPlan.digestDomain.utf8)
        material.append(0)
        material.append(contentsOf: taskID.utf8)
        material.append(0)
        material.append(contentsOf: folderID.utf8)
        material.append(0)
        material.append(contentsOf: configurationRevision.utf8)
        material.append(0)
        material.append(contentsOf: maximumNetworkBytes.utf8)
        material.append(0)
        material.append(contentsOf: operation.utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    static func pendingFolderObservationPlan(
        taskID: String,
        folderID: String,
        offeringDeviceID: String,
        configurationRevision: String,
        maximumNetworkBytes: String
    ) -> String {
        var material = Data(PendingFolderObservationPlan.digestDomain.utf8)
        for part in [
            taskID,
            folderID,
            offeringDeviceID,
            configurationRevision,
            maximumNetworkBytes,
        ] {
            material.append(0)
            material.append(contentsOf: part.utf8)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    static func pendingFolderDiscoveryPlan(
        taskID: String,
        offeringDeviceID: String,
        configurationRevision: String,
        maximumNetworkBytes: String
    ) -> String {
        var material = Data(PendingFolderDiscoveryPlan.digestDomain.utf8)
        for part in [
            taskID,
            offeringDeviceID,
            configurationRevision,
            maximumNetworkBytes,
        ] {
            material.append(0)
            material.append(contentsOf: part.utf8)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    static func stableVersion(_ parts: [String]) -> String {
        var material = Data()
        for part in parts {
            material.append(contentsOf: part.utf8)
            material.append(0)
        }
        return Data(SHA256.hash(data: material)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isCanonicalStableVersion(_ value: String) -> Bool {
        guard value.utf8.count == 43,
            value.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 45 || byte == 95
            })
        else { return false }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append("=")
        guard let decoded = Data(base64Encoded: base64), decoded.count == 32 else {
            return false
        }
        return decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") == value
    }
}
