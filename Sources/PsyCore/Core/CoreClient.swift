import Foundation

public enum CoreClientError: Error, Codable, Hashable, Sendable, LocalizedError {
    case bridgeUnavailable
    case invalidResponse(String)
    case coreRejected(String)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .bridgeUnavailable: "The Syncthing Go bridge has not been built for this target."
        case .invalidResponse(let message): "Invalid response from Syncthing core: \(message)"
        case .coreRejected(let message): "Syncthing core rejected the operation: \(message)"
        case .notRunning: "Syncthing core is not running."
        }
    }
}

/// Converts a validated native bridge error envelope into the typed failure
/// consumed by CoreRuntime. Platform adapters use this shared path so a
/// cancellation after a committed mutation cannot lose its reconciliation
/// phase while ordinary command cancellation retains its stable bridge code.
public enum CoreBridgeFailureClassifier {
    public static let networkByteLimitReachedCode = "network_byte_limit_reached"

    /// The native hard-cap code is stable only on the two operations that can
    /// initiate protocol I/O. A query must never synthesize it.
    public static func validatedOperationalCode(
        _ code: String,
        responseKind: String
    ) -> String? {
        guard code == networkByteLimitReachedCode,
            responseKind == "command" || responseKind == "readRange"
        else { return nil }
        return code
    }

    public static func failure(
        code: String,
        mutationPhase: String?,
        mutationAmbiguous: Bool?,
        expectsMutationMetadata: Bool
    ) -> any Error {
        guard expectsMutationMetadata else {
            return CoreClientError.coreRejected(code)
        }
        guard let mutationPhase,
            let phase = CoreMutationFailurePhase(rawValue: mutationPhase),
            let mutationAmbiguous
        else {
            return CoreClientError.invalidResponse("mutation_failure_metadata")
        }
        return CoreMutationFailure(
            code: code,
            phase: phase,
            ambiguous: mutationAmbiguous
        )
    }
}

public struct CoreReadRangeRequest: Hashable, Sendable {
    public var folderID: FolderID
    public var itemID: String
    public var relativePath: String
    public var contentVersion: Data
    public var offset: Int64
    public var length: Int

    public init(
        folderID: FolderID,
        itemID: String,
        relativePath: String,
        contentVersion: Data,
        offset: Int64,
        length: Int
    ) {
        self.folderID = folderID
        self.itemID = itemID
        self.relativePath = relativePath
        self.contentVersion = contentVersion
        self.offset = offset
        self.length = length
    }
}

/// Process-wide Syncthing protocol byte counters, normalized by a CoreClient
/// to the current start/stop lifetime, plus the native session budget report.
/// They intentionally contain no peer or connection identity.
public struct CoreNetworkTransferTotals: Codable, Hashable, Sendable {
    public var receivedBytes: Int64
    public var sentBytes: Int64
    public var budgetLimited: Bool
    public var budgetLimitBytes: Int64
    public var budgetUsedBytes: Int64
    public var budgetExhausted: Bool

    public init(
        receivedBytes: Int64,
        sentBytes: Int64,
        budgetLimited: Bool = false,
        budgetLimitBytes: Int64 = 0,
        budgetUsedBytes: Int64 = 0,
        budgetExhausted: Bool = false
    ) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.budgetLimited = budgetLimited
        self.budgetLimitBytes = budgetLimitBytes
        self.budgetUsedBytes = budgetUsedBytes
        self.budgetExhausted = budgetExhausted
    }

    public static let zero = Self(receivedBytes: 0, sentBytes: 0)

    public var totalBytes: Int64? {
        guard receivedBytes >= 0, sentBytes >= 0 else { return nil }
        let (total, overflowed) = receivedBytes.addingReportingOverflow(sentBytes)
        return overflowed ? nil : total
    }

    public func delta(since baseline: Self) -> Self? {
        guard receivedBytes >= baseline.receivedBytes,
            sentBytes >= baseline.sentBytes,
            baseline.receivedBytes >= 0,
            baseline.sentBytes >= 0
        else {
            return nil
        }
        return Self(
            receivedBytes: receivedBytes - baseline.receivedBytes,
            sentBytes: sentBytes - baseline.sentBytes,
            budgetLimited: budgetLimited,
            budgetLimitBytes: budgetLimitBytes,
            budgetUsedBytes: budgetUsedBytes,
            budgetExhausted: budgetExhausted
        )
    }

    /// The bridge may mark a limited budget exhausted before used bytes reach
    /// the limit when the next indivisible protocol frame cannot fit.
    public var hasCoherentBudgetState: Bool {
        guard budgetLimitBytes >= 0, budgetUsedBytes >= 0 else { return false }
        if budgetLimited {
            return budgetUsedBytes <= budgetLimitBytes
                && (budgetExhausted || budgetUsedBytes < budgetLimitBytes)
        }
        return budgetLimitBytes == 0 && !budgetExhausted
    }

    public func matchesNetworkSessionBudget(maximumNetworkBytes: String) -> Bool {
        guard hasCoherentBudgetState, totalBytes == budgetUsedBytes else { return false }
        if maximumNetworkBytes == "unlimited" {
            return !budgetLimited
        }
        guard let limit = Int64(maximumNetworkBytes),
            String(limit) == maximumNetworkBytes,
            limit >= 0
        else { return false }
        return budgetLimited
            && budgetLimitBytes == limit
            && (limit != 0 || budgetExhausted)
    }
}

public protocol CoreClient: Sendable {
    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID
    /// Opens the configuration-only control plane without starting Syncthing's
    /// database, protocol listeners, discovery, or transfer services.
    func openConfigurationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID
    ) async throws -> CoreExplicitSessionReceipt
    /// Opens a single-folder network lifetime bound to an immutable task plan.
    func openNetworkSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: CoreNetworkSessionPlan
    ) async throws -> CoreExplicitSessionReceipt
    /// Opens a target-device, zero-folder runtime that can capture exactly one
    /// authoritative pending-folder observation under a finite byte cap.
    func openPendingFolderObservationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: PendingFolderObservationPlan
    ) async throws -> CoreExplicitSessionReceipt
    /// Captures and durably persists the current authoritative offer proof.
    func capturePendingFolderObservation() async throws
        -> PendingFolderObservationCaptureReceipt
    /// Opens a target-device, zero-folder runtime that discovers a bounded
    /// batch of non-authoritative pending-folder summaries.
    func openPendingFolderDiscoverySession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: PendingFolderDiscoveryPlan
    ) async throws -> CoreExplicitSessionReceipt
    /// Captures the current redacted offer batch. Accepting or ignoring any
    /// returned offer still requires a separate live observation proof.
    func capturePendingFolderDiscovery() async throws
        -> PendingFolderDiscoveryCaptureReceipt
    /// Closes and drains the current explicit session and returns the final,
    /// bridge-validated configuration revision.
    func closeExplicitSession() async throws -> CoreExplicitSessionReceipt
    /// Requests cancellation without waiting for the client's serialized async
    /// executor. Implementations that wrap a blocking native call must make this
    /// method thread-safe and nonblocking.
    func requestCancellation()
    func stop() async throws
    func snapshot() async throws -> CoreSnapshot
    /// Returns exact protocol traffic since this client's most recent Start.
    /// `nil` means the concrete bridge cannot provide a trustworthy counter;
    /// callers must preserve that distinction instead of treating it as zero.
    func networkTransferTotals() async throws -> CoreNetworkTransferTotals?
    func execute(_ command: CoreCommand) async throws
    /// Releases the bridge's exactly-once ledger entry only after the shared
    /// queue has durably acknowledged this command.
    func acknowledgeCommand(_ id: UUID) async throws
    /// Releases an indeterminate native mutation ledger entry only after an
    /// authoritative requested-state proof has been durably persisted.
    func acknowledgeReconciledCommand(
        _ command: CoreCommand,
        proof: CoreMutationReconciliationProof
    ) async throws
    /// Releases a non-replay-safe configuration ledger entry after a later
    /// owner proves its exact postcondition from an authoritative snapshot.
    func acknowledgeReconciledConfigurationCommand(
        _ command: CoreCommand,
        proof: CoreConfigurationReconciliationProof
    ) async throws
    func readRange(_ request: CoreReadRangeRequest) async throws -> Data
    /// Lists redacted App-owned File Provider mutation recovery metadata. The
    /// cursor is opaque and no native recovery locator crosses this boundary.
    func mutationRecoveries(after cursor: String?, limit: Int) async throws
        -> CoreMutationRecoveryPage
    /// Creates an exact App-owned snapshot without exposing the retained
    /// payload's native locator. This is valid only in a configuration session.
    func exportMutationRecovery(
        _ summary: CoreMutationRecoverySummary,
        exportID: UUID,
        outputName: String
    ) async throws
    /// Removes only the exact App-owned snapshot identified by `exportID`.
    /// `requestID` identifies the independently acknowledged native ledger
    /// operation and must not be confused with the export container identity.
    func discardMutationRecoveryExport(_ exportID: UUID, requestID: UUID) async throws
}

extension CoreClient {
    public func requestCancellation() {}

    public func openConfigurationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID
    ) async throws -> CoreExplicitSessionReceipt {
        throw CoreClientError.bridgeUnavailable
    }

    public func openConfigurationSession(
        configurationDirectory: URL,
        dataDirectory: URL
    ) async throws -> CoreExplicitSessionReceipt {
        try await openConfigurationSession(
            configurationDirectory: configurationDirectory,
            dataDirectory: dataDirectory,
            sessionID: UUID()
        )
    }

    public func openNetworkSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: CoreNetworkSessionPlan
    ) async throws -> CoreExplicitSessionReceipt {
        throw CoreClientError.bridgeUnavailable
    }

    public func openPendingFolderObservationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: PendingFolderObservationPlan
    ) async throws -> CoreExplicitSessionReceipt {
        throw CoreClientError.bridgeUnavailable
    }

    public func openPendingFolderObservationSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        plan: PendingFolderObservationPlan
    ) async throws -> CoreExplicitSessionReceipt {
        try await openPendingFolderObservationSession(
            configurationDirectory: configurationDirectory,
            dataDirectory: dataDirectory,
            sessionID: UUID(),
            plan: plan
        )
    }

    public func capturePendingFolderObservation() async throws
        -> PendingFolderObservationCaptureReceipt
    {
        throw CoreClientError.bridgeUnavailable
    }

    public func openPendingFolderDiscoverySession(
        configurationDirectory: URL,
        dataDirectory: URL,
        sessionID: UUID,
        plan: PendingFolderDiscoveryPlan
    ) async throws -> CoreExplicitSessionReceipt {
        throw CoreClientError.bridgeUnavailable
    }

    public func openPendingFolderDiscoverySession(
        configurationDirectory: URL,
        dataDirectory: URL,
        plan: PendingFolderDiscoveryPlan
    ) async throws -> CoreExplicitSessionReceipt {
        try await openPendingFolderDiscoverySession(
            configurationDirectory: configurationDirectory,
            dataDirectory: dataDirectory,
            sessionID: UUID(),
            plan: plan
        )
    }

    public func capturePendingFolderDiscovery() async throws
        -> PendingFolderDiscoveryCaptureReceipt
    {
        throw CoreClientError.bridgeUnavailable
    }

    public func openNetworkSession(
        configurationDirectory: URL,
        dataDirectory: URL,
        plan: CoreNetworkSessionPlan
    ) async throws -> CoreExplicitSessionReceipt {
        try await openNetworkSession(
            configurationDirectory: configurationDirectory,
            dataDirectory: dataDirectory,
            sessionID: UUID(),
            plan: plan
        )
    }

    public func closeExplicitSession() async throws -> CoreExplicitSessionReceipt {
        throw CoreClientError.bridgeUnavailable
    }

    public func acknowledgeCommand(_ id: UUID) async throws {}

    public func networkTransferTotals() async throws -> CoreNetworkTransferTotals? { nil }

    public func acknowledgeReconciledCommand(
        _ command: CoreCommand,
        proof: CoreMutationReconciliationProof
    ) async throws {
        throw CoreClientError.bridgeUnavailable
    }

    public func acknowledgeReconciledConfigurationCommand(
        _ command: CoreCommand,
        proof: CoreConfigurationReconciliationProof
    ) async throws {
        throw CoreClientError.bridgeUnavailable
    }

    public func readRange(_ request: CoreReadRangeRequest) async throws -> Data {
        throw CoreClientError.bridgeUnavailable
    }

    public func mutationRecoveries(after cursor: String?, limit: Int) async throws
        -> CoreMutationRecoveryPage
    {
        throw CoreClientError.bridgeUnavailable
    }

    public func exportMutationRecovery(
        _ summary: CoreMutationRecoverySummary,
        exportID: UUID,
        outputName: String
    ) async throws {
        throw CoreClientError.bridgeUnavailable
    }

    public func discardMutationRecoveryExport(_ exportID: UUID, requestID: UUID) async throws {
        throw CoreClientError.bridgeUnavailable
    }
}

public actor UnavailableCoreClient: CoreClient {
    public init() {}

    public func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        throw CoreClientError.bridgeUnavailable
    }

    public func stop() async throws {}

    public func snapshot() async throws -> CoreSnapshot {
        throw CoreClientError.bridgeUnavailable
    }

    public func execute(_ command: CoreCommand) async throws {
        throw CoreClientError.bridgeUnavailable
    }
}
