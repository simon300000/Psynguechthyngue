import CryptoKit
import Darwin
import Foundation

public enum CoreCommandKind: String, Codable, CaseIterable, Sendable {
    case addDevice
    case editDevice
    case removeDevice
    case acceptDevice
    case ignorePendingDevice
    case unignorePendingDevice
    case addFolder
    case editFolder
    case removeFolder
    case acceptFolder
    case ignorePendingFolder
    case unignorePendingFolder
    case sync
    case upload
    case download
    case exchangeIndex
    case pause
    case resume
    case rescan
    case materialize
    case pin
    case evict
    case create
    case modify
    case move
    case delete
    case disposeRecovery
    case disposeRecoveryReviewed
}

/// Fixed scheduling classes are derived from the command's executable
/// semantics. They are deliberately not encoded in the queue record, so a
/// serialized `arguments["priority"]` value cannot promote work ahead of a
/// pending safety stop.
public enum CoreCommandSchedulingClass: Int, CaseIterable, Sendable {
    case safetyControl = 0
    case userConfiguration = 1
    case fileProvider = 2
    case appUser = 3
    case appIntent = 4
    case background = 5
    case maintenance = 6
}

/// The only folder-priority values accepted from the trusted policy resolver.
/// Missing and out-of-range raw values are treated as `.normal` by the queue.
public enum CoreFolderSchedulingPriority: Int, CaseIterable, Sendable {
    case low = -1
    case normal = 0
    case high = 1

    fileprivate static func normalized(_ rawValue: Int?) -> Self {
        guard let rawValue, let priority = Self(rawValue: rawValue) else {
            return .normal
        }
        return priority
    }
}

public enum CoreTaskPolicyBindingError: Error, Hashable, Sendable {
    case invalidProfile
    case invalidDigest
    case expired
    case invalidTrigger
}

/// Immutable authority copied from a named profile when a command is queued.
/// Runtime never re-resolves the mutable profile name or current profile list.
public struct CoreTaskPolicyBinding: Codable, Hashable, Sendable {
    public var profileID: UUID
    public var maximumNetworkBytes: Int64
    public var requestsTemporaryOverride: Bool
    public var expiresAt: Date
    public var digest: String

    public init(
        profile: TemporarySyncPolicyProfile,
        commandCreatedAt: Date,
        trigger: SyncTrigger
    ) throws {
        let profile = try profile.validated()
        guard trigger == .user || trigger == .appIntent else {
            throw CoreTaskPolicyBindingError.invalidTrigger
        }
        profileID = profile.id
        maximumNetworkBytes = profile.maximumNetworkBytes
        requestsTemporaryOverride = profile.requestsTemporaryOverride
        expiresAt = commandCreatedAt.addingTimeInterval(TimeInterval(profile.validitySeconds))
        digest = Self.digest(
            profileID: profile.id,
            maximumNetworkBytes: profile.maximumNetworkBytes,
            requestsTemporaryOverride: profile.requestsTemporaryOverride,
            expiresAt: expiresAt
        )
    }

    @discardableResult
    public func validated(
        commandCreatedAt: Date,
        trigger: SyncTrigger,
        now: Date
    ) throws -> Self {
        guard trigger == .user || trigger == .appIntent else {
            throw CoreTaskPolicyBindingError.invalidTrigger
        }
        let lifetime = expiresAt.timeIntervalSince(commandCreatedAt)
        let roundedLifetime = lifetime.rounded()
        let validitySeconds = Int64(roundedLifetime)
        guard abs(lifetime - roundedLifetime) < 0.001,
            (TemporarySyncPolicyProfile.minimumValiditySeconds...TemporarySyncPolicyProfile.maximumValiditySeconds)
                .contains(validitySeconds),
            (1...TemporarySyncPolicyProfile.maximumNetworkBytes).contains(maximumNetworkBytes)
        else {
            throw CoreTaskPolicyBindingError.invalidProfile
        }
        guard now < expiresAt else { throw CoreTaskPolicyBindingError.expired }
        guard
            digest
                == Self.digest(
                    profileID: profileID,
                    maximumNetworkBytes: maximumNetworkBytes,
                    requestsTemporaryOverride: requestsTemporaryOverride,
                    expiresAt: expiresAt
                )
        else {
            throw CoreTaskPolicyBindingError.invalidDigest
        }
        return self
    }

    private static func digest(
        profileID: UUID,
        maximumNetworkBytes: Int64,
        requestsTemporaryOverride: Bool,
        expiresAt: Date
    ) -> String {
        var material = Data("psy-task-policy-binding-v1".utf8)
        for value in [
            profileID.uuidString.lowercased(),
            String(maximumNetworkBytes),
            requestsTemporaryOverride ? "1" : "0",
            String(expiresAt.timeIntervalSince1970.bitPattern, radix: 16),
        ] {
            material.append(0)
            material.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CoreCommand: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var kind: CoreCommandKind
    public var folderID: FolderID?
    public var itemID: String?
    public var arguments: [String: String]
    /// App-side precondition binding folder-targeted work to the exact durable
    /// folder incarnation observed when the command was enqueued.
    public var folderIncarnationDigest: String?
    /// Native configuration precondition captured from the authoritative
    /// enqueue-time snapshot. It is distinct from an explicit session's live
    /// configuration revision.
    public var commandConfigurationRevision: String?
    public var taskPolicyBinding: CoreTaskPolicyBinding?
    public var trigger: SyncTrigger
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: CoreCommandKind,
        folderID: FolderID? = nil,
        itemID: String? = nil,
        arguments: [String: String] = [:],
        folderIncarnationDigest: String? = nil,
        commandConfigurationRevision: String? = nil,
        taskPolicyBinding: CoreTaskPolicyBinding? = nil,
        trigger: SyncTrigger,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.folderID = folderID
        self.itemID = itemID
        self.arguments = arguments
        self.folderIncarnationDigest = folderIncarnationDigest
        self.commandConfigurationRevision = commandConfigurationRevision
        self.taskPolicyBinding = taskPolicyBinding
        self.trigger = trigger
        self.createdAt = createdAt
    }

    /// Scheduling authority comes only from the command kind and trigger that
    /// also determine what the core will execute. Stop/remove/ignore requests
    /// prevent further sharing and therefore outrank commands such as resume,
    /// add, edit, accept, and unignore that can expand it.
    public var schedulingClass: CoreCommandSchedulingClass {
        switch kind {
        case .pause, .removeDevice, .removeFolder,
            .ignorePendingDevice, .ignorePendingFolder:
            return .safetyControl
        case .resume,
            .addDevice, .editDevice, .acceptDevice, .unignorePendingDevice,
            .addFolder, .editFolder, .acceptFolder, .unignorePendingFolder:
            return .userConfiguration
        default:
            switch trigger {
            case .fileProvider:
                return .fileProvider
            case .user:
                return .appUser
            case .appIntent:
                return .appIntent
            case .backgroundRefresh, .backgroundProcessing:
                return .background
            case .foreground:
                return .maintenance
            }
        }
    }

    /// The native command ledger permits a completed failure to execute again
    /// only for bounded, idempotent maintenance operations. Mutations never
    /// replay their original UUID; they are reconciled through a separate
    /// rescan request and an authoritative snapshot proof.
    public var supportsNativeFailureReplay: Bool {
        switch kind {
        case .rescan, .sync, .evict, .materialize, .pin,
            .disposeRecovery, .disposeRecoveryReviewed,
            .ignorePendingDevice, .unignorePendingDevice,
            .ignorePendingFolder, .unignorePendingFolder:
            true
        default:
            false
        }
    }

    public var isFileProviderMutation: Bool {
        switch kind {
        case .create, .modify, .move, .delete:
            true
        default:
            false
        }
    }

    /// Commands whose durable Swift-side intent must be tied to the exact
    /// enqueue-time configuration snapshot. This is intentionally broader
    /// than the set of revisions permitted on the Go command wire format.
    public var requiresDurableConfigurationRevisionPrecondition: Bool {
        switch kind {
        case .addDevice, .editDevice, .removeDevice, .acceptDevice,
            .ignorePendingDevice, .unignorePendingDevice,
            .addFolder, .editFolder, .removeFolder, .acceptFolder,
            .ignorePendingFolder, .unignorePendingFolder,
            .pause, .resume,
            .evict, .materialize, .pin, .create, .modify, .move, .delete:
            true
        default:
            false
        }
    }

    /// The exact Go configuration-command whitelist for the top-level
    /// `commandConfigurationRevision` wire field. Suppression and recovery
    /// commands must omit it even when Swift retains a durable local fence.
    public var requiresGoConfigurationWireRevisionFence: Bool {
        switch kind {
        case .addDevice, .editDevice, .removeDevice, .acceptDevice,
            .addFolder, .editFolder, .removeFolder, .acceptFolder,
            .pause, .resume:
            true
        default:
            false
        }
    }

    public var isCoreMutationRecoveryDisposal: Bool {
        kind == .disposeRecovery || kind == .disposeRecoveryReviewed
    }

    public func requiresManualReconciliation(for result: CoreCommandResult) -> Bool {
        guard result.status != .blocked else { return false }
        if isFileProviderMutation, result.status == .failed {
            return result.requiresManualReconciliation
        }
        guard !supportsNativeFailureReplay else { return false }
        if result.requiresManualReconciliation { return true }
        return [
            "propagation_not_indexed",
            "rescan_failed",
            "configuration_reconciliation_conflict",
            "coreInvalidResponse",
            "coreExecutionFailed",
        ].contains(result.errorCode)
    }
}

public enum CoreCommandResultStatus: String, Codable, Sendable {
    case succeeded
    case retryable
    case blocked
    case failed
}

public enum CoreMutationFailurePhase: String, Codable, Hashable, Sendable {
    case precommit
    case postcommit
    case indeterminate
}

/// Structured bridge failure metadata. The phase is supplied by the native
/// mutation implementation, not inferred from a localized error message.
public struct CoreMutationFailure: Error, Hashable, Sendable {
    public var code: String
    public var phase: CoreMutationFailurePhase
    public var ambiguous: Bool

    public init(code: String, phase: CoreMutationFailurePhase, ambiguous: Bool) {
        self.code = code
        self.phase = phase
        self.ambiguous = ambiguous
    }
}

public struct CoreCommandResult: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { commandID }
    public let commandID: UUID
    public var status: CoreCommandResultStatus
    public var completedAt: Date
    public var snapshotGeneration: UInt64?
    public var ownerEpoch: UInt64?
    public var instanceID: UUID?
    public var errorCode: String?
    /// Expected item type captured from the authoritative pre-mutation
    /// snapshot. A later owner must not infer this from the state it is trying
    /// to prove.
    public var reconciliationExpectedIsDirectory: Bool?
    /// Pre-mutation proof for create. Only an exact `true` permits automatic
    /// reconciliation; a missing, duplicate, or already-present target is not
    /// distinguishable from a rejected create after restart.
    public var reconciliationCreateTargetWasAbsent: Bool?
    /// Canonical source path captured from the authoritative pre-mutation
    /// snapshot. Move reconciliation must prove that this exact path did not
    /// remain or reappear as another live item.
    public var reconciliationSourceRelativePath: String?
    public var mutationFailurePhase: CoreMutationFailurePhase?
    public var mutationFailureAmbiguous: Bool?
    /// Persisted proof evidence lets a later owner retry the narrow native
    /// reconciliation acknowledgement after a crash or ledger write failure.
    public var reconciliationProofKind: String?
    public var reconciliationProofStateDigest: Data?

    public init(
        commandID: UUID,
        status: CoreCommandResultStatus,
        completedAt: Date = .now,
        snapshotGeneration: UInt64? = nil,
        ownerEpoch: UInt64? = nil,
        instanceID: UUID? = nil,
        errorCode: String? = nil,
        reconciliationExpectedIsDirectory: Bool? = nil,
        reconciliationCreateTargetWasAbsent: Bool? = nil,
        reconciliationSourceRelativePath: String? = nil,
        mutationFailurePhase: CoreMutationFailurePhase? = nil,
        mutationFailureAmbiguous: Bool? = nil,
        reconciliationProofKind: String? = nil,
        reconciliationProofStateDigest: Data? = nil
    ) {
        self.commandID = commandID
        self.status = status
        self.completedAt = completedAt
        self.snapshotGeneration = snapshotGeneration
        self.ownerEpoch = ownerEpoch
        self.instanceID = instanceID
        self.errorCode = errorCode
        self.reconciliationExpectedIsDirectory = reconciliationExpectedIsDirectory
        self.reconciliationCreateTargetWasAbsent = reconciliationCreateTargetWasAbsent
        self.reconciliationSourceRelativePath = reconciliationSourceRelativePath
        self.mutationFailurePhase = mutationFailurePhase
        self.mutationFailureAmbiguous = mutationFailureAmbiguous
        self.reconciliationProofKind = reconciliationProofKind
        self.reconciliationProofStateDigest = reconciliationProofStateDigest
    }

    /// The native bridge may already have committed this command but lost the
    /// exact response before it could durably mark the ledger entry complete.
    /// Any upload bytes associated with such a result must remain available for
    /// explicit reconciliation; treating it as ordinary terminal cleanup could
    /// discard the only copy supplied by Files.
    public var requiresManualReconciliation: Bool {
        if let mutationFailureAmbiguous { return mutationFailureAmbiguous }
        if let mutationFailurePhase { return mutationFailurePhase != .precommit }
        return [
            "indeterminate_prior_attempt",
            "internal_error",
            "propagation_not_indexed",
            "rescan_failed",
            "coreInvalidResponse",
            "coreExecutionFailed",
        ].contains(errorCode)
    }
}

/// Durable scheduling state for one retryable command. `attempt` counts only
/// executions that reached a retryable failure; policy deferrals and manual
/// releases never change it.
public struct CoreCommandRetryState: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { commandID }
    public let commandID: UUID
    public fileprivate(set) var attempt: UInt64
    public fileprivate(set) var lastError: String
    public fileprivate(set) var earliestRetryAt: Date
    fileprivate var lastAttemptAt: Date

    fileprivate init(
        commandID: UUID,
        attempt: UInt64,
        lastError: String,
        earliestRetryAt: Date,
        lastAttemptAt: Date
    ) {
        self.commandID = commandID
        self.attempt = attempt
        self.lastError = lastError
        self.earliestRetryAt = earliestRetryAt
        self.lastAttemptAt = lastAttemptAt
    }
}

public enum CoreCommandQueueError: Error, Hashable, Sendable {
    case identifierCollision(UUID)
    case ownerLeaseMismatch
    case completedCleanupAttemptOverflow(UUID)
    case retryAttemptOverflow(UUID)
    case invalidRetryClock
    case retryClockRollback(lastObservedAt: Date, proposedAt: Date)
    case invalidRetryScheduleDocument
    case unsupportedRetryScheduleSchema(Int)
    case folderIDRequiredForDeduplication
    case backgroundTriggerRequiredForDeduplication
    case emptyBatch
    case batchTooLarge
    case invalidBatchDocument
}

struct CompletedCommandCleanupEntry: Sendable {
    let command: CoreCommand
    fileprivate let filename: String?
    fileprivate let batchID: UUID?
    fileprivate let attempt: UInt64
}

private enum CoreCommandBatchEntryState: String, Codable, Sendable {
    case pending
    case completed
}

private struct CoreCommandBatchEntry: Codable, Sendable {
    var command: CoreCommand
    var semanticDigest: String
    var state: CoreCommandBatchEntryState
    var cleanupAttempt: UInt64
}

private struct CoreCommandBatchEnvelope: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var batchID: UUID
    var entries: [CoreCommandBatchEntry]

    init(batchID: UUID, commands: [CoreCommand]) throws {
        schemaVersion = Self.currentSchemaVersion
        self.batchID = batchID
        entries = try commands.map {
            CoreCommandBatchEntry(
                command: $0,
                semanticDigest: try CoreCommandQueue.semanticDigest(for: $0),
                state: .pending,
                cleanupAttempt: 0
            )
        }
    }
}

private struct LoadedCoreCommandBatch: Sendable {
    var url: URL
    var envelope: CoreCommandBatchEnvelope
}

private struct LegacyCoreCommandRetryState: Codable, Sendable {
    var commandID: UUID
    var attempt: UInt64
    var lastError: String
    var earliestRetryAt: Date
}

private struct LegacyCoreCommandRetrySchedule: Codable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var entries: [LegacyCoreCommandRetryState]
}

private struct CoreCommandRetrySchedule: Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int = Self.currentSchemaVersion
    var lastObservedAt: Date
    var entries: [CoreCommandRetryState]
}

public struct CoreCommandQueue: Sendable {
    public static let maximumBatchCommands = 4_096
    public static let maximumBatchDocumentBytes: Int64 = 16 * 1_048_576
    static let retryScheduleFilename = "retry-schedule.json"

    private static let maximumRetryScheduleDocumentBytes: Int64 = 32 * 1_048_576
    private static let maximumRetryErrorBytes = 128

    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    public func enqueue(_ command: CoreCommand) throws {
        try FileLock.withExclusiveLock(at: queueLockURL) {
            try enqueueLocked(command)
        }
    }

    /// Publishes a prepared command batch as one durable file. Readers either
    /// observe the complete validated envelope or no batch at all; the atomic
    /// rename performed by `SecureLockFile` is the commit marker. Hidden
    /// temporary files left by a killed writer are never enumerated.
    ///
    /// Reusing `batchID` with byte-for-byte equivalent command semantics is an
    /// idempotent replay. Any identifier already owned by a legacy queue file
    /// or another batch fails the complete publication before it becomes
    /// visible.
    public func enqueueAtomically(
        _ commands: [CoreCommand],
        batchID: UUID
    ) throws {
        guard !commands.isEmpty else { throw CoreCommandQueueError.emptyBatch }
        guard commands.count <= Self.maximumBatchCommands else {
            throw CoreCommandQueueError.batchTooLarge
        }
        try FileLock.withExclusiveLock(at: queueLockURL) {
            try publishBatchLocked(commands, batchID: batchID)
        }
    }

    /// Atomically publishes only the exact-folder background commands that do
    /// not already have pending work of the same executable kind. The API
    /// rejects non-background triggers so foreground/manual work cannot be
    /// accidentally coalesced by a caller.
    @discardableResult
    public func enqueueBackgroundBatchIfNeeded(
        _ commands: [CoreCommand],
        batchID: UUID
    ) throws -> [CoreCommand] {
        guard
            commands.allSatisfy({
                $0.folderID != nil
                    && ($0.trigger == .backgroundRefresh || $0.trigger == .backgroundProcessing)
            })
        else {
            if commands.contains(where: { $0.folderID == nil }) {
                throw CoreCommandQueueError.folderIDRequiredForDeduplication
            }
            throw CoreCommandQueueError.backgroundTriggerRequiredForDeduplication
        }
        guard !commands.isEmpty else { return [] }
        return try FileLock.withExclusiveLock(at: queueLockURL) {
            if let existing = try batchEnvelopesLocked().first(where: {
                $0.envelope.batchID == batchID
            }) {
                let replay = try CoreCommandBatchEnvelope(
                    batchID: batchID,
                    commands: commands
                )
                guard Self.batchSemanticallyEqual(existing.envelope, replay) else {
                    throw CoreCommandQueueError.identifierCollision(
                        commands.first?.id ?? batchID
                    )
                }
                return []
            }
            let pending = try pendingLocked(limit: .max)
            var occupied = Set(
                pending.compactMap { command in
                    command.folderID.map { "\(command.kind.rawValue)\u{0}\($0.rawValue)" }
                }
            )
            var selected: [CoreCommand] = []
            for command in commands {
                guard let folderID = command.folderID else {
                    throw CoreCommandQueueError.folderIDRequiredForDeduplication
                }
                let key = "\(command.kind.rawValue)\u{0}\(folderID.rawValue)"
                if occupied.insert(key).inserted {
                    selected.append(command)
                }
            }
            guard !selected.isEmpty else { return [] }
            try publishBatchLocked(selected, batchID: batchID)
            return selected
        }
    }

    /// Atomically adds `command` only when no pending command exists. This is
    /// used by opportunistic background processing so concurrent launch paths
    /// cannot manufacture duplicate full-sync requests.
    @discardableResult
    public func enqueueIfEmpty(_ command: CoreCommand) throws -> Bool {
        try FileLock.withExclusiveLock(at: queueLockURL) {
            guard try pendingLocked(limit: 1).isEmpty else { return false }
            try enqueueLocked(command)
            return true
        }
    }

    /// Foreground polling coalesces across all triggers, under the queue lock.
    /// Manual requests retain their own identity and are never swallowed here.
    @discardableResult
    public func enqueueForegroundSyncIfNeeded(_ command: CoreCommand) throws -> Bool {
        guard let folderID = command.folderID else {
            throw CoreCommandQueueError.folderIDRequiredForDeduplication
        }
        guard command.trigger == .foreground,
            [.sync, .upload, .exchangeIndex].contains(command.kind)
        else { throw CoreCommandQueueError.backgroundTriggerRequiredForDeduplication }
        return try FileLock.withExclusiveLock(at: queueLockURL) {
            guard try !pendingLocked(limit: .max).contains(where: {
                $0.folderID == folderID && $0.kind == command.kind
            }) else { return false }
            try enqueueLocked(command)
            return true
        }
    }

    /// Atomically coalesces opportunistic per-folder work by its executable
    /// kind. Only background requests may use this API: a manual request must
    /// never be swallowed by an older, lower-class background request. The key
    /// is derived from typed command fields rather than caller-supplied
    /// arguments, and intentionally spans existing triggers: a pending user
    /// sync already satisfies a later background request for the same folder.
    @discardableResult
    public func enqueueIfNoPendingCommandInSameFolderAndKind(
        _ command: CoreCommand
    ) throws -> Bool {
        guard let folderID = command.folderID else {
            throw CoreCommandQueueError.folderIDRequiredForDeduplication
        }
        guard command.trigger == .backgroundRefresh || command.trigger == .backgroundProcessing else {
            throw CoreCommandQueueError.backgroundTriggerRequiredForDeduplication
        }
        return try FileLock.withExclusiveLock(at: queueLockURL) {
            let duplicateExists = try pendingLocked(limit: .max).contains {
                $0.folderID == folderID && $0.kind == command.kind
            }
            guard !duplicateExists else { return false }
            try enqueueLocked(command)
            return true
        }
    }

    private func enqueueLocked(_ command: CoreCommand) throws {
        try FileLock.withExclusiveLock(at: lockURL(for: command.id)) {
            let pending = root.appendingPathComponent("pending", isDirectory: true)
            let completed = root.appendingPathComponent("completed", isDirectory: true)
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)

            for directory in [pending, completed] {
                let candidates = try matchingCommandURLs(in: directory, id: command.id)
                if let existingURL = candidates.first {
                    let existing = try decoder.decode(CoreCommand.self, from: Data(contentsOf: existingURL))
                    guard Self.semanticallyEqual(existing, command) else {
                        throw CoreCommandQueueError.identifierCollision(command.id)
                    }
                    return
                }
            }
            if let existing = try batchEntryLocked(commandID: command.id) {
                guard Self.semanticallyEqual(existing.entry.command, command) else {
                    throw CoreCommandQueueError.identifierCollision(command.id)
                }
                return
            }

            let final = pending.appendingPathComponent(Self.filename(for: command))
            let temporary = root.appendingPathComponent(".\(command.id.uuidString).tmp")
            try encoder.encode(command).write(to: temporary, options: Self.writeOptions)
            do {
                try FileManager.default.moveItem(at: temporary, to: final)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }

    public func pending(limit: Int = 100) throws -> [CoreCommand] {
        try FileLock.withExclusiveLock(at: queueLockURL) {
            try pendingLocked(limit: limit)
        }
    }

    /// Selects the highest-priority runnable command without changing durable
    /// storage order. A deferred or blocked high-class command can be rejected
    /// by `isRunnable`, allowing lower-class work to make progress.
    ///
    /// Folder priority is consulted only after the fixed scheduling class. The
    /// resolver is expected to read trusted policy state; nil or any integer
    /// outside `CoreFolderSchedulingPriority` is normalized to `.normal`.
    public func nextRunnable(
        at date: Date = .now,
        folderPriorityResolver: (FolderID) -> Int? = { _ in nil },
        isRunnable: (CoreCommand) throws -> Bool = { _ in true }
    ) throws -> CoreCommand? {
        func selected(
            from commands: [CoreCommand],
            retryStates: [UUID: CoreCommandRetryState],
            safetyOnly: Bool
        ) throws -> CoreCommand? {
            var candidates: [(command: CoreCommand, folderPriority: Int)] = []
            for command in commands {
                if safetyOnly, command.schedulingClass != .safetyControl { continue }
                if !safetyOnly,
                    command.schedulingClass != .safetyControl,
                    let retryState = retryStates[command.id],
                    retryState.earliestRetryAt > date
                {
                    continue
                }
                guard try isRunnable(command) else { continue }
                let rawPriority = command.folderID.flatMap(folderPriorityResolver)
                let priority = CoreFolderSchedulingPriority.normalized(rawPriority)
                candidates.append((command, priority.rawValue))
            }
            return candidates.min { lhs, rhs in
                let lhsClass = lhs.command.schedulingClass.rawValue
                let rhsClass = rhs.command.schedulingClass.rawValue
                if lhsClass != rhsClass { return lhsClass < rhsClass }
                if lhs.folderPriority != rhs.folderPriority {
                    return lhs.folderPriority > rhs.folderPriority
                }
                if lhs.command.createdAt != rhs.command.createdAt {
                    return lhs.command.createdAt < rhs.command.createdAt
                }
                return lhs.command.id.uuidString < rhs.command.id.uuidString
            }?.command
        }

        let initialCommands = try pending(limit: .max)
        if let safety = try selected(
            from: initialCommands,
            retryStates: [:],
            safetyOnly: true
        ) {
            return safety
        }

        let snapshot: (commands: [CoreCommand], retryStates: [UUID: CoreCommandRetryState])
        do {
            snapshot = try FileLock.withExclusiveLock(at: queueLockURL) {
                let commands = try pendingLocked(limit: .max)
                let schedule = try reconciledRetryScheduleLocked(
                    for: commands,
                    observedAt: date
                )
                return (
                    commands,
                    Dictionary(
                        uniqueKeysWithValues: (schedule?.entries ?? []).map {
                            ($0.commandID, $0)
                        }
                    )
                )
            }
        } catch {
            // Retry metadata is never allowed to suppress a stop/remove/ignore
            // request. Recheck after the failed schedule read so a safety
            // command enqueued during selection still has an escape path.
            if let safety = try selected(
                from: pending(limit: .max),
                retryStates: [:],
                safetyOnly: true
            ) {
                return safety
            }
            throw error
        }
        return try selected(
            from: snapshot.commands,
            retryStates: snapshot.retryStates,
            safetyOnly: false
        )
    }

    /// Returns the current durable retry state after migrating any legacy
    /// retryable result for the command. Reading advances the persisted wall
    /// clock watermark so a later rollback cannot release work early.
    public func retryState(
        for commandID: UUID,
        at date: Date = .now
    ) throws -> CoreCommandRetryState? {
        try FileLock.withExclusiveLock(at: queueLockURL) {
            let commands = try pendingLocked(limit: .max)
            return try reconciledRetryScheduleLocked(
                for: commands,
                observedAt: date
            )?.entries.first { $0.commandID == commandID }
        }
    }

    /// Makes one pending retry immediately eligible without inventing another
    /// failed attempt or discarding its last stable error. This is the explicit
    /// manual-retry boundary used by callers after user intent is confirmed.
    @discardableResult
    public func retryNow(
        _ commandID: UUID,
        at date: Date = .now
    ) throws -> Bool {
        try FileLock.withExclusiveLock(at: queueLockURL) {
            let commands = try pendingLocked(limit: .max)
            guard
                var schedule = try reconciledRetryScheduleLocked(
                    for: commands,
                    observedAt: date
                ),
                let index = schedule.entries.firstIndex(where: { $0.commandID == commandID })
            else {
                return false
            }
            schedule.entries[index].earliestRetryAt = date
            schedule.lastObservedAt = date
            try writeRetryScheduleLocked(schedule)
            return true
        }
    }

    /// Commands already acknowledged by the shared queue remain available for
    /// bridge-ledger garbage collection. The queue entry is the durable proof
    /// that replay is no longer required, so the bridge must never discard its
    /// exactly-once record before a command appears here.
    public func completed(limit: Int = 4096) throws -> [CoreCommand] {
        try completedCleanupBatch(limit: limit).map(\.command)
    }

    func completedCleanupBatch(limit: Int = 4096) throws -> [CompletedCommandCleanupEntry] {
        try FileLock.withExclusiveLock(at: queueLockURL) {
            try completedCleanupBatchLocked(limit: limit)
        }
    }

    private func completedCleanupBatchLocked(limit: Int) throws -> [CompletedCommandCleanupEntry] {
        let urls = try commandURLs(in: "completed")
        var entries = try urls.map { url in
            let command = try decoder.decode(CoreCommand.self, from: Data(contentsOf: url))
            return CompletedCommandCleanupEntry(
                command: command,
                filename: url.lastPathComponent,
                batchID: nil,
                attempt: try Self.completedCleanupAttempt(for: url, commandID: command.id)
            )
        }
        for batch in try batchEnvelopesLocked() {
            entries.append(
                contentsOf: batch.envelope.entries.compactMap { entry in
                    guard entry.state == .completed else { return nil }
                    return CompletedCommandCleanupEntry(
                        command: entry.command,
                        filename: nil,
                        batchID: batch.envelope.batchID,
                        attempt: entry.cleanupAttempt
                    )
                }
            )
        }
        entries.sort { lhs, rhs in
            if lhs.attempt != rhs.attempt { return lhs.attempt < rhs.attempt }
            return lhs.command.id.uuidString < rhs.command.id.uuidString
        }
        return Array(entries.prefix(max(0, limit)))
    }

    /// Returns every command identifier whose File Provider staging directory
    /// must survive age-based cleanup.
    ///
    /// Pending commands are always retained. Completed commands are retained
    /// only when their native outcome is intentionally indeterminate and still
    /// requires manual reconciliation. Reading pending before completed makes a
    /// concurrent one-way move between those directories conservative: the
    /// command is observed in at least one collection.
    public func retainedFileProviderStagingCommandIDs() throws -> Set<UUID> {
        var retained = Set(try pending(limit: .max).map(\.id))
        for command in try completed(limit: .max) {
            if let result = try result(for: command.id),
                command.requiresManualReconciliation(for: result)
            {
                retained.insert(command.id)
            }
        }
        return retained
    }

    private func pendingLocked(limit: Int) throws -> [CoreCommand] {
        var commands = try commandURLs(in: "pending").map {
            try decoder.decode(CoreCommand.self, from: Data(contentsOf: $0))
        }
        for batch in try batchEnvelopesLocked() {
            commands.append(
                contentsOf: batch.envelope.entries.compactMap {
                    $0.state == .pending ? $0.command : nil
                }
            )
        }
        var identifiers = Set<UUID>()
        for command in commands {
            guard identifiers.insert(command.id).inserted else {
                throw CoreCommandQueueError.identifierCollision(command.id)
            }
        }
        commands.sort(by: Self.commandOrder)
        return Array(commands.prefix(max(0, limit)))
    }

    private func commandURLs(in component: String) throws -> [URL] {
        let directory = root.appendingPathComponent(component, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func acknowledge(_ command: CoreCommand) throws {
        try acknowledge(command, leaseValidation: nil)
    }

    public func acknowledge(
        _ command: CoreCommand,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws {
        try CoreOwnerMetadataStore.withValidatedLease(lease, at: ownerMetadataURL) {
            try acknowledge(command, leaseValidation: nil)
        }
    }

    /// Removes the durable native-cleanup handoff only after the bridge has
    /// acknowledged that its exactly-once entry is gone. Result records remain
    /// untouched so callers can continue to observe terminal history.
    public func retireCompleted(
        _ command: CoreCommand,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws {
        try retireCompleted(
            command,
            expectedFilename: nil,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
    }

    func retireCompleted(
        _ entry: CompletedCommandCleanupEntry,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws {
        try retireCompleted(
            entry.command,
            expectedFilename: entry.filename,
            expectedBatchID: entry.batchID,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
    }

    private func retireCompleted(
        _ command: CoreCommand,
        expectedFilename: String?,
        expectedBatchID: UUID? = nil,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws {
        try CoreOwnerMetadataStore.withValidatedLease(lease, at: ownerMetadataURL) {
            try FileLock.withExclusiveLock(at: queueLockURL) {
                try FileLock.withExclusiveLock(at: lockURL(for: command.id)) {
                    if try updateBatchEntryLocked(
                        command: command,
                        expectedBatchID: expectedBatchID,
                        requiredState: .completed,
                        transform: { _ in nil }
                    ) {
                        return
                    }
                    guard expectedBatchID == nil else { return }
                    let completed = root.appendingPathComponent("completed", isDirectory: true)
                    guard
                        let source = try completedSourceURL(
                            in: completed,
                            for: command,
                            expectedFilename: expectedFilename
                        )
                    else {
                        return
                    }
                    let existing = try decoder.decode(CoreCommand.self, from: Data(contentsOf: source))
                    guard Self.semanticallyEqual(existing, command) else {
                        throw CoreCommandQueueError.identifierCollision(command.id)
                    }
                    try FileManager.default.removeItem(at: source)
                }
            }
        }
    }

    /// Moves an unresolved cleanup entry behind every entry with fewer cleanup
    /// attempts. The fixed-width attempt and command UUID form a durable,
    /// deterministic round-robin order: a fixed prefix of transient failures
    /// cannot starve the 4,097th command forever.
    public func deferCompletedCleanup(
        _ command: CoreCommand,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws {
        try deferCompletedCleanup(
            command,
            expectedFilename: nil,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
    }

    func deferCompletedCleanup(
        _ entry: CompletedCommandCleanupEntry,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws {
        try deferCompletedCleanup(
            entry.command,
            expectedFilename: entry.filename,
            expectedBatchID: entry.batchID,
            lease: lease,
            ownerMetadataURL: ownerMetadataURL
        )
    }

    private func deferCompletedCleanup(
        _ command: CoreCommand,
        expectedFilename: String?,
        expectedBatchID: UUID? = nil,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws {
        try CoreOwnerMetadataStore.withValidatedLease(lease, at: ownerMetadataURL) {
            try FileLock.withExclusiveLock(at: queueLockURL) {
                try FileLock.withExclusiveLock(at: lockURL(for: command.id)) {
                    if try updateBatchEntryLocked(
                        command: command,
                        expectedBatchID: expectedBatchID,
                        requiredState: .completed,
                        transform: { entry in
                            let (nextAttempt, overflow) = entry.cleanupAttempt.addingReportingOverflow(1)
                            guard !overflow else {
                                throw CoreCommandQueueError.completedCleanupAttemptOverflow(command.id)
                            }
                            var updated = entry
                            updated.cleanupAttempt = nextAttempt
                            return updated
                        }
                    ) {
                        return
                    }
                    guard expectedBatchID == nil else { return }
                    let completed = root.appendingPathComponent("completed", isDirectory: true)
                    guard
                        let source = try completedSourceURL(
                            in: completed,
                            for: command,
                            expectedFilename: expectedFilename
                        )
                    else {
                        return
                    }
                    let existing = try decoder.decode(CoreCommand.self, from: Data(contentsOf: source))
                    guard Self.semanticallyEqual(existing, command) else {
                        throw CoreCommandQueueError.identifierCollision(command.id)
                    }
                    let attempt = try Self.completedCleanupAttempt(
                        for: source,
                        commandID: command.id
                    )
                    let (nextAttempt, overflow) = attempt.addingReportingOverflow(1)
                    guard !overflow else {
                        throw CoreCommandQueueError.completedCleanupAttemptOverflow(command.id)
                    }
                    let target = completed.appendingPathComponent(
                        Self.completedFilename(commandID: command.id, attempt: nextAttempt)
                    )
                    try FileManager.default.moveItem(at: source, to: target)
                }
            }
        }
    }

    private func acknowledge(
        _ command: CoreCommand,
        leaseValidation: (() throws -> Void)?
    ) throws {
        try FileLock.withExclusiveLock(at: queueLockURL) {
            try FileLock.withExclusiveLock(at: lockURL(for: command.id)) {
                try leaseValidation?()
                try removeRetryStateLocked(commandID: command.id, migrationAt: .now)
                if try updateBatchEntryLocked(
                    command: command,
                    expectedBatchID: nil,
                    requiredState: .pending,
                    transform: { entry in
                        var updated = entry
                        updated.state = .completed
                        updated.cleanupAttempt = 0
                        return updated
                    }
                ) {
                    return
                }
                let pending = root.appendingPathComponent("pending", isDirectory: true)
                let completed = root.appendingPathComponent("completed", isDirectory: true)
                try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
                guard let source = try matchingCommandURLs(in: pending, id: command.id).first else { return }
                let target = completed.appendingPathComponent(
                    Self.completedFilename(commandID: command.id, attempt: 0)
                )
                if FileManager.default.fileExists(atPath: target.path) {
                    let existing = try decoder.decode(CoreCommand.self, from: Data(contentsOf: target))
                    guard Self.semanticallyEqual(existing, command) else {
                        throw CoreCommandQueueError.identifierCollision(command.id)
                    }
                    try FileManager.default.removeItem(at: source)
                    return
                }
                try FileManager.default.moveItem(at: source, to: target)
            }
        }
    }

    public func record(
        _ result: CoreCommandResult,
        at date: Date = .now
    ) throws {
        try record(result, at: date, leaseValidation: nil)
    }

    public func record(
        _ result: CoreCommandResult,
        at date: Date = .now,
        lease: CoreOwnerLease,
        ownerMetadataURL: URL
    ) throws {
        guard result.ownerEpoch == lease.epoch, result.instanceID == lease.instanceID else {
            throw CoreCommandQueueError.ownerLeaseMismatch
        }
        try CoreOwnerMetadataStore.withValidatedLease(lease, at: ownerMetadataURL) {
            try record(result, at: date, leaseValidation: nil)
        }
    }

    private func record(
        _ result: CoreCommandResult,
        at date: Date,
        leaseValidation: (() throws -> Void)?
    ) throws {
        try FileLock.withExclusiveLock(at: queueLockURL) {
            try FileLock.withExclusiveLock(at: lockURL(for: result.commandID)) {
                try leaseValidation?()
                let directory = root.appendingPathComponent("results", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let final = resultURL(for: result.commandID)
                let existing: CoreCommandResult?
                if FileManager.default.fileExists(atPath: final.path) {
                    existing = try decoder.decode(
                        CoreCommandResult.self,
                        from: Data(contentsOf: final)
                    )
                } else {
                    existing = nil
                }
                if existing?.status == .succeeded {
                    try removeRetryStateLocked(commandID: result.commandID, migrationAt: date)
                    return
                }

                let pendingCommands = try pendingLocked(limit: .max)
                if result.status == .retryable,
                    let command = pendingCommands.first(where: { $0.id == result.commandID })
                {
                    var schedule =
                        try reconciledRetryScheduleLocked(
                            for: pendingCommands,
                            observedAt: date
                        ) ?? CoreCommandRetrySchedule(lastObservedAt: date, entries: [])
                    let previousAttempt =
                        schedule.entries.first(where: {
                            $0.commandID == result.commandID
                        })?.attempt ?? 0
                    let (attempt, overflow) = previousAttempt.addingReportingOverflow(1)
                    guard !overflow else {
                        throw CoreCommandQueueError.retryAttemptOverflow(result.commandID)
                    }
                    let lastError = try Self.validatedRetryError(result.errorCode)
                    let delay = Self.retryDelay(for: command, attempt: attempt)
                    let earliestRetryAt = date.addingTimeInterval(delay)
                    guard Self.isValidRetryDate(earliestRetryAt) else {
                        throw CoreCommandQueueError.invalidRetryClock
                    }
                    let state = CoreCommandRetryState(
                        commandID: result.commandID,
                        attempt: attempt,
                        lastError: lastError,
                        earliestRetryAt: earliestRetryAt,
                        lastAttemptAt: date
                    )
                    schedule.entries.removeAll { $0.commandID == result.commandID }
                    schedule.entries.append(state)
                    schedule.lastObservedAt = date
                    // The schedule is committed first. A crash before the
                    // companion result write can delay a command, but can never
                    // cause an immediate replay storm.
                    try writeRetryScheduleLocked(schedule)
                    try encoder.encode(result).write(to: final, options: Self.writeOptions)
                    return
                }

                // Terminal outcomes clear retry metadata before publication.
                // If the result write then fails, a legacy retryable result can
                // conservatively recreate its schedule on the next read.
                try removeRetryStateLocked(commandID: result.commandID, migrationAt: date)
                try encoder.encode(result).write(to: final, options: Self.writeOptions)
            }
        }
    }

    public func result(for commandID: UUID) throws -> CoreCommandResult? {
        try FileLock.withExclusiveLock(at: lockURL(for: commandID)) {
            let url = resultURL(for: commandID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try decoder.decode(CoreCommandResult.self, from: Data(contentsOf: url))
        }
    }

    public func waitForResult(
        commandID: UUID,
        timeout: Duration = .seconds(30),
        pollingInterval: Duration = .milliseconds(100)
    ) async throws -> CoreCommandResult? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            try Task.checkCancellation()
            if let result = try result(for: commandID) { return result }
            try await Task.sleep(for: pollingInterval)
        } while clock.now < deadline
        return try result(for: commandID)
    }

    /// Bounded exponential retry delay with deterministic per-command jitter.
    /// Safety controls remain immediately runnable; user-facing triggers use a
    /// shorter envelope than opportunistic background work.
    static func retryDelay(
        for command: CoreCommand,
        attempt: UInt64
    ) -> TimeInterval {
        guard command.schedulingClass != .safetyControl else { return 0 }
        let envelope: (base: TimeInterval, maximum: TimeInterval)
        switch command.trigger {
        case .fileProvider:
            envelope = (1, 30)
        case .user:
            envelope = (2, 120)
        case .appIntent:
            envelope = (5, 300)
        case .foreground:
            envelope = (15, 900)
        case .backgroundProcessing:
            envelope = (30, 1_800)
        case .backgroundRefresh:
            envelope = (60, 3_600)
        }
        let exponent = min(attempt > 0 ? attempt - 1 : 0, 20)
        let exponential = min(
            envelope.maximum,
            envelope.base * pow(2, Double(exponent))
        )
        let seed = Data(
            "\(command.id.uuidString)|\(command.kind.rawValue)|\(command.trigger.rawValue)|\(attempt)"
                .utf8
        )
        let digest = SHA256.hash(data: seed)
        let bucket = digest.prefix(8).reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        let unit = Double(bucket) / Double(UInt64.max)
        return exponential * (0.75 + (unit * 0.25))
    }

    private func reconciledRetryScheduleLocked(
        for commands: [CoreCommand],
        observedAt date: Date
    ) throws -> CoreCommandRetrySchedule? {
        guard Self.isValidRetryDate(date) else {
            throw CoreCommandQueueError.invalidRetryClock
        }
        let loaded = try loadRetryScheduleLocked(migrationAt: date)
        var schedule = loaded ?? CoreCommandRetrySchedule(lastObservedAt: date, entries: [])
        if !schedule.entries.isEmpty, date < schedule.lastObservedAt {
            throw CoreCommandQueueError.retryClockRollback(
                lastObservedAt: schedule.lastObservedAt,
                proposedAt: date
            )
        }

        let pendingIDs = Set(commands.map(\.id))
        var changed = schedule.entries.contains { !pendingIDs.contains($0.commandID) }
        schedule.entries.removeAll { !pendingIDs.contains($0.commandID) }
        var states = Dictionary(
            uniqueKeysWithValues: schedule.entries.map { ($0.commandID, $0) }
        )

        for command in commands {
            let persistedResult = try resultLocked(for: command.id)
            if let persistedResult, persistedResult.status != .retryable {
                if states.removeValue(forKey: command.id) != nil { changed = true }
                continue
            }
            guard states[command.id] == nil,
                let persistedResult,
                persistedResult.status == .retryable
            else {
                continue
            }
            guard Self.isValidRetryDate(persistedResult.completedAt) else {
                throw CoreCommandQueueError.invalidRetryClock
            }
            guard date >= persistedResult.completedAt else {
                throw CoreCommandQueueError.retryClockRollback(
                    lastObservedAt: persistedResult.completedAt,
                    proposedAt: date
                )
            }
            let lastError = try Self.validatedRetryError(persistedResult.errorCode)
            let earliestRetryAt = persistedResult.completedAt.addingTimeInterval(
                Self.retryDelay(for: command, attempt: 1)
            )
            guard Self.isValidRetryDate(earliestRetryAt) else {
                throw CoreCommandQueueError.invalidRetryClock
            }
            states[command.id] = CoreCommandRetryState(
                commandID: command.id,
                attempt: 1,
                lastError: lastError,
                earliestRetryAt: earliestRetryAt,
                lastAttemptAt: persistedResult.completedAt
            )
            changed = true
        }

        schedule.entries = Array(states.values)
        guard !schedule.entries.isEmpty else {
            if loaded != nil { try writeRetryScheduleLocked(schedule) }
            return nil
        }
        if schedule.lastObservedAt != date {
            schedule.lastObservedAt = date
            changed = true
        }
        if loaded == nil || changed {
            try writeRetryScheduleLocked(schedule)
        }
        return schedule
    }

    private func resultLocked(for commandID: UUID) throws -> CoreCommandResult? {
        let url = resultURL(for: commandID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(CoreCommandResult.self, from: Data(contentsOf: url))
    }

    private func removeRetryStateLocked(
        commandID: UUID,
        migrationAt date: Date
    ) throws {
        guard var schedule = try loadRetryScheduleLocked(migrationAt: date) else { return }
        let previousCount = schedule.entries.count
        schedule.entries.removeAll { $0.commandID == commandID }
        guard schedule.entries.count != previousCount else { return }
        try writeRetryScheduleLocked(schedule)
    }

    private func loadRetryScheduleLocked(
        migrationAt date: Date
    ) throws -> CoreCommandRetrySchedule? {
        let data: Data
        do {
            guard
                let persisted = try SecureLockFile.readRegularFileIfPresent(
                    at: retryScheduleURL,
                    maximumSize: Self.maximumRetryScheduleDocumentBytes
                )
            else {
                return nil
            }
            data = persisted
        } catch let error as CoreCommandQueueError {
            throw error
        } catch {
            throw CoreCommandQueueError.invalidRetryScheduleDocument
        }
        let version: Int
        do {
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let number = object["schemaVersion"] as? NSNumber
            else {
                throw CoreCommandQueueError.invalidRetryScheduleDocument
            }
            version = number.intValue
        } catch let error as CoreCommandQueueError {
            throw error
        } catch {
            throw CoreCommandQueueError.invalidRetryScheduleDocument
        }

        do {
            switch version {
            case CoreCommandRetrySchedule.currentSchemaVersion:
                let schedule = try decoder.decode(CoreCommandRetrySchedule.self, from: data)
                try validateCanonicalRetryDocument(data, decoded: schedule)
                try Self.validateRetrySchedule(schedule)
                return schedule
            case LegacyCoreCommandRetrySchedule.schemaVersion:
                guard Self.isValidRetryDate(date) else {
                    throw CoreCommandQueueError.invalidRetryClock
                }
                let legacy = try decoder.decode(LegacyCoreCommandRetrySchedule.self, from: data)
                try validateCanonicalRetryDocument(data, decoded: legacy)
                try Self.validateLegacyRetrySchedule(legacy)
                let migrated = CoreCommandRetrySchedule(
                    lastObservedAt: date,
                    entries: legacy.entries.map {
                        CoreCommandRetryState(
                            commandID: $0.commandID,
                            attempt: $0.attempt,
                            lastError: $0.lastError,
                            earliestRetryAt: $0.earliestRetryAt,
                            lastAttemptAt: min($0.earliestRetryAt, date)
                        )
                    }
                )
                try writeRetryScheduleLocked(migrated)
                return migrated
            default:
                throw CoreCommandQueueError.unsupportedRetryScheduleSchema(version)
            }
        } catch let error as CoreCommandQueueError {
            throw error
        } catch {
            throw CoreCommandQueueError.invalidRetryScheduleDocument
        }
    }

    private func validateCanonicalRetryDocument<T: Encodable>(
        _ original: Data,
        decoded: T
    ) throws {
        let canonical = try encoder.encode(decoded)
        guard
            let originalObject = try JSONSerialization.jsonObject(with: original) as? NSObject,
            let canonicalObject = try JSONSerialization.jsonObject(with: canonical) as? NSObject,
            originalObject == canonicalObject
        else {
            throw CoreCommandQueueError.invalidRetryScheduleDocument
        }
    }

    private static func validateRetrySchedule(
        _ schedule: CoreCommandRetrySchedule
    ) throws {
        guard schedule.schemaVersion == CoreCommandRetrySchedule.currentSchemaVersion,
            isValidRetryDate(schedule.lastObservedAt)
        else {
            throw CoreCommandQueueError.invalidRetryScheduleDocument
        }
        var commandIDs = Set<UUID>()
        for state in schedule.entries {
            guard commandIDs.insert(state.commandID).inserted,
                state.attempt > 0,
                try validatedRetryError(state.lastError) == state.lastError,
                isValidRetryDate(state.lastAttemptAt),
                isValidRetryDate(state.earliestRetryAt),
                state.lastAttemptAt <= state.earliestRetryAt,
                state.lastAttemptAt <= schedule.lastObservedAt
            else {
                throw CoreCommandQueueError.invalidRetryScheduleDocument
            }
        }
    }

    private static func validateLegacyRetrySchedule(
        _ schedule: LegacyCoreCommandRetrySchedule
    ) throws {
        guard schedule.schemaVersion == LegacyCoreCommandRetrySchedule.schemaVersion else {
            throw CoreCommandQueueError.invalidRetryScheduleDocument
        }
        var commandIDs = Set<UUID>()
        for state in schedule.entries {
            guard commandIDs.insert(state.commandID).inserted,
                state.attempt > 0,
                try validatedRetryError(state.lastError) == state.lastError,
                isValidRetryDate(state.earliestRetryAt)
            else {
                throw CoreCommandQueueError.invalidRetryScheduleDocument
            }
        }
    }

    private static func validatedRetryError(_ errorCode: String?) throws -> String {
        let value = errorCode ?? "unknown_retryable_error"
        guard !value.isEmpty, value.utf8.count <= maximumRetryErrorBytes else {
            throw CoreCommandQueueError.invalidRetryScheduleDocument
        }
        return value
    }

    private static func isValidRetryDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite
    }

    private func writeRetryScheduleLocked(
        _ proposed: CoreCommandRetrySchedule
    ) throws {
        guard !proposed.entries.isEmpty else {
            if FileManager.default.fileExists(atPath: retryScheduleURL.path) {
                try FileManager.default.removeItem(at: retryScheduleURL)
            }
            return
        }
        var schedule = proposed
        schedule.schemaVersion = CoreCommandRetrySchedule.currentSchemaVersion
        schedule.entries.sort { $0.commandID.uuidString < $1.commandID.uuidString }
        try Self.validateRetrySchedule(schedule)
        let data = try encoder.encode(schedule)
        guard data.count <= Self.maximumRetryScheduleDocumentBytes else {
            throw CoreCommandQueueError.invalidRetryScheduleDocument
        }
        try SecureLockFile.writeAtomically(data, to: retryScheduleURL)
    }

    private func batchEnvelopesLocked() throws -> [LoadedCoreCommandBatch] {
        let directory = batchDirectory
        var status = stat()
        if lstat(directory.path, &status) != 0 {
            if errno == ENOENT { return [] }
            throw CoreCommandQueueError.invalidBatchDocument
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), status.st_nlink > 0 else {
            throw CoreCommandQueueError.invalidBatchDocument
        }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw CoreCommandQueueError.invalidBatchDocument
        }

        var loaded: [LoadedCoreCommandBatch] = []
        var batchIDs = Set<UUID>()
        var commandIDs = Set<UUID>()
        for url in urls {
            guard let filenameID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                url.lastPathComponent == "\(filenameID.uuidString.lowercased()).json"
            else {
                throw CoreCommandQueueError.invalidBatchDocument
            }
            let data: Data
            do {
                guard
                    let value = try SecureLockFile.readRegularFileIfPresent(
                        at: url,
                        maximumSize: Self.maximumBatchDocumentBytes
                    )
                else {
                    throw CoreCommandQueueError.invalidBatchDocument
                }
                data = value
            } catch let error as CoreCommandQueueError {
                throw error
            } catch {
                throw CoreCommandQueueError.invalidBatchDocument
            }
            let envelope: CoreCommandBatchEnvelope
            do {
                envelope = try decoder.decode(CoreCommandBatchEnvelope.self, from: data)
                try validateCanonicalBatchDocument(data, decoded: envelope)
                try validateBatchEnvelope(envelope)
            } catch let error as CoreCommandQueueError {
                throw error
            } catch {
                throw CoreCommandQueueError.invalidBatchDocument
            }
            guard envelope.batchID == filenameID,
                batchIDs.insert(envelope.batchID).inserted
            else {
                throw CoreCommandQueueError.invalidBatchDocument
            }
            for entry in envelope.entries {
                guard commandIDs.insert(entry.command.id).inserted else {
                    throw CoreCommandQueueError.identifierCollision(entry.command.id)
                }
            }
            loaded.append(.init(url: url, envelope: envelope))
        }
        return loaded
    }

    private func publishBatchLocked(
        _ commands: [CoreCommand],
        batchID: UUID
    ) throws {
        guard !commands.isEmpty else { throw CoreCommandQueueError.emptyBatch }
        guard commands.count <= Self.maximumBatchCommands else {
            throw CoreCommandQueueError.batchTooLarge
        }
        let envelope = try CoreCommandBatchEnvelope(batchID: batchID, commands: commands)
        try validateBatchEnvelope(envelope)
        let existingBatches = try batchEnvelopesLocked()
        if let existing = existingBatches.first(where: { $0.envelope.batchID == batchID }) {
            guard Self.batchSemanticallyEqual(existing.envelope, envelope) else {
                throw CoreCommandQueueError.identifierCollision(commands.first?.id ?? batchID)
            }
            return
        }

        for command in commands {
            let pending = root.appendingPathComponent("pending", isDirectory: true)
            let completed = root.appendingPathComponent("completed", isDirectory: true)
            guard try matchingCommandURLs(in: pending, id: command.id).isEmpty,
                try matchingCommandURLs(in: completed, id: command.id).isEmpty,
                !existingBatches.contains(where: {
                    $0.envelope.entries.contains(where: { $0.command.id == command.id })
                })
            else {
                throw CoreCommandQueueError.identifierCollision(command.id)
            }
        }

        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumBatchDocumentBytes else {
            throw CoreCommandQueueError.batchTooLarge
        }
        try SecureLockFile.writeAtomically(data, to: batchURL(for: batchID))
    }

    private func batchEntryLocked(
        commandID: UUID
    ) throws -> (batch: LoadedCoreCommandBatch, entry: CoreCommandBatchEntry)? {
        for batch in try batchEnvelopesLocked() {
            if let entry = batch.envelope.entries.first(where: { $0.command.id == commandID }) {
                return (batch, entry)
            }
        }
        return nil
    }

    /// Returns true when the identifier belongs to a durable batch, including
    /// an already-applied state transition. The full envelope is validated
    /// before and after the mutation and replaced with one atomic rename.
    private func updateBatchEntryLocked(
        command: CoreCommand,
        expectedBatchID: UUID?,
        requiredState: CoreCommandBatchEntryState,
        transform: (CoreCommandBatchEntry) throws -> CoreCommandBatchEntry?
    ) throws -> Bool {
        let batches = try batchEnvelopesLocked()
        guard
            let loaded = batches.first(where: { batch in
                batch.envelope.entries.contains(where: { $0.command.id == command.id })
            })
        else {
            return false
        }
        if let expectedBatchID, loaded.envelope.batchID != expectedBatchID {
            throw CoreCommandQueueError.identifierCollision(command.id)
        }
        guard let index = loaded.envelope.entries.firstIndex(where: { $0.command.id == command.id }) else {
            throw CoreCommandQueueError.invalidBatchDocument
        }
        let existing = loaded.envelope.entries[index]
        guard Self.semanticallyEqual(existing.command, command) else {
            throw CoreCommandQueueError.identifierCollision(command.id)
        }
        // Repeating an already-applied transition is an idempotent no-op. It
        // must not fall through to legacy paths with the same identifier.
        guard existing.state == requiredState else { return true }

        var envelope = loaded.envelope
        if let replacement = try transform(existing) {
            envelope.entries[index] = replacement
        } else {
            envelope.entries.remove(at: index)
        }
        if envelope.entries.isEmpty {
            do {
                try FileManager.default.removeItem(at: loaded.url)
            } catch CocoaError.fileNoSuchFile {
                throw CoreCommandQueueError.invalidBatchDocument
            } catch {
                throw error
            }
        } else {
            try writeBatchEnvelopeLocked(envelope, to: loaded.url)
        }
        return true
    }

    private func validateBatchEnvelope(_ envelope: CoreCommandBatchEnvelope) throws {
        guard envelope.schemaVersion == CoreCommandBatchEnvelope.currentSchemaVersion,
            !envelope.entries.isEmpty,
            envelope.entries.count <= Self.maximumBatchCommands
        else {
            throw CoreCommandQueueError.invalidBatchDocument
        }
        var identifiers = Set<UUID>()
        for entry in envelope.entries {
            guard identifiers.insert(entry.command.id).inserted,
                entry.semanticDigest == (try Self.semanticDigest(for: entry.command)),
                CoreSessionDigest.isLowercaseSHA256(entry.semanticDigest),
                entry.state == .completed || entry.cleanupAttempt == 0
            else {
                throw CoreCommandQueueError.invalidBatchDocument
            }
        }
    }

    private func validateCanonicalBatchDocument(
        _ data: Data,
        decoded envelope: CoreCommandBatchEnvelope
    ) throws {
        let original = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.jsonObject(with: encoder.encode(envelope))
        guard let originalObject = original as? NSObject,
            let canonicalObject = canonical as? NSObject,
            originalObject == canonicalObject
        else {
            throw CoreCommandQueueError.invalidBatchDocument
        }
    }

    private func writeBatchEnvelopeLocked(
        _ envelope: CoreCommandBatchEnvelope,
        to url: URL
    ) throws {
        try validateBatchEnvelope(envelope)
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumBatchDocumentBytes else {
            throw CoreCommandQueueError.batchTooLarge
        }
        try SecureLockFile.writeAtomically(data, to: url)
    }

    fileprivate static func semanticDigest(for command: CoreCommand) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(command))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func batchSemanticallyEqual(
        _ lhs: CoreCommandBatchEnvelope,
        _ rhs: CoreCommandBatchEnvelope
    ) -> Bool {
        lhs.batchID == rhs.batchID
            && lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy {
                Self.semanticallyEqual($0.command, $1.command)
                    && $0.semanticDigest == $1.semanticDigest
            }
    }

    private static func commandOrder(_ lhs: CoreCommand, _ rhs: CoreCommand) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private var batchDirectory: URL {
        root.appendingPathComponent("batches", isDirectory: true)
    }

    private var retryScheduleURL: URL {
        root.appendingPathComponent(Self.retryScheduleFilename)
    }

    private func batchURL(for batchID: UUID) -> URL {
        batchDirectory.appendingPathComponent("\(batchID.uuidString.lowercased()).json")
    }

    private static func filename(for command: CoreCommand) -> String {
        let micros = Int64(command.createdAt.timeIntervalSince1970 * 1_000_000)
        return String(format: "%020lld-%@.json", micros, command.id.uuidString.lowercased())
    }

    private static func completedCleanupAttempt(for url: URL, commandID: UUID) throws -> UInt64 {
        let filename = url.lastPathComponent
        let prefix = "~retry-"
        guard filename.hasPrefix(prefix) else { return 0 }
        let suffix = "-\(commandID.uuidString.lowercased()).json"
        guard filename.hasSuffix(suffix) else {
            throw CoreCommandQueueError.identifierCollision(commandID)
        }
        let attemptStart = filename.index(filename.startIndex, offsetBy: prefix.count)
        let attemptEnd = filename.index(filename.endIndex, offsetBy: -suffix.count)
        guard filename.distance(from: attemptStart, to: attemptEnd) == 20,
            let attempt = UInt64(filename[attemptStart..<attemptEnd])
        else {
            throw CoreCommandQueueError.identifierCollision(commandID)
        }
        return attempt
    }

    private static func completedFilename(commandID: UUID, attempt: UInt64) -> String {
        String(
            format: "~retry-%020llu-%@.json",
            attempt,
            commandID.uuidString.lowercased()
        )
    }

    private static func semanticallyEqual(_ lhs: CoreCommand, _ rhs: CoreCommand) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.folderID == rhs.folderID
            && lhs.itemID == rhs.itemID
            && lhs.arguments == rhs.arguments
            && lhs.folderIncarnationDigest == rhs.folderIncarnationDigest
            && lhs.commandConfigurationRevision == rhs.commandConfigurationRevision
            && lhs.taskPolicyBinding == rhs.taskPolicyBinding
            && lhs.trigger == rhs.trigger
    }

    private func resultURL(for commandID: UUID) -> URL {
        root.appendingPathComponent("results", isDirectory: true)
            .appendingPathComponent("\(commandID.uuidString.lowercased()).json")
    }

    private func lockURL(for commandID: UUID) -> URL {
        root.appendingPathComponent("locks", isDirectory: true)
            .appendingPathComponent("\(commandID.uuidString.lowercased()).lock")
    }

    private var queueLockURL: URL {
        root.appendingPathComponent("queue.lock")
    }

    private func matchingCommandURLs(in directory: URL, id: UUID) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let suffix = "-\(id.uuidString.lowercased()).json"
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasSuffix(suffix) }
    }

    private func completedSourceURL(
        in directory: URL,
        for command: CoreCommand,
        expectedFilename: String?
    ) throws -> URL? {
        if let expectedFilename {
            let candidate = directory.appendingPathComponent(expectedFilename)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        let initial = directory.appendingPathComponent(
            Self.completedFilename(commandID: command.id, attempt: 0)
        )
        if FileManager.default.fileExists(atPath: initial.path) { return initial }
        let original = directory.appendingPathComponent(Self.filename(for: command))
        if FileManager.default.fileExists(atPath: original.path) { return original }
        return try matchingCommandURLs(in: directory, id: command.id).first
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
            [.atomic, .completeFileProtectionUnlessOpen]
        #else
            [.atomic]
        #endif
    }
}
