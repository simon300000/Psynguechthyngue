import CryptoKit
import Darwin
import Foundation

public enum ControlledMirrorErrorCode: String, Codable, Hashable, Sendable {
    case unsupportedMode
    case invalidRoot
    case rootsOverlap
    case invalidRelativePath
    case pathOutsideRoot
    case symbolicLinkRejected
    case pathCollision
    case unsupportedEntryType
    case entryTypeConflict
    case stateCorrupt
    case unsupportedSchema
    case ioEnumerate
    case ioRead
    case ioWrite
    case atomicReplaceFailed
    case sourceChangedDuringRun
    case destinationChangedDuringRun
    case rootChangedDuringRun
    case confirmationNotFound
    case confirmationChanged
    case directoryNotEmpty
}

public struct ControlledMirrorFailure: Error, Codable, Hashable, Sendable {
    public let code: ControlledMirrorErrorCode
    public let relativePath: String?

    public init(code: ControlledMirrorErrorCode, relativePath: String? = nil) {
        self.code = code
        self.relativePath = Self.safeRelativePath(relativePath)
    }

    private static func safeRelativePath(_ value: String?) -> String? {
        guard let value,
            !value.hasPrefix("/"),
            !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else {
            return nil
        }
        return value
    }
}

public enum ControlledMirrorSide: String, Codable, Hashable, Sendable {
    case managed
    case external
}

public enum ControlledMirrorConfirmationKind: String, Codable, Hashable, Sendable {
    case deleteManaged
    case deleteExternal
}

public enum ControlledMirrorConfirmationDecision: String, Codable, Hashable, Sendable {
    /// Delete the unchanged surviving copy, completing the deletion in the
    /// opposite mirror root.
    case propagateDeletion
    /// Preserve the surviving copy. Controlled mirrors restore it to the
    /// missing side; one-way modes accept the safe divergence as a new base.
    case keepSurvivingCopy
}

public struct ControlledMirrorConfirmation: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: ControlledMirrorConfirmationKind
    public let relativePath: String
    public let expectedContentDigest: String?

    public init(
        id: String,
        kind: ControlledMirrorConfirmationKind,
        relativePath: String,
        expectedContentDigest: String?
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.expectedContentDigest = expectedContentDigest
    }
}

public struct ControlledMirrorConflict: Codable, Hashable, Sendable {
    public let originalRelativePath: String
    public let artifactRelativePath: String
    public let preservedSide: ControlledMirrorSide

    public init(
        originalRelativePath: String,
        artifactRelativePath: String,
        preservedSide: ControlledMirrorSide
    ) {
        self.originalRelativePath = originalRelativePath
        self.artifactRelativePath = artifactRelativePath
        self.preservedSide = preservedSide
    }
}

public struct ControlledMirrorRunResult: Codable, Hashable, Sendable {
    public let generation: UInt64
    public let copiedToManaged: Int
    public let copiedToExternal: Int
    public let conflicts: [ControlledMirrorConflict]
    public let confirmationRequired: [ControlledMirrorConfirmation]

    public init(
        generation: UInt64,
        copiedToManaged: Int,
        copiedToExternal: Int,
        conflicts: [ControlledMirrorConflict],
        confirmationRequired: [ControlledMirrorConfirmation]
    ) {
        self.generation = generation
        self.copiedToManaged = copiedToManaged
        self.copiedToExternal = copiedToExternal
        self.conflicts = conflicts
        self.confirmationRequired = confirmationRequired
    }
}

/// One finite provider-payload event. Metadata-only enumeration contributes
/// zero bytes, but every content hash, cross-boundary copy/write, staged
/// verification, deletion fence, and final manifest hash has its own event (or
/// a conservative aggregate for the descriptor-bound atomic transaction).
public struct ControlledMirrorLogicalTransfer: Hashable, Sendable, Identifiable {
    public enum Direction: String, Hashable, Sendable {
        case fromExternalProvider
        case toExternalProvider
        case withinExternalProvider
        /// Reads provider payload bytes only to produce a recovery fingerprint;
        /// unlike an import, this does not install bytes on the managed volume.
        case readExternalProvider
    }

    public let id: UUID
    public let direction: Direction
    public let byteCount: Int64
    public let isCompleted: Bool
    let eventKey: String

    fileprivate init(
        id: UUID,
        direction: Direction,
        byteCount: Int64,
        isCompleted: Bool,
        eventKey: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.byteCount = byteCount
        self.isCompleted = isCompleted
        self.eventKey = eventKey ?? id.uuidString
    }
}

public enum ControlledMirrorPreparedStage: String, Hashable, Sendable {
    /// A metadata-only bound for the hashes needed to decide and durably form
    /// the journal. No provider payload has been read when this is returned.
    case observation
    /// A journal-derived bound for apply, all provider probes, and final scan.
    case apply
    /// Existing recovery APIs already use a separate exact prepared scope.
    case recovery
}

/// Durable identity and worst-case logical byte bounds for a mirror journal.
/// Instances are produced only by `prepareSynchronization()` and are rechecked
/// against the journal immediately before apply.
public struct ControlledMirrorPreparedPlan: Hashable, Sendable {
    public let runID: UUID
    public let planDigest: String
    public let stage: ControlledMirrorPreparedStage
    public let logicalTransfers: [ControlledMirrorLogicalTransfer]
    public let maximumLogicalProviderBytes: Int64
    public let remainingLogicalProviderBytes: Int64
    fileprivate let observationPreparation: ControlledMirror.ObservationPreparation?

    fileprivate init(
        runID: UUID,
        planDigest: String,
        stage: ControlledMirrorPreparedStage = .apply,
        logicalTransfers: [ControlledMirrorLogicalTransfer],
        maximumLogicalProviderBytes: Int64,
        remainingLogicalProviderBytes: Int64,
        observationPreparation: ControlledMirror.ObservationPreparation? = nil
    ) {
        self.runID = runID
        self.planDigest = planDigest
        self.stage = stage
        self.logicalTransfers = logicalTransfers
        self.maximumLogicalProviderBytes = maximumLogicalProviderBytes
        self.remainingLogicalProviderBytes = remainingLogicalProviderBytes
        self.observationPreparation = observationPreparation
    }
}

/// In-memory result of an accounted observation. The broker must settle the
/// observation session before asking the mirror to persist this journal.
public struct ControlledMirrorObservedPlan: Sendable {
    public let runID: UUID
    public let planDigest: String

    fileprivate let draft: ControlledMirror.ObservedDraft
}

public enum ControlledMirrorPreparedPlanError: Error, Hashable, Sendable {
    case changed
    case invalidJournal
    case byteCountOverflow
}

public enum ControlledMirrorPreparedRecoveryError: Error, Hashable, Sendable {
    case changed
    case unboundedExternalPayload
    case byteCountOverflow
}

/// A finite, metadata-only bound for one recovery API call. `plan` is consumed
/// by the same durable owner/reservation/session lifecycle as a mirror journal;
/// the private scope prevents using a summaries grant to resolve a payload.
public struct ControlledMirrorPreparedRecovery: Sendable {
    public let plan: ControlledMirrorPreparedPlan

    fileprivate let scope: RecoveryScope
    fileprivate let reads: [RecoveryReadExpectation]
}

private enum RecoveryScope: Sendable {
    case summaries
    case export(requested: ControlledMirrorRecoverySummary)
    case resolution(
        requested: ControlledMirrorRecoverySummary,
        decision: ControlledMirrorRecoveryDecision
    )
}

private struct RecoveryReadBound: Codable, Hashable, Sendable {
    let operationID: UUID
    let side: ControlledMirrorSide
    let payloadName: String
    let byteCount: Int64
}

private struct RecoveryReadExpectation: Sendable {
    let bound: RecoveryReadBound
    let transfer: ControlledMirrorLogicalTransfer
}

private struct RecoveryPlanDigestPayload: Codable {
    let schemaVersion: Int
    let scopeKind: String
    let requested: ControlledMirrorRecoverySummary?
    let decision: ControlledMirrorRecoveryDecision?
    let reads: [RecoveryReadBound]
}

/// Synchronous metering callbacks deliberately sit immediately around the one
/// logical payload-copy operation. Authorization completes before provider I/O;
/// failures after authorization are reported as uncertain.
public struct ControlledMirrorTransferMeter: Sendable {
    public typealias Authorize = @Sendable (ControlledMirrorLogicalTransfer) throws -> Void
    public typealias Complete = @Sendable (ControlledMirrorLogicalTransfer) throws -> Void
    public typealias MarkUncertain = @Sendable (ControlledMirrorLogicalTransfer) -> Void

    private let authorizeBody: Authorize
    private let completeBody: Complete
    private let markUncertainBody: MarkUncertain

    public init(
        authorize: @escaping Authorize,
        complete: @escaping Complete,
        markUncertain: @escaping MarkUncertain
    ) {
        authorizeBody = authorize
        completeBody = complete
        markUncertainBody = markUncertain
    }

    public func authorize(_ transfer: ControlledMirrorLogicalTransfer) throws {
        try authorizeBody(transfer)
    }

    public func complete(_ transfer: ControlledMirrorLogicalTransfer) throws {
        try completeBody(transfer)
    }

    public func markUncertain(_ transfer: ControlledMirrorLogicalTransfer) {
        markUncertainBody(transfer)
    }

    static let unmetered = Self(
        authorize: { _ in },
        complete: { _ in },
        markUncertain: { _ in }
    )
}

public enum ControlledMirrorRecoveryKind: String, Codable, Hashable, Sendable {
    case copyBackup
    case deleteQuarantine
}

public enum ControlledMirrorRecoveryPayloadKind: String, Codable, Hashable, Sendable {
    case file
    case directory
}

public enum ControlledMirrorRecoveryStatus: String, Codable, Hashable, Sendable {
    case prepared
    case retainedRequiresUserConfirmation
    case conflictRequiresManualCleanup
    case disposalApprovedPendingCleanup
}

public struct ControlledMirrorRecoverySummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String { side.rawValue + ":" + operationID.uuidString }

    public let operationID: UUID
    public let side: ControlledMirrorSide
    public let kind: ControlledMirrorRecoveryKind
    public let relativePath: String
    public let payloadKind: ControlledMirrorRecoveryPayloadKind
    public let contentDigest: String
    public let byteCount: Int64
    public let createdAt: Date
    public let status: ControlledMirrorRecoveryStatus
    /// True only while a planned/applying mirror journal still references
    /// this recovery operation. The payload is required for restart recovery
    /// and must not be disposed until the journal finishes.
    public let isReferencedByActiveJournal: Bool

    public init(
        operationID: UUID,
        side: ControlledMirrorSide,
        kind: ControlledMirrorRecoveryKind,
        relativePath: String,
        payloadKind: ControlledMirrorRecoveryPayloadKind,
        contentDigest: String,
        byteCount: Int64,
        createdAt: Date,
        status: ControlledMirrorRecoveryStatus,
        isReferencedByActiveJournal: Bool = false
    ) {
        self.operationID = operationID
        self.side = side
        self.kind = kind
        self.relativePath = relativePath
        self.payloadKind = payloadKind
        self.contentDigest = contentDigest
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.status = status
        self.isReferencedByActiveJournal = isReferencedByActiveJournal
    }

    fileprivate func withActiveJournalReference(_ value: Bool) -> Self {
        Self(
            operationID: operationID,
            side: side,
            kind: kind,
            relativePath: relativePath,
            payloadKind: payloadKind,
            contentDigest: contentDigest,
            byteCount: byteCount,
            createdAt: createdAt,
            status: status,
            isReferencedByActiveJournal: value
        )
    }
}

public enum ControlledMirrorRecoveryDecision: String, Codable, Hashable, Sendable {
    /// Keep the recovery payload and its durable record unchanged.
    case retain
    /// Dispose only the exact bytes shown in the requested summary after an
    /// explicit authorization and policy fence succeeds immediately before removal.
    case deleteAfterUserConfirmation
}

public enum ControlledMirrorRecoveryError: Error, Equatable, Sendable {
    case notFound
    case changed
    case activeJournal
    case authorizationDenied
    case exportFailed
    case disposalFailed
}

/// A private, content-fenced snapshot suitable for an explicit system share or
/// Files export. The retained recovery payload itself is never exposed.
public struct ControlledMirrorRecoveryExport: Hashable, Sendable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let payloadKind: ControlledMirrorRecoveryPayloadKind

    fileprivate let containerName: String

    fileprivate init(
        url: URL,
        payloadKind: ControlledMirrorRecoveryPayloadKind,
        containerName: String
    ) {
        self.url = url
        self.payloadKind = payloadKind
        self.containerName = containerName
    }
}

/// Matches each real provider fingerprint read to the exact prepared transfer.
/// A mismatch is rejected before the descriptor is read; a failure after
/// authorization makes that transfer conservative through the session meter.
private final class ControlledMirrorRecoveryMeterState: @unchecked Sendable {
    private let expectations: [RecoveryReadExpectation]
    private let meter: ControlledMirrorTransferMeter
    private let lock = NSLock()
    private var nextIndex = 0

    init(
        expectations: [RecoveryReadExpectation],
        meter: ControlledMirrorTransferMeter
    ) {
        self.expectations = expectations
        self.meter = meter
    }

    func authorize(
        operationID: UUID,
        side: ControlledMirrorSide,
        payloadName: String,
        byteCount: Int64
    ) throws -> ControlledMirrorLogicalTransfer {
        let expectation = try lock.withLock {
            guard nextIndex < expectations.count else {
                throw ControlledMirrorPreparedRecoveryError.changed
            }
            let expectation = expectations[nextIndex]
            guard
                expectation.bound
                    == RecoveryReadBound(
                        operationID: operationID,
                        side: side,
                        payloadName: payloadName,
                        byteCount: byteCount
                    )
            else {
                throw ControlledMirrorPreparedRecoveryError.changed
            }
            return expectation
        }
        try meter.authorize(expectation.transfer)
        return expectation.transfer
    }

    func complete(_ transfer: ControlledMirrorLogicalTransfer) throws {
        do {
            try meter.complete(transfer)
        } catch {
            meter.markUncertain(transfer)
            advance(after: transfer)
            throw error
        }
        advance(after: transfer)
    }

    func markUncertain(_ transfer: ControlledMirrorLogicalTransfer) {
        meter.markUncertain(transfer)
        advance(after: transfer)
    }

    func requireFullyConsumed() throws {
        let consumed = lock.withLock { nextIndex == expectations.count }
        guard consumed else { throw ControlledMirrorPreparedRecoveryError.changed }
    }

    private func advance(after transfer: ControlledMirrorLogicalTransfer) {
        lock.withLock {
            guard nextIndex < expectations.count,
                expectations[nextIndex].transfer.id == transfer.id
            else {
                return
            }
            nextIndex += 1
        }
    }
}

/// Matches provider payload operations to a finite prepared grant before the
/// operation starts. Apply plans may contain conservative branch capacity, so
/// unused events are permitted; observation plans require full consumption.
private final class ControlledMirrorProviderMeterState: @unchecked Sendable {
    private let expectations: [ControlledMirrorLogicalTransfer]
    private let meter: ControlledMirrorTransferMeter
    private let lock = NSLock()
    private var usedIDs: Set<UUID> = []

    init(
        expectations: [ControlledMirrorLogicalTransfer],
        meter: ControlledMirrorTransferMeter
    ) {
        self.expectations = expectations.filter { !$0.isCompleted }
        self.meter = meter
    }

    func perform<T>(
        eventKey: String,
        direction: ControlledMirrorLogicalTransfer.Direction,
        byteCount: Int64,
        validate: (T) -> Bool = { _ in true },
        _ body: (ControlledMirrorLogicalTransfer) throws -> T
    ) throws -> T {
        let transfer = try take(
            eventKey: eventKey,
            direction: direction,
            byteCount: byteCount
        )
        try meter.authorize(transfer)
        do {
            let result = try body(transfer)
            guard validate(result) else {
                throw ControlledMirrorPreparedPlanError.changed
            }
            try meter.complete(transfer)
            return result
        } catch {
            meter.markUncertain(transfer)
            throw error
        }
    }

    /// Claims one prepared event at the exact point its provider payload I/O
    /// starts. Multiple finite events can share a semantic prefix; their
    /// ordinal suffixes remain unique while unused rollback/resume capacity is
    /// deliberately left unconsumed.
    func performNext<T>(
        eventKeyPrefix: String,
        direction: ControlledMirrorLogicalTransfer.Direction,
        byteCount: Int64,
        validate: (T) -> Bool = { _ in true },
        _ body: (ControlledMirrorLogicalTransfer) throws -> T
    ) throws -> T {
        let transfer = try takeNext(
            eventKeyPrefix: eventKeyPrefix,
            direction: direction,
            byteCount: byteCount
        )
        try meter.authorize(transfer)
        do {
            let result = try body(transfer)
            guard validate(result) else {
                throw ControlledMirrorPreparedPlanError.changed
            }
            try meter.complete(transfer)
            return result
        } catch {
            meter.markUncertain(transfer)
            throw error
        }
    }

    private func take(
        eventKey: String,
        direction: ControlledMirrorLogicalTransfer.Direction,
        byteCount: Int64
    ) throws -> ControlledMirrorLogicalTransfer {
        try lock.withLock {
            guard byteCount >= 0,
                let transfer = expectations.first(where: {
                    !usedIDs.contains($0.id)
                        && $0.eventKey == eventKey
                        && $0.direction == direction
                        && $0.byteCount == byteCount
                })
            else {
                throw ControlledMirrorPreparedPlanError.changed
            }
            usedIDs.insert(transfer.id)
            return transfer
        }
    }

    private func takeNext(
        eventKeyPrefix: String,
        direction: ControlledMirrorLogicalTransfer.Direction,
        byteCount: Int64
    ) throws -> ControlledMirrorLogicalTransfer {
        try lock.withLock {
            let prefix = eventKeyPrefix + ":"
            guard byteCount >= 0,
                let transfer = expectations.first(where: {
                    !usedIDs.contains($0.id)
                        && $0.eventKey.hasPrefix(prefix)
                        && $0.direction == direction
                        && $0.byteCount == byteCount
                })
            else {
                throw ControlledMirrorPreparedPlanError.changed
            }
            usedIDs.insert(transfer.id)
            return transfer
        }
    }

    func requireFullyConsumed() throws {
        let complete = lock.withLock { usedIDs.count == expectations.count }
        guard complete else { throw ControlledMirrorPreparedPlanError.changed }
    }
}

private enum ControlledMirrorProviderPayloadPurpose: String {
    case stageSourceRead = "stage-source-read"
    case stageProviderWrite = "stage-provider-write"
    case incomingRead = "incoming-read"
    case sourceRead = "source-read"
    case oldRead = "old-read"
    case resumeOldRead = "resume-old-read"
    case deleteRead = "delete-read"
}

private func controlledMirrorProviderEventPrefix(
    operationID: UUID,
    relativePath: String,
    purpose: ControlledMirrorProviderPayloadPurpose
) -> String {
    "op:\(operationID.uuidString):path:\(relativePath):io:\(purpose.rawValue)"
}

public struct ControlledMirrorPayloadIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
}

/// A narrow seam around provider-coordinated I/O. Tests can inject failures
/// without replacing path validation, manifests, or journal behavior.
public struct ControlledMirrorIO: Sendable {
    public typealias ReadData = @Sendable (URL) throws -> Data
    public typealias ReadDataBounded =
        @Sendable (URL, Int64, ControlledMirrorPayloadIdentity?) throws -> Data
    public typealias WriteData = @Sendable (Data, URL) throws -> Void
    public typealias CreateDirectory = @Sendable (URL) throws -> Void
    public typealias CopyFile = @Sendable (URL, URL, URL) throws -> Void
    public typealias RemoveItem = @Sendable (URL) throws -> Void
    typealias BeforeAtomicCopyCommit = @Sendable (URL, URL, URL) throws -> Void
    typealias AfterAtomicCopySwap = @Sendable (URL, URL, URL) throws -> Void
    typealias BeforeDeleteCommit = @Sendable (URL) throws -> Void
    typealias AfterDeleteVerification = @Sendable (URL) throws -> Void
    typealias BeforeCopyBackupRetention = @Sendable (URL) throws -> Void
    typealias BeforeDeleteRecoveryRetention = @Sendable (URL) throws -> Void
    typealias AfterRecoveryMove = @Sendable (URL) throws -> Void
    typealias BeforeRecoveryPayloadRead =
        @Sendable (
            ControlledMirrorSide,
            ControlledMirrorRecoveryPayloadKind,
            Int64?
        ) throws -> Void
    typealias AfterRecoveryPayloadRead =
        @Sendable (
            ControlledMirrorSide,
            ControlledMirrorRecoveryPayloadKind,
            Int64
        ) throws -> Void
    typealias BeforeProviderPayloadIO =
        @Sendable (ControlledMirrorLogicalTransfer) throws -> Void
    typealias AtomicCopyDiagnostic = @Sendable (AtomicCopyStage, Int32?) -> Void

    enum AtomicCopyStage: String, Sendable {
        case prepareStaging
        case stageCopy
        case coordinatedCommit
        case swapExisting
        case validateAfterSwap
        case rollbackSwap
        case installMissing
        case validateInstall
        case rollbackInstall
        case deleteMove
        case deleteRollback
        case deleteCleanup
    }

    fileprivate enum AtomicCopyFailure: Error {
        case sourceChanged
        case destinationChanged
        case unsafePath
        case pathRebound
        case commitFailed
        case rollbackFailed
    }

    private let readDataBody: ReadData
    private let readDataBoundedBody: ReadDataBounded
    private let writeDataBody: WriteData
    private let createDirectoryBody: CreateDirectory
    private let copyFileBody: CopyFile
    private let removeItemBody: RemoveItem
    private let beforeAtomicCopyCommitBody: BeforeAtomicCopyCommit
    private let afterAtomicCopySwapBody: AfterAtomicCopySwap
    private let beforeDeleteCommitBody: BeforeDeleteCommit
    private let afterDeleteVerificationBody: AfterDeleteVerification
    private let beforeCopyBackupRetentionBody: BeforeCopyBackupRetention
    private let beforeDeleteRecoveryRetentionBody: BeforeDeleteRecoveryRetention
    private let afterRecoveryMoveBody: AfterRecoveryMove
    private let beforeRecoveryPayloadReadBody: BeforeRecoveryPayloadRead
    private let afterRecoveryPayloadReadBody: AfterRecoveryPayloadRead
    private let beforeProviderPayloadIOBody: BeforeProviderPayloadIO
    private let atomicCopyDiagnosticBody: AtomicCopyDiagnostic

    public init(
        readData: @escaping ReadData,
        readDataBounded: ReadDataBounded? = nil,
        writeDataAtomically: @escaping WriteData,
        createDirectory: @escaping CreateDirectory,
        copyFileAtomically: @escaping CopyFile,
        removeItem: @escaping RemoveItem
    ) {
        readDataBody = readData
        readDataBoundedBody =
            readDataBounded ?? { url, expectedByteCount, expectedIdentity in
                try Self.readRegularFileExactly(
                    at: url,
                    expectedByteCount: expectedByteCount,
                    expectedIdentity: expectedIdentity
                )
            }
        writeDataBody = writeDataAtomically
        createDirectoryBody = createDirectory
        copyFileBody = copyFileAtomically
        removeItemBody = removeItem
        beforeAtomicCopyCommitBody = { _, _, _ in }
        afterAtomicCopySwapBody = { _, _, _ in }
        beforeDeleteCommitBody = { _ in }
        afterDeleteVerificationBody = { _ in }
        beforeCopyBackupRetentionBody = { _ in }
        beforeDeleteRecoveryRetentionBody = { _ in }
        afterRecoveryMoveBody = { _ in }
        beforeRecoveryPayloadReadBody = { _, _, _ in }
        afterRecoveryPayloadReadBody = { _, _, _ in }
        beforeProviderPayloadIOBody = { _ in }
        atomicCopyDiagnosticBody = Self.environmentDiagnostic
    }

    /// Internal transaction seam used for pre-commit fencing and deterministic
    /// concurrency tests. The public initializer has no callback.
    init(
        readData: @escaping ReadData,
        readDataBounded: ReadDataBounded? = nil,
        writeDataAtomically: @escaping WriteData,
        createDirectory: @escaping CreateDirectory,
        copyFileAtomically: @escaping CopyFile,
        removeItem: @escaping RemoveItem,
        beforeAtomicCopyCommit: @escaping BeforeAtomicCopyCommit,
        afterAtomicCopySwap: @escaping AfterAtomicCopySwap = { _, _, _ in },
        beforeDeleteCommit: @escaping BeforeDeleteCommit = { _ in },
        afterDeleteVerification: @escaping AfterDeleteVerification = { _ in },
        beforeCopyBackupRetention: @escaping BeforeCopyBackupRetention = { _ in },
        beforeDeleteRecoveryRetention: @escaping BeforeDeleteRecoveryRetention = { _ in },
        afterRecoveryMove: @escaping AfterRecoveryMove = { _ in },
        beforeRecoveryPayloadRead: @escaping BeforeRecoveryPayloadRead = { _, _, _ in },
        afterRecoveryPayloadRead: @escaping AfterRecoveryPayloadRead = { _, _, _ in },
        beforeProviderPayloadIO: @escaping BeforeProviderPayloadIO = { _ in },
        atomicCopyDiagnostic: @escaping AtomicCopyDiagnostic = Self.environmentDiagnostic
    ) {
        readDataBody = readData
        readDataBoundedBody =
            readDataBounded ?? { url, expectedByteCount, expectedIdentity in
                try Self.readRegularFileExactly(
                    at: url,
                    expectedByteCount: expectedByteCount,
                    expectedIdentity: expectedIdentity
                )
            }
        writeDataBody = writeDataAtomically
        createDirectoryBody = createDirectory
        copyFileBody = copyFileAtomically
        removeItemBody = removeItem
        beforeAtomicCopyCommitBody = beforeAtomicCopyCommit
        afterAtomicCopySwapBody = afterAtomicCopySwap
        beforeDeleteCommitBody = beforeDeleteCommit
        afterDeleteVerificationBody = afterDeleteVerification
        beforeCopyBackupRetentionBody = beforeCopyBackupRetention
        beforeDeleteRecoveryRetentionBody = beforeDeleteRecoveryRetention
        afterRecoveryMoveBody = afterRecoveryMove
        beforeRecoveryPayloadReadBody = beforeRecoveryPayloadRead
        afterRecoveryPayloadReadBody = afterRecoveryPayloadRead
        beforeProviderPayloadIOBody = beforeProviderPayloadIO
        atomicCopyDiagnosticBody = atomicCopyDiagnostic
    }

    public func readData(at url: URL) throws -> Data {
        try readDataBody(url)
    }

    public func readData(
        at url: URL,
        exactByteCount: Int64,
        expectedIdentity: ControlledMirrorPayloadIdentity? = nil
    ) throws -> Data {
        try readDataBoundedBody(url, exactByteCount, expectedIdentity)
    }

    public func writeDataAtomically(_ data: Data, to url: URL) throws {
        try writeDataBody(data, url)
    }

    public func createDirectory(at url: URL) throws {
        try createDirectoryBody(url)
    }

    public func copyFileAtomically(from source: URL, to destination: URL, stagingAt staging: URL) throws {
        try copyFileBody(source, destination, staging)
    }

    public func removeItem(at url: URL) throws {
        try removeItemBody(url)
    }

    func beforeAtomicCopyCommit(
        source: URL,
        destination: URL,
        staging: URL
    ) throws {
        try beforeAtomicCopyCommitBody(source, destination, staging)
    }

    func beforeRecoveryPayloadRead(
        side: ControlledMirrorSide,
        kind: ControlledMirrorRecoveryPayloadKind,
        byteCount: Int64?
    ) throws {
        try beforeRecoveryPayloadReadBody(side, kind, byteCount)
    }

    func afterRecoveryPayloadRead(
        side: ControlledMirrorSide,
        kind: ControlledMirrorRecoveryPayloadKind,
        byteCount: Int64
    ) throws {
        try afterRecoveryPayloadReadBody(side, kind, byteCount)
    }

    func beforeProviderPayloadIO(_ transfer: ControlledMirrorLogicalTransfer) throws {
        try beforeProviderPayloadIOBody(transfer)
    }

    private func diagnose(_ stage: AtomicCopyStage, error: Error) {
        let posixCode = (error as? POSIXError).map { Int32($0.code.rawValue) }
        atomicCopyDiagnosticBody(stage, posixCode)
    }

    static func environmentDiagnostic(_ stage: AtomicCopyStage, _ posixCode: Int32?) {
        guard ProcessInfo.processInfo.environment["PSY_MIRROR_IO_DIAGNOSTICS"] == "1" else {
            return
        }
        let code = posixCode.map(String.init) ?? "none"
        let line = "ControlledMirrorIO stage=\(stage.rawValue) errno=\(code)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }

    public static let coordinated = ControlledMirrorIO(
        readData: { url in
            let directRead = { try Data(contentsOf: url, options: .mappedIfSafe) }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<Data, Error>?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                result = Result { try Data(contentsOf: coordinatedURL, options: .mappedIfSafe) }
            }
            if let result { return try result.get() }
            // filecoordinationd is unavailable in some command-line and test
            // sandboxes. Falling back is safe only for a confirmed local volume;
            // provider-backed volumes still require successful coordination.
            if (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true {
                return try directRead()
            }
            throw coordinationError ?? CocoaError(.fileReadUnknown)
        },
        readDataBounded: { url, expectedByteCount, expectedIdentity in
            let directRead = {
                try Self.readRegularFileExactly(
                    at: url,
                    expectedByteCount: expectedByteCount,
                    expectedIdentity: expectedIdentity
                )
            }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<Data, Error>?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
                coordinatedURL in
                result = Result {
                    try Self.readRegularFileExactly(
                        at: coordinatedURL,
                        expectedByteCount: expectedByteCount,
                        expectedIdentity: expectedIdentity
                    )
                }
            }
            if let result { return try result.get() }
            if (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true {
                return try directRead()
            }
            throw coordinationError ?? CocoaError(.fileReadUnknown)
        },
        writeDataAtomically: { data, url in
            let directWrite = {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) {
                coordinatedURL in
                result = Result {
                    try FileManager.default.createDirectory(
                        at: coordinatedURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: coordinatedURL, options: .atomic)
                }
            }
            if let result {
                try result.get()
            } else if (try? url.deletingLastPathComponent().resourceValues(
                forKeys: [.volumeIsLocalKey]
            ).volumeIsLocal) == true {
                try directWrite()
            } else {
                throw coordinationError ?? CocoaError(.fileWriteUnknown)
            }
        },
        createDirectory: { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        },
        copyFileAtomically: { source, destination, staging in
            let install: (URL, URL) throws -> Void = { readableSource, writableDestination in
                let manager = FileManager.default
                try manager.createDirectory(
                    at: writableDestination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try manager.createDirectory(
                    at: staging.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if manager.fileExists(atPath: staging.path) {
                    try manager.removeItem(at: staging)
                }
                do {
                    try manager.copyItem(at: readableSource, to: staging)
                    if manager.fileExists(atPath: writableDestination.path) {
                        _ = try manager.replaceItemAt(
                            writableDestination,
                            withItemAt: staging,
                            backupItemName: nil,
                            options: .usingNewMetadataOnly
                        )
                    } else {
                        try manager.moveItem(at: staging, to: writableDestination)
                    }
                } catch {
                    try? manager.removeItem(at: staging)
                    throw error
                }
            }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            coordinator.coordinate(
                readingItemAt: source,
                options: [],
                writingItemAt: destination,
                options: .forReplacing,
                error: &coordinationError
            ) { coordinatedSource, coordinatedDestination in
                result = Result { try install(coordinatedSource, coordinatedDestination) }
            }
            if let result {
                try result.get()
            } else {
                let sourceIsLocal = (try? source.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
                let destinationIsLocal =
                    (try? destination.deletingLastPathComponent().resourceValues(
                        forKeys: [.volumeIsLocalKey]
                    ).volumeIsLocal) == true
                guard sourceIsLocal, destinationIsLocal else {
                    throw coordinationError ?? CocoaError(.fileWriteUnknown)
                }
                try install(source, destination)
            }
        },
        removeItem: { url in
            let directRemove = { try FileManager.default.removeItem(at: url) }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) {
                coordinatedURL in
                result = Result { try FileManager.default.removeItem(at: coordinatedURL) }
            }
            if let result {
                try result.get()
            } else if (try? url.deletingLastPathComponent().resourceValues(
                forKeys: [.volumeIsLocalKey]
            ).volumeIsLocal) == true {
                try directRemove()
            } else {
                throw coordinationError ?? CocoaError(.fileWriteUnknown)
            }
        }
    )

    private static func readRegularFileExactly(
        at url: URL,
        expectedByteCount: Int64,
        expectedIdentity: ControlledMirrorPayloadIdentity?,
        didRead: @Sendable (Int) -> Void = { _ in }
    ) throws -> Data {
        guard expectedByteCount >= 0,
            expectedByteCount <= Int64(Int.max)
        else {
            throw AtomicCopyFailure.sourceChanged
        }
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw AtomicCopyFailure.sourceChanged }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_size == expectedByteCount
        else {
            throw AtomicCopyFailure.sourceChanged
        }
        let openedIdentity = Self.payloadIdentity(before)
        if let expectedIdentity {
            guard openedIdentity == expectedIdentity else {
                throw AtomicCopyFailure.sourceChanged
            }
        }
        let identity = FileIdentity(before)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        var data = Data()
        data.reserveCapacity(Int(expectedByteCount))
        var remaining = expectedByteCount
        while remaining > 0 {
            let request = Int(min(remaining, 1_048_576))
            guard let chunk = try handle.read(upToCount: request), !chunk.isEmpty else {
                throw AtomicCopyFailure.sourceChanged
            }
            data.append(chunk)
            didRead(chunk.count)
            remaining -= Int64(chunk.count)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            FileIdentity(after) == identity,
            Self.payloadIdentity(after) == openedIdentity,
            Int64(data.count) == expectedByteCount,
            Self.path(at: url, matches: openedIdentity)
        else {
            throw AtomicCopyFailure.sourceChanged
        }
        return data
    }

    static func readRegularFileExactlyForTesting(
        at url: URL,
        expectedByteCount: Int64,
        expectedIdentity: ControlledMirrorPayloadIdentity?,
        didRead: @escaping @Sendable (Int) -> Void
    ) throws -> Data {
        try readRegularFileExactly(
            at: url,
            expectedByteCount: expectedByteCount,
            expectedIdentity: expectedIdentity,
            didRead: didRead
        )
    }

    private static func payloadIdentity(_ value: stat) -> ControlledMirrorPayloadIdentity {
        ControlledMirrorPayloadIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            byteCount: value.st_size,
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private static func path(
        at url: URL,
        matches expected: ControlledMirrorPayloadIdentity
    ) -> Bool {
        var status = stat()
        return url.path.withCString({ lstat($0, &status) }) == 0
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && payloadIdentity(status) == expected
    }
}

extension ControlledMirrorIO {
    private enum FileProbe {
        case missing
        case file(ControlledMirror.Fingerprint)
        case other
        case symbolicLink
        case unstable

        func matches(_ expected: ControlledMirror.Fingerprint?) -> Bool {
            switch (self, expected) {
            case (.missing, nil):
                true
            case (.file(let actual), let expected?):
                actual == expected
            default:
                false
            }
        }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            size = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }

    private struct FileObjectIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let type: mode_t

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            type = value.st_mode & mode_t(S_IFMT)
        }
    }

    private final class BoundPath {
        private struct DirectoryComponent {
            let name: String
            let descriptor: Int32
            let identity: FileObjectIdentity
        }

        let root: URL
        let url: URL
        let leafName: String
        private let rootIdentity: FileObjectIdentity
        private let components: [DirectoryComponent]

        var parentDescriptor: Int32 {
            components.last?.descriptor ?? -1
        }

        var rootDescriptor: Int32 {
            components.first?.descriptor ?? -1
        }

        init(_ url: URL, within root: URL) throws {
            let canonicalRoot = root.standardizedFileURL
            let candidate = url.standardizedFileURL
            guard candidate != canonicalRoot, ControlledMirror.contains(canonicalRoot, candidate) else {
                throw AtomicCopyFailure.unsafePath
            }
            let relativeComponents = Array(
                candidate.pathComponents.dropFirst(canonicalRoot.pathComponents.count)
            )
            guard let leafName = relativeComponents.last,
                !leafName.isEmpty,
                leafName != ".",
                leafName != "..",
                !leafName.contains("/")
            else {
                throw AtomicCopyFailure.unsafePath
            }

            let rootDescriptor = canonicalRoot.path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            }
            guard rootDescriptor >= 0 else { throw AtomicCopyFailure.unsafePath }
            var retained: [DirectoryComponent] = []
            var shouldClose = true
            defer {
                if shouldClose {
                    if retained.isEmpty {
                        close(rootDescriptor)
                    } else {
                        for component in retained.reversed() { close(component.descriptor) }
                    }
                }
            }
            var rootStatus = stat()
            var rootPathStatus = stat()
            guard fstat(rootDescriptor, &rootStatus) == 0,
                canonicalRoot.path.withCString({ lstat($0, &rootPathStatus) }) == 0,
                rootPathStatus.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK),
                FileObjectIdentity(rootStatus) == FileObjectIdentity(rootPathStatus),
                rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                throw AtomicCopyFailure.unsafePath
            }
            let rootIdentity = FileObjectIdentity(rootStatus)
            retained.append(
                DirectoryComponent(name: "", descriptor: rootDescriptor, identity: rootIdentity)
            )

            var parentDescriptor = rootDescriptor
            for name in relativeComponents.dropLast() {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                    throw AtomicCopyFailure.unsafePath
                }
                let descriptor = name.withCString {
                    openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                    )
                }
                guard descriptor >= 0 else { throw AtomicCopyFailure.unsafePath }
                var status = stat()
                guard fstat(descriptor, &status) == 0,
                    status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                else {
                    close(descriptor)
                    throw AtomicCopyFailure.unsafePath
                }
                retained.append(
                    DirectoryComponent(
                        name: name,
                        descriptor: descriptor,
                        identity: FileObjectIdentity(status)
                    )
                )
                parentDescriptor = descriptor
            }

            self.root = canonicalRoot
            self.url = candidate
            self.leafName = leafName
            self.rootIdentity = rootIdentity
            components = retained
            shouldClose = false
        }

        deinit {
            for component in components.reversed() { close(component.descriptor) }
        }

        func revalidate() throws {
            let rootCheck = root.path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            }
            guard rootCheck >= 0 else { throw AtomicCopyFailure.pathRebound }
            var rootStatus = stat()
            let validRoot =
                fstat(rootCheck, &rootStatus) == 0
                && FileObjectIdentity(rootStatus) == rootIdentity
            close(rootCheck)
            guard validRoot else { throw AtomicCopyFailure.pathRebound }

            for (index, component) in components.enumerated() {
                var retainedStatus = stat()
                guard fstat(component.descriptor, &retainedStatus) == 0,
                    FileObjectIdentity(retainedStatus) == component.identity
                else {
                    throw AtomicCopyFailure.pathRebound
                }
                guard index > 0 else { continue }
                let parent = components[index - 1].descriptor
                let rebound = component.name.withCString {
                    openat(parent, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
                }
                guard rebound >= 0 else { throw AtomicCopyFailure.pathRebound }
                var reboundStatus = stat()
                let valid =
                    fstat(rebound, &reboundStatus) == 0
                    && FileObjectIdentity(reboundStatus) == component.identity
                close(rebound)
                guard valid else { throw AtomicCopyFailure.pathRebound }
            }
        }

        func leafIdentity() throws -> FileObjectIdentity? {
            try revalidate()
            var status = stat()
            let result = leafName.withCString {
                fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result != 0 {
                if errno == ENOENT { return nil }
                throw AtomicCopyFailure.commitFailed
            }
            let identity = FileObjectIdentity(status)
            guard identity.type != mode_t(S_IFLNK) else {
                throw AtomicCopyFailure.unsafePath
            }
            return identity
        }

        func openLeaf(directory: Bool = false) throws -> Int32 {
            try revalidate()
            let directoryFlag = directory ? O_DIRECTORY : 0
            let descriptor = leafName.withCString {
                openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | directoryFlag
                )
            }
            guard descriptor >= 0 else {
                if errno == ELOOP { throw AtomicCopyFailure.unsafePath }
                throw AtomicCopyFailure.commitFailed
            }
            return descriptor
        }

        func payloadIdentity() throws -> ControlledMirrorPayloadIdentity? {
            guard let identity = try leafIdentity() else { return nil }
            guard identity.type == mode_t(S_IFREG) else { return nil }
            let descriptor = try openLeaf()
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                FileObjectIdentity(status) == identity
            else {
                throw AtomicCopyFailure.pathRebound
            }
            return ControlledMirrorIO.payloadIdentity(status)
        }
    }

    private static func rename(_ source: BoundPath, _ destination: BoundPath, flags: UInt32) throws {
        try source.revalidate()
        try destination.revalidate()
        let result = source.leafName.withCString { sourceName in
            destination.leafName.withCString { destinationName in
                renameatx_np(
                    source.parentDescriptor,
                    sourceName,
                    destination.parentDescriptor,
                    destinationName,
                    flags
                )
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try source.revalidate()
        try destination.revalidate()
    }

    private static func probe(
        _ path: BoundPath,
        expectedByteCount: Int64
    ) throws -> FileProbe {
        guard expectedByteCount >= 0 else { return .unstable }
        guard let identity = try path.leafIdentity() else { return .missing }
        guard identity.type == mode_t(S_IFREG) else { return .other }
        let descriptor = try path.openLeaf()
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            FileObjectIdentity(before) == identity,
            before.st_size == expectedByteCount
        else {
            return .unstable
        }
        let beforeIdentity = FileIdentity(before)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var digest = SHA256()
        var byteCount: Int64 = 0
        do {
            while byteCount < expectedByteCount {
                let request = Int(min(expectedByteCount - byteCount, 1_048_576))
                guard let chunk = try handle.read(upToCount: request), !chunk.isEmpty else {
                    return .unstable
                }
                digest.update(data: chunk)
                byteCount += Int64(chunk.count)
            }
        } catch {
            throw AtomicCopyFailure.commitFailed
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            beforeIdentity == FileIdentity(after),
            byteCount == expectedByteCount,
            after.st_size == expectedByteCount,
            try path.leafIdentity() == identity
        else {
            return .unstable
        }
        let contentDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return .file(
            ControlledMirror.Fingerprint(
                kind: .file,
                contentDigest: contentDigest,
                byteCount: byteCount
            )
        )
    }

    private func providerProbe(
        _ path: BoundPath,
        expectedByteCount: Int64,
        providerMeter: ControlledMirrorProviderMeterState?,
        eventKeyPrefix: String?
    ) throws -> FileProbe {
        guard let providerMeter, let eventKeyPrefix else {
            return try Self.probe(path, expectedByteCount: expectedByteCount)
        }
        guard expectedByteCount >= 0 else { return .unstable }
        guard let identity = try path.leafIdentity() else { return .missing }
        guard identity.type == mode_t(S_IFREG) else { return .other }
        let descriptor = try path.openLeaf()
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            FileObjectIdentity(status) == identity,
            status.st_size == expectedByteCount
        else {
            return .unstable
        }
        return try providerMeter.performNext(
            eventKeyPrefix: eventKeyPrefix,
            direction: .readExternalProvider,
            byteCount: expectedByteCount,
            validate: {
                if case .file = $0 { return true }
                return false
            },
            { transfer in
                try beforeProviderPayloadIOBody(transfer)
                return try Self.probe(path, expectedByteCount: expectedByteCount)
            }
        )
    }

    private func providerRegularFileFingerprint(
        descriptor: Int32,
        expectedIdentity: FileObjectIdentity,
        expectedByteCount: Int64,
        providerMeter: ControlledMirrorProviderMeterState?,
        eventKeyPrefix: String?
    ) throws -> ControlledMirror.Fingerprint? {
        guard let providerMeter, let eventKeyPrefix else {
            return try Self.regularFileFingerprint(
                descriptor: descriptor,
                expectedIdentity: expectedIdentity,
                maximumByteCount: expectedByteCount
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            FileObjectIdentity(status) == expectedIdentity,
            status.st_size == expectedByteCount
        else {
            return nil
        }
        return try providerMeter.performNext(
            eventKeyPrefix: eventKeyPrefix,
            direction: .readExternalProvider,
            byteCount: expectedByteCount,
            validate: { $0 != nil },
            { transfer in
                try beforeProviderPayloadIOBody(transfer)
                return try Self.regularFileFingerprint(
                    descriptor: descriptor,
                    expectedIdentity: expectedIdentity,
                    maximumByteCount: expectedByteCount
                )
            }
        )
    }

    private static func synchronizeRegularFile(_ path: BoundPath) throws {
        let descriptor = try path.openLeaf()
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            fsync(descriptor) == 0,
            try path.leafIdentity() == FileObjectIdentity(status)
        else {
            throw AtomicCopyFailure.commitFailed
        }
    }

    private static func synchronizeParent(_ path: BoundPath) throws {
        try path.revalidate()
        guard fsync(path.parentDescriptor) == 0 else {
            throw AtomicCopyFailure.commitFailed
        }
    }

    private static func path(
        _ path: BoundPath,
        matches expected: ControlledMirror.Fingerprint
    ) throws -> Bool {
        switch expected.kind {
        case .file:
            return try probe(path, expectedByteCount: expected.byteCount).matches(expected)
        case .directory:
            guard try path.leafIdentity()?.type == mode_t(S_IFDIR) else { return false }
            let descriptor = try path.openLeaf(directory: true)
            defer { close(descriptor) }
            return try directoryIsEmpty(descriptor)
        }
    }

    private static func path(
        _ path: BoundPath,
        matches expected: ControlledMirror.Fingerprint?
    ) throws -> Bool {
        guard let expected else { return try path.leafIdentity() == nil }
        return try Self.path(path, matches: expected)
    }

    private func providerPath(
        _ path: BoundPath,
        matches expected: ControlledMirror.Fingerprint?,
        providerMeter: ControlledMirrorProviderMeterState?,
        eventKeyPrefix: String?
    ) throws -> Bool {
        guard let expected else { return try path.leafIdentity() == nil }
        switch expected.kind {
        case .file:
            return try providerProbe(
                path,
                expectedByteCount: expected.byteCount,
                providerMeter: providerMeter,
                eventKeyPrefix: eventKeyPrefix
            ).matches(expected)
        case .directory:
            guard try path.leafIdentity()?.type == mode_t(S_IFDIR) else { return false }
            let descriptor = try path.openLeaf(directory: true)
            defer { close(descriptor) }
            return try Self.directoryIsEmpty(descriptor)
        }
    }

    private static func directoryIsEmpty(_ descriptor: Int32) throws -> Bool {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw AtomicCopyFailure.commitFailed
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { return false }
        }
        return true
    }

    private static func removeRegularFileOrLinkIfPresent(_ path: BoundPath) throws {
        try path.revalidate()
        var status = stat()
        let lookup = path.leafName.withCString {
            fstatat(path.parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if lookup != 0 {
            if errno == ENOENT { return }
            throw AtomicCopyFailure.commitFailed
        }
        let itemType = status.st_mode & mode_t(S_IFMT)
        guard itemType == mode_t(S_IFREG) || itemType == mode_t(S_IFLNK) else {
            throw AtomicCopyFailure.unsafePath
        }
        let result = path.leafName.withCString { unlinkat(path.parentDescriptor, $0, 0) }
        guard result == 0 else { throw AtomicCopyFailure.commitFailed }
        try path.revalidate()
        guard fsync(path.parentDescriptor) == 0 else { throw AtomicCopyFailure.commitFailed }
    }

    private typealias RecoveryKind = ControlledMirrorRecoveryKind
    private typealias RecoveryStatus = ControlledMirrorRecoveryStatus

    private struct RecoveryRecord: Codable, Equatable {
        let schemaVersion: Int
        let operationID: String
        let kind: RecoveryKind
        let relativePath: String
        let expectedContentDigest: String?
        let expectedByteCount: Int64
        let payloadKind: ControlledMirror.EntryKind
        let payloadRelativePath: String
        let payloadContentDigest: String?
        let payloadByteCount: Int64?
        let createdAt: Int64
        let status: RecoveryStatus

        func withStatus(
            _ status: RecoveryStatus,
            payload: RecoveryPayloadFingerprint
        ) -> RecoveryRecord {
            RecoveryRecord(
                schemaVersion: schemaVersion,
                operationID: operationID,
                kind: kind,
                relativePath: relativePath,
                expectedContentDigest: expectedContentDigest,
                expectedByteCount: expectedByteCount,
                payloadKind: payloadKind,
                payloadRelativePath: payloadRelativePath,
                payloadContentDigest: payload.contentDigest,
                payloadByteCount: payload.byteCount,
                createdAt: createdAt,
                status: status
            )
        }

        func matchesOperationInvariant(of other: RecoveryRecord) -> Bool {
            schemaVersion == other.schemaVersion
                && operationID == other.operationID
                && kind == other.kind
                && relativePath == other.relativePath
                && expectedContentDigest == other.expectedContentDigest
                && expectedByteCount == other.expectedByteCount
                && payloadKind == other.payloadKind
                && payloadRelativePath == other.payloadRelativePath
                && createdAt == other.createdAt
        }

        var payloadFingerprint: RecoveryPayloadFingerprint? {
            guard let payloadContentDigest, let payloadByteCount, payloadByteCount >= 0 else {
                return nil
            }
            return RecoveryPayloadFingerprint(
                kind: payloadKind,
                contentDigest: payloadContentDigest,
                byteCount: payloadByteCount
            )
        }
    }

    private struct RecoveryPayloadFingerprint: Equatable {
        let kind: ControlledMirror.EntryKind
        let contentDigest: String
        let byteCount: Int64
    }

    private static let recoverySchemaVersion = 2
    private static let recoveryDirectoryName = "recovery"
    private static let recoveryPayloadName = "payload"
    private static let recoveryPreparedName = "prepared.json"
    private static let recoveryRetainedName = "retained.json"
    private static let recoveryConflictName = "conflict.json"
    private static let recoveryDisposalName = "disposal.json"
    fileprivate static let recoveryDisposingPayloadName = "disposing"
    private static let maximumRecoveryRecords = 512
    private static let maximumRecoveryRecordBytes = 4_096

    private func prepareRecovery(
        root: URL,
        rootBinding: BoundPath? = nil,
        operationID: UUID,
        kind: RecoveryKind,
        relativePath: String,
        expected: ControlledMirror.Fingerprint
    ) throws -> RecoveryRecord {
        guard Self.isSafeRecoveryRelativePath(relativePath) else {
            throw AtomicCopyFailure.unsafePath
        }
        let operationName = operationID.uuidString
        return try Self.withRecoveryDirectories(
            root: root,
            rootBinding: rootBinding,
            operationName: operationName
        ) { _, recoveryDescriptor, operationDescriptor in
            if let existing = try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryPreparedName
            ) {
                let proposed = RecoveryRecord(
                    schemaVersion: Self.recoverySchemaVersion,
                    operationID: operationName,
                    kind: kind,
                    relativePath: relativePath,
                    expectedContentDigest: expected.contentDigest,
                    expectedByteCount: expected.byteCount,
                    payloadKind: expected.kind,
                    payloadRelativePath: Self.recoveryPayloadRelativePath(
                        operationName: operationName
                    ),
                    payloadContentDigest: nil,
                    payloadByteCount: nil,
                    createdAt: existing.createdAt,
                    status: .prepared
                )
                guard existing.status == .prepared,
                    existing == proposed
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                return existing
            }

            let record = RecoveryRecord(
                schemaVersion: Self.recoverySchemaVersion,
                operationID: operationName,
                kind: kind,
                relativePath: relativePath,
                expectedContentDigest: expected.contentDigest,
                expectedByteCount: expected.byteCount,
                payloadKind: expected.kind,
                payloadRelativePath: Self.recoveryPayloadRelativePath(
                    operationName: operationName
                ),
                payloadContentDigest: nil,
                payloadByteCount: nil,
                createdAt: Int64(Date().timeIntervalSince1970),
                status: .prepared
            )
            try Self.writeRecoveryRecord(
                record,
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryPreparedName
            )
            guard fsync(operationDescriptor) == 0, fsync(recoveryDescriptor) == 0 else {
                throw AtomicCopyFailure.commitFailed
            }
            return record
        }
    }

    private func retainRecoverySource(
        _ source: URL,
        sourceBinding suppliedSourceBinding: BoundPath? = nil,
        root: URL,
        operationID: UUID,
        kind: RecoveryKind,
        relativePath: String,
        expected: ControlledMirror.Fingerprint,
        expectedIdentity: FileObjectIdentity?,
        status: RecoveryStatus,
        providerMeter: ControlledMirrorProviderMeterState? = nil,
        providerEventKeyPrefix: String? = nil,
        beforeMove: () throws -> Void
    ) throws {
        let sourceBinding = try suppliedSourceBinding ?? BoundPath(source, within: root)
        let prepared = try prepareRecovery(
            root: root,
            rootBinding: sourceBinding,
            operationID: operationID,
            kind: kind,
            relativePath: relativePath,
            expected: expected
        )
        try sourceBinding.revalidate()
        let operationName = operationID.uuidString
        try Self.withRecoveryDirectories(
            root: root,
            rootBinding: sourceBinding,
            operationName: operationName
        ) { _, recoveryDescriptor, operationDescriptor in
            if try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryDisposalName
            ) != nil {
                throw AtomicCopyFailure.rollbackFailed
            }
            if let conflict = try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryConflictName
            ) {
                guard conflict.status == .conflictRequiresManualCleanup,
                    conflict.matchesOperationInvariant(of: prepared)
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                throw AtomicCopyFailure.rollbackFailed
            }
            if let retained = try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryRetainedName
            ) {
                guard retained.status == .retainedRequiresUserConfirmation,
                    retained.matchesOperationInvariant(of: prepared),
                    try sourceBinding.leafIdentity() == nil
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                try Self.secureAndSynchronizeRecoveryPayload(
                    operationDescriptor: operationDescriptor,
                    expectedKind: expected.kind
                )
                let currentPayload = try Self.captureRecoveryPayload(
                    operationDescriptor: operationDescriptor,
                    expectedKind: expected.kind,
                    providerMeter: providerMeter,
                    providerEventKeyPrefix: providerEventKeyPrefix,
                    expectedProviderByteCount: expected.byteCount,
                    beforeProviderPayloadIO: beforeProviderPayloadIOBody
                )
                guard retained.payloadFingerprint == currentPayload else {
                    let conflict = retained.withStatus(
                        .conflictRequiresManualCleanup,
                        payload: currentPayload
                    )
                    try Self.writeRecoveryRecord(
                        conflict,
                        directoryDescriptor: operationDescriptor,
                        name: Self.recoveryConflictName
                    )
                    guard fsync(operationDescriptor) == 0, fsync(recoveryDescriptor) == 0 else {
                        throw AtomicCopyFailure.commitFailed
                    }
                    throw AtomicCopyFailure.rollbackFailed
                }
                return
            }

            let existingPayload = try Self.recoveryPayloadIdentity(
                operationDescriptor: operationDescriptor,
                expectedKind: expected.kind
            )
            let sourceIdentity = try sourceBinding.leafIdentity()
            guard existingPayload == nil || sourceIdentity == nil else {
                throw AtomicCopyFailure.rollbackFailed
            }

            if existingPayload == nil {
                guard let sourceIdentity,
                    expectedIdentity == nil || sourceIdentity == expectedIdentity
                else {
                    throw AtomicCopyFailure.commitFailed
                }
                let sourceDescriptor = try Self.openRecoveryPayloadCandidate(
                    parentDescriptor: sourceBinding.parentDescriptor,
                    name: sourceBinding.leafName,
                    expectedKind: expected.kind
                )
                defer { close(sourceDescriptor) }
                var openedStatus = stat()
                guard fstat(sourceDescriptor, &openedStatus) == 0,
                    FileObjectIdentity(openedStatus) == sourceIdentity
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }

                try beforeMove()

                var finalStatus = stat()
                guard fstat(sourceDescriptor, &finalStatus) == 0,
                    FileObjectIdentity(finalStatus) == sourceIdentity
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                try sourceBinding.revalidate()
                let renameResult = sourceBinding.leafName.withCString { sourceNamePointer in
                    Self.recoveryPayloadName.withCString { payloadNamePointer in
                        renameatx_np(
                            sourceBinding.parentDescriptor,
                            sourceNamePointer,
                            operationDescriptor,
                            payloadNamePointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard renameResult == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard
                    try Self.recoveryPayloadIdentity(
                        operationDescriptor: operationDescriptor,
                        expectedKind: expected.kind
                    ) == sourceIdentity
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                try sourceBinding.revalidate()
                guard try sourceBinding.leafIdentity() == nil else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                try Self.secureAndSynchronizeRecoveryPayload(
                    operationDescriptor: operationDescriptor,
                    expectedKind: expected.kind
                )
                guard fsync(sourceBinding.parentDescriptor) == 0, fsync(operationDescriptor) == 0 else {
                    throw AtomicCopyFailure.commitFailed
                }
                let payload =
                    root
                    .appendingPathComponent(ControlledMirror.stateDirectoryName, isDirectory: true)
                    .appendingPathComponent(Self.recoveryDirectoryName, isDirectory: true)
                    .appendingPathComponent(operationName, isDirectory: true)
                    .appendingPathComponent(Self.recoveryPayloadName)
                try afterRecoveryMoveBody(payload)
            } else {
                guard sourceIdentity == nil else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                try Self.secureAndSynchronizeRecoveryPayload(
                    operationDescriptor: operationDescriptor,
                    expectedKind: expected.kind
                )
            }

            let payloadFingerprint = try Self.captureRecoveryPayload(
                operationDescriptor: operationDescriptor,
                expectedKind: expected.kind,
                providerMeter: providerMeter,
                providerEventKeyPrefix: providerEventKeyPrefix,
                expectedProviderByteCount: expected.byteCount,
                beforeProviderPayloadIO: beforeProviderPayloadIOBody
            )
            let finalRecord = prepared.withStatus(status, payload: payloadFingerprint)
            let recordName =
                status == .conflictRequiresManualCleanup
                ? Self.recoveryConflictName : Self.recoveryRetainedName
            try Self.writeRecoveryRecord(
                finalRecord,
                directoryDescriptor: operationDescriptor,
                name: recordName
            )
            guard fsync(operationDescriptor) == 0, fsync(recoveryDescriptor) == 0 else {
                throw AtomicCopyFailure.commitFailed
            }
            if status == .conflictRequiresManualCleanup {
                throw AtomicCopyFailure.rollbackFailed
            }
        }
    }

    private static func isSafeRecoveryRelativePath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("\0")
            && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && components.first != Substring(ControlledMirror.stateDirectoryName)
    }

    private static func recoveryPayloadRelativePath(operationName: String) -> String {
        ControlledMirror.stateDirectoryName + "/" + recoveryDirectoryName + "/"
            + operationName + "/" + recoveryPayloadName
    }

    private static func withRecoveryDirectories<T>(
        root: URL,
        rootBinding: BoundPath? = nil,
        operationName: String,
        _ body: (Int32, Int32, Int32) throws -> T
    ) throws -> T {
        guard UUID(uuidString: operationName)?.uuidString == operationName else {
            throw AtomicCopyFailure.unsafePath
        }
        let canonicalRoot = root.standardizedFileURL
        let ownedRootDescriptor: Int32?
        let rootDescriptor: Int32
        if let rootBinding {
            guard rootBinding.root == canonicalRoot else { throw AtomicCopyFailure.unsafePath }
            try rootBinding.revalidate()
            rootDescriptor = rootBinding.rootDescriptor
            ownedRootDescriptor = nil
        } else {
            let descriptor = canonicalRoot.path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw AtomicCopyFailure.unsafePath }
            rootDescriptor = descriptor
            ownedRootDescriptor = descriptor
        }
        defer {
            if let ownedRootDescriptor { close(ownedRootDescriptor) }
        }

        let stateDescriptor = try openOrCreateRecoveryDirectory(
            parentDescriptor: rootDescriptor,
            name: ControlledMirror.stateDirectoryName
        )
        defer { close(stateDescriptor) }
        let recoveryDescriptor = try openOrCreateRecoveryDirectory(
            parentDescriptor: stateDescriptor,
            name: recoveryDirectoryName
        )
        defer { close(recoveryDescriptor) }

        let operationExists =
            try directoryEntryIdentity(
                parentDescriptor: recoveryDescriptor,
                name: operationName
            ) != nil
        if !operationExists {
            guard
                try recoveryRecordCount(directoryDescriptor: recoveryDescriptor)
                    < maximumRecoveryRecords
            else {
                throw AtomicCopyFailure.commitFailed
            }
        }
        let operationDescriptor = try openOrCreateRecoveryDirectory(
            parentDescriptor: recoveryDescriptor,
            name: operationName
        )
        defer { close(operationDescriptor) }
        let value = try body(stateDescriptor, recoveryDescriptor, operationDescriptor)
        try rootBinding?.revalidate()
        return value
    }

    private static func withExistingRecoveryDirectory<T>(
        root: URL,
        _ body: (Int32) throws -> T
    ) throws -> T? {
        try withStableRootDescriptor(root: root) { rootDescriptor in
            guard
                let stateDescriptor = try openExistingDirectory(
                    parentDescriptor: rootDescriptor,
                    name: ControlledMirror.stateDirectoryName
                )
            else {
                return nil
            }
            defer { close(stateDescriptor) }
            guard
                let recoveryDescriptor = try openExistingDirectory(
                    parentDescriptor: stateDescriptor,
                    name: recoveryDirectoryName
                )
            else {
                return nil
            }
            defer { close(recoveryDescriptor) }
            return try body(recoveryDescriptor)
        }
    }

    private static func withStableRootDescriptor<T>(
        root: URL,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let canonicalRoot = root.standardizedFileURL
        let descriptor = canonicalRoot.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw AtomicCopyFailure.unsafePath }
        defer { close(descriptor) }
        var openedStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            canonicalRoot.path.withCString({ lstat($0, &pathStatus) }) == 0,
            FileObjectIdentity(openedStatus) == FileObjectIdentity(pathStatus),
            openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw AtomicCopyFailure.unsafePath
        }
        let rootIdentity = FileObjectIdentity(openedStatus)
        do {
            let value = try body(descriptor)
            try revalidateRootPath(canonicalRoot, expectedIdentity: rootIdentity)
            return value
        } catch {
            do {
                try revalidateRootPath(canonicalRoot, expectedIdentity: rootIdentity)
            } catch {
                throw AtomicCopyFailure.pathRebound
            }
            throw error
        }
    }

    private static func revalidateRootPath(
        _ root: URL,
        expectedIdentity: FileObjectIdentity
    ) throws {
        let descriptor = root.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw AtomicCopyFailure.pathRebound }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            FileObjectIdentity(status) == expectedIdentity
        else {
            throw AtomicCopyFailure.pathRebound
        }
    }

    private static func openExistingDirectory(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw AtomicCopyFailure.unsafePath
        }
        guard
            let identity = try directoryEntryIdentity(
                parentDescriptor: parentDescriptor,
                name: name
            )
        else {
            return nil
        }
        guard identity.type == mode_t(S_IFDIR) else { throw AtomicCopyFailure.unsafePath }
        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw AtomicCopyFailure.unsafePath }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            FileObjectIdentity(status) == identity
        else {
            close(descriptor)
            throw AtomicCopyFailure.pathRebound
        }
        return descriptor
    }

    private static func openOrCreateRecoveryDirectory(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw AtomicCopyFailure.unsafePath
        }
        var created = false
        let result = name.withCString { mkdirat(parentDescriptor, $0, mode_t(0o700)) }
        if result == 0 {
            created = true
        } else if errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw AtomicCopyFailure.unsafePath }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            fchmod(descriptor, mode_t(0o700)) == 0
        else {
            close(descriptor)
            throw AtomicCopyFailure.unsafePath
        }
        if created, fsync(parentDescriptor) != 0 {
            close(descriptor)
            throw AtomicCopyFailure.commitFailed
        }
        return descriptor
    }

    private static func recoveryRecordCount(directoryDescriptor: Int32) throws -> Int {
        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw AtomicCopyFailure.commitFailed
        }
        defer { closedir(directory) }
        var count = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard UUID(uuidString: name)?.uuidString == name,
                let identity = try directoryEntryIdentity(
                    parentDescriptor: directoryDescriptor,
                    name: name
                ),
                identity.type == mode_t(S_IFDIR)
            else {
                throw AtomicCopyFailure.unsafePath
            }
            count += 1
        }
        return count
    }

    private static func directoryEntryIdentity(
        parentDescriptor: Int32,
        name: String
    ) throws -> FileObjectIdentity? {
        var status = stat()
        let result = name.withCString {
            fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw AtomicCopyFailure.commitFailed
        }
        let identity = FileObjectIdentity(status)
        guard identity.type != mode_t(S_IFLNK) else { throw AtomicCopyFailure.unsafePath }
        return identity
    }

    private static func openRecoveryPayloadCandidate(
        parentDescriptor: Int32,
        name: String,
        expectedKind: ControlledMirror.EntryKind
    ) throws -> Int32 {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw AtomicCopyFailure.unsafePath
        }
        let directoryFlag = expectedKind == .directory ? O_DIRECTORY : 0
        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | directoryFlag)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw AtomicCopyFailure.unsafePath }
            throw AtomicCopyFailure.commitFailed
        }
        var status = stat()
        let expectedType = expectedKind == .directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == expectedType
        else {
            close(descriptor)
            throw AtomicCopyFailure.unsafePath
        }
        return descriptor
    }

    private static func recoveryPayloadIdentity(
        operationDescriptor: Int32,
        expectedKind: ControlledMirror.EntryKind,
        name: String = recoveryPayloadName
    ) throws -> FileObjectIdentity? {
        guard
            let identity = try directoryEntryIdentity(
                parentDescriptor: operationDescriptor,
                name: name
            )
        else {
            return nil
        }
        let expectedType = expectedKind == .directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
        guard identity.type == expectedType else { throw AtomicCopyFailure.unsafePath }
        return identity
    }

    private static func secureAndSynchronizeRecoveryPayload(
        operationDescriptor: Int32,
        expectedKind: ControlledMirror.EntryKind,
        name: String = recoveryPayloadName
    ) throws {
        let descriptor = try openRecoveryPayloadCandidate(
            parentDescriptor: operationDescriptor,
            name: name,
            expectedKind: expectedKind
        )
        defer { close(descriptor) }
        try secureAndSynchronizeRecoveryObject(
            descriptor: descriptor,
            kind: expectedKind
        )
        guard fsync(operationDescriptor) == 0 else {
            throw AtomicCopyFailure.commitFailed
        }
    }

    private static func secureAndSynchronizeRecoveryObject(
        descriptor: Int32,
        kind: ControlledMirror.EntryKind
    ) throws {
        let permissions = kind == .directory ? mode_t(0o700) : mode_t(0o600)
        guard fchmod(descriptor, permissions) == 0 else {
            throw AtomicCopyFailure.commitFailed
        }
        if kind == .directory {
            for name in try directoryEntryNames(descriptor) {
                guard
                    let identity = try directoryEntryIdentity(
                        parentDescriptor: descriptor,
                        name: name
                    )
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                let childKind: ControlledMirror.EntryKind
                switch identity.type {
                case mode_t(S_IFREG): childKind = .file
                case mode_t(S_IFDIR): childKind = .directory
                default: throw AtomicCopyFailure.unsafePath
                }
                let childDescriptor = try openRecoveryPayloadCandidate(
                    parentDescriptor: descriptor,
                    name: name,
                    expectedKind: childKind
                )
                defer { close(childDescriptor) }
                var openedStatus = stat()
                guard fstat(childDescriptor, &openedStatus) == 0,
                    FileObjectIdentity(openedStatus) == identity
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                try secureAndSynchronizeRecoveryObject(
                    descriptor: childDescriptor,
                    kind: childKind
                )
                guard
                    try directoryEntryIdentity(
                        parentDescriptor: descriptor,
                        name: name
                    ) == identity
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
            }
        }
        guard fsync(descriptor) == 0 else { throw AtomicCopyFailure.commitFailed }
    }

    private static func captureRecoveryPayload(
        operationDescriptor: Int32,
        expectedKind: ControlledMirror.EntryKind,
        name: String = recoveryPayloadName,
        operationID: UUID? = nil,
        side: ControlledMirrorSide? = nil,
        recoveryMeter: ControlledMirrorRecoveryMeterState? = nil,
        providerMeter: ControlledMirrorProviderMeterState? = nil,
        providerEventKeyPrefix: String? = nil,
        expectedProviderByteCount: Int64? = nil,
        beforeProviderPayloadIO: @Sendable (ControlledMirrorLogicalTransfer) throws -> Void = {
            _ in
        },
        beforeRead: @Sendable (ControlledMirrorRecoveryPayloadKind, Int64?) throws -> Void = {
            _, _ in
        },
        afterRead: @Sendable (ControlledMirrorRecoveryPayloadKind, Int64) throws -> Void = {
            _, _ in
        }
    ) throws -> RecoveryPayloadFingerprint {
        guard
            let identity = try recoveryPayloadIdentity(
                operationDescriptor: operationDescriptor,
                expectedKind: expectedKind,
                name: name
            )
        else {
            throw AtomicCopyFailure.rollbackFailed
        }
        let descriptor = try openRecoveryPayloadCandidate(
            parentDescriptor: operationDescriptor,
            name: name,
            expectedKind: expectedKind
        )
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            FileObjectIdentity(openedStatus) == identity
        else {
            throw AtomicCopyFailure.rollbackFailed
        }
        let publicKind: ControlledMirrorRecoveryPayloadKind =
            expectedKind == .file ? .file : .directory
        let discoveredByteCount: Int64?
        if expectedKind == .file, openedStatus.st_size >= 0 {
            discoveredByteCount = Int64(openedStatus.st_size)
        } else {
            // A directory can change while recursively enumerated, so its full
            // content size is not a safe pre-read transfer bound.
            discoveredByteCount = nil
        }
        if expectedKind == .directory, let expectedProviderByteCount {
            guard expectedProviderByteCount == 0 else {
                throw AtomicCopyFailure.rollbackFailed
            }
        } else if providerMeter != nil, let expectedProviderByteCount {
            guard expectedProviderByteCount >= 0,
                discoveredByteCount == expectedProviderByteCount
            else {
                throw AtomicCopyFailure.rollbackFailed
            }
        }
        try beforeRead(publicKind, discoveredByteCount)
        guard recoveryMeter == nil || providerMeter == nil else {
            throw AtomicCopyFailure.commitFailed
        }
        let maximumByteCount: Int64?
        if expectedKind == .directory {
            maximumByteCount = expectedProviderByteCount
        } else if providerMeter != nil {
            maximumByteCount = expectedProviderByteCount
        } else {
            maximumByteCount = discoveredByteCount
        }
        let captureAndFence = {
            let fingerprint = try captureRecoveryObject(
                descriptor: descriptor,
                kind: expectedKind,
                identity: identity,
                maximumByteCount: maximumByteCount
            )
            guard
                try recoveryPayloadIdentity(
                    operationDescriptor: operationDescriptor,
                    expectedKind: expectedKind,
                    name: name
                ) == identity
            else {
                throw AtomicCopyFailure.rollbackFailed
            }
            return fingerprint
        }

        if let providerMeter {
            guard expectedKind == .file,
                let providerEventKeyPrefix,
                let expectedProviderByteCount,
                discoveredByteCount == expectedProviderByteCount
            else {
                // Empty-directory recovery is metadata-only and therefore has
                // no payload event. The bounded recursive capture below rejects
                // any concurrently inserted child before opening it.
                guard expectedKind == .directory,
                    expectedProviderByteCount == 0,
                    providerEventKeyPrefix == nil
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                let fingerprint = try captureAndFence()
                try afterRead(publicKind, fingerprint.byteCount)
                return fingerprint
            }
            return try providerMeter.performNext(
                eventKeyPrefix: providerEventKeyPrefix,
                direction: .readExternalProvider,
                byteCount: expectedProviderByteCount,
                validate: { $0.byteCount == expectedProviderByteCount },
                { transfer in
                    try beforeProviderPayloadIO(transfer)
                    let fingerprint = try captureAndFence()
                    try afterRead(publicKind, fingerprint.byteCount)
                    return fingerprint
                }
            )
        }

        let meteredTransfer: ControlledMirrorLogicalTransfer?
        if let recoveryMeter {
            guard let operationID, let side, let discoveredByteCount else {
                throw ControlledMirrorPreparedRecoveryError.unboundedExternalPayload
            }
            meteredTransfer = try recoveryMeter.authorize(
                operationID: operationID,
                side: side,
                payloadName: name,
                byteCount: discoveredByteCount
            )
        } else {
            meteredTransfer = nil
        }
        let fingerprint: RecoveryPayloadFingerprint
        do {
            fingerprint = try captureAndFence()
        } catch {
            if let meteredTransfer {
                recoveryMeter?.markUncertain(meteredTransfer)
            }
            throw error
        }
        do {
            try afterRead(publicKind, fingerprint.byteCount)
        } catch {
            if let meteredTransfer {
                recoveryMeter?.markUncertain(meteredTransfer)
            }
            throw error
        }
        if let meteredTransfer {
            try recoveryMeter?.complete(meteredTransfer)
        }
        return fingerprint
    }

    private static func authorizeRecoveryPayloadRead(
        operationDescriptor: Int32,
        expectedKind: ControlledMirror.EntryKind,
        name: String = recoveryPayloadName,
        beforeRead: @Sendable (ControlledMirrorRecoveryPayloadKind, Int64?) throws -> Void
    ) throws {
        guard
            let identity = try recoveryPayloadIdentity(
                operationDescriptor: operationDescriptor,
                expectedKind: expectedKind,
                name: name
            )
        else {
            throw AtomicCopyFailure.rollbackFailed
        }
        let descriptor = try openRecoveryPayloadCandidate(
            parentDescriptor: operationDescriptor,
            name: name,
            expectedKind: expectedKind
        )
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            FileObjectIdentity(openedStatus) == identity
        else {
            throw AtomicCopyFailure.rollbackFailed
        }
        let publicKind: ControlledMirrorRecoveryPayloadKind =
            expectedKind == .file ? .file : .directory
        let boundedByteCount =
            expectedKind == .file && openedStatus.st_size >= 0
            ? Int64(openedStatus.st_size) : nil
        try beforeRead(publicKind, boundedByteCount)
    }

    private static func captureRecoveryObject(
        descriptor: Int32,
        kind: ControlledMirror.EntryKind,
        identity: FileObjectIdentity,
        maximumByteCount: Int64? = nil
    ) throws -> RecoveryPayloadFingerprint {
        switch kind {
        case .file:
            guard
                let fingerprint = try regularFileFingerprint(
                    descriptor: descriptor,
                    expectedIdentity: identity,
                    maximumByteCount: maximumByteCount
                ), let contentDigest = fingerprint.contentDigest,
                fsync(descriptor) == 0
            else {
                throw AtomicCopyFailure.rollbackFailed
            }
            return RecoveryPayloadFingerprint(
                kind: .file,
                contentDigest: contentDigest,
                byteCount: fingerprint.byteCount
            )
        case .directory:
            var before = stat()
            guard fstat(descriptor, &before) == 0,
                FileObjectIdentity(before) == identity
            else {
                throw AtomicCopyFailure.rollbackFailed
            }
            let beforeIdentity = FileIdentity(before)
            var digest = SHA256()
            updateRecoveryDigest(&digest, field: Data("directory-v1".utf8))
            var byteCount: Int64 = 0
            let names = try directoryEntryNames(descriptor)
            if let maximumByteCount {
                guard maximumByteCount == 0, names.isEmpty else {
                    throw AtomicCopyFailure.rollbackFailed
                }
            }
            for name in names {
                guard
                    let childIdentity = try directoryEntryIdentity(
                        parentDescriptor: descriptor,
                        name: name
                    )
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                let childKind: ControlledMirror.EntryKind
                switch childIdentity.type {
                case mode_t(S_IFREG): childKind = .file
                case mode_t(S_IFDIR): childKind = .directory
                default: throw AtomicCopyFailure.unsafePath
                }
                let childDescriptor = try openRecoveryPayloadCandidate(
                    parentDescriptor: descriptor,
                    name: name,
                    expectedKind: childKind
                )
                defer { close(childDescriptor) }
                var openedStatus = stat()
                guard fstat(childDescriptor, &openedStatus) == 0,
                    FileObjectIdentity(openedStatus) == childIdentity
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                let child = try captureRecoveryObject(
                    descriptor: childDescriptor,
                    kind: childKind,
                    identity: childIdentity
                )
                guard
                    try directoryEntryIdentity(
                        parentDescriptor: descriptor,
                        name: name
                    ) == childIdentity
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                let (nextByteCount, overflow) = byteCount.addingReportingOverflow(child.byteCount)
                guard !overflow else { throw AtomicCopyFailure.commitFailed }
                byteCount = nextByteCount
                updateRecoveryDigest(&digest, field: Data(childKind.rawValue.utf8))
                updateRecoveryDigest(&digest, field: Data(name.utf8))
                updateRecoveryDigest(&digest, field: Data(child.contentDigest.utf8))
                var encodedSize = UInt64(bitPattern: child.byteCount).bigEndian
                withUnsafeBytes(of: &encodedSize) { digest.update(bufferPointer: $0) }
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                FileObjectIdentity(after) == identity,
                FileIdentity(after) == beforeIdentity,
                maximumByteCount == nil || byteCount == maximumByteCount,
                fsync(descriptor) == 0
            else {
                throw AtomicCopyFailure.rollbackFailed
            }
            let contentDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
            return RecoveryPayloadFingerprint(
                kind: .directory,
                contentDigest: contentDigest,
                byteCount: byteCount
            )
        }
    }

    private static func updateRecoveryDigest(_ digest: inout SHA256, field: Data) {
        var count = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &count) { digest.update(bufferPointer: $0) }
        digest.update(data: field)
    }

    private static func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let iteratorDescriptor = ".".withCString {
            openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard iteratorDescriptor >= 0, let directory = fdopendir(iteratorDescriptor) else {
            if iteratorDescriptor >= 0 { close(iteratorDescriptor) }
            throw AtomicCopyFailure.commitFailed
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer -> String? in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw AtomicCopyFailure.unsafePath }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                throw AtomicCopyFailure.unsafePath
            }
            names.append(name)
        }
        return names.sorted()
    }

    private static func readRecoveryRecord(
        directoryDescriptor: Int32,
        name: String
    ) throws -> RecoveryRecord? {
        guard try directoryEntryIdentity(parentDescriptor: directoryDescriptor, name: name) != nil else {
            return nil
        }
        let descriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw AtomicCopyFailure.unsafePath }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            status.st_size > 0,
            status.st_size <= maximumRecoveryRecordBytes,
            fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw AtomicCopyFailure.unsafePath
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw AtomicCopyFailure.commitFailed
        }
        guard data.count == status.st_size else { throw AtomicCopyFailure.commitFailed }
        do {
            let record = try JSONDecoder().decode(RecoveryRecord.self, from: data)
            guard validRecoveryRecord(record) else { throw AtomicCopyFailure.rollbackFailed }
            return record
        } catch {
            if let failure = error as? AtomicCopyFailure { throw failure }
            throw AtomicCopyFailure.rollbackFailed
        }
    }

    private static func validRecoveryRecord(_ record: RecoveryRecord) -> Bool {
        guard record.schemaVersion == recoverySchemaVersion,
            UUID(uuidString: record.operationID)?.uuidString == record.operationID,
            isSafeRecoveryRelativePath(record.relativePath),
            record.payloadRelativePath == recoveryPayloadRelativePath(operationName: record.operationID),
            record.expectedByteCount >= 0,
            record.createdAt > 0
        else {
            return false
        }
        switch record.payloadKind {
        case .file:
            guard let expectedContentDigest = record.expectedContentDigest,
                isSHA256Hex(expectedContentDigest)
            else {
                return false
            }
        case .directory:
            guard record.expectedContentDigest == nil, record.expectedByteCount == 0 else {
                return false
            }
        }
        switch record.status {
        case .prepared:
            return record.payloadContentDigest == nil && record.payloadByteCount == nil
        case .retainedRequiresUserConfirmation, .conflictRequiresManualCleanup,
            .disposalApprovedPendingCleanup:
            guard let payloadContentDigest = record.payloadContentDigest,
                let payloadByteCount = record.payloadByteCount
            else {
                return false
            }
            return isSHA256Hex(payloadContentDigest) && payloadByteCount >= 0
        }
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }

    private static func writeRecoveryRecord(
        _ record: RecoveryRecord,
        directoryDescriptor: Int32,
        name: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw AtomicCopyFailure.commitFailed
        }
        guard !data.isEmpty, data.count <= maximumRecoveryRecordBytes else {
            throw AtomicCopyFailure.commitFailed
        }
        let descriptor = name.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        if descriptor < 0, errno == EEXIST {
            guard
                let existing = try readRecoveryRecord(
                    directoryDescriptor: directoryDescriptor,
                    name: name
                ), existing == record
            else {
                throw AtomicCopyFailure.rollbackFailed
            }
            return
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += count
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0,
            fsync(directoryDescriptor) == 0
        else {
            throw AtomicCopyFailure.commitFailed
        }
    }

    /// Descriptor-only provider preflight. Recovery records and payload inode
    /// metadata are validated, but no payload content is fingerprinted here.
    /// Directories deliberately have no finite recursive bound and fail closed.
    fileprivate func recoveryReadBounds(
        root: URL,
        side: ControlledMirrorSide,
        operationIDFilter: UUID? = nil
    ) throws -> [RecoveryReadBound] {
        guard side == .external else { return [] }
        return try Self.withExistingRecoveryDirectory(root: root) { recoveryDescriptor in
            let operationNames = try Self.directoryEntryNames(recoveryDescriptor)
            guard operationNames.count <= Self.maximumRecoveryRecords else {
                throw AtomicCopyFailure.commitFailed
            }
            var bounds: [RecoveryReadBound] = []
            for operationName in operationNames {
                guard let operationID = UUID(uuidString: operationName),
                    operationID.uuidString == operationName
                else {
                    throw AtomicCopyFailure.unsafePath
                }
                if let operationIDFilter, operationID != operationIDFilter { continue }
                guard
                    let operationDescriptor = try Self.openExistingDirectory(
                        parentDescriptor: recoveryDescriptor,
                        name: operationName
                    )
                else {
                    throw AtomicCopyFailure.unsafePath
                }
                defer { close(operationDescriptor) }
                guard
                    let prepared = try Self.readRecoveryRecord(
                        directoryDescriptor: operationDescriptor,
                        name: Self.recoveryPreparedName
                    ), prepared.operationID == operationName,
                    prepared.status == .prepared
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                let retained = try Self.readRecoveryRecord(
                    directoryDescriptor: operationDescriptor,
                    name: Self.recoveryRetainedName
                )
                let conflict = try Self.readRecoveryRecord(
                    directoryDescriptor: operationDescriptor,
                    name: Self.recoveryConflictName
                )
                let disposal = try Self.readRecoveryRecord(
                    directoryDescriptor: operationDescriptor,
                    name: Self.recoveryDisposalName
                )
                guard
                    retained.map({
                        $0.status == .retainedRequiresUserConfirmation
                            && $0.matchesOperationInvariant(of: prepared)
                    }) != false,
                    conflict.map({
                        $0.status == .conflictRequiresManualCleanup
                            && $0.matchesOperationInvariant(of: prepared)
                    }) != false,
                    disposal.map({
                        $0.status == .disposalApprovedPendingCleanup
                            && $0.matchesOperationInvariant(of: prepared)
                    }) != false
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }

                let payloadIdentity = try Self.recoveryPayloadIdentity(
                    operationDescriptor: operationDescriptor,
                    expectedKind: prepared.payloadKind
                )
                let disposingIdentity = try Self.recoveryPayloadIdentity(
                    operationDescriptor: operationDescriptor,
                    expectedKind: prepared.payloadKind,
                    name: Self.recoveryDisposingPayloadName
                )
                guard payloadIdentity == nil || disposingIdentity == nil else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                let payloadName: String?
                if payloadIdentity != nil {
                    payloadName = Self.recoveryPayloadName
                } else if disposingIdentity != nil {
                    payloadName = Self.recoveryDisposingPayloadName
                } else {
                    payloadName = nil
                }
                guard let payloadName else { continue }
                guard prepared.payloadKind == .file else {
                    throw ControlledMirrorPreparedRecoveryError.unboundedExternalPayload
                }
                let descriptor = try Self.openRecoveryPayloadCandidate(
                    parentDescriptor: operationDescriptor,
                    name: payloadName,
                    expectedKind: prepared.payloadKind
                )
                defer { close(descriptor) }
                var status = stat()
                guard fstat(descriptor, &status) == 0,
                    status.st_size >= 0,
                    FileObjectIdentity(status)
                        == (payloadName == Self.recoveryPayloadName
                            ? payloadIdentity : disposingIdentity)
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                bounds.append(
                    RecoveryReadBound(
                        operationID: operationID,
                        side: side,
                        payloadName: payloadName,
                        byteCount: Int64(status.st_size)
                    )
                )
            }
            return bounds
        } ?? []
    }

    fileprivate func recoverySummaries(
        root: URL,
        side: ControlledMirrorSide,
        operationIDFilter: UUID? = nil,
        recoveryMeter: ControlledMirrorRecoveryMeterState? = nil
    ) throws -> [ControlledMirrorRecoverySummary] {
        let summaries: [ControlledMirrorRecoverySummary] =
            try Self.withExistingRecoveryDirectory(root: root) { recoveryDescriptor in
                let operationNames = try Self.directoryEntryNames(recoveryDescriptor)
                guard operationNames.count <= Self.maximumRecoveryRecords else {
                    throw AtomicCopyFailure.commitFailed
                }
                var summaries: [ControlledMirrorRecoverySummary] = []
                summaries.reserveCapacity(operationNames.count)
                for operationName in operationNames {
                    guard let operationID = UUID(uuidString: operationName),
                        operationID.uuidString == operationName
                    else {
                        throw AtomicCopyFailure.unsafePath
                    }
                    if let operationIDFilter, operationID != operationIDFilter { continue }
                    guard
                        let operationDescriptor = try Self.openExistingDirectory(
                            parentDescriptor: recoveryDescriptor,
                            name: operationName
                        )
                    else {
                        throw AtomicCopyFailure.unsafePath
                    }
                    defer { close(operationDescriptor) }
                    guard
                        let prepared = try Self.readRecoveryRecord(
                            directoryDescriptor: operationDescriptor,
                            name: Self.recoveryPreparedName
                        ), prepared.operationID == operationName,
                        prepared.status == .prepared
                    else {
                        throw AtomicCopyFailure.rollbackFailed
                    }
                    let retained = try Self.readRecoveryRecord(
                        directoryDescriptor: operationDescriptor,
                        name: Self.recoveryRetainedName
                    )
                    let conflict = try Self.readRecoveryRecord(
                        directoryDescriptor: operationDescriptor,
                        name: Self.recoveryConflictName
                    )
                    let disposal = try Self.readRecoveryRecord(
                        directoryDescriptor: operationDescriptor,
                        name: Self.recoveryDisposalName
                    )
                    if let retained {
                        guard retained.status == .retainedRequiresUserConfirmation,
                            retained.matchesOperationInvariant(of: prepared)
                        else {
                            throw AtomicCopyFailure.rollbackFailed
                        }
                    }
                    if let conflict {
                        guard conflict.status == .conflictRequiresManualCleanup,
                            conflict.matchesOperationInvariant(of: prepared)
                        else {
                            throw AtomicCopyFailure.rollbackFailed
                        }
                    }
                    if let disposal {
                        guard disposal.status == .disposalApprovedPendingCleanup,
                            disposal.matchesOperationInvariant(of: prepared)
                        else {
                            throw AtomicCopyFailure.rollbackFailed
                        }
                    }
                    let payloadIdentity = try Self.recoveryPayloadIdentity(
                        operationDescriptor: operationDescriptor,
                        expectedKind: prepared.payloadKind
                    )
                    let disposingIdentity = try Self.recoveryPayloadIdentity(
                        operationDescriptor: operationDescriptor,
                        expectedKind: prepared.payloadKind,
                        name: Self.recoveryDisposingPayloadName
                    )
                    guard payloadIdentity == nil || disposingIdentity == nil else {
                        throw AtomicCopyFailure.rollbackFailed
                    }
                    let payloadName: String?
                    if payloadIdentity != nil {
                        payloadName = Self.recoveryPayloadName
                    } else if disposingIdentity != nil {
                        payloadName = Self.recoveryDisposingPayloadName
                    } else {
                        payloadName = nil
                    }
                    guard let payloadName else {
                        if let disposal, let recorded = disposal.payloadFingerprint {
                            summaries.append(
                                Self.recoverySummary(
                                    record: disposal,
                                    actual: recorded,
                                    operationID: operationID,
                                    side: side
                                )
                            )
                            continue
                        }
                        if retained != nil || conflict != nil {
                            throw AtomicCopyFailure.rollbackFailed
                        }
                        continue
                    }
                    try Self.authorizeRecoveryPayloadRead(
                        operationDescriptor: operationDescriptor,
                        expectedKind: prepared.payloadKind,
                        name: payloadName,
                        beforeRead: { kind, byteCount in
                            try beforeRecoveryPayloadReadBody(side, kind, byteCount)
                        }
                    )
                    try Self.secureAndSynchronizeRecoveryPayload(
                        operationDescriptor: operationDescriptor,
                        expectedKind: prepared.payloadKind,
                        name: payloadName
                    )
                    let actual = try Self.captureRecoveryPayload(
                        operationDescriptor: operationDescriptor,
                        expectedKind: prepared.payloadKind,
                        name: payloadName,
                        operationID: operationID,
                        side: side,
                        recoveryMeter: recoveryMeter,
                        beforeRead: { kind, byteCount in
                            try beforeRecoveryPayloadReadBody(side, kind, byteCount)
                        },
                        afterRead: { kind, byteCount in
                            try afterRecoveryPayloadReadBody(side, kind, byteCount)
                        }
                    )
                    let selectedRecord: RecoveryRecord
                    if let disposal {
                        selectedRecord = disposal
                    } else if let conflict {
                        selectedRecord = conflict
                    } else if let retained {
                        if retained.payloadFingerprint == actual {
                            selectedRecord = retained
                        } else {
                            let promoted = retained.withStatus(
                                .conflictRequiresManualCleanup,
                                payload: actual
                            )
                            try Self.writeRecoveryRecord(
                                promoted,
                                directoryDescriptor: operationDescriptor,
                                name: Self.recoveryConflictName
                            )
                            guard fsync(operationDescriptor) == 0,
                                fsync(recoveryDescriptor) == 0
                            else {
                                throw AtomicCopyFailure.commitFailed
                            }
                            selectedRecord = promoted
                        }
                    } else {
                        selectedRecord = prepared
                    }
                    summaries.append(
                        Self.recoverySummary(
                            record: selectedRecord,
                            actual: actual,
                            operationID: operationID,
                            side: side
                        )
                    )
                }
                return summaries
            } ?? []
        return summaries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }

    private static func recoverySummary(
        record: RecoveryRecord,
        actual: RecoveryPayloadFingerprint,
        operationID: UUID,
        side: ControlledMirrorSide
    ) -> ControlledMirrorRecoverySummary {
        let payloadKind: ControlledMirrorRecoveryPayloadKind =
            actual.kind == .file ? .file : .directory
        return ControlledMirrorRecoverySummary(
            operationID: operationID,
            side: side,
            kind: record.kind,
            relativePath: record.relativePath,
            payloadKind: payloadKind,
            contentDigest: actual.contentDigest,
            byteCount: actual.byteCount,
            createdAt: Date(timeIntervalSince1970: TimeInterval(record.createdAt)),
            status: record.status
        )
    }

    fileprivate func exportRecovery(
        root: URL,
        side: ControlledMirrorSide,
        requested: ControlledMirrorRecoverySummary,
        to outputDirectory: URL,
        recoveryMeter: ControlledMirrorRecoveryMeterState? = nil,
        authorization: @Sendable (ControlledMirrorRecoverySummary) throws -> Bool
    ) throws -> ControlledMirrorRecoveryExport {
        let current = try recoverySummaries(
            root: root,
            side: side,
            operationIDFilter: requested.operationID,
            recoveryMeter: recoveryMeter
        ).first { $0.operationID == requested.operationID }
        guard let current else { throw ControlledMirrorRecoveryError.notFound }
        guard current == requested else { throw ControlledMirrorRecoveryError.changed }
        guard try authorization(current) else {
            throw ControlledMirrorRecoveryError.authorizationDenied
        }

        let exported = try Self.withExistingRecoveryDirectory(root: root) {
            recoveryDescriptor in
            let operationName = requested.operationID.uuidString
            guard
                let operationDescriptor = try Self.openExistingDirectory(
                    parentDescriptor: recoveryDescriptor,
                    name: operationName
                )
            else {
                throw ControlledMirrorRecoveryError.notFound
            }
            defer { close(operationDescriptor) }
            guard
                let prepared = try Self.readRecoveryRecord(
                    directoryDescriptor: operationDescriptor,
                    name: Self.recoveryPreparedName
                ), prepared.operationID == operationName,
                prepared.status == .prepared
            else {
                throw ControlledMirrorRecoveryError.changed
            }
            let retained = try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryRetainedName
            )
            let conflict = try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryConflictName
            )
            let disposal = try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryDisposalName
            )
            let selected = disposal ?? conflict ?? retained ?? prepared
            guard selected.matchesOperationInvariant(of: prepared),
                selected.status == requested.status
            else {
                throw ControlledMirrorRecoveryError.changed
            }
            let payloadIdentity = try Self.recoveryPayloadIdentity(
                operationDescriptor: operationDescriptor,
                expectedKind: prepared.payloadKind
            )
            let disposingIdentity = try Self.recoveryPayloadIdentity(
                operationDescriptor: operationDescriptor,
                expectedKind: prepared.payloadKind,
                name: Self.recoveryDisposingPayloadName
            )
            guard payloadIdentity == nil || disposingIdentity == nil else {
                throw ControlledMirrorRecoveryError.changed
            }
            let payloadName: String
            if payloadIdentity != nil {
                payloadName = Self.recoveryPayloadName
            } else if disposingIdentity != nil {
                payloadName = Self.recoveryDisposingPayloadName
            } else {
                throw ControlledMirrorRecoveryError.notFound
            }
            let result = try Self.copyRecoveryPayloadForExport(
                operationDescriptor: operationDescriptor,
                expectedKind: prepared.payloadKind,
                payloadName: payloadName,
                operationID: requested.operationID,
                side: side,
                requested: requested,
                outputDirectory: outputDirectory,
                recoveryMeter: recoveryMeter,
                beforeRead: { kind, byteCount in
                    try beforeRecoveryPayloadReadBody(side, kind, byteCount)
                },
                afterRead: { kind, byteCount in
                    try afterRecoveryPayloadReadBody(side, kind, byteCount)
                }
            )
            do {
                guard try authorization(requested) else {
                    throw ControlledMirrorRecoveryError.authorizationDenied
                }
            } catch {
                try? Self.removeRecoveryExport(result, from: outputDirectory)
                throw error
            }
            return result
        }
        guard let exported else { throw ControlledMirrorRecoveryError.notFound }
        return exported
    }

    private static func copyRecoveryPayloadForExport(
        operationDescriptor: Int32,
        expectedKind: ControlledMirror.EntryKind,
        payloadName: String,
        operationID: UUID,
        side: ControlledMirrorSide,
        requested: ControlledMirrorRecoverySummary,
        outputDirectory: URL,
        recoveryMeter: ControlledMirrorRecoveryMeterState?,
        beforeRead: @Sendable (ControlledMirrorRecoveryPayloadKind, Int64?) throws -> Void,
        afterRead: @Sendable (ControlledMirrorRecoveryPayloadKind, Int64) throws -> Void
    ) throws -> ControlledMirrorRecoveryExport {
        guard
            let sourceIdentity = try recoveryPayloadIdentity(
                operationDescriptor: operationDescriptor,
                expectedKind: expectedKind,
                name: payloadName
            )
        else {
            throw ControlledMirrorRecoveryError.notFound
        }
        let sourceDescriptor = try openRecoveryPayloadCandidate(
            parentDescriptor: operationDescriptor,
            name: payloadName,
            expectedKind: expectedKind
        )
        defer { close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
            FileObjectIdentity(sourceStatus) == sourceIdentity
        else {
            throw ControlledMirrorRecoveryError.changed
        }
        let publicKind: ControlledMirrorRecoveryPayloadKind =
            expectedKind == .file ? .file : .directory
        let boundedByteCount =
            expectedKind == .file && sourceStatus.st_size >= 0
            ? Int64(sourceStatus.st_size) : nil
        try beforeRead(publicKind, boundedByteCount)
        let transfer: ControlledMirrorLogicalTransfer?
        if let recoveryMeter {
            guard let boundedByteCount else {
                throw ControlledMirrorPreparedRecoveryError.unboundedExternalPayload
            }
            transfer = try recoveryMeter.authorize(
                operationID: operationID,
                side: side,
                payloadName: payloadName,
                byteCount: boundedByteCount
            )
        } else {
            transfer = nil
        }

        do {
            let outputDescriptor = try openOrCreateExportDirectory(outputDirectory)
            defer { close(outputDescriptor) }
            let containerName = ".psy-recovery-export-" + UUID().uuidString
            guard containerName.withCString({ mkdirat(outputDescriptor, $0, mode_t(0o700)) }) == 0
            else {
                throw ControlledMirrorRecoveryError.exportFailed
            }
            let containerDescriptor = try openExistingDirectory(
                parentDescriptor: outputDescriptor,
                name: containerName
            )
            guard let containerDescriptor else {
                throw ControlledMirrorRecoveryError.exportFailed
            }
            defer { close(containerDescriptor) }
            var committed = false
            defer {
                if !committed {
                    try? removeRecoveryObject(
                        parentDescriptor: outputDescriptor,
                        name: containerName,
                        kind: .directory
                    )
                    _ = fsync(outputDescriptor)
                }
            }
            let outputName = recoveryExportName(for: requested)
            let copied = try copyRecoveryObjectForExport(
                sourceDescriptor: sourceDescriptor,
                sourceIdentity: sourceIdentity,
                kind: expectedKind,
                destinationParentDescriptor: containerDescriptor,
                destinationName: outputName
            )
            guard copied.contentDigest == requested.contentDigest,
                copied.byteCount == requested.byteCount,
                copied.kind == expectedKind,
                try recoveryPayloadIdentity(
                    operationDescriptor: operationDescriptor,
                    expectedKind: expectedKind,
                    name: payloadName
                ) == sourceIdentity,
                fsync(containerDescriptor) == 0,
                fsync(outputDescriptor) == 0
            else {
                throw ControlledMirrorRecoveryError.changed
            }
            let containerURL = outputDirectory.appendingPathComponent(
                containerName,
                isDirectory: true
            )
            #if os(iOS)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableContainerURL = containerURL
                try mutableContainerURL.setResourceValues(values)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: containerURL.path
                )
            #endif
            let export = ControlledMirrorRecoveryExport(
                url: containerURL.appendingPathComponent(
                    outputName,
                    isDirectory: expectedKind == .directory
                ),
                payloadKind: publicKind,
                containerName: containerName
            )
            try afterRead(publicKind, copied.byteCount)
            if let transfer { try recoveryMeter?.complete(transfer) }
            committed = true
            return export
        } catch {
            if let transfer { recoveryMeter?.markUncertain(transfer) }
            if error is ControlledMirrorRecoveryError
                || error is ControlledMirrorPreparedRecoveryError
            {
                throw error
            }
            throw ControlledMirrorRecoveryError.exportFailed
        }
    }

    private static func copyRecoveryObjectForExport(
        sourceDescriptor: Int32,
        sourceIdentity: FileObjectIdentity,
        kind: ControlledMirror.EntryKind,
        destinationParentDescriptor: Int32,
        destinationName: String
    ) throws -> RecoveryPayloadFingerprint {
        var before = stat()
        guard fstat(sourceDescriptor, &before) == 0,
            FileObjectIdentity(before) == sourceIdentity
        else {
            throw ControlledMirrorRecoveryError.changed
        }
        let beforeIdentity = FileIdentity(before)
        switch kind {
        case .file:
            let destinationDescriptor = destinationName.withCString {
                openat(
                    destinationParentDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            guard destinationDescriptor >= 0 else {
                throw ControlledMirrorRecoveryError.exportFailed
            }
            defer { close(destinationDescriptor) }
            var digest = SHA256()
            var byteCount: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
                }
                if count == 0 { break }
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw ControlledMirrorRecoveryError.changed
                }
                let (next, overflow) = byteCount.addingReportingOverflow(Int64(count))
                guard !overflow else { throw ControlledMirrorRecoveryError.exportFailed }
                byteCount = next
                try buffer.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    digest.update(bufferPointer: UnsafeRawBufferPointer(start: base, count: count))
                    var offset = 0
                    while offset < count {
                        let written = Darwin.write(
                            destinationDescriptor,
                            base.advanced(by: offset),
                            count - offset
                        )
                        guard written > 0 else {
                            if errno == EINTR { continue }
                            throw ControlledMirrorRecoveryError.exportFailed
                        }
                        offset += written
                    }
                }
            }
            var after = stat()
            var destinationStatus = stat()
            guard fstat(sourceDescriptor, &after) == 0,
                FileObjectIdentity(after) == sourceIdentity,
                FileIdentity(after) == beforeIdentity,
                fchmod(destinationDescriptor, mode_t(0o600)) == 0,
                fsync(destinationDescriptor) == 0,
                fstat(destinationDescriptor, &destinationStatus) == 0,
                destinationStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                destinationStatus.st_size == byteCount
            else {
                throw ControlledMirrorRecoveryError.changed
            }
            return RecoveryPayloadFingerprint(
                kind: .file,
                contentDigest: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                byteCount: byteCount
            )
        case .directory:
            guard
                destinationName.withCString({
                    mkdirat(destinationParentDescriptor, $0, mode_t(0o700))
                }) == 0
            else {
                throw ControlledMirrorRecoveryError.exportFailed
            }
            guard
                let destinationDescriptor = try openExistingDirectory(
                    parentDescriptor: destinationParentDescriptor,
                    name: destinationName
                )
            else {
                throw ControlledMirrorRecoveryError.exportFailed
            }
            defer { close(destinationDescriptor) }
            var digest = SHA256()
            updateRecoveryDigest(&digest, field: Data("directory-v1".utf8))
            var byteCount: Int64 = 0
            for childName in try directoryEntryNames(sourceDescriptor) {
                guard
                    let childIdentity = try directoryEntryIdentity(
                        parentDescriptor: sourceDescriptor,
                        name: childName
                    )
                else {
                    throw ControlledMirrorRecoveryError.changed
                }
                let childKind: ControlledMirror.EntryKind
                switch childIdentity.type {
                case mode_t(S_IFREG): childKind = .file
                case mode_t(S_IFDIR): childKind = .directory
                default: throw ControlledMirrorRecoveryError.changed
                }
                let childDescriptor = try openRecoveryPayloadCandidate(
                    parentDescriptor: sourceDescriptor,
                    name: childName,
                    expectedKind: childKind
                )
                let child: RecoveryPayloadFingerprint
                do {
                    child = try copyRecoveryObjectForExport(
                        sourceDescriptor: childDescriptor,
                        sourceIdentity: childIdentity,
                        kind: childKind,
                        destinationParentDescriptor: destinationDescriptor,
                        destinationName: childName
                    )
                } catch {
                    close(childDescriptor)
                    throw error
                }
                close(childDescriptor)
                guard
                    try directoryEntryIdentity(
                        parentDescriptor: sourceDescriptor,
                        name: childName
                    ) == childIdentity
                else {
                    throw ControlledMirrorRecoveryError.changed
                }
                let (next, overflow) = byteCount.addingReportingOverflow(child.byteCount)
                guard !overflow else { throw ControlledMirrorRecoveryError.exportFailed }
                byteCount = next
                updateRecoveryDigest(&digest, field: Data(childKind.rawValue.utf8))
                updateRecoveryDigest(&digest, field: Data(childName.utf8))
                updateRecoveryDigest(&digest, field: Data(child.contentDigest.utf8))
                var encodedSize = UInt64(bitPattern: child.byteCount).bigEndian
                withUnsafeBytes(of: &encodedSize) { digest.update(bufferPointer: $0) }
            }
            var after = stat()
            guard fstat(sourceDescriptor, &after) == 0,
                FileObjectIdentity(after) == sourceIdentity,
                FileIdentity(after) == beforeIdentity,
                fchmod(destinationDescriptor, mode_t(0o700)) == 0,
                fsync(destinationDescriptor) == 0
            else {
                throw ControlledMirrorRecoveryError.changed
            }
            return RecoveryPayloadFingerprint(
                kind: .directory,
                contentDigest: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                byteCount: byteCount
            )
        }
    }

    private static func openOrCreateExportDirectory(_ directory: URL) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ControlledMirrorRecoveryError.exportFailed
        }
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ControlledMirrorRecoveryError.exportFailed }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            fchmod(descriptor, mode_t(0o700)) == 0
        else {
            close(descriptor)
            throw ControlledMirrorRecoveryError.exportFailed
        }
        return descriptor
    }

    private static func recoveryExportName(
        for summary: ControlledMirrorRecoverySummary
    ) -> String {
        let leaf = summary.relativePath.split(separator: "/").last.map(String.init) ?? "Recovery"
        let safeLeaf =
            !leaf.isEmpty && leaf != "." && leaf != ".." && !leaf.contains("\0")
                && leaf.utf8.count <= 160
            ? leaf : "Recovery"
        let suffix = String(summary.operationID.uuidString.prefix(8))
        guard summary.payloadKind == .file else {
            return safeLeaf + " Recovery " + suffix
        }
        let pathExtension = (safeLeaf as NSString).pathExtension
        guard !pathExtension.isEmpty else {
            return safeLeaf + " Recovery " + suffix
        }
        let baseName = (safeLeaf as NSString).deletingPathExtension
        return baseName + " Recovery " + suffix + "." + pathExtension
    }

    fileprivate static func removeRecoveryExport(
        _ export: ControlledMirrorRecoveryExport,
        from outputDirectory: URL
    ) throws {
        let expectedContainer = outputDirectory.appendingPathComponent(
            export.containerName,
            isDirectory: true
        ).standardizedFileURL
        guard export.containerName.hasPrefix(".psy-recovery-export-"),
            export.url.standardizedFileURL.deletingLastPathComponent() == expectedContainer
        else {
            throw ControlledMirrorRecoveryError.exportFailed
        }
        let outputDescriptor = try openOrCreateExportDirectory(outputDirectory)
        defer { close(outputDescriptor) }
        try removeRecoveryObject(
            parentDescriptor: outputDescriptor,
            name: export.containerName,
            kind: .directory
        )
        guard fsync(outputDescriptor) == 0 else {
            throw ControlledMirrorRecoveryError.exportFailed
        }
    }

    fileprivate static func removeTemporaryRecoveryExports(
        from outputDirectory: URL
    ) throws {
        let outputDescriptor = try openOrCreateExportDirectory(outputDirectory)
        defer { close(outputDescriptor) }
        let prefix = ".psy-recovery-export-"
        for name in try directoryEntryNames(outputDescriptor) {
            guard name.hasPrefix(prefix),
                UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            else {
                throw ControlledMirrorRecoveryError.exportFailed
            }
            try removeRecoveryObject(
                parentDescriptor: outputDescriptor,
                name: name,
                kind: .directory
            )
        }
        guard fsync(outputDescriptor) == 0 else {
            throw ControlledMirrorRecoveryError.exportFailed
        }
    }

    fileprivate func resolveRecovery(
        root: URL,
        side: ControlledMirrorSide,
        requested: ControlledMirrorRecoverySummary,
        decision: ControlledMirrorRecoveryDecision,
        recoveryMeter: ControlledMirrorRecoveryMeterState? = nil,
        authorization: @Sendable (ControlledMirrorRecoverySummary) throws -> Bool
    ) throws {
        let current = try recoverySummaries(
            root: root,
            side: side,
            operationIDFilter: requested.operationID,
            recoveryMeter: recoveryMeter
        ).first {
            $0.operationID == requested.operationID
        }
        guard let current else { throw ControlledMirrorRecoveryError.notFound }
        guard current == requested else { throw ControlledMirrorRecoveryError.changed }
        guard try authorization(current) else {
            throw ControlledMirrorRecoveryError.authorizationDenied
        }
        guard decision == .deleteAfterUserConfirmation else { return }

        let completed = try Self.withExistingRecoveryDirectory(root: root) { recoveryDescriptor in
            let operationName = requested.operationID.uuidString
            guard
                let operationDescriptor = try Self.openExistingDirectory(
                    parentDescriptor: recoveryDescriptor,
                    name: operationName
                )
            else {
                throw ControlledMirrorRecoveryError.notFound
            }
            defer { close(operationDescriptor) }
            var operationStatus = stat()
            guard fstat(operationDescriptor, &operationStatus) == 0 else {
                throw ControlledMirrorRecoveryError.changed
            }
            let operationIdentity = FileObjectIdentity(operationStatus)
            guard
                let prepared = try Self.readRecoveryRecord(
                    directoryDescriptor: operationDescriptor,
                    name: Self.recoveryPreparedName
                ), prepared.operationID == operationName,
                prepared.status == .prepared
            else {
                throw ControlledMirrorRecoveryError.changed
            }
            let retained = try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryRetainedName
            )
            let conflict = try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryConflictName
            )
            var disposal = try Self.readRecoveryRecord(
                directoryDescriptor: operationDescriptor,
                name: Self.recoveryDisposalName
            )
            let selected = disposal ?? conflict ?? retained ?? prepared
            guard selected.matchesOperationInvariant(of: prepared),
                selected.status == requested.status
            else {
                throw ControlledMirrorRecoveryError.changed
            }

            let allowedNames = Set([
                Self.recoveryPreparedName,
                Self.recoveryRetainedName,
                Self.recoveryConflictName,
                Self.recoveryDisposalName,
                Self.recoveryPayloadName,
                Self.recoveryDisposingPayloadName,
            ])
            guard Set(try Self.directoryEntryNames(operationDescriptor)).isSubset(of: allowedNames) else {
                throw ControlledMirrorRecoveryError.changed
            }

            let payloadIdentity = try Self.recoveryPayloadIdentity(
                operationDescriptor: operationDescriptor,
                expectedKind: prepared.payloadKind
            )
            let disposingIdentity = try Self.recoveryPayloadIdentity(
                operationDescriptor: operationDescriptor,
                expectedKind: prepared.payloadKind,
                name: Self.recoveryDisposingPayloadName
            )
            guard payloadIdentity == nil || disposingIdentity == nil else {
                throw ControlledMirrorRecoveryError.changed
            }
            var payloadName: String?
            if payloadIdentity != nil {
                payloadName = Self.recoveryPayloadName
            } else if disposingIdentity != nil {
                payloadName = Self.recoveryDisposingPayloadName
            } else {
                payloadName = nil
            }

            if let payloadName {
                let actual = try Self.captureRecoveryPayload(
                    operationDescriptor: operationDescriptor,
                    expectedKind: prepared.payloadKind,
                    name: payloadName,
                    operationID: requested.operationID,
                    side: side,
                    recoveryMeter: recoveryMeter,
                    beforeRead: { kind, byteCount in
                        try beforeRecoveryPayloadReadBody(side, kind, byteCount)
                    },
                    afterRead: { kind, byteCount in
                        try afterRecoveryPayloadReadBody(side, kind, byteCount)
                    }
                )
                guard
                    Self.recoverySummary(
                        record: selected,
                        actual: actual,
                        operationID: requested.operationID,
                        side: side
                    ) == requested,
                    try authorization(requested)
                else {
                    throw ControlledMirrorRecoveryError.changed
                }
                let finalFence = try Self.captureRecoveryPayload(
                    operationDescriptor: operationDescriptor,
                    expectedKind: prepared.payloadKind,
                    name: payloadName,
                    operationID: requested.operationID,
                    side: side,
                    recoveryMeter: recoveryMeter,
                    beforeRead: { kind, byteCount in
                        try beforeRecoveryPayloadReadBody(side, kind, byteCount)
                    },
                    afterRead: { kind, byteCount in
                        try afterRecoveryPayloadReadBody(side, kind, byteCount)
                    }
                )
                guard finalFence == actual else { throw ControlledMirrorRecoveryError.changed }

                if disposal == nil {
                    let approved = selected.withStatus(
                        .disposalApprovedPendingCleanup,
                        payload: actual
                    )
                    try Self.writeRecoveryRecord(
                        approved,
                        directoryDescriptor: operationDescriptor,
                        name: Self.recoveryDisposalName
                    )
                    guard fsync(operationDescriptor) == 0, fsync(recoveryDescriptor) == 0 else {
                        throw ControlledMirrorRecoveryError.disposalFailed
                    }
                    disposal = approved
                }
                if payloadName == Self.recoveryPayloadName {
                    let renameResult = Self.recoveryPayloadName.withCString { sourceName in
                        Self.recoveryDisposingPayloadName.withCString { destinationName in
                            renameatx_np(
                                operationDescriptor,
                                sourceName,
                                operationDescriptor,
                                destinationName,
                                UInt32(RENAME_EXCL)
                            )
                        }
                    }
                    guard renameResult == 0, fsync(operationDescriptor) == 0 else {
                        throw ControlledMirrorRecoveryError.disposalFailed
                    }
                }
                let disposing = try Self.captureRecoveryPayload(
                    operationDescriptor: operationDescriptor,
                    expectedKind: prepared.payloadKind,
                    name: Self.recoveryDisposingPayloadName,
                    operationID: requested.operationID,
                    side: side,
                    recoveryMeter: recoveryMeter,
                    beforeRead: { kind, byteCount in
                        try beforeRecoveryPayloadReadBody(side, kind, byteCount)
                    },
                    afterRead: { kind, byteCount in
                        try afterRecoveryPayloadReadBody(side, kind, byteCount)
                    }
                )
                guard disposing == actual, try authorization(requested) else {
                    try? Self.restoreDisposingRecoveryPayload(
                        operationDescriptor: operationDescriptor
                    )
                    throw ControlledMirrorRecoveryError.changed
                }
                do {
                    try Self.removeRecoveryObject(
                        parentDescriptor: operationDescriptor,
                        name: Self.recoveryDisposingPayloadName,
                        kind: prepared.payloadKind
                    )
                    guard fsync(operationDescriptor) == 0 else {
                        throw ControlledMirrorRecoveryError.disposalFailed
                    }
                } catch {
                    try? Self.restoreDisposingRecoveryPayload(
                        operationDescriptor: operationDescriptor
                    )
                    throw ControlledMirrorRecoveryError.disposalFailed
                }
            } else {
                guard disposal?.status == .disposalApprovedPendingCleanup,
                    disposal?.payloadFingerprint?.contentDigest == requested.contentDigest,
                    disposal?.payloadFingerprint?.byteCount == requested.byteCount,
                    try authorization(requested)
                else {
                    throw ControlledMirrorRecoveryError.changed
                }
            }

            guard let disposal else { throw ControlledMirrorRecoveryError.disposalFailed }
            try Self.removeCompletedRecoveryRecord(
                recoveryDescriptor: recoveryDescriptor,
                operationDescriptor: operationDescriptor,
                operationName: operationName,
                operationIdentity: operationIdentity,
                prepared: prepared,
                disposal: disposal
            )
            return true
        }
        guard completed == true else { throw ControlledMirrorRecoveryError.notFound }
    }

    private static func restoreDisposingRecoveryPayload(
        operationDescriptor: Int32
    ) throws {
        guard
            try directoryEntryIdentity(
                parentDescriptor: operationDescriptor,
                name: recoveryPayloadName
            ) == nil,
            try directoryEntryIdentity(
                parentDescriptor: operationDescriptor,
                name: recoveryDisposingPayloadName
            ) != nil
        else {
            throw ControlledMirrorRecoveryError.disposalFailed
        }
        let result = recoveryDisposingPayloadName.withCString { sourceName in
            recoveryPayloadName.withCString { destinationName in
                renameatx_np(
                    operationDescriptor,
                    sourceName,
                    operationDescriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0, fsync(operationDescriptor) == 0 else {
            throw ControlledMirrorRecoveryError.disposalFailed
        }
    }

    private static func removeRecoveryObject(
        parentDescriptor: Int32,
        name: String,
        kind: ControlledMirror.EntryKind
    ) throws {
        guard
            let identity = try directoryEntryIdentity(
                parentDescriptor: parentDescriptor,
                name: name
            )
        else {
            throw ControlledMirrorRecoveryError.changed
        }
        let descriptor = try openRecoveryPayloadCandidate(
            parentDescriptor: parentDescriptor,
            name: name,
            expectedKind: kind
        )
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            FileObjectIdentity(status) == identity
        else {
            throw ControlledMirrorRecoveryError.changed
        }
        if kind == .directory {
            for childName in try directoryEntryNames(descriptor) {
                guard
                    let childIdentity = try directoryEntryIdentity(
                        parentDescriptor: descriptor,
                        name: childName
                    )
                else {
                    throw ControlledMirrorRecoveryError.changed
                }
                let childKind: ControlledMirror.EntryKind
                switch childIdentity.type {
                case mode_t(S_IFREG): childKind = .file
                case mode_t(S_IFDIR): childKind = .directory
                default: throw ControlledMirrorRecoveryError.changed
                }
                try removeRecoveryObject(
                    parentDescriptor: descriptor,
                    name: childName,
                    kind: childKind
                )
            }
            guard try directoryIsEmpty(descriptor) else {
                throw ControlledMirrorRecoveryError.changed
            }
        }
        guard
            try directoryEntryIdentity(
                parentDescriptor: parentDescriptor,
                name: name
            ) == identity
        else {
            throw ControlledMirrorRecoveryError.changed
        }
        let flags = kind == .directory ? AT_REMOVEDIR : 0
        let result = name.withCString { unlinkat(parentDescriptor, $0, flags) }
        guard result == 0 else { throw ControlledMirrorRecoveryError.disposalFailed }
    }

    private static func removeCompletedRecoveryRecord(
        recoveryDescriptor: Int32,
        operationDescriptor: Int32,
        operationName: String,
        operationIdentity: FileObjectIdentity,
        prepared: RecoveryRecord,
        disposal: RecoveryRecord
    ) throws {
        do {
            for name in [recoveryRetainedName, recoveryConflictName] {
                try removeInternalRecoveryFileIfPresent(
                    directoryDescriptor: operationDescriptor,
                    name: name
                )
            }
            try removeInternalRecoveryFileIfPresent(
                directoryDescriptor: operationDescriptor,
                name: recoveryDisposalName
            )
            try removeInternalRecoveryFileIfPresent(
                directoryDescriptor: operationDescriptor,
                name: recoveryPreparedName
            )
            guard try directoryIsEmpty(operationDescriptor),
                try directoryEntryIdentity(
                    parentDescriptor: recoveryDescriptor,
                    name: operationName
                ) == operationIdentity
            else {
                throw ControlledMirrorRecoveryError.disposalFailed
            }
            let result = operationName.withCString {
                unlinkat(recoveryDescriptor, $0, AT_REMOVEDIR)
            }
            guard result == 0, fsync(recoveryDescriptor) == 0 else {
                throw ControlledMirrorRecoveryError.disposalFailed
            }
        } catch {
            try? writeRecoveryRecord(
                prepared,
                directoryDescriptor: operationDescriptor,
                name: recoveryPreparedName
            )
            try? writeRecoveryRecord(
                disposal,
                directoryDescriptor: operationDescriptor,
                name: recoveryDisposalName
            )
            _ = fsync(operationDescriptor)
            throw ControlledMirrorRecoveryError.disposalFailed
        }
    }

    private static func removeInternalRecoveryFileIfPresent(
        directoryDescriptor: Int32,
        name: String
    ) throws {
        guard
            let identity = try directoryEntryIdentity(
                parentDescriptor: directoryDescriptor,
                name: name
            )
        else {
            return
        }
        guard identity.type == mode_t(S_IFREG) else {
            throw ControlledMirrorRecoveryError.changed
        }
        let descriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ControlledMirrorRecoveryError.changed }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            FileObjectIdentity(status) == identity,
            try directoryEntryIdentity(
                parentDescriptor: directoryDescriptor,
                name: name
            ) == identity
        else {
            throw ControlledMirrorRecoveryError.changed
        }
        let result = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
        guard result == 0 else { throw ControlledMirrorRecoveryError.disposalFailed }
    }

    /// Copies through an ignored, same-volume staging file and only installs
    /// it after the staged bytes, source, and destination still match the
    /// journal. Existing destinations are atomically swapped into `staging`
    /// and retained there until every post-commit check succeeds.
    fileprivate func copyFileAtomically(
        from source: URL,
        sourceRoot: URL,
        sourceRelativePath: String,
        sourceIsExternal: Bool,
        to destination: URL,
        destinationRoot: URL,
        destinationIsExternal: Bool,
        stagingAt staging: URL,
        operationID: UUID,
        destinationRelativePath: String,
        expectedSource: ControlledMirror.Fingerprint,
        expectedDestination: ControlledMirror.Fingerprint?,
        providerMeter: ControlledMirrorProviderMeterState
    ) throws {
        guard expectedSource.kind == .file,
            expectedDestination == nil || expectedDestination?.kind == .file
        else {
            throw AtomicCopyFailure.commitFailed
        }
        try Self.validatePath(source, within: sourceRoot, leafMayBeMissing: false)
        try Self.validatePath(destination, within: destinationRoot, leafMayBeMissing: true)
        try Self.validatePath(staging, within: destinationRoot, leafMayBeMissing: true)

        let incoming = staging.appendingPathExtension("incoming")
        let stageSourceEvent = controlledMirrorProviderEventPrefix(
            operationID: operationID,
            relativePath: sourceRelativePath,
            purpose: .stageSourceRead
        )
        let providerWriteEvent = controlledMirrorProviderEventPrefix(
            operationID: operationID,
            relativePath: destinationRelativePath,
            purpose: .stageProviderWrite
        )
        let incomingEvent = controlledMirrorProviderEventPrefix(
            operationID: operationID,
            relativePath: destinationRelativePath,
            purpose: .incomingRead
        )
        let sourceEvent = controlledMirrorProviderEventPrefix(
            operationID: operationID,
            relativePath: sourceRelativePath,
            purpose: .sourceRead
        )
        let oldEvent = controlledMirrorProviderEventPrefix(
            operationID: operationID,
            relativePath: destinationRelativePath,
            purpose: .oldRead
        )
        try Self.validatePath(incoming, within: destinationRoot, leafMayBeMissing: true)
        // The managed state tree is prepared at run start, but an export's
        // same-volume staging tree belongs to the external destination.
        // NSFileCoordinator cannot reliably coordinate a deep target whose
        // parent does not exist, and locality fallback is intentionally not
        // assumed for provider-backed volumes. Establish and revalidate the
        // ignored staging parent before asking the coordinated copier to create
        // its incoming file.
        do {
            try createDirectoryBody(staging.deletingLastPathComponent())
            try Self.validatePath(
                staging.deletingLastPathComponent(),
                within: destinationRoot,
                leafMayBeMissing: false
            )
        } catch {
            diagnose(.prepareStaging, error: error)
            if let failure = error as? AtomicCopyFailure { throw failure }
            throw AtomicCopyFailure.commitFailed
        }
        let sourceBinding: BoundPath
        let destinationBinding: BoundPath
        let stagingBinding: BoundPath
        let incomingBinding: BoundPath
        do {
            sourceBinding = try BoundPath(source, within: sourceRoot)
            destinationBinding = try BoundPath(destination, within: destinationRoot)
            stagingBinding = try BoundPath(staging, within: destinationRoot)
            incomingBinding = try BoundPath(incoming, within: destinationRoot)
        } catch {
            diagnose(.prepareStaging, error: error)
            throw AtomicCopyFailure.unsafePath
        }
        do {
            guard
                let sourceIdentity = try sourceBinding.payloadIdentity(),
                sourceIdentity.byteCount == expectedSource.byteCount
            else {
                throw AtomicCopyFailure.sourceChanged
            }
            let stagedData: Data
            if sourceIsExternal {
                stagedData = try providerMeter.performNext(
                    eventKeyPrefix: stageSourceEvent,
                    direction: .fromExternalProvider,
                    byteCount: expectedSource.byteCount,
                    validate: { Int64($0.count) == expectedSource.byteCount },
                    { transfer in
                        try beforeProviderPayloadIOBody(transfer)
                        return try readDataBoundedBody(
                            source,
                            expectedSource.byteCount,
                            sourceIdentity
                        )
                    }
                )
            } else {
                stagedData = try readDataBoundedBody(
                    source,
                    expectedSource.byteCount,
                    sourceIdentity
                )
            }
            guard Int64(stagedData.count) == expectedSource.byteCount,
                ControlledMirror.digest(stagedData) == expectedSource.contentDigest
            else {
                throw AtomicCopyFailure.sourceChanged
            }
            if destinationIsExternal {
                try providerMeter.performNext(
                    eventKeyPrefix: providerWriteEvent,
                    direction: .toExternalProvider,
                    byteCount: expectedSource.byteCount,
                    { transfer in
                        try beforeProviderPayloadIOBody(transfer)
                        try writeDataBody(stagedData, staging)
                        guard
                            try stagingBinding.payloadIdentity()?.byteCount
                                == expectedSource.byteCount
                        else {
                            throw AtomicCopyFailure.commitFailed
                        }
                    }
                )
            } else {
                try writeDataBody(stagedData, staging)
            }
            guard
                try providerProbe(
                    stagingBinding,
                    expectedByteCount: expectedSource.byteCount,
                    providerMeter: destinationIsExternal ? providerMeter : nil,
                    eventKeyPrefix: destinationIsExternal ? incomingEvent : nil
                ).matches(expectedSource)
            else {
                throw AtomicCopyFailure.sourceChanged
            }
            try Self.synchronizeRegularFile(stagingBinding)
            try beforeAtomicCopyCommitBody(source, destination, staging)
        } catch {
            diagnose(.stageCopy, error: error)
            try? Self.removeRegularFileOrLinkIfPresent(incomingBinding)
            try? Self.removeRegularFileOrLinkIfPresent(stagingBinding)
            if let failure = error as? AtomicCopyFailure {
                throw failure
            }
            throw AtomicCopyFailure.commitFailed
        }
        try? Self.removeRegularFileOrLinkIfPresent(incomingBinding)

        let commit: (URL, URL) throws -> Void = { coordinatedSource, coordinatedDestination in
            guard coordinatedSource.standardizedFileURL == source.standardizedFileURL,
                coordinatedDestination.standardizedFileURL == destination.standardizedFileURL
            else {
                throw AtomicCopyFailure.unsafePath
            }
            try Self.validatePath(coordinatedSource, within: sourceRoot, leafMayBeMissing: false)
            try Self.validatePath(
                coordinatedDestination,
                within: destinationRoot,
                leafMayBeMissing: true
            )
            try Self.validatePath(staging, within: destinationRoot, leafMayBeMissing: false)
            try sourceBinding.revalidate()
            try destinationBinding.revalidate()
            try stagingBinding.revalidate()
            try incomingBinding.revalidate()
            guard
                try providerProbe(
                    stagingBinding,
                    expectedByteCount: expectedSource.byteCount,
                    providerMeter: destinationIsExternal ? providerMeter : nil,
                    eventKeyPrefix: destinationIsExternal ? incomingEvent : nil
                ).matches(expectedSource)
            else {
                throw AtomicCopyFailure.sourceChanged
            }
            guard
                try providerProbe(
                    sourceBinding,
                    expectedByteCount: expectedSource.byteCount,
                    providerMeter: sourceIsExternal ? providerMeter : nil,
                    eventKeyPrefix: sourceIsExternal ? sourceEvent : nil
                ).matches(expectedSource)
            else {
                throw AtomicCopyFailure.sourceChanged
            }
            guard
                try providerPath(
                    destinationBinding,
                    matches: expectedDestination,
                    providerMeter: destinationIsExternal ? providerMeter : nil,
                    eventKeyPrefix: destinationIsExternal ? oldEvent : nil
                )
            else {
                throw AtomicCopyFailure.destinationChanged
            }
            try commitStagedFile(
                staging,
                to: coordinatedDestination,
                source: coordinatedSource,
                stagingBinding: stagingBinding,
                destinationBinding: destinationBinding,
                sourceBinding: sourceBinding,
                destinationRoot: destinationRoot,
                operationID: operationID,
                destinationRelativePath: destinationRelativePath,
                expectedSource: expectedSource,
                expectedDestination: expectedDestination,
                sourceIsExternal: sourceIsExternal,
                destinationIsExternal: destinationIsExternal,
                providerMeter: providerMeter,
                incomingEventKeyPrefix: incomingEvent,
                sourceEventKeyPrefix: sourceEvent,
                oldEventKeyPrefix: oldEvent
            )
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(
            readingItemAt: source,
            options: [],
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            result = Result { try commit(coordinatedSource, coordinatedDestination) }
        }

        do {
            if let result {
                try result.get()
            } else {
                let sourceIsLocal =
                    (try? source.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
                let destinationIsLocal =
                    (try? destination.deletingLastPathComponent().resourceValues(
                        forKeys: [.volumeIsLocalKey]
                    ).volumeIsLocal) == true
                guard sourceIsLocal, destinationIsLocal else {
                    throw coordinationError ?? CocoaError(.fileWriteUnknown)
                }
                try commit(source, destination)
            }
        } catch {
            diagnose(.coordinatedCommit, error: error)
            // Once an existing destination may have been swapped, `staging`
            // can be the only remaining link to its inode. Never unlink it on
            // an ambiguous failure; restart recovery will either retain it or
            // keep the journal pending.
            if case AtomicCopyFailure.rollbackFailed = error {
                throw error
            }
            if expectedDestination == nil {
                try? Self.removeRegularFileOrLinkIfPresent(stagingBinding)
            }
            if let failure = error as? AtomicCopyFailure {
                throw failure
            }
            throw AtomicCopyFailure.commitFailed
        }
    }

    /// Moves the candidate into an ignored quarantine before deleting it. The
    /// move is atomic, and both inode identity and content are checked after
    /// the move. If the path was replaced after planning, the moved object is
    /// restored instead of being deleted.
    fileprivate func removeItemIfUnchanged(
        at destination: URL,
        destinationRoot: URL,
        quarantineAt quarantine: URL,
        operationID: UUID,
        destinationRelativePath: String,
        expected: ControlledMirror.Fingerprint,
        destinationIsExternal: Bool,
        providerMeter: ControlledMirrorProviderMeterState
    ) throws {
        let deleteEvent = controlledMirrorProviderEventPrefix(
            operationID: operationID,
            relativePath: destinationRelativePath,
            purpose: .deleteRead
        )
        let payloadMeter =
            destinationIsExternal && expected.kind == .file ? providerMeter : nil
        let payloadEvent = payloadMeter == nil ? nil : deleteEvent
        try Self.validatePath(destination, within: destinationRoot, leafMayBeMissing: true)
        try Self.validatePath(quarantine, within: destinationRoot, leafMayBeMissing: true)
        let destinationBinding = try BoundPath(destination, within: destinationRoot)
        let quarantineBinding = try BoundPath(quarantine, within: destinationRoot)
        _ = try prepareRecovery(
            root: destinationRoot,
            rootBinding: destinationBinding,
            operationID: operationID,
            kind: .deleteQuarantine,
            relativePath: destinationRelativePath,
            expected: expected
        )

        let destinationIdentity = try destinationBinding.leafIdentity()
        let quarantineIdentity = try quarantineBinding.leafIdentity()
        switch (destinationIdentity, quarantineIdentity) {
        case (nil, nil):
            // A missing visible item is complete only when this exact
            // operation already has a durable retained recovery payload.
            try retainRecoverySource(
                quarantine,
                sourceBinding: quarantineBinding,
                root: destinationRoot,
                operationID: operationID,
                kind: .deleteQuarantine,
                relativePath: destinationRelativePath,
                expected: expected,
                expectedIdentity: nil,
                status: .retainedRequiresUserConfirmation,
                providerMeter: payloadMeter,
                providerEventKeyPrefix: payloadEvent,
                beforeMove: {}
            )
            return
        case (nil, let quarantined?):
            // A prior attempt moved the item but could not durably clean it.
            // The operation UUID makes this quarantine path stable across a
            // restart, so cleanup must be retried before deletion can finish.
            try cleanupQuarantinedItem(
                at: quarantine,
                quarantineBinding: quarantineBinding,
                destinationRoot: destinationRoot,
                operationID: operationID,
                destinationRelativePath: destinationRelativePath,
                expectedIdentity: quarantined,
                expected: expected,
                providerMeter: payloadMeter,
                providerEventKeyPrefix: payloadEvent
            )
            return
        case (_?, _?):
            // Never guess which copy belongs to this operation.
            throw AtomicCopyFailure.rollbackFailed
        case (let expectedIdentity?, nil):
            guard
                try providerPath(
                    destinationBinding,
                    matches: expected,
                    providerMeter: payloadMeter,
                    eventKeyPrefix: payloadEvent
                )
            else {
                throw AtomicCopyFailure.destinationChanged
            }

            try beforeDeleteCommitBody(destination)
            guard try destinationBinding.leafIdentity() == expectedIdentity,
                try providerPath(
                    destinationBinding,
                    matches: expected,
                    providerMeter: payloadMeter,
                    eventKeyPrefix: payloadEvent
                ),
                try quarantineBinding.leafIdentity() == nil
            else {
                throw AtomicCopyFailure.destinationChanged
            }
            do {
                try Self.rename(destinationBinding, quarantineBinding, flags: UInt32(RENAME_EXCL))
            } catch let error as POSIXError where error.code == .ENOENT {
                throw AtomicCopyFailure.destinationChanged
            } catch let error as POSIXError where error.code == .EEXIST {
                throw AtomicCopyFailure.rollbackFailed
            } catch {
                diagnose(.deleteMove, error: error)
                throw AtomicCopyFailure.commitFailed
            }

            guard let movedIdentity = try quarantineBinding.leafIdentity() else {
                throw AtomicCopyFailure.rollbackFailed
            }
            guard movedIdentity == expectedIdentity,
                try providerPath(
                    quarantineBinding,
                    matches: expected,
                    providerMeter: payloadMeter,
                    eventKeyPrefix: payloadEvent
                )
            else {
                atomicCopyDiagnosticBody(.deleteRollback, nil)
                // The atomic move captured a concurrently installed object.
                // Put that exact inode back only if the destination is still
                // absent.
                guard try destinationBinding.leafIdentity() == nil else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                do {
                    try Self.rename(quarantineBinding, destinationBinding, flags: UInt32(RENAME_EXCL))
                    guard try destinationBinding.leafIdentity() == movedIdentity else {
                        throw AtomicCopyFailure.rollbackFailed
                    }
                    try Self.synchronizeParent(destinationBinding)
                    try Self.synchronizeParent(quarantineBinding)
                } catch {
                    diagnose(.deleteRollback, error: error)
                    throw AtomicCopyFailure.rollbackFailed
                }
                throw AtomicCopyFailure.destinationChanged
            }

            try Self.synchronizeParent(destinationBinding)
            try Self.synchronizeParent(quarantineBinding)
            try cleanupQuarantinedItem(
                at: quarantine,
                quarantineBinding: quarantineBinding,
                destinationRoot: destinationRoot,
                operationID: operationID,
                destinationRelativePath: destinationRelativePath,
                expectedIdentity: expectedIdentity,
                expected: expected,
                providerMeter: payloadMeter,
                providerEventKeyPrefix: payloadEvent
            )
        }
    }

    fileprivate func completeCopyRecoveryIfNeeded(
        staging: URL,
        destinationRoot: URL,
        operationID: UUID,
        destinationRelativePath: String,
        expectedDestination: ControlledMirror.Fingerprint,
        destinationIsExternal: Bool,
        providerMeter: ControlledMirrorProviderMeterState
    ) throws {
        let resumeEvent = controlledMirrorProviderEventPrefix(
            operationID: operationID,
            relativePath: destinationRelativePath,
            purpose: .resumeOldRead
        )
        let stagingBinding = try BoundPath(staging, within: destinationRoot)
        try retainRecoverySource(
            staging,
            sourceBinding: stagingBinding,
            root: destinationRoot,
            operationID: operationID,
            kind: .copyBackup,
            relativePath: destinationRelativePath,
            expected: expectedDestination,
            expectedIdentity: try stagingBinding.leafIdentity(),
            status: .retainedRequiresUserConfirmation,
            providerMeter: destinationIsExternal ? providerMeter : nil,
            providerEventKeyPrefix: destinationIsExternal ? resumeEvent : nil,
            beforeMove: {}
        )
    }

    /// Verifies and removes the quarantined object as one cleanup attempt. A
    /// regular file stays open through both verification passes so writes via
    /// descriptors opened before the rename change the same inode we inspect.
    /// Any mismatch leaves the named quarantine and the journal pending for
    /// explicit/manual cleanup instead of silently unlinking newer bytes.
    private func cleanupQuarantinedItem(
        at quarantine: URL,
        quarantineBinding: BoundPath,
        destinationRoot: URL,
        operationID: UUID,
        destinationRelativePath: String,
        expectedIdentity: FileObjectIdentity,
        expected: ControlledMirror.Fingerprint,
        providerMeter: ControlledMirrorProviderMeterState?,
        providerEventKeyPrefix: String?
    ) throws {
        switch expected.kind {
        case .file:
            let descriptor = try quarantineBinding.openLeaf()
            defer { close(descriptor) }

            guard
                try providerRegularFileFingerprint(
                    descriptor: descriptor,
                    expectedIdentity: expectedIdentity,
                    expectedByteCount: expected.byteCount,
                    providerMeter: providerMeter,
                    eventKeyPrefix: providerEventKeyPrefix
                ) == expected,
                try quarantineBinding.leafIdentity() == expectedIdentity
            else {
                atomicCopyDiagnosticBody(.deleteRollback, nil)
                try? retainRecoverySource(
                    quarantine,
                    sourceBinding: quarantineBinding,
                    root: destinationRoot,
                    operationID: operationID,
                    kind: .deleteQuarantine,
                    relativePath: destinationRelativePath,
                    expected: expected,
                    expectedIdentity: expectedIdentity,
                    status: .conflictRequiresManualCleanup,
                    providerMeter: providerMeter,
                    providerEventKeyPrefix: providerEventKeyPrefix,
                    beforeMove: {}
                )
                throw AtomicCopyFailure.rollbackFailed
            }

            do {
                try afterDeleteVerificationBody(quarantine)
            } catch {
                diagnose(.deleteRollback, error: error)
                throw AtomicCopyFailure.rollbackFailed
            }

            // This is intentionally a second descriptor-based digest, not a
            // path re-open: a writer holding the pre-rename inode can mutate it
            // while the item is quarantined.
            guard
                try providerRegularFileFingerprint(
                    descriptor: descriptor,
                    expectedIdentity: expectedIdentity,
                    expectedByteCount: expected.byteCount,
                    providerMeter: providerMeter,
                    eventKeyPrefix: providerEventKeyPrefix
                ) == expected,
                try quarantineBinding.leafIdentity() == expectedIdentity
            else {
                atomicCopyDiagnosticBody(.deleteRollback, nil)
                try? retainRecoverySource(
                    quarantine,
                    sourceBinding: quarantineBinding,
                    root: destinationRoot,
                    operationID: operationID,
                    kind: .deleteQuarantine,
                    relativePath: destinationRelativePath,
                    expected: expected,
                    expectedIdentity: expectedIdentity,
                    status: .conflictRequiresManualCleanup,
                    providerMeter: providerMeter,
                    providerEventKeyPrefix: providerEventKeyPrefix,
                    beforeMove: {}
                )
                throw AtomicCopyFailure.rollbackFailed
            }
        case .directory:
            guard expectedIdentity.type == mode_t(S_IFDIR),
                try quarantineBinding.leafIdentity() == expectedIdentity,
                try Self.path(quarantineBinding, matches: expected)
            else {
                atomicCopyDiagnosticBody(.deleteRollback, nil)
                try? retainRecoverySource(
                    quarantine,
                    sourceBinding: quarantineBinding,
                    root: destinationRoot,
                    operationID: operationID,
                    kind: .deleteQuarantine,
                    relativePath: destinationRelativePath,
                    expected: expected,
                    expectedIdentity: expectedIdentity,
                    status: .conflictRequiresManualCleanup,
                    beforeMove: {}
                )
                throw AtomicCopyFailure.rollbackFailed
            }
            do {
                try afterDeleteVerificationBody(quarantine)
            } catch {
                diagnose(.deleteRollback, error: error)
                throw AtomicCopyFailure.rollbackFailed
            }
            guard try quarantineBinding.leafIdentity() == expectedIdentity,
                try Self.path(quarantineBinding, matches: expected)
            else {
                atomicCopyDiagnosticBody(.deleteRollback, nil)
                try? retainRecoverySource(
                    quarantine,
                    sourceBinding: quarantineBinding,
                    root: destinationRoot,
                    operationID: operationID,
                    kind: .deleteQuarantine,
                    relativePath: destinationRelativePath,
                    expected: expected,
                    expectedIdentity: expectedIdentity,
                    status: .conflictRequiresManualCleanup,
                    beforeMove: {}
                )
                throw AtomicCopyFailure.rollbackFailed
            }
        }

        do {
            try retainRecoverySource(
                quarantine,
                sourceBinding: quarantineBinding,
                root: destinationRoot,
                operationID: operationID,
                kind: .deleteQuarantine,
                relativePath: destinationRelativePath,
                expected: expected,
                expectedIdentity: expectedIdentity,
                status: .retainedRequiresUserConfirmation,
                providerMeter: providerMeter,
                providerEventKeyPrefix: providerEventKeyPrefix,
                beforeMove: { try beforeDeleteRecoveryRetentionBody(quarantine) }
            )
        } catch {
            diagnose(.deleteCleanup, error: error)
            // The operation stays incomplete unless the exact operation's
            // durable recovery record and payload were both committed.
            if let failure = error as? AtomicCopyFailure { throw failure }
            throw AtomicCopyFailure.commitFailed
        }
    }

    private static func regularFileFingerprint(
        descriptor: Int32,
        expectedIdentity: FileObjectIdentity,
        maximumByteCount: Int64? = nil
    ) throws -> ControlledMirror.Fingerprint? {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            FileObjectIdentity(before) == expectedIdentity
        else {
            return nil
        }
        if let maximumByteCount, maximumByteCount < 0 || before.st_size != maximumByteCount {
            return nil
        }
        let beforeIdentity = FileIdentity(before)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.seek(toOffset: 0)
        } catch {
            throw AtomicCopyFailure.commitFailed
        }
        var digest = SHA256()
        var byteCount: Int64 = 0
        do {
            if let maximumByteCount {
                while byteCount < maximumByteCount {
                    let remaining = maximumByteCount - byteCount
                    let requestCount = Int(min(Int64(1_048_576), remaining))
                    guard let chunk = try handle.read(upToCount: requestCount), !chunk.isEmpty else {
                        break
                    }
                    digest.update(data: chunk)
                    byteCount += Int64(chunk.count)
                }
            } else {
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    digest.update(data: chunk)
                    byteCount += Int64(chunk.count)
                }
            }
        } catch {
            throw AtomicCopyFailure.commitFailed
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw AtomicCopyFailure.commitFailed
        }
        guard beforeIdentity == FileIdentity(after), byteCount == after.st_size else {
            return nil
        }
        let contentDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return ControlledMirror.Fingerprint(
            kind: .file,
            contentDigest: contentDigest,
            byteCount: byteCount
        )
    }

    private func commitStagedFile(
        _ staging: URL,
        to destination: URL,
        source: URL,
        stagingBinding: BoundPath,
        destinationBinding: BoundPath,
        sourceBinding: BoundPath,
        destinationRoot: URL,
        operationID: UUID,
        destinationRelativePath: String,
        expectedSource: ControlledMirror.Fingerprint,
        expectedDestination: ControlledMirror.Fingerprint?,
        sourceIsExternal: Bool,
        destinationIsExternal: Bool,
        providerMeter: ControlledMirrorProviderMeterState,
        incomingEventKeyPrefix: String,
        sourceEventKeyPrefix: String,
        oldEventKeyPrefix: String
    ) throws {
        guard let incomingIdentity = try stagingBinding.leafIdentity() else {
            throw AtomicCopyFailure.commitFailed
        }
        if let expectedDestination {
            guard let backupIdentity = try destinationBinding.leafIdentity() else {
                throw AtomicCopyFailure.destinationChanged
            }
            _ = try prepareRecovery(
                root: destinationRoot,
                rootBinding: destinationBinding,
                operationID: operationID,
                kind: .copyBackup,
                relativePath: destinationRelativePath,
                expected: expectedDestination
            )
            do {
                try Self.rename(stagingBinding, destinationBinding, flags: UInt32(RENAME_SWAP))
            } catch {
                diagnose(.swapExisting, error: error)
                throw AtomicCopyFailure.commitFailed
            }
            do {
                try afterAtomicCopySwapBody(source, destination, staging)
                try Self.synchronizeRegularFile(destinationBinding)
                try Self.synchronizeParent(destinationBinding)
                try Self.synchronizeParent(stagingBinding)
                guard try destinationBinding.leafIdentity() == incomingIdentity,
                    try providerProbe(
                        destinationBinding,
                        expectedByteCount: expectedSource.byteCount,
                        providerMeter: destinationIsExternal ? providerMeter : nil,
                        eventKeyPrefix: destinationIsExternal ? incomingEventKeyPrefix : nil
                    ).matches(expectedSource)
                else {
                    throw AtomicCopyFailure.commitFailed
                }
                guard try stagingBinding.leafIdentity() == backupIdentity,
                    try providerProbe(
                        stagingBinding,
                        expectedByteCount: expectedDestination.byteCount,
                        providerMeter: destinationIsExternal ? providerMeter : nil,
                        eventKeyPrefix: destinationIsExternal ? oldEventKeyPrefix : nil
                    ).matches(expectedDestination)
                else {
                    throw AtomicCopyFailure.destinationChanged
                }
                guard
                    try providerProbe(
                        sourceBinding,
                        expectedByteCount: expectedSource.byteCount,
                        providerMeter: sourceIsExternal ? providerMeter : nil,
                        eventKeyPrefix: sourceIsExternal ? sourceEventKeyPrefix : nil
                    ).matches(expectedSource)
                else {
                    throw AtomicCopyFailure.sourceChanged
                }
            } catch {
                let validationError = error
                diagnose(.validateAfterSwap, error: error)
                // Never blindly swap during rollback. A concurrent writer may
                // already have replaced the installed bytes; swapping then
                // cleaning staging would move and delete that newer version.
                guard try destinationBinding.leafIdentity() == incomingIdentity,
                    try providerProbe(
                        destinationBinding,
                        expectedByteCount: expectedSource.byteCount,
                        providerMeter: destinationIsExternal ? providerMeter : nil,
                        eventKeyPrefix: destinationIsExternal ? incomingEventKeyPrefix : nil
                    ).matches(expectedSource),
                    try stagingBinding.leafIdentity() == backupIdentity,
                    try providerProbe(
                        stagingBinding,
                        expectedByteCount: expectedDestination.byteCount,
                        providerMeter: destinationIsExternal ? providerMeter : nil,
                        eventKeyPrefix: destinationIsExternal ? oldEventKeyPrefix : nil
                    ).matches(expectedDestination)
                else {
                    atomicCopyDiagnosticBody(.rollbackSwap, nil)
                    if try stagingBinding.leafIdentity() == backupIdentity {
                        try? retainRecoverySource(
                            staging,
                            sourceBinding: stagingBinding,
                            root: destinationRoot,
                            operationID: operationID,
                            kind: .copyBackup,
                            relativePath: destinationRelativePath,
                            expected: expectedDestination,
                            expectedIdentity: backupIdentity,
                            status: .conflictRequiresManualCleanup,
                            providerMeter: destinationIsExternal ? providerMeter : nil,
                            providerEventKeyPrefix: destinationIsExternal
                                ? oldEventKeyPrefix : nil,
                            beforeMove: {}
                        )
                    }
                    throw AtomicCopyFailure.rollbackFailed
                }
                atomicCopyDiagnosticBody(.rollbackSwap, nil)
                do {
                    try Self.rename(stagingBinding, destinationBinding, flags: UInt32(RENAME_SWAP))
                    guard try destinationBinding.leafIdentity() == backupIdentity,
                        try providerProbe(
                            destinationBinding,
                            expectedByteCount: expectedDestination.byteCount,
                            providerMeter: destinationIsExternal ? providerMeter : nil,
                            eventKeyPrefix: destinationIsExternal ? oldEventKeyPrefix : nil
                        ).matches(expectedDestination),
                        try stagingBinding.leafIdentity() == incomingIdentity,
                        try providerProbe(
                            stagingBinding,
                            expectedByteCount: expectedSource.byteCount,
                            providerMeter: destinationIsExternal ? providerMeter : nil,
                            eventKeyPrefix: destinationIsExternal ? incomingEventKeyPrefix : nil
                        ).matches(expectedSource)
                    else {
                        throw AtomicCopyFailure.rollbackFailed
                    }
                    try Self.synchronizeRegularFile(destinationBinding)
                    try Self.synchronizeParent(destinationBinding)
                    try Self.synchronizeParent(stagingBinding)
                } catch {
                    diagnose(.rollbackSwap, error: error)
                    throw AtomicCopyFailure.rollbackFailed
                }
                throw validationError
            }
            guard try stagingBinding.leafIdentity() == backupIdentity,
                try providerProbe(
                    stagingBinding,
                    expectedByteCount: expectedDestination.byteCount,
                    providerMeter: destinationIsExternal ? providerMeter : nil,
                    eventKeyPrefix: destinationIsExternal ? oldEventKeyPrefix : nil
                ).matches(expectedDestination)
            else {
                try? retainRecoverySource(
                    staging,
                    sourceBinding: stagingBinding,
                    root: destinationRoot,
                    operationID: operationID,
                    kind: .copyBackup,
                    relativePath: destinationRelativePath,
                    expected: expectedDestination,
                    expectedIdentity: backupIdentity,
                    status: .conflictRequiresManualCleanup,
                    providerMeter: destinationIsExternal ? providerMeter : nil,
                    providerEventKeyPrefix: destinationIsExternal ? oldEventKeyPrefix : nil,
                    beforeMove: {}
                )
                throw AtomicCopyFailure.rollbackFailed
            }
            try retainRecoverySource(
                staging,
                sourceBinding: stagingBinding,
                root: destinationRoot,
                operationID: operationID,
                kind: .copyBackup,
                relativePath: destinationRelativePath,
                expected: expectedDestination,
                expectedIdentity: backupIdentity,
                status: .retainedRequiresUserConfirmation,
                providerMeter: destinationIsExternal ? providerMeter : nil,
                providerEventKeyPrefix: destinationIsExternal ? oldEventKeyPrefix : nil,
                beforeMove: { try beforeCopyBackupRetentionBody(staging) }
            )
            return
        }

        do {
            try Self.rename(stagingBinding, destinationBinding, flags: UInt32(RENAME_EXCL))
        } catch let error as POSIXError where error.code == .EEXIST {
            throw AtomicCopyFailure.destinationChanged
        } catch {
            diagnose(.installMissing, error: error)
            throw AtomicCopyFailure.commitFailed
        }
        do {
            try Self.synchronizeRegularFile(destinationBinding)
            try Self.synchronizeParent(destinationBinding)
            try Self.synchronizeParent(stagingBinding)
            guard try destinationBinding.leafIdentity() == incomingIdentity,
                try providerProbe(
                    destinationBinding,
                    expectedByteCount: expectedSource.byteCount,
                    providerMeter: destinationIsExternal ? providerMeter : nil,
                    eventKeyPrefix: destinationIsExternal ? incomingEventKeyPrefix : nil
                ).matches(expectedSource)
            else {
                throw AtomicCopyFailure.commitFailed
            }
            guard
                try providerProbe(
                    sourceBinding,
                    expectedByteCount: expectedSource.byteCount,
                    providerMeter: sourceIsExternal ? providerMeter : nil,
                    eventKeyPrefix: sourceIsExternal ? sourceEventKeyPrefix : nil
                ).matches(expectedSource)
            else {
                throw AtomicCopyFailure.sourceChanged
            }
        } catch {
            let validationError = error
            diagnose(.validateInstall, error: error)
            guard try destinationBinding.leafIdentity() == incomingIdentity,
                try providerProbe(
                    destinationBinding,
                    expectedByteCount: expectedSource.byteCount,
                    providerMeter: destinationIsExternal ? providerMeter : nil,
                    eventKeyPrefix: destinationIsExternal ? incomingEventKeyPrefix : nil
                ).matches(expectedSource)
            else {
                atomicCopyDiagnosticBody(.rollbackInstall, nil)
                throw AtomicCopyFailure.rollbackFailed
            }
            atomicCopyDiagnosticBody(.rollbackInstall, nil)
            do {
                try Self.rename(destinationBinding, stagingBinding, flags: UInt32(RENAME_EXCL))
                guard try stagingBinding.leafIdentity() == incomingIdentity,
                    try providerProbe(
                        stagingBinding,
                        expectedByteCount: expectedSource.byteCount,
                        providerMeter: destinationIsExternal ? providerMeter : nil,
                        eventKeyPrefix: destinationIsExternal ? incomingEventKeyPrefix : nil
                    ).matches(expectedSource)
                else {
                    throw AtomicCopyFailure.rollbackFailed
                }
                try Self.synchronizeParent(destinationBinding)
                try Self.synchronizeParent(stagingBinding)
            } catch {
                diagnose(.rollbackInstall, error: error)
                throw AtomicCopyFailure.rollbackFailed
            }
            throw validationError
        }
    }

    private static func probe(
        _ url: URL,
        expectedByteCount: Int64
    ) throws -> FileProbe {
        guard expectedByteCount >= 0 else { return .unstable }
        var linkStatus = stat()
        let linkResult = url.path.withCString { lstat($0, &linkStatus) }
        if linkResult != 0 {
            if errno == ENOENT { return .missing }
            throw AtomicCopyFailure.commitFailed
        }
        let linkType = linkStatus.st_mode & mode_t(S_IFMT)
        if linkType == mode_t(S_IFLNK) { return .symbolicLink }
        guard linkType == mode_t(S_IFREG) else { return .other }

        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return .missing }
            if errno == ELOOP { return .symbolicLink }
            throw AtomicCopyFailure.commitFailed
        }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_size == expectedByteCount
        else {
            throw AtomicCopyFailure.commitFailed
        }
        let beforeIdentity = FileIdentity(before)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var digest = SHA256()
        var byteCount: Int64 = 0
        do {
            while byteCount < expectedByteCount {
                let request = Int(min(expectedByteCount - byteCount, 1_048_576))
                guard let chunk = try handle.read(upToCount: request), !chunk.isEmpty else {
                    return .unstable
                }
                digest.update(data: chunk)
                byteCount += Int64(chunk.count)
            }
        } catch {
            throw AtomicCopyFailure.commitFailed
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw AtomicCopyFailure.commitFailed
        }
        guard beforeIdentity == FileIdentity(after),
            byteCount == expectedByteCount,
            after.st_size == expectedByteCount
        else {
            return .unstable
        }
        let contentDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return .file(
            ControlledMirror.Fingerprint(
                kind: .file,
                contentDigest: contentDigest,
                byteCount: byteCount
            )
        )
    }

    private static func objectIdentity(at url: URL) throws -> FileObjectIdentity? {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw AtomicCopyFailure.commitFailed
        }
        let identity = FileObjectIdentity(status)
        guard identity.type != mode_t(S_IFLNK) else {
            throw AtomicCopyFailure.unsafePath
        }
        return identity
    }

    private static func path(
        _ url: URL,
        matches expected: ControlledMirror.Fingerprint
    ) throws -> Bool {
        switch expected.kind {
        case .file:
            return try probe(url, expectedByteCount: expected.byteCount).matches(expected)
        case .directory:
            guard try objectIdentity(at: url)?.type == mode_t(S_IFDIR) else { return false }
            return try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty
        }
    }

    private static func validatePath(
        _ url: URL,
        within root: URL,
        leafMayBeMissing: Bool
    ) throws {
        let canonicalRoot = root.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate != canonicalRoot, ControlledMirror.contains(canonicalRoot, candidate) else {
            throw AtomicCopyFailure.unsafePath
        }

        var current = canonicalRoot
        let relativeComponents = candidate.pathComponents.dropFirst(canonicalRoot.pathComponents.count)
        for (index, component) in relativeComponents.enumerated() {
            current.appendPathComponent(component)
            var status = stat()
            let result = current.path.withCString { lstat($0, &status) }
            if result != 0 {
                if errno == ENOENT, leafMayBeMissing {
                    return
                }
                throw AtomicCopyFailure.unsafePath
            }
            let itemType = status.st_mode & mode_t(S_IFMT)
            guard itemType != mode_t(S_IFLNK) else {
                throw AtomicCopyFailure.unsafePath
            }
            if index < relativeComponents.count - 1, itemType != mode_t(S_IFDIR) {
                throw AtomicCopyFailure.unsafePath
            }
        }
    }

    private static func synchronizeRegularFile(at url: URL) throws {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw AtomicCopyFailure.commitFailed }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            fsync(descriptor) == 0
        else {
            throw AtomicCopyFailure.commitFailed
        }
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw AtomicCopyFailure.commitFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw AtomicCopyFailure.commitFailed }
    }

    private static func rename(_ source: URL, _ destination: URL, flags: UInt32) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, flags)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func removeRegularFileOrLinkIfPresent(at url: URL) throws {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        if result != 0 {
            if errno == ENOENT { return }
            throw AtomicCopyFailure.commitFailed
        }
        let itemType = status.st_mode & mode_t(S_IFMT)
        guard itemType == mode_t(S_IFREG) || itemType == mode_t(S_IFLNK) else {
            throw AtomicCopyFailure.unsafePath
        }
        guard url.path.withCString({ unlink($0) }) == 0 else {
            throw AtomicCopyFailure.commitFailed
        }
    }
}

public actor ControlledMirror {
    /// Mirror bookkeeping lives inside Syncthing's reserved marker directory.
    /// The core never indexes this directory, so the App does not need to add
    /// or maintain any rule in the user's `.stignore` file.
    public static let stateDirectoryName = ".stfolder"
    public static let manifestFileName = "manifest.json"
    public static let journalFileName = "journal.json"

    public let managedRoot: URL
    public let externalRoot: URL
    public let mode: ExternalDirectoryMode

    private let io: ControlledMirrorIO

    public init(
        managedRoot: URL,
        externalRoot: URL,
        mode: ExternalDirectoryMode,
        io: ControlledMirrorIO = .coordinated
    ) {
        self.managedRoot = managedRoot
        self.externalRoot = externalRoot
        self.mode = mode
        self.io = io
    }

    func synchronize() throws -> ControlledMirrorRunResult {
        let prepared = try prepareSynchronization()
        if prepared.stage == .apply {
            return try apply(prepared, meter: .unmetered)
        }
        let observed = try observeSynchronization(prepared, meter: .unmetered)
        let applyPlan = try commitObservedPlan(observed)
        return try apply(applyPlan, meter: .unmetered)
    }

    /// Descriptor-relative enumerate/fstat only. This returns the finite bound
    /// for the observation hashes without reading any managed or provider
    /// payload and without creating a journal.
    public func prepareSynchronization() throws -> ControlledMirrorPreparedPlan {
        guard mode != .direct else {
            throw ControlledMirrorFailure(code: .unsupportedMode)
        }
        let roots = try preparedRoots()
        try prepareStateDirectories(roots: roots, mode: mode)
        let previousManifest = try loadManifest(roots: roots, mode: mode)

        if let journal = try loadJournal(roots: roots, mode: mode),
            journal.phase == .planned || journal.phase == .applying
        {
            return try preparedPlan(for: journal)
        }
        return try preparedObservation(
            roots: roots,
            previousManifest: previousManifest,
            purpose: .synchronization
        )
    }

    /// Performs exactly the hashes authorized by a metadata-only observation
    /// plan. The returned draft remains in memory; callers settle this stage
    /// before `commitObservedPlan` durably creates the journal.
    public func observeSynchronization(
        _ prepared: ControlledMirrorPreparedPlan,
        meter: ControlledMirrorTransferMeter
    ) throws -> ControlledMirrorObservedPlan {
        try observe(prepared, expectedPurpose: .synchronization, meter: meter)
    }

    /// Persists a journal only after the broker has durably settled the
    /// observation session, then derives a distinct finite apply subgrant.
    public func commitObservedPlan(
        _ observed: ControlledMirrorObservedPlan
    ) throws -> ControlledMirrorPreparedPlan {
        let roots = try preparedRoots()
        let draft = observed.draft
        guard draft.runID == observed.runID,
            draft.accountingPlanDigest == observed.planDigest
        else {
            throw ControlledMirrorPreparedPlanError.changed
        }
        if let existing = try loadJournal(roots: roots, mode: mode),
            existing.phase == .planned || existing.phase == .applying
        {
            throw ControlledMirrorPreparedPlanError.changed
        }
        let isNoOp: Bool
        if let previous = draft.previousManifest {
            isNoOp =
                draft.plan.operations.isEmpty
                && draft.plan.conflicts.isEmpty
                && draft.plan.confirmations == previous.pendingConfirmations
                && draft.snapshot.manifestEntries == previous.entries
        } else {
            isNoOp = false
        }
        let nextGeneration =
            isNoOp
            ? draft.previousManifest?.generation ?? 0
            : (draft.previousManifest?.generation ?? 0) + 1
        let journal = MirrorJournal(
            schemaVersion: Self.journalSchemaVersion,
            runID: draft.runID,
            accountingPlanDigest: draft.accountingPlanDigest,
            targetGeneration: nextGeneration,
            mode: mode,
            phase: .planned,
            operations: draft.plan.operations,
            expectedEntries: draft.plan.expectedEntries,
            conflicts: draft.plan.conflicts,
            confirmations: draft.plan.confirmations
        )
        try persistJournal(journal, roots: roots)
        return try preparedPlan(for: journal)
    }

    /// Applies only the exact plan returned by `prepareSynchronization()`.
    /// A changed/replaced journal fails before logical provider payload I/O.
    public func apply(
        _ prepared: ControlledMirrorPreparedPlan,
        meter: ControlledMirrorTransferMeter
    ) throws -> ControlledMirrorRunResult {
        guard mode != .direct else {
            throw ControlledMirrorFailure(code: .unsupportedMode)
        }
        guard prepared.stage == .apply else {
            throw ControlledMirrorPreparedPlanError.changed
        }
        let roots = try preparedRoots()
        try prepareStateDirectories(roots: roots, mode: mode)
        let previousManifest = try loadManifest(roots: roots, mode: mode)
        let providerMeter = ControlledMirrorProviderMeterState(
            expectations: prepared.logicalTransfers,
            meter: meter
        )

        if var journal = try loadJournal(roots: roots, mode: mode) {
            let current = try preparedPlan(for: journal)
            if current.runID == prepared.runID,
                current.planDigest == prepared.planDigest,
                current.maximumLogicalProviderBytes == prepared.maximumLogicalProviderBytes
            {
                switch journal.phase {
                case .planned, .applying:
                    return try resume(
                        journal: &journal,
                        previousManifest: previousManifest,
                        roots: roots,
                        providerMeter: providerMeter
                    )
                case .committed:
                    return result(for: journal)
                case .aborted:
                    throw ControlledMirrorPreparedPlanError.changed
                }
            }
            if journal.phase == .planned || journal.phase == .applying {
                throw ControlledMirrorPreparedPlanError.changed
            }
        }

        _ = previousManifest
        throw ControlledMirrorPreparedPlanError.changed
    }

    /// Produces a finite provider-byte plan using recovery records plus fstat;
    /// no recovery payload content is read by this preparation step.
    func prepareRecoverySummaries() throws -> ControlledMirrorPreparedRecovery {
        let roots = try preparedRoots()
        let reads = try io.recoveryReadBounds(root: roots.external, side: .external)
        return try preparedRecovery(scope: .summaries, bounds: reads)
    }

    /// Returns only relative, content-fenced recovery metadata. Every external
    /// payload fingerprint is matched to and metered against `prepared`.
    func recoverySummaries(
        _ prepared: ControlledMirrorPreparedRecovery,
        meter: ControlledMirrorTransferMeter
    ) throws -> [ControlledMirrorRecoverySummary] {
        guard case .summaries = prepared.scope else {
            throw ControlledMirrorPreparedRecoveryError.changed
        }
        let roots = try preparedRoots()
        let currentReads = try io.recoveryReadBounds(root: roots.external, side: .external)
        guard currentReads == prepared.reads.map(\.bound) else {
            throw ControlledMirrorPreparedRecoveryError.changed
        }
        let recoveryMeter = ControlledMirrorRecoveryMeterState(
            expectations: prepared.reads,
            meter: meter
        )
        do {
            let activeOperationIDs = try activeRecoveryOperationIDs(roots: roots)
            let summaries = try
                (io.recoverySummaries(root: roots.managed, side: .managed)
                + io.recoverySummaries(
                    root: roots.external,
                    side: .external,
                    recoveryMeter: recoveryMeter
                )).sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id < $1.id
                }.map {
                    $0.withActiveJournalReference(activeOperationIDs.contains($0.operationID))
                }
            try recoveryMeter.requireFullyConsumed()
            return summaries
        } catch let error as ControlledMirrorRecoveryError {
            throw error
        } catch ControlledMirrorIO.AtomicCopyFailure.commitFailed {
            throw ControlledMirrorRecoveryError.disposalFailed
        } catch {
            throw ControlledMirrorRecoveryError.changed
        }
    }

    /// Module-internal compatibility for direct ControlledMirror tests. The
    /// product broker always supplies a durable accounting meter.
    func recoverySummaries() throws -> [ControlledMirrorRecoverySummary] {
        let prepared = try prepareRecoverySummaries()
        return try recoverySummaries(prepared, meter: .unmetered)
    }

    /// Prepares the summary verification plus the one streaming snapshot read
    /// needed to export an exact recovery payload. Provider-backed directories
    /// remain fail-closed because no finite recursive byte bound exists.
    func prepareRecoveryExport(
        _ requested: ControlledMirrorRecoverySummary
    ) throws -> ControlledMirrorPreparedRecovery {
        let roots = try preparedRoots()
        let initialBounds: [RecoveryReadBound]
        if requested.side == .external {
            initialBounds = try io.recoveryReadBounds(
                root: roots.external,
                side: .external,
                operationIDFilter: requested.operationID
            )
        } else {
            initialBounds = []
        }
        guard initialBounds.count <= 1 else {
            throw ControlledMirrorPreparedRecoveryError.changed
        }
        let bounds = initialBounds.flatMap { [$0, $0] }
        return try preparedRecovery(scope: .export(requested: requested), bounds: bounds)
    }

    /// Creates a private, content-fenced snapshot for an explicit system share.
    /// The retained source remains unchanged and its internal path is never
    /// returned to the caller.
    func exportRecovery(
        _ prepared: ControlledMirrorPreparedRecovery,
        to outputDirectory: URL,
        authorization: @Sendable (ControlledMirrorRecoverySummary) throws -> Bool,
        meter: ControlledMirrorTransferMeter
    ) throws -> ControlledMirrorRecoveryExport {
        guard case .export(let requested) = prepared.scope else {
            throw ControlledMirrorPreparedRecoveryError.changed
        }
        let roots = try preparedRoots()
        let initialBounds: [RecoveryReadBound]
        if requested.side == .external {
            initialBounds = try io.recoveryReadBounds(
                root: roots.external,
                side: .external,
                operationIDFilter: requested.operationID
            )
        } else {
            initialBounds = []
        }
        guard initialBounds.flatMap({ [$0, $0] }) == prepared.reads.map(\.bound) else {
            throw ControlledMirrorPreparedRecoveryError.changed
        }
        let recoveryMeter = ControlledMirrorRecoveryMeterState(
            expectations: prepared.reads,
            meter: meter
        )
        do {
            let export = try io.exportRecovery(
                root: roots.url(for: requested.side),
                side: requested.side,
                requested: requested.withActiveJournalReference(false),
                to: outputDirectory,
                recoveryMeter: requested.side == .external ? recoveryMeter : nil,
                authorization: { current in
                    try authorization(
                        current.withActiveJournalReference(
                            requested.isReferencedByActiveJournal
                        )
                    )
                }
            )
            try recoveryMeter.requireFullyConsumed()
            return export
        } catch let error as ControlledMirrorRecoveryError {
            throw error
        } catch {
            throw error
        }
    }

    static func removeRecoveryExport(
        _ export: ControlledMirrorRecoveryExport,
        from outputDirectory: URL
    ) throws {
        try ControlledMirrorIO.removeRecoveryExport(export, from: outputDirectory)
    }

    static func removeTemporaryRecoveryExports(from outputDirectory: URL) throws {
        try ControlledMirrorIO.removeTemporaryRecoveryExports(from: outputDirectory)
    }

    /// Prepares the exact finite read sequence for one recovery decision. A
    /// delete needs four content fences; retain needs the initial summary read.
    func prepareRecoveryResolution(
        _ requested: ControlledMirrorRecoverySummary,
        decision: ControlledMirrorRecoveryDecision
    ) throws -> ControlledMirrorPreparedRecovery {
        let roots = try preparedRoots()
        let activeOperationIDs = try activeRecoveryOperationIDs(roots: roots)
        guard
            requested.isReferencedByActiveJournal
                == activeOperationIDs.contains(requested.operationID)
        else {
            throw ControlledMirrorRecoveryError.changed
        }
        if decision == .deleteAfterUserConfirmation,
            requested.isReferencedByActiveJournal
        {
            throw ControlledMirrorRecoveryError.activeJournal
        }
        let initialBounds: [RecoveryReadBound]
        if requested.side == .external {
            initialBounds = try io.recoveryReadBounds(
                root: roots.external,
                side: .external,
                operationIDFilter: requested.operationID
            )
        } else {
            initialBounds = []
        }
        guard initialBounds.count <= 1 else {
            throw ControlledMirrorPreparedRecoveryError.changed
        }
        let bounds = Self.resolutionReadBounds(
            initial: initialBounds,
            decision: decision
        )
        return try preparedRecovery(
            scope: .resolution(requested: requested, decision: decision),
            bounds: bounds
        )
    }

    /// Resolves an exact recovery summary. The caller must supply a live owner,
    /// authorization, and policy fence; deletion re-evaluates it immediately
    /// before touching the retained payload.
    func resolveRecovery(
        _ prepared: ControlledMirrorPreparedRecovery,
        authorization: @Sendable (ControlledMirrorRecoverySummary) throws -> Bool,
        meter: ControlledMirrorTransferMeter
    ) throws {
        guard
            case .resolution(let requested, let decision) = prepared.scope
        else {
            throw ControlledMirrorPreparedRecoveryError.changed
        }
        let roots = try preparedRoots()
        let activeOperationIDs = try activeRecoveryOperationIDs(roots: roots)
        let isActive = activeOperationIDs.contains(requested.operationID)
        guard requested.isReferencedByActiveJournal == isActive else {
            throw ControlledMirrorRecoveryError.changed
        }
        if decision == .deleteAfterUserConfirmation, isActive {
            throw ControlledMirrorRecoveryError.activeJournal
        }
        let initialBounds: [RecoveryReadBound]
        if requested.side == .external {
            initialBounds = try io.recoveryReadBounds(
                root: roots.external,
                side: .external,
                operationIDFilter: requested.operationID
            )
        } else {
            initialBounds = []
        }
        let currentReads = Self.resolutionReadBounds(
            initial: initialBounds,
            decision: decision
        )
        guard currentReads == prepared.reads.map(\.bound) else {
            throw ControlledMirrorPreparedRecoveryError.changed
        }
        let recoveryMeter = ControlledMirrorRecoveryMeterState(
            expectations: prepared.reads,
            meter: meter
        )
        let root = roots.url(for: requested.side)
        let undecoratedRequest = requested.withActiveJournalReference(false)
        do {
            try io.resolveRecovery(
                root: root,
                side: requested.side,
                requested: undecoratedRequest,
                decision: decision,
                recoveryMeter: recoveryMeter,
                authorization: { current in
                    try authorization(current.withActiveJournalReference(isActive))
                }
            )
            try recoveryMeter.requireFullyConsumed()
        } catch let error as ControlledMirrorRecoveryError {
            throw error
        } catch ControlledMirrorIO.AtomicCopyFailure.commitFailed {
            throw ControlledMirrorRecoveryError.disposalFailed
        } catch {
            throw error
        }
    }

    /// Module-internal compatibility for direct ControlledMirror tests.
    func resolveRecovery(
        _ requested: ControlledMirrorRecoverySummary,
        decision: ControlledMirrorRecoveryDecision,
        authorization: @Sendable (ControlledMirrorRecoverySummary) throws -> Bool
    ) throws {
        let prepared = try prepareRecoveryResolution(requested, decision: decision)
        try resolveRecovery(
            prepared,
            authorization: authorization,
            meter: .unmetered
        )
    }

    private func preparedRecovery(
        scope: RecoveryScope,
        bounds: [RecoveryReadBound]
    ) throws -> ControlledMirrorPreparedRecovery {
        let scopeKind: String
        let requested: ControlledMirrorRecoverySummary?
        let decision: ControlledMirrorRecoveryDecision?
        switch scope {
        case .summaries:
            scopeKind = "summaries"
            requested = nil
            decision = nil
        case .export(let value):
            scopeKind = "export"
            requested = value
            decision = nil
        case .resolution(let value, let valueDecision):
            scopeKind = "resolution"
            requested = value
            decision = valueDecision
        }
        let digestPayload = RecoveryPlanDigestPayload(
            schemaVersion: 1,
            scopeKind: scopeKind,
            requested: requested,
            decision: decision,
            reads: bounds
        )
        let encoded: Data
        do {
            encoded = try Self.encoder.encode(digestPayload)
        } catch {
            throw ControlledMirrorPreparedRecoveryError.changed
        }
        var maximumBytes: Int64 = 0
        var expectations: [RecoveryReadExpectation] = []
        expectations.reserveCapacity(bounds.count)
        for bound in bounds {
            guard bound.byteCount >= 0 else {
                throw ControlledMirrorPreparedRecoveryError.unboundedExternalPayload
            }
            let (next, overflow) = maximumBytes.addingReportingOverflow(bound.byteCount)
            guard !overflow else {
                throw ControlledMirrorPreparedRecoveryError.byteCountOverflow
            }
            maximumBytes = next
            expectations.append(
                RecoveryReadExpectation(
                    bound: bound,
                    transfer: ControlledMirrorLogicalTransfer(
                        id: UUID(),
                        direction: .readExternalProvider,
                        byteCount: bound.byteCount,
                        isCompleted: false
                    )
                )
            )
        }
        let plan = ControlledMirrorPreparedPlan(
            runID: UUID(),
            planDigest: Self.digest(encoded),
            stage: .recovery,
            logicalTransfers: expectations.map(\.transfer),
            maximumLogicalProviderBytes: maximumBytes,
            remainingLogicalProviderBytes: maximumBytes
        )
        return ControlledMirrorPreparedRecovery(
            plan: plan,
            scope: scope,
            reads: expectations
        )
    }

    private static func resolutionReadBounds(
        initial: [RecoveryReadBound],
        decision: ControlledMirrorRecoveryDecision
    ) -> [RecoveryReadBound] {
        guard let first = initial.first else { return [] }
        switch decision {
        case .retain:
            return [first]
        case .deleteAfterUserConfirmation:
            let disposing = RecoveryReadBound(
                operationID: first.operationID,
                side: first.side,
                payloadName: ControlledMirrorIO.recoveryDisposingPayloadName,
                byteCount: first.byteCount
            )
            return [first, first, first, disposing]
        }
    }

    private func activeRecoveryOperationIDs(roots: Roots) throws -> Set<UUID> {
        guard let journal = try loadJournal(roots: roots, mode: mode),
            journal.phase == .planned || journal.phase == .applying
        else {
            return []
        }
        return Set(journal.operations.map(\.id))
    }

    /// Returns only a pre-existing interrupted journal. Unlike
    /// `prepareSynchronization`, this never scans into or creates unrelated
    /// synchronization work while a user confirmation is being resolved.
    func prepareInterruptedSynchronization() throws -> ControlledMirrorPreparedPlan? {
        guard mode != .direct else {
            throw ControlledMirrorFailure(code: .unsupportedMode)
        }
        let roots = try preparedRoots()
        try prepareStateDirectories(roots: roots, mode: mode)
        guard let journal = try loadJournal(roots: roots, mode: mode),
            journal.phase == .planned || journal.phase == .applying
        else {
            return nil
        }
        return try preparedPlan(for: journal)
    }

    func isResumableJournal(for prepared: ControlledMirrorPreparedPlan) throws -> Bool {
        guard prepared.stage == .apply else { return false }
        return try hasResumableJournal(
            runID: prepared.runID,
            planDigest: prepared.planDigest
        )
    }

    func hasResumableJournal(runID: UUID, planDigest: String) throws -> Bool {
        let roots = try preparedRoots()
        guard let journal = try loadJournal(roots: roots, mode: mode),
            journal.runID == runID,
            journal.accountingPlanDigest == planDigest
        else {
            return false
        }
        return journal.phase == .planned || journal.phase == .applying
    }

    /// Metadata-only confirmation planning. The prompt identity is checked
    /// from managed state, while provider bytes remain untouched until the
    /// returned finite observation stage has a live accounting session.
    func prepareConfirmation(
        _ requestedConfirmation: ControlledMirrorConfirmation,
        decision: ControlledMirrorConfirmationDecision
    ) throws -> ControlledMirrorPreparedPlan {
        let roots = try preparedRoots()
        try prepareStateDirectories(roots: roots, mode: mode)
        if let interrupted = try loadJournal(roots: roots, mode: mode),
            interrupted.phase == .planned || interrupted.phase == .applying
        {
            throw ControlledMirrorPreparedPlanError.changed
        }
        guard let manifest = try loadManifest(roots: roots, mode: mode),
            let confirmation = manifest.pendingConfirmations.first(where: {
                $0.id == requestedConfirmation.id
            })
        else {
            throw ControlledMirrorFailure(code: .confirmationNotFound)
        }
        guard confirmation == requestedConfirmation else {
            throw ControlledMirrorFailure(
                code: .confirmationChanged,
                relativePath: requestedConfirmation.relativePath
            )
        }
        return try preparedObservation(
            roots: roots,
            previousManifest: manifest,
            purpose: .confirmation(requestedConfirmation, decision)
        )
    }

    func observeConfirmation(
        _ prepared: ControlledMirrorPreparedPlan,
        requestedConfirmation: ControlledMirrorConfirmation,
        decision: ControlledMirrorConfirmationDecision,
        meter: ControlledMirrorTransferMeter
    ) throws -> ControlledMirrorObservedPlan {
        try observe(
            prepared,
            expectedPurpose: .confirmation(requestedConfirmation, decision),
            meter: meter
        )
    }

    /// Test-only/module-internal compatibility seam. Product broker entry
    /// points use the finite prepare/reserve/apply lifecycle above.
    func resolveConfirmation(
        _ requestedConfirmation: ControlledMirrorConfirmation,
        decision: ControlledMirrorConfirmationDecision
    ) throws -> ControlledMirrorRunResult {
        if let interrupted = try prepareInterruptedSynchronization() {
            _ = try apply(interrupted, meter: .unmetered)
        }
        let prepared = try prepareConfirmation(
            requestedConfirmation,
            decision: decision
        )
        let observed = try observeConfirmation(
            prepared,
            requestedConfirmation: requestedConfirmation,
            decision: decision,
            meter: .unmetered
        )
        let applyPlan = try commitObservedPlan(observed)
        return try apply(applyPlan, meter: .unmetered)
    }
}

extension ControlledMirror {
    fileprivate static let manifestSchemaVersion = 1
    fileprivate static let journalSchemaVersion = 2

    fileprivate enum ObservationPurpose: Codable, Hashable, Sendable {
        case synchronization
        case confirmation(
            ControlledMirrorConfirmation,
            ControlledMirrorConfirmationDecision
        )
    }

    fileprivate struct MetadataIdentity: Codable, Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        var payloadIdentity: ControlledMirrorPayloadIdentity {
            ControlledMirrorPayloadIdentity(
                device: device,
                inode: inode,
                byteCount: byteCount,
                modifiedSeconds: modifiedSeconds,
                modifiedNanoseconds: modifiedNanoseconds,
                changedSeconds: changedSeconds,
                changedNanoseconds: changedNanoseconds
            )
        }
    }

    fileprivate struct MetadataEntry: Codable, Hashable, Sendable {
        let side: ControlledMirrorSide
        let relativePath: String
        let kind: EntryKind
        let identity: MetadataIdentity?

        var byteCount: Int64 { identity?.byteCount ?? 0 }
    }

    fileprivate struct ObservationEnvelope: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let runID: UUID
        let mode: ExternalDirectoryMode
        let purpose: ObservationPurpose
        let previousManifest: MirrorManifest?
        let metadata: [MetadataEntry]
    }

    fileprivate struct ObservationPreparation: Hashable, Sendable {
        let purpose: ObservationPurpose
        let previousManifest: MirrorManifest?
        let metadata: [MetadataEntry]
    }

    fileprivate struct ObservedDraft: Sendable {
        let purpose: ObservationPurpose
        let runID: UUID
        let accountingPlanDigest: String
        let previousManifest: MirrorManifest?
        let snapshot: Snapshot
        let plan: Plan
    }

    fileprivate struct Roots {
        let managed: URL
        let external: URL

        func url(for side: ControlledMirrorSide) -> URL {
            switch side {
            case .managed: managed
            case .external: external
            }
        }
    }

    fileprivate enum EntryKind: String, Codable, Hashable, Sendable {
        case file
        case directory
    }

    fileprivate struct Fingerprint: Codable, Hashable, Sendable {
        let kind: EntryKind
        let contentDigest: String?
        let byteCount: Int64

        static let directory = Fingerprint(kind: .directory, contentDigest: nil, byteCount: 0)
    }

    fileprivate struct ManifestEntry: Codable, Hashable, Sendable {
        let relativePath: String
        let managed: Fingerprint?
        let external: Fingerprint?
    }

    fileprivate struct MirrorManifest: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let generation: UInt64
        let entries: [ManifestEntry]
        let pendingConfirmations: [ControlledMirrorConfirmation]
    }

    fileprivate enum JournalPhase: String, Codable, Hashable, Sendable {
        case planned
        case applying
        case committed
        case aborted
    }

    fileprivate enum JournalOperationKind: String, Codable, Hashable, Sendable {
        case ensureDirectory
        case copyFile
        case deleteItem
    }

    fileprivate struct JournalOperation: Codable, Hashable, Sendable, Identifiable {
        let id: UUID
        let kind: JournalOperationKind
        let sourceSide: ControlledMirrorSide?
        let destinationSide: ControlledMirrorSide
        let sourceRelativePath: String?
        let destinationRelativePath: String
        let expectedSource: Fingerprint?
        let expectedDestination: Fingerprint?
        var isCompleted: Bool
        var lastErrorCode: ControlledMirrorErrorCode?
    }

    fileprivate struct MirrorJournal: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let runID: UUID
        let accountingPlanDigest: String
        let targetGeneration: UInt64
        let mode: ExternalDirectoryMode
        var phase: JournalPhase
        var operations: [JournalOperation]
        let expectedEntries: [ManifestEntry]
        let conflicts: [ControlledMirrorConflict]
        let confirmations: [ControlledMirrorConfirmation]
    }

    fileprivate struct Snapshot {
        var managed: [String: Fingerprint]
        var external: [String: Fingerprint]

        var allPaths: [String] {
            Array(Set(managed.keys).union(external.keys)).sorted()
        }

        var manifestEntries: [ManifestEntry] {
            allPaths.map {
                ManifestEntry(relativePath: $0, managed: managed[$0], external: external[$0])
            }
        }

        func fingerprint(on side: ControlledMirrorSide, path: String) -> Fingerprint? {
            switch side {
            case .managed: managed[path]
            case .external: external[path]
            }
        }

        mutating func set(_ value: Fingerprint?, on side: ControlledMirrorSide, path: String) {
            switch side {
            case .managed: managed[path] = value
            case .external: external[path] = value
            }
        }
    }

    fileprivate struct Plan {
        let operations: [JournalOperation]
        let expectedEntries: [ManifestEntry]
        let conflicts: [ControlledMirrorConflict]
        let confirmations: [ControlledMirrorConfirmation]
    }

    fileprivate struct PlanBuilder {
        var current: Snapshot
        var expected: Snapshot
        let previous: [String: ManifestEntry]
        var operations: [JournalOperation] = []
        var conflicts: [ControlledMirrorConflict] = []
        var confirmations: [ControlledMirrorConfirmation] = []
    }

    fileprivate struct NoOpPlanDigestPayload: Codable {
        let schemaVersion: Int
        let mode: ExternalDirectoryMode
        let generation: UInt64
        let manifestEntries: [ManifestEntry]
        let snapshotEntries: [ManifestEntry]
        let confirmations: [ControlledMirrorConfirmation]
    }

    fileprivate func preparedObservation(
        roots: Roots,
        previousManifest: MirrorManifest?,
        purpose: ObservationPurpose
    ) throws -> ControlledMirrorPreparedPlan {
        let runID = UUID()
        let metadata = try metadataSnapshot(roots: roots)
        let envelope = ObservationEnvelope(
            schemaVersion: Self.journalSchemaVersion,
            runID: runID,
            mode: mode,
            purpose: purpose,
            previousManifest: previousManifest,
            metadata: metadata
        )
        let encoded: Data
        do {
            encoded = try Self.encoder.encode(envelope)
        } catch {
            throw ControlledMirrorPreparedPlanError.invalidJournal
        }
        let transfers = metadata.compactMap { entry -> ControlledMirrorLogicalTransfer? in
            guard entry.side == .external, entry.kind == .file else { return nil }
            return ControlledMirrorLogicalTransfer(
                id: UUID(),
                direction: .readExternalProvider,
                byteCount: entry.byteCount,
                isCompleted: false,
                eventKey: "observation:external:\(entry.relativePath)"
            )
        }
        let maximum = try Self.logicalByteSum(transfers.map(\.byteCount))
        return ControlledMirrorPreparedPlan(
            runID: runID,
            planDigest: Self.digest(encoded),
            stage: .observation,
            logicalTransfers: transfers,
            maximumLogicalProviderBytes: maximum,
            remainingLogicalProviderBytes: maximum,
            observationPreparation: ObservationPreparation(
                purpose: purpose,
                previousManifest: previousManifest,
                metadata: metadata
            )
        )
    }

    fileprivate func observe(
        _ prepared: ControlledMirrorPreparedPlan,
        expectedPurpose: ObservationPurpose,
        meter: ControlledMirrorTransferMeter
    ) throws -> ControlledMirrorObservedPlan {
        guard prepared.stage == .observation,
            let preparation = prepared.observationPreparation,
            preparation.purpose == expectedPurpose
        else {
            throw ControlledMirrorPreparedPlanError.changed
        }
        let roots = try preparedRoots()
        guard try metadataSnapshot(roots: roots) == preparation.metadata else {
            throw ControlledMirrorPreparedPlanError.changed
        }
        let envelope = ObservationEnvelope(
            schemaVersion: Self.journalSchemaVersion,
            runID: prepared.runID,
            mode: mode,
            purpose: preparation.purpose,
            previousManifest: preparation.previousManifest,
            metadata: preparation.metadata
        )
        let encoded: Data
        do {
            encoded = try Self.encoder.encode(envelope)
        } catch {
            throw ControlledMirrorPreparedPlanError.invalidJournal
        }
        guard Self.digest(encoded) == prepared.planDigest else {
            throw ControlledMirrorPreparedPlanError.changed
        }
        let providerMeter = ControlledMirrorProviderMeterState(
            expectations: prepared.logicalTransfers,
            meter: meter
        )
        let expectedMetadata = Dictionary(
            uniqueKeysWithValues: preparation.metadata.compactMap {
                entry -> (String, MetadataIdentity)? in
                guard let identity = entry.identity else { return nil }
                return (entry.side.rawValue + ":" + entry.relativePath, identity)
            }
        )
        let snapshot = try scanRoots(
            roots,
            providerMeter: providerMeter,
            expectedMetadata: expectedMetadata
        )
        try providerMeter.requireFullyConsumed()
        let plan = try observedPlan(
            purpose: preparation.purpose,
            snapshot: snapshot,
            previousManifest: preparation.previousManifest
        )
        let draft = ObservedDraft(
            purpose: preparation.purpose,
            runID: prepared.runID,
            accountingPlanDigest: prepared.planDigest,
            previousManifest: preparation.previousManifest,
            snapshot: snapshot,
            plan: plan
        )
        return ControlledMirrorObservedPlan(
            runID: prepared.runID,
            planDigest: prepared.planDigest,
            draft: draft
        )
    }

    fileprivate func observedPlan(
        purpose: ObservationPurpose,
        snapshot: Snapshot,
        previousManifest: MirrorManifest?
    ) throws -> Plan {
        switch purpose {
        case .synchronization:
            return try makePlan(
                current: snapshot,
                previous: previousManifest,
                mode: mode
            )
        case .confirmation(let requested, let decision):
            guard let manifest = previousManifest,
                snapshot.manifestEntries == manifest.entries,
                let confirmation = manifest.pendingConfirmations.first(where: {
                    $0.id == requested.id
                }),
                confirmation == requested,
                stillRequiresConfirmation(confirmation, current: snapshot)
            else {
                throw ControlledMirrorFailure(
                    code: .confirmationChanged,
                    relativePath: requested.relativePath
                )
            }
            let survivingSide: ControlledMirrorSide
            let missingSide: ControlledMirrorSide
            switch confirmation.kind {
            case .deleteManaged:
                survivingSide = .managed
                missingSide = .external
            case .deleteExternal:
                survivingSide = .external
                missingSide = .managed
            }
            guard
                let surviving = snapshot.fingerprint(
                    on: survivingSide,
                    path: confirmation.relativePath
                ), surviving.contentDigest == confirmation.expectedContentDigest
            else {
                throw ControlledMirrorFailure(
                    code: .confirmationChanged,
                    relativePath: confirmation.relativePath
                )
            }
            var builder = PlanBuilder(
                current: snapshot,
                expected: snapshot,
                previous: Dictionary(
                    uniqueKeysWithValues: manifest.entries.map { ($0.relativePath, $0) }
                )
            )
            switch decision {
            case .propagateDeletion:
                builder.operations.append(
                    JournalOperation(
                        id: UUID(),
                        kind: .deleteItem,
                        sourceSide: nil,
                        destinationSide: survivingSide,
                        sourceRelativePath: nil,
                        destinationRelativePath: confirmation.relativePath,
                        expectedSource: nil,
                        expectedDestination: surviving,
                        isCompleted: false,
                        lastErrorCode: nil
                    )
                )
                builder.expected.set(nil, on: survivingSide, path: confirmation.relativePath)
            case .keepSurvivingCopy:
                if mode == .controlledMirror {
                    try appendCopy(
                        path: confirmation.relativePath,
                        source: survivingSide,
                        destination: missingSide,
                        builder: &builder
                    )
                }
            }
            let remaining = manifest.pendingConfirmations
                .filter { $0.id != confirmation.id }
                .sorted { $0.relativePath < $1.relativePath }
            return Plan(
                operations: builder.operations,
                expectedEntries: builder.expected.manifestEntries,
                conflicts: [],
                confirmations: remaining
            )
        }
    }

    fileprivate static func logicalByteSum(_ values: [Int64]) throws -> Int64 {
        var total: Int64 = 0
        for value in values {
            guard value >= 0 else { throw ControlledMirrorPreparedPlanError.changed }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw ControlledMirrorPreparedPlanError.byteCountOverflow }
            total = next
        }
        return total
    }

    fileprivate func preparedPlan(
        for journal: MirrorJournal
    ) throws -> ControlledMirrorPreparedPlan {
        guard journal.mode == mode,
            journal.accountingPlanDigest.utf8.count == 64,
            journal.accountingPlanDigest.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            throw ControlledMirrorPreparedPlanError.invalidJournal
        }
        var operationIDs = Set<UUID>()
        var transfers: [ControlledMirrorLogicalTransfer] = []
        func append(
            key: String,
            _ direction: ControlledMirrorLogicalTransfer.Direction,
            _ byteCount: Int64,
            completed: Bool
        ) throws {
            guard byteCount >= 0 else {
                throw ControlledMirrorPreparedPlanError.invalidJournal
            }
            transfers.append(
                ControlledMirrorLogicalTransfer(
                    id: UUID(),
                    direction: direction,
                    byteCount: byteCount,
                    isCompleted: completed,
                    eventKey: key
                )
            )
        }
        func appendSeries(
            prefix: String,
            _ direction: ControlledMirrorLogicalTransfer.Direction,
            _ byteCount: Int64,
            count: Int,
            completed: Bool
        ) throws {
            guard count >= 0 else {
                throw ControlledMirrorPreparedPlanError.invalidJournal
            }
            for ordinal in 0..<count {
                try append(
                    key: "\(prefix):\(ordinal)",
                    direction,
                    byteCount,
                    completed: completed
                )
            }
        }
        for operation in journal.operations {
            guard operationIDs.insert(operation.id).inserted else {
                throw ControlledMirrorPreparedPlanError.invalidJournal
            }
            let completed = operation.isCompleted
            switch operation.kind {
            case .ensureDirectory:
                break
            case .deleteItem:
                if operation.destinationSide == .external,
                    let destination = operation.expectedDestination,
                    destination.kind == .file
                {
                    try appendSeries(
                        prefix: "op:\(operation.id.uuidString):destination-preflight",
                        .readExternalProvider,
                        destination.byteCount,
                        count: 1,
                        completed: completed
                    )
                    // The descriptor-bound delete transaction performs six
                    // successful-path content fences across the destination,
                    // quarantine, and retained recovery payload.
                    try appendSeries(
                        prefix: controlledMirrorProviderEventPrefix(
                            operationID: operation.id,
                            relativePath: operation.destinationRelativePath,
                            purpose: .deleteRead
                        ),
                        .readExternalProvider,
                        destination.byteCount,
                        count: 6,
                        completed: completed
                    )
                }
            case .copyFile:
                guard let sourceSide = operation.sourceSide,
                    let sourceRelativePath = operation.sourceRelativePath,
                    let source = operation.expectedSource,
                    source.kind == .file
                else {
                    throw ControlledMirrorPreparedPlanError.invalidJournal
                }
                if operation.destinationSide == .external {
                    var preflightByteCounts: [Int64] = []
                    if let destination = operation.expectedDestination,
                        destination.kind == .file
                    {
                        preflightByteCounts.append(destination.byteCount)
                    }
                    if !preflightByteCounts.contains(source.byteCount) {
                        preflightByteCounts.append(source.byteCount)
                    }
                    for (ordinal, byteCount) in preflightByteCounts.enumerated() {
                        try append(
                            key: "op:\(operation.id.uuidString):destination-preflight:\(ordinal)",
                            .readExternalProvider,
                            byteCount,
                            completed: completed
                        )
                    }
                }
                if sourceSide == .external {
                    try appendSeries(
                        prefix: "op:\(operation.id.uuidString):source-preflight",
                        .readExternalProvider,
                        source.byteCount,
                        count: 1,
                        completed: completed
                    )
                    try appendSeries(
                        prefix: controlledMirrorProviderEventPrefix(
                            operationID: operation.id,
                            relativePath: sourceRelativePath,
                            purpose: .stageSourceRead
                        ),
                        .fromExternalProvider,
                        source.byteCount,
                        count: 1,
                        completed: completed
                    )
                    try appendSeries(
                        prefix: controlledMirrorProviderEventPrefix(
                            operationID: operation.id,
                            relativePath: sourceRelativePath,
                            purpose: .sourceRead
                        ),
                        .readExternalProvider,
                        source.byteCount,
                        count: 2,
                        completed: completed
                    )
                }
                if operation.destinationSide == .external {
                    try appendSeries(
                        prefix: controlledMirrorProviderEventPrefix(
                            operationID: operation.id,
                            relativePath: operation.destinationRelativePath,
                            purpose: .stageProviderWrite
                        ),
                        .toExternalProvider,
                        source.byteCount,
                        count: 1,
                        completed: completed
                    )
                    try appendSeries(
                        prefix: controlledMirrorProviderEventPrefix(
                            operationID: operation.id,
                            relativePath: operation.destinationRelativePath,
                            purpose: .incomingRead
                        ),
                        .readExternalProvider,
                        source.byteCount,
                        count: 5,
                        completed: completed
                    )
                    if let destination = operation.expectedDestination,
                        destination.kind == .file
                    {
                        try appendSeries(
                            prefix: controlledMirrorProviderEventPrefix(
                                operationID: operation.id,
                                relativePath: operation.destinationRelativePath,
                                purpose: .oldRead
                            ),
                            .readExternalProvider,
                            destination.byteCount,
                            count: 4,
                            completed: completed
                        )
                        try appendSeries(
                            prefix: controlledMirrorProviderEventPrefix(
                                operationID: operation.id,
                                relativePath: operation.destinationRelativePath,
                                purpose: .resumeOldRead
                            ),
                            .readExternalProvider,
                            destination.byteCount,
                            count: 1,
                            completed: completed
                        )
                    }
                    try appendSeries(
                        prefix: "op:\(operation.id.uuidString):installed",
                        .readExternalProvider,
                        source.byteCount,
                        count: 1,
                        completed: completed
                    )
                }
            }
        }
        // The final manifest fence re-hashes every expected external regular
        // file after all operations, including a true no-op run.
        for entry in journal.expectedEntries {
            if let external = entry.external, external.kind == .file {
                try append(
                    key: "final:external:\(entry.relativePath)",
                    .readExternalProvider,
                    external.byteCount,
                    completed: false
                )
            }
        }
        let maximumBytes = try Self.logicalByteSum(transfers.map(\.byteCount))
        let remainingBytes = try Self.logicalByteSum(
            transfers.filter { !$0.isCompleted }.map(\.byteCount)
        )
        return ControlledMirrorPreparedPlan(
            runID: journal.runID,
            planDigest: journal.accountingPlanDigest,
            stage: .apply,
            logicalTransfers: transfers,
            maximumLogicalProviderBytes: maximumBytes,
            remainingLogicalProviderBytes: remainingBytes
        )
    }

    fileprivate func preparedNoOpPlan(
        runID: UUID,
        manifest: MirrorManifest,
        snapshot: Snapshot,
        confirmations: [ControlledMirrorConfirmation]
    ) throws -> ControlledMirrorPreparedPlan {
        let payload = NoOpPlanDigestPayload(
            schemaVersion: Self.journalSchemaVersion,
            mode: mode,
            generation: manifest.generation,
            manifestEntries: manifest.entries,
            snapshotEntries: snapshot.manifestEntries,
            confirmations: confirmations
        )
        let encoded: Data
        do {
            encoded = try Self.encoder.encode(payload)
        } catch {
            throw ControlledMirrorPreparedPlanError.invalidJournal
        }
        return ControlledMirrorPreparedPlan(
            runID: runID,
            planDigest: Self.digest(encoded),
            logicalTransfers: [],
            maximumLogicalProviderBytes: 0,
            remainingLogicalProviderBytes: 0
        )
    }

    fileprivate func preparedRoots() throws -> Roots {
        let manager = FileManager.default
        if !manager.fileExists(atPath: managedRoot.path) {
            do {
                try io.createDirectory(at: managedRoot)
            } catch {
                throw ControlledMirrorFailure(code: .invalidRoot)
            }
        }
        let managed = try validatedRoot(managedRoot)
        let external = try validatedRoot(externalRoot)
        guard !Self.contains(managed, external), !Self.contains(external, managed) else {
            throw ControlledMirrorFailure(code: .rootsOverlap)
        }
        return Roots(managed: managed, external: external)
    }

    fileprivate func validatedRoot(_ root: URL) throws -> URL {
        let standardized = root.standardizedFileURL
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: standardized.path) else {
            throw ControlledMirrorFailure(code: .invalidRoot)
        }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ControlledMirrorFailure(code: .symbolicLinkRejected)
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ControlledMirrorFailure(code: .invalidRoot)
        }
        return standardized.resolvingSymlinksInPath()
    }

    fileprivate static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    fileprivate func prepareStateDirectories(roots: Roots, mode _: ExternalDirectoryMode) throws {
        try prepareStateDirectory(root: roots.managed)
    }

    fileprivate func prepareStateDirectory(root: URL) throws {
        let stateRoot = root.appendingPathComponent(Self.stateDirectoryName, isDirectory: true)
        try ensureExistingComponentsAreNotSymlinks(root: root, relativePath: Self.stateDirectoryName)
        do {
            try io.createDirectory(at: stateRoot.appendingPathComponent("staging", isDirectory: true))
        } catch {
            throw ControlledMirrorFailure(code: .ioWrite)
        }
        try ensureExistingComponentsAreNotSymlinks(
            root: root,
            relativePath: Self.stateDirectoryName + "/staging"
        )
    }

    /// Enumerates with an open root descriptor and uses `fstatat` without
    /// following links. Only names, entry kinds, stable identities, and finite
    /// sizes are captured; payload descriptors are never opened here.
    fileprivate func metadataSnapshot(roots: Roots) throws -> [MetadataEntry] {
        let managed = try metadataEntries(root: roots.managed, side: .managed)
        let external = try metadataEntries(root: roots.external, side: .external)
        try validatePathCollisions(
            paths: managed.map(\.relativePath) + external.map(\.relativePath)
        )
        return (managed + external).sorted {
            if $0.side != $1.side { return $0.side.rawValue < $1.side.rawValue }
            return $0.relativePath < $1.relativePath
        }
    }

    fileprivate func metadataEntries(
        root: URL,
        side: ControlledMirrorSide
    ) throws -> [MetadataEntry] {
        let descriptor = root.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ControlledMirrorFailure(code: .ioEnumerate)
        }
        defer { close(descriptor) }
        return try metadataEntries(
            directoryDescriptor: descriptor,
            prefix: "",
            side: side
        ).sorted { $0.relativePath < $1.relativePath }
    }

    fileprivate func metadataEntries(
        directoryDescriptor: Int32,
        prefix: String,
        side: ControlledMirrorSide
    ) throws -> [MetadataEntry] {
        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw ControlledMirrorFailure(code: .ioEnumerate, relativePath: prefix)
        }
        defer { closedir(directory) }
        var result: [MetadataEntry] = []
        while let pointer = readdir(directory) {
            let name = withUnsafePointer(to: pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
                throw ControlledMirrorFailure(code: .invalidRelativePath, relativePath: prefix)
            }
            let relativePath = prefix.isEmpty ? name : prefix + "/" + name
            var status = stat()
            let statusResult = name.withCString {
                fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0 else {
                throw ControlledMirrorFailure(code: .ioEnumerate, relativePath: relativePath)
            }
            let type = status.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFLNK) {
                throw ControlledMirrorFailure(
                    code: .symbolicLinkRejected,
                    relativePath: relativePath
                )
            }
            if relativePath == Self.stateDirectoryName {
                guard type == mode_t(S_IFDIR) else {
                    throw ControlledMirrorFailure(code: .pathCollision, relativePath: relativePath)
                }
                continue
            }
            guard !relativePath.hasPrefix(Self.stateDirectoryName + "/") else { continue }
            switch type {
            case mode_t(S_IFDIR):
                result.append(
                    MetadataEntry(
                        side: side,
                        relativePath: relativePath,
                        kind: .directory,
                        identity: nil
                    )
                )
                let child = name.withCString {
                    openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                    )
                }
                guard child >= 0 else {
                    throw ControlledMirrorFailure(code: .ioEnumerate, relativePath: relativePath)
                }
                defer { close(child) }
                var openedStatus = stat()
                guard fstat(child, &openedStatus) == 0,
                    UInt64(openedStatus.st_dev) == UInt64(status.st_dev),
                    UInt64(openedStatus.st_ino) == UInt64(status.st_ino)
                else {
                    throw ControlledMirrorPreparedPlanError.changed
                }
                result.append(
                    contentsOf: try metadataEntries(
                        directoryDescriptor: child,
                        prefix: relativePath,
                        side: side
                    )
                )
            case mode_t(S_IFREG):
                guard status.st_size >= 0 else {
                    throw ControlledMirrorPreparedPlanError.changed
                }
                result.append(
                    MetadataEntry(
                        side: side,
                        relativePath: relativePath,
                        kind: .file,
                        identity: MetadataIdentity(
                            device: UInt64(status.st_dev),
                            inode: UInt64(status.st_ino),
                            byteCount: status.st_size,
                            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
                            changedSeconds: Int64(status.st_ctimespec.tv_sec),
                            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
                        )
                    )
                )
            default:
                throw ControlledMirrorFailure(
                    code: .unsupportedEntryType,
                    relativePath: relativePath
                )
            }
        }
        return result
    }

    fileprivate func scanRoots(
        _ roots: Roots,
        providerMeter: ControlledMirrorProviderMeterState? = nil,
        eventKeyPrefix: String = "observation",
        expectedMetadata: [String: MetadataIdentity]? = nil
    ) throws -> Snapshot {
        let managed = try scan(
            root: roots.managed,
            side: .managed,
            providerMeter: providerMeter,
            eventKeyPrefix: eventKeyPrefix,
            expectedMetadata: expectedMetadata
        )
        let external = try scan(
            root: roots.external,
            side: .external,
            providerMeter: providerMeter,
            eventKeyPrefix: eventKeyPrefix,
            expectedMetadata: expectedMetadata
        )
        try validatePathCollisions(paths: Array(managed.keys) + Array(external.keys))
        return Snapshot(managed: managed, external: external)
    }

    fileprivate func scan(
        root: URL,
        side: ControlledMirrorSide,
        providerMeter: ControlledMirrorProviderMeterState? = nil,
        eventKeyPrefix: String = "observation",
        expectedMetadata: [String: MetadataIdentity]? = nil
    ) throws -> [String: Fingerprint] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        var enumerationFailed = false
        guard
            let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            )
        else {
            throw ControlledMirrorFailure(code: .ioEnumerate)
        }

        var result: [String: Fingerprint] = [:]
        for case let url as URL in enumerator {
            let relativePath = try relativePath(of: url, within: root)
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                throw ControlledMirrorFailure(code: .ioEnumerate, relativePath: relativePath)
            }
            if values.isSymbolicLink == true {
                throw ControlledMirrorFailure(code: .symbolicLinkRejected, relativePath: relativePath)
            }
            if relativePath == Self.stateDirectoryName {
                guard values.isDirectory == true else {
                    throw ControlledMirrorFailure(code: .pathCollision, relativePath: relativePath)
                }
                enumerator.skipDescendants()
                continue
            }
            guard !relativePath.hasPrefix(Self.stateDirectoryName + "/") else { continue }
            if values.isDirectory == true {
                result[relativePath] = .directory
            } else if values.isRegularFile == true {
                let data: Data
                do {
                    let attributes = try manager.attributesOfItem(atPath: url.path)
                    guard let number = attributes[.size] as? NSNumber,
                        let byteCount = Int64(exactly: number), byteCount >= 0
                    else {
                        throw ControlledMirrorPreparedPlanError.changed
                    }
                    if side == .external {
                        guard let providerMeter else {
                            throw ExternalMirrorTransferAccountingError.sessionUnavailable
                        }
                        data = try providerMeter.perform(
                            eventKey: "\(eventKeyPrefix):external:\(relativePath)",
                            direction: .readExternalProvider,
                            byteCount: byteCount,
                            validate: { Int64($0.count) == byteCount },
                            { transfer in
                                try io.beforeProviderPayloadIO(transfer)
                                return try io.readData(
                                    at: url,
                                    exactByteCount: byteCount,
                                    expectedIdentity: expectedMetadata?[
                                        side.rawValue + ":" + relativePath
                                    ]?.payloadIdentity
                                )
                            }
                        )
                    } else {
                        data = try io.readData(
                            at: url,
                            exactByteCount: byteCount,
                            expectedIdentity: expectedMetadata?[
                                side.rawValue + ":" + relativePath
                            ]?.payloadIdentity
                        )
                    }
                } catch {
                    throw ControlledMirrorFailure(code: .ioRead, relativePath: relativePath)
                }
                result[relativePath] = Fingerprint(
                    kind: .file,
                    contentDigest: Self.digest(data),
                    byteCount: Int64(data.count)
                )
            } else {
                throw ControlledMirrorFailure(code: .unsupportedEntryType, relativePath: relativePath)
            }
        }
        if enumerationFailed {
            throw ControlledMirrorFailure(code: .ioEnumerate)
        }
        try validatePathCollisions(paths: Array(result.keys))
        return result
    }

    fileprivate func relativePath(of url: URL, within root: URL) throws -> String {
        let standardized = url.standardizedFileURL
        guard Self.contains(root, standardized), standardized != root else {
            throw ControlledMirrorFailure(code: .pathOutsideRoot)
        }
        let rootComponents = root.pathComponents
        let components = standardized.pathComponents.dropFirst(rootComponents.count)
        let relative = components.joined(separator: "/")
        try validateRelativePath(relative, allowStateDirectory: true)
        return relative
    }

    fileprivate func validatePathCollisions(paths: [String]) throws {
        var spellingByCanonicalPath: [String: String] = [:]
        for path in paths.sorted() {
            let canonical = Self.canonicalPath(path)
            if let existing = spellingByCanonicalPath[canonical], existing != path {
                throw ControlledMirrorFailure(
                    code: .pathCollision,
                    relativePath: min(existing, path)
                )
            }
            spellingByCanonicalPath[canonical] = path
        }
    }

    fileprivate static func canonicalPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map {
                String($0).precomposedStringWithCompatibilityMapping.folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
            }
            .joined(separator: "/")
    }

    fileprivate func makePlan(
        current: Snapshot,
        previous: MirrorManifest?,
        mode: ExternalDirectoryMode
    ) throws -> Plan {
        let previousByPath = Dictionary(
            uniqueKeysWithValues: (previous?.entries ?? []).map { ($0.relativePath, $0) }
        )
        let pendingByPath = Dictionary(
            uniqueKeysWithValues: (previous?.pendingConfirmations ?? []).map { ($0.relativePath, $0) }
        )
        var builder = PlanBuilder(current: current, expected: current, previous: previousByPath)

        for path in Set(current.allPaths).union(previousByPath.keys).sorted() {
            if let pending = pendingByPath[path], stillRequiresConfirmation(pending, current: current) {
                builder.confirmations.append(updatedConfirmation(pending, current: current))
                continue
            }
            let managed = current.managed[path]
            let external = current.external[path]
            if let managed, let external, managed.kind != external.kind {
                throw ControlledMirrorFailure(code: .entryTypeConflict, relativePath: path)
            }
            let prior = previousByPath[path]
            switch mode {
            case .controlledMirror:
                try planControlled(path: path, prior: prior, builder: &builder)
            case .importOnly:
                try planOneWay(
                    path: path,
                    sourceSide: .external,
                    destinationSide: .managed,
                    deletionKind: .deleteManaged,
                    prior: prior,
                    builder: &builder
                )
            case .exportOnly:
                try planOneWay(
                    path: path,
                    sourceSide: .managed,
                    destinationSide: .external,
                    deletionKind: .deleteExternal,
                    prior: prior,
                    builder: &builder
                )
            case .readOnly:
                break
            case .direct:
                throw ControlledMirrorFailure(code: .unsupportedMode)
            }
        }

        return Plan(
            operations: builder.operations,
            expectedEntries: builder.expected.manifestEntries,
            conflicts: builder.conflicts.sorted { $0.originalRelativePath < $1.originalRelativePath },
            confirmations: builder.confirmations.sorted { $0.relativePath < $1.relativePath }
        )
    }

    fileprivate func stillRequiresConfirmation(_ pending: ControlledMirrorConfirmation, current: Snapshot) -> Bool {
        switch pending.kind {
        case .deleteManaged:
            current.external[pending.relativePath] == nil && current.managed[pending.relativePath] != nil
        case .deleteExternal:
            current.managed[pending.relativePath] == nil && current.external[pending.relativePath] != nil
        }
    }

    fileprivate func updatedConfirmation(
        _ pending: ControlledMirrorConfirmation,
        current: Snapshot
    ) -> ControlledMirrorConfirmation {
        let fingerprint: Fingerprint?
        switch pending.kind {
        case .deleteManaged: fingerprint = current.managed[pending.relativePath]
        case .deleteExternal: fingerprint = current.external[pending.relativePath]
        }
        return ControlledMirrorConfirmation(
            id: pending.id,
            kind: pending.kind,
            relativePath: pending.relativePath,
            expectedContentDigest: fingerprint?.contentDigest
        )
    }

    fileprivate func planControlled(
        path: String,
        prior: ManifestEntry?,
        builder: inout PlanBuilder
    ) throws {
        let managed = builder.current.managed[path]
        let external = builder.current.external[path]
        switch (managed, external) {
        case (nil, nil):
            return
        case (let managed?, nil):
            if prior?.external != nil {
                builder.confirmations.append(
                    Self.confirmation(kind: .deleteManaged, path: path, fingerprint: managed)
                )
            } else {
                try appendCopy(path: path, source: .managed, destination: .external, builder: &builder)
            }
        case (nil, let external?):
            if prior?.managed != nil {
                builder.confirmations.append(
                    Self.confirmation(kind: .deleteExternal, path: path, fingerprint: external)
                )
            } else {
                try appendCopy(path: path, source: .external, destination: .managed, builder: &builder)
            }
        case (let managed?, let external?):
            guard managed != external else { return }
            let managedChanged = managed != prior?.managed
            let externalChanged = external != prior?.external
            if managedChanged, !externalChanged {
                try appendCopy(path: path, source: .managed, destination: .external, builder: &builder)
            } else if !managedChanged, externalChanged {
                try appendCopy(path: path, source: .external, destination: .managed, builder: &builder)
            } else {
                try appendConflict(
                    path: path,
                    winner: .managed,
                    preserved: .external,
                    builder: &builder
                )
            }
        }
    }

    fileprivate func planOneWay(
        path: String,
        sourceSide: ControlledMirrorSide,
        destinationSide: ControlledMirrorSide,
        deletionKind: ControlledMirrorConfirmationKind,
        prior: ManifestEntry?,
        builder: inout PlanBuilder
    ) throws {
        let source = builder.current.fingerprint(on: sourceSide, path: path)
        let destination = builder.current.fingerprint(on: destinationSide, path: path)
        let priorSource = Self.fingerprint(in: prior, side: sourceSide)
        let priorDestination = Self.fingerprint(in: prior, side: destinationSide)
        guard let source else {
            if priorSource != nil, let destination {
                builder.confirmations.append(
                    Self.confirmation(kind: deletionKind, path: path, fingerprint: destination)
                )
            }
            return
        }
        guard let destination else {
            try appendCopy(path: path, source: sourceSide, destination: destinationSide, builder: &builder)
            return
        }
        guard source.kind == destination.kind else {
            throw ControlledMirrorFailure(code: .entryTypeConflict, relativePath: path)
        }
        guard source != destination else { return }

        let destinationChanged = destination != priorDestination
        let sourceChanged = source != priorSource
        if destinationChanged, sourceChanged || prior == nil {
            try appendConflict(
                path: path,
                winner: sourceSide,
                preserved: destinationSide,
                builder: &builder
            )
        } else if destinationChanged {
            // One-way modes still preserve an edited destination before the
            // configured source replaces the canonical path.
            try appendConflict(
                path: path,
                winner: sourceSide,
                preserved: destinationSide,
                builder: &builder
            )
        } else {
            try appendCopy(path: path, source: sourceSide, destination: destinationSide, builder: &builder)
        }
    }

    fileprivate func appendCopy(
        path: String,
        source: ControlledMirrorSide,
        destination: ControlledMirrorSide,
        builder: inout PlanBuilder
    ) throws {
        guard let sourceFingerprint = builder.expected.fingerprint(on: source, path: path) else {
            throw ControlledMirrorFailure(code: .sourceChangedDuringRun, relativePath: path)
        }
        let destinationFingerprint = builder.expected.fingerprint(on: destination, path: path)
        if let destinationFingerprint, destinationFingerprint.kind != sourceFingerprint.kind {
            throw ControlledMirrorFailure(code: .entryTypeConflict, relativePath: path)
        }
        if sourceFingerprint == destinationFingerprint { return }
        let kind: JournalOperationKind = sourceFingerprint.kind == .directory ? .ensureDirectory : .copyFile
        builder.operations.append(
            JournalOperation(
                id: UUID(),
                kind: kind,
                sourceSide: sourceFingerprint.kind == .file ? source : nil,
                destinationSide: destination,
                sourceRelativePath: sourceFingerprint.kind == .file ? path : nil,
                destinationRelativePath: path,
                expectedSource: sourceFingerprint.kind == .file ? sourceFingerprint : nil,
                expectedDestination: destinationFingerprint,
                isCompleted: false,
                lastErrorCode: nil
            )
        )
        builder.expected.set(sourceFingerprint, on: destination, path: path)
    }

    fileprivate func appendConflict(
        path: String,
        winner: ControlledMirrorSide,
        preserved: ControlledMirrorSide,
        builder: inout PlanBuilder
    ) throws {
        guard let winnerFingerprint = builder.current.fingerprint(on: winner, path: path),
            let preservedFingerprint = builder.current.fingerprint(on: preserved, path: path),
            winnerFingerprint.kind == .file,
            preservedFingerprint.kind == .file,
            let preservedDigest = preservedFingerprint.contentDigest
        else {
            throw ControlledMirrorFailure(code: .entryTypeConflict, relativePath: path)
        }
        let artifactPath = Self.conflictArtifactPath(
            originalPath: path,
            preservedSide: preserved,
            digest: preservedDigest
        )
        try validateRelativePath(artifactPath, allowStateDirectory: false)
        try validateArtifactPath(artifactPath, fingerprint: preservedFingerprint, snapshot: builder.current)

        switch (mode, winner, preserved) {
        case (.controlledMirror, .managed, .external):
            try appendCopy(
                sourcePath: path,
                destinationPath: artifactPath,
                source: .external,
                destination: .managed,
                builder: &builder
            )
            try appendCopy(
                sourcePath: path,
                destinationPath: artifactPath,
                source: .external,
                destination: .external,
                builder: &builder
            )
            try appendCopy(path: path, source: .managed, destination: .external, builder: &builder)
        case (.importOnly, .external, .managed):
            try appendCopy(
                sourcePath: path,
                destinationPath: artifactPath,
                source: .managed,
                destination: .managed,
                builder: &builder
            )
            try appendCopy(path: path, source: .external, destination: .managed, builder: &builder)
        case (.exportOnly, .managed, .external):
            try appendCopy(
                sourcePath: path,
                destinationPath: artifactPath,
                source: .external,
                destination: .external,
                builder: &builder
            )
            try appendCopy(path: path, source: .managed, destination: .external, builder: &builder)
        default:
            throw ControlledMirrorFailure(code: .entryTypeConflict, relativePath: path)
        }

        builder.conflicts.append(
            ControlledMirrorConflict(
                originalRelativePath: path,
                artifactRelativePath: artifactPath,
                preservedSide: preserved
            )
        )
    }

    fileprivate func appendCopy(
        sourcePath: String,
        destinationPath: String,
        source: ControlledMirrorSide,
        destination: ControlledMirrorSide,
        builder: inout PlanBuilder
    ) throws {
        guard let sourceFingerprint = builder.expected.fingerprint(on: source, path: sourcePath),
            sourceFingerprint.kind == .file
        else {
            throw ControlledMirrorFailure(code: .sourceChangedDuringRun, relativePath: sourcePath)
        }
        let destinationFingerprint = builder.expected.fingerprint(on: destination, path: destinationPath)
        if let destinationFingerprint, destinationFingerprint != sourceFingerprint {
            throw ControlledMirrorFailure(code: .pathCollision, relativePath: destinationPath)
        }
        guard destinationFingerprint != sourceFingerprint else { return }
        builder.operations.append(
            JournalOperation(
                id: UUID(),
                kind: .copyFile,
                sourceSide: source,
                destinationSide: destination,
                sourceRelativePath: sourcePath,
                destinationRelativePath: destinationPath,
                expectedSource: sourceFingerprint,
                expectedDestination: destinationFingerprint,
                isCompleted: false,
                lastErrorCode: nil
            )
        )
        builder.expected.set(sourceFingerprint, on: destination, path: destinationPath)
    }

    fileprivate func validateArtifactPath(
        _ artifactPath: String,
        fingerprint: Fingerprint,
        snapshot: Snapshot
    ) throws {
        let canonical = Self.canonicalPath(artifactPath)
        for existingPath in snapshot.allPaths where Self.canonicalPath(existingPath) == canonical {
            guard existingPath == artifactPath else {
                throw ControlledMirrorFailure(code: .pathCollision, relativePath: artifactPath)
            }
            for side in [ControlledMirrorSide.managed, .external] {
                if let existing = snapshot.fingerprint(on: side, path: existingPath), existing != fingerprint {
                    throw ControlledMirrorFailure(code: .pathCollision, relativePath: artifactPath)
                }
            }
        }
    }

    fileprivate static func fingerprint(in entry: ManifestEntry?, side: ControlledMirrorSide) -> Fingerprint? {
        switch side {
        case .managed: entry?.managed
        case .external: entry?.external
        }
    }

    fileprivate static func confirmation(
        kind: ControlledMirrorConfirmationKind,
        path: String,
        fingerprint: Fingerprint
    ) -> ControlledMirrorConfirmation {
        let id = digest(Data("\(kind.rawValue)\u{0}\(path)".utf8))
        return ControlledMirrorConfirmation(
            id: id,
            kind: kind,
            relativePath: path,
            expectedContentDigest: fingerprint.contentDigest
        )
    }

    fileprivate static func conflictArtifactPath(
        originalPath: String,
        preservedSide: ControlledMirrorSide,
        digest: String
    ) -> String {
        let path = originalPath as NSString
        let directory = path.deletingLastPathComponent
        let fileName = path.lastPathComponent as NSString
        let pathExtension = fileName.pathExtension
        let baseName = fileName.deletingPathExtension
        let suffix = ".psy-conflict-\(preservedSide.rawValue)-\(digest.prefix(12))"
        let artifactName =
            pathExtension.isEmpty
            ? baseName + suffix
            : baseName + suffix + "." + pathExtension
        return directory == "." || directory.isEmpty ? artifactName : directory + "/" + artifactName
    }

    fileprivate func resume(
        journal: inout MirrorJournal,
        previousManifest: MirrorManifest?,
        roots: Roots,
        providerMeter: ControlledMirrorProviderMeterState
    ) throws -> ControlledMirrorRunResult {
        journal.phase = .applying
        try persistJournal(journal, roots: roots)

        for index in journal.operations.indices where !journal.operations[index].isCompleted {
            do {
                try execute(
                    operation: journal.operations[index],
                    roots: roots,
                    providerMeter: providerMeter
                )
                journal.operations[index].isCompleted = true
                journal.operations[index].lastErrorCode = nil
                try persistJournal(journal, roots: roots)
            } catch let failure as ControlledMirrorFailure {
                journal.operations[index].lastErrorCode = failure.code
                if failure.code == .sourceChangedDuringRun || failure.code == .destinationChangedDuringRun {
                    journal.phase = .aborted
                }
                try? persistJournal(journal, roots: roots)
                throw failure
            } catch {
                journal.operations[index].lastErrorCode = .atomicReplaceFailed
                try? persistJournal(journal, roots: roots)
                throw ControlledMirrorFailure(
                    code: .atomicReplaceFailed,
                    relativePath: journal.operations[index].destinationRelativePath
                )
            }
        }

        let finalSnapshot = try scanRoots(
            roots,
            providerMeter: providerMeter,
            eventKeyPrefix: "final"
        )
        guard finalSnapshot.manifestEntries == journal.expectedEntries else {
            journal.phase = .aborted
            try? persistJournal(journal, roots: roots)
            let differingPath = Self.firstDifference(
                expected: journal.expectedEntries,
                actual: finalSnapshot.manifestEntries
            )
            throw ControlledMirrorFailure(code: .rootChangedDuringRun, relativePath: differingPath)
        }

        let manifest = MirrorManifest(
            schemaVersion: Self.manifestSchemaVersion,
            generation: journal.targetGeneration,
            entries: finalSnapshot.manifestEntries,
            pendingConfirmations: journal.confirmations
        )
        try persistManifest(manifest, roots: roots, mode: journal.mode)
        journal.phase = .committed
        try persistJournal(journal, roots: roots)
        return result(for: journal)
    }

    fileprivate func execute(
        operation: JournalOperation,
        roots: Roots,
        providerMeter: ControlledMirrorProviderMeterState
    ) throws {
        let destinationRoot = roots.url(for: operation.destinationSide)
        let currentDestination = try fingerprintAt(
            root: destinationRoot,
            side: operation.destinationSide,
            relativePath: operation.destinationRelativePath,
            eventKey: "op:\(operation.id.uuidString):destination-preflight",
            providerMeter: providerMeter
        )
        if operation.kind == .deleteItem {
            guard let expectedDestination = operation.expectedDestination else {
                throw ControlledMirrorFailure(code: .stateCorrupt)
            }
            guard currentDestination == nil || currentDestination == expectedDestination else {
                throw ControlledMirrorFailure(
                    code: .destinationChangedDuringRun,
                    relativePath: operation.destinationRelativePath
                )
            }
            let destination = try safeURL(
                root: destinationRoot,
                relativePath: operation.destinationRelativePath,
                allowStateDirectory: false
            )
            try ensureExistingComponentsAreNotSymlinks(
                root: destinationRoot,
                relativePath: operation.destinationRelativePath
            )
            if currentDestination == .directory {
                let contents: [URL]
                do {
                    contents = try FileManager.default.contentsOfDirectory(
                        at: destination,
                        includingPropertiesForKeys: nil
                    )
                } catch {
                    throw ControlledMirrorFailure(
                        code: .ioEnumerate,
                        relativePath: operation.destinationRelativePath
                    )
                }
                guard contents.isEmpty else {
                    throw ControlledMirrorFailure(
                        code: .directoryNotEmpty,
                        relativePath: operation.destinationRelativePath
                    )
                }
            }
            let quarantineParent =
                destinationRoot
                .appendingPathComponent(Self.stateDirectoryName, isDirectory: true)
                .appendingPathComponent("staging", isDirectory: true)
            do {
                try io.createDirectory(at: quarantineParent)
                try ensureExistingComponentsAreNotSymlinks(
                    root: destinationRoot,
                    relativePath: Self.stateDirectoryName + "/staging"
                )
            } catch let failure as ControlledMirrorFailure {
                throw failure
            } catch {
                throw ControlledMirrorFailure(
                    code: .atomicReplaceFailed,
                    relativePath: operation.destinationRelativePath
                )
            }
            let quarantine = quarantineParent.appendingPathComponent(
                operation.id.uuidString + ".deleting",
                isDirectory: expectedDestination == .directory
            )
            do {
                try io.removeItemIfUnchanged(
                    at: destination,
                    destinationRoot: destinationRoot,
                    quarantineAt: quarantine,
                    operationID: operation.id,
                    destinationRelativePath: operation.destinationRelativePath,
                    expected: expectedDestination,
                    destinationIsExternal: operation.destinationSide == .external,
                    providerMeter: providerMeter
                )
            } catch ControlledMirrorIO.AtomicCopyFailure.destinationChanged {
                throw ControlledMirrorFailure(
                    code: .destinationChangedDuringRun,
                    relativePath: operation.destinationRelativePath
                )
            } catch ControlledMirrorIO.AtomicCopyFailure.unsafePath {
                throw ControlledMirrorFailure(
                    code: .symbolicLinkRejected,
                    relativePath: operation.destinationRelativePath
                )
            } catch let failure as ControlledMirrorFailure {
                throw failure
            } catch {
                throw ControlledMirrorFailure(
                    code: .atomicReplaceFailed,
                    relativePath: operation.destinationRelativePath
                )
            }
            guard
                try fingerprintAt(
                    root: destinationRoot,
                    side: operation.destinationSide,
                    relativePath: operation.destinationRelativePath,
                    eventKey: "op:\(operation.id.uuidString):deleted-verification",
                    providerMeter: providerMeter
                ) == nil
            else {
                throw ControlledMirrorFailure(
                    code: .ioWrite,
                    relativePath: operation.destinationRelativePath
                )
            }
            return
        }
        if operation.kind == .ensureDirectory {
            if currentDestination == .directory { return }
            guard currentDestination == operation.expectedDestination else {
                throw ControlledMirrorFailure(
                    code: .destinationChangedDuringRun,
                    relativePath: operation.destinationRelativePath
                )
            }
            let destination = try safeURL(
                root: destinationRoot,
                relativePath: operation.destinationRelativePath,
                allowStateDirectory: false
            )
            do {
                try io.createDirectory(at: destination)
            } catch {
                throw ControlledMirrorFailure(code: .ioWrite, relativePath: operation.destinationRelativePath)
            }
            return
        }

        guard let sourceSide = operation.sourceSide,
            let sourcePath = operation.sourceRelativePath,
            let expectedSource = operation.expectedSource
        else {
            throw ControlledMirrorFailure(code: .stateCorrupt)
        }
        if currentDestination == expectedSource {
            if let expectedDestination = operation.expectedDestination {
                let staging =
                    destinationRoot
                    .appendingPathComponent(Self.stateDirectoryName, isDirectory: true)
                    .appendingPathComponent("staging", isDirectory: true)
                    .appendingPathComponent(operation.id.uuidString)
                do {
                    try ensureExistingComponentsAreNotSymlinks(
                        root: destinationRoot,
                        relativePath: Self.stateDirectoryName + "/staging"
                    )
                    try io.completeCopyRecoveryIfNeeded(
                        staging: staging,
                        destinationRoot: destinationRoot,
                        operationID: operation.id,
                        destinationRelativePath: operation.destinationRelativePath,
                        expectedDestination: expectedDestination,
                        destinationIsExternal: operation.destinationSide == .external,
                        providerMeter: providerMeter
                    )
                } catch ControlledMirrorIO.AtomicCopyFailure.unsafePath {
                    throw ControlledMirrorFailure(
                        code: .symbolicLinkRejected,
                        relativePath: operation.destinationRelativePath
                    )
                } catch {
                    throw ControlledMirrorFailure(
                        code: .atomicReplaceFailed,
                        relativePath: operation.destinationRelativePath
                    )
                }
            }
            return
        }
        guard currentDestination == operation.expectedDestination else {
            throw ControlledMirrorFailure(
                code: .destinationChangedDuringRun,
                relativePath: operation.destinationRelativePath
            )
        }
        let sourceRoot = roots.url(for: sourceSide)
        let currentSource = try fingerprintAt(
            root: sourceRoot,
            side: sourceSide,
            relativePath: sourcePath,
            eventKey: "op:\(operation.id.uuidString):source-preflight",
            providerMeter: providerMeter
        )
        guard currentSource == expectedSource else {
            throw ControlledMirrorFailure(code: .sourceChangedDuringRun, relativePath: sourcePath)
        }
        let source = try safeURL(root: sourceRoot, relativePath: sourcePath, allowStateDirectory: false)
        let destination = try safeURL(
            root: destinationRoot,
            relativePath: operation.destinationRelativePath,
            allowStateDirectory: false
        )
        let staging =
            destinationRoot
            .appendingPathComponent(Self.stateDirectoryName, isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(operation.id.uuidString)
        try ensureExistingComponentsAreNotSymlinks(
            root: destinationRoot,
            relativePath: Self.stateDirectoryName + "/staging"
        )
        do {
            try io.copyFileAtomically(
                from: source,
                sourceRoot: sourceRoot,
                sourceRelativePath: sourcePath,
                sourceIsExternal: sourceSide == .external,
                to: destination,
                destinationRoot: destinationRoot,
                destinationIsExternal: operation.destinationSide == .external,
                stagingAt: staging,
                operationID: operation.id,
                destinationRelativePath: operation.destinationRelativePath,
                expectedSource: expectedSource,
                expectedDestination: operation.expectedDestination,
                providerMeter: providerMeter
            )
        } catch ControlledMirrorIO.AtomicCopyFailure.sourceChanged {
            throw ControlledMirrorFailure(code: .sourceChangedDuringRun, relativePath: sourcePath)
        } catch ControlledMirrorIO.AtomicCopyFailure.destinationChanged {
            throw ControlledMirrorFailure(
                code: .destinationChangedDuringRun,
                relativePath: operation.destinationRelativePath
            )
        } catch ControlledMirrorIO.AtomicCopyFailure.unsafePath {
            throw ControlledMirrorFailure(
                code: .symbolicLinkRejected,
                relativePath: operation.destinationRelativePath
            )
        } catch {
            throw ControlledMirrorFailure(
                code: .atomicReplaceFailed,
                relativePath: operation.destinationRelativePath
            )
        }
        let installed = try fingerprintAt(
            root: destinationRoot,
            side: operation.destinationSide,
            relativePath: operation.destinationRelativePath,
            eventKey: "op:\(operation.id.uuidString):installed",
            providerMeter: providerMeter
        )
        guard installed == expectedSource else {
            throw ControlledMirrorFailure(
                code: .atomicReplaceFailed,
                relativePath: operation.destinationRelativePath
            )
        }
    }

    fileprivate func result(for journal: MirrorJournal) -> ControlledMirrorRunResult {
        var copiedToManaged = 0
        var copiedToExternal = 0
        for operation in journal.operations where operation.kind == .copyFile {
            switch operation.destinationSide {
            case .managed: copiedToManaged += 1
            case .external: copiedToExternal += 1
            }
        }
        return ControlledMirrorRunResult(
            generation: journal.targetGeneration,
            copiedToManaged: copiedToManaged,
            copiedToExternal: copiedToExternal,
            conflicts: journal.conflicts,
            confirmationRequired: journal.confirmations
        )
    }

    fileprivate func fingerprintAt(
        root: URL,
        side: ControlledMirrorSide,
        relativePath: String,
        eventKey: String,
        providerMeter: ControlledMirrorProviderMeterState
    ) throws -> Fingerprint? {
        let url = try safeURL(root: root, relativePath: relativePath, allowStateDirectory: false)
        try ensureExistingComponentsAreNotSymlinks(root: root, relativePath: relativePath)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return .directory }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: url.path)
        } catch {
            throw ControlledMirrorFailure(code: .ioRead, relativePath: relativePath)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ControlledMirrorFailure(code: .unsupportedEntryType, relativePath: relativePath)
        }
        let data: Data
        do {
            guard let size = attributes[.size] as? NSNumber,
                let byteCount = Int64(exactly: size), byteCount >= 0
            else {
                throw ControlledMirrorPreparedPlanError.changed
            }
            if side == .external {
                data = try providerMeter.performNext(
                    eventKeyPrefix: eventKey,
                    direction: .readExternalProvider,
                    byteCount: byteCount,
                    validate: { Int64($0.count) == byteCount },
                    { transfer in
                        try io.beforeProviderPayloadIO(transfer)
                        return try io.readData(at: url, exactByteCount: byteCount)
                    }
                )
            } else {
                data = try io.readData(at: url, exactByteCount: byteCount)
            }
        } catch {
            throw ControlledMirrorFailure(code: .ioRead, relativePath: relativePath)
        }
        return Fingerprint(kind: .file, contentDigest: Self.digest(data), byteCount: Int64(data.count))
    }

    fileprivate func safeURL(
        root: URL,
        relativePath: String,
        allowStateDirectory: Bool
    ) throws -> URL {
        try validateRelativePath(relativePath, allowStateDirectory: allowStateDirectory)
        let candidate = relativePath.split(separator: "/").reduce(root) {
            $0.appendingPathComponent(String($1))
        }.standardizedFileURL
        guard Self.contains(root, candidate), candidate != root else {
            throw ControlledMirrorFailure(code: .pathOutsideRoot, relativePath: relativePath)
        }
        return candidate
    }

    fileprivate func validateRelativePath(_ value: String, allowStateDirectory: Bool) throws {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty,
            !value.hasPrefix("/"),
            !value.contains("\0"),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw ControlledMirrorFailure(code: .invalidRelativePath, relativePath: value)
        }
        if !allowStateDirectory, components.first == Substring(Self.stateDirectoryName) {
            throw ControlledMirrorFailure(code: .invalidRelativePath, relativePath: value)
        }
    }

    fileprivate func ensureExistingComponentsAreNotSymlinks(root: URL, relativePath: String) throws {
        let manager = FileManager.default
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            if (try? manager.destinationOfSymbolicLink(atPath: current.path)) != nil {
                let relative = String(
                    current.path.dropFirst(root.path.count + (current.path.count > root.path.count ? 1 : 0))
                )
                throw ControlledMirrorFailure(code: .symbolicLinkRejected, relativePath: relative)
            }
            if !manager.fileExists(atPath: current.path) { return }
            if let attributes = try? manager.attributesOfItem(atPath: current.path),
                attributes[.type] as? FileAttributeType == .typeSymbolicLink
            {
                let relative = String(current.path.dropFirst(root.path.count + 1))
                throw ControlledMirrorFailure(code: .symbolicLinkRejected, relativePath: relative)
            }
        }
    }

    fileprivate func loadManifest(roots: Roots, mode _: ExternalDirectoryMode) throws -> MirrorManifest? {
        let managedURL = stateFileURL(root: roots.managed, fileName: Self.manifestFileName)
        if let manifest: MirrorManifest = try loadState(at: managedURL, root: roots.managed) {
            guard manifest.schemaVersion == Self.manifestSchemaVersion else {
                throw ControlledMirrorFailure(code: .unsupportedSchema)
            }
            return manifest
        }
        return nil
    }

    fileprivate func loadJournal(roots: Roots, mode _: ExternalDirectoryMode) throws -> MirrorJournal? {
        let managedURL = stateFileURL(root: roots.managed, fileName: Self.journalFileName)
        if let journal: MirrorJournal = try loadState(at: managedURL, root: roots.managed) {
            guard journal.schemaVersion == Self.journalSchemaVersion else {
                throw ControlledMirrorFailure(code: .unsupportedSchema)
            }
            return journal
        }
        return nil
    }

    fileprivate func loadState<T: Decodable>(at url: URL, root: URL) throws -> T? {
        let relative = Self.stateDirectoryName + "/" + url.lastPathComponent
        try ensureExistingComponentsAreNotSymlinks(root: root, relativePath: relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try io.readData(at: url)
        } catch {
            throw ControlledMirrorFailure(code: .ioRead, relativePath: relative)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw ControlledMirrorFailure(code: .stateCorrupt, relativePath: relative)
        }
    }

    fileprivate func persistManifest(
        _ manifest: MirrorManifest,
        roots: Roots,
        mode _: ExternalDirectoryMode
    ) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(manifest)
        } catch {
            throw ControlledMirrorFailure(code: .ioWrite)
        }
        try writeState(data, root: roots.managed, fileName: Self.manifestFileName)
    }

    fileprivate func persistJournal(_ journal: MirrorJournal, roots: Roots) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(journal)
        } catch {
            throw ControlledMirrorFailure(code: .ioWrite)
        }
        try writeState(data, root: roots.managed, fileName: Self.journalFileName)
    }

    fileprivate func writeState(_ data: Data, root: URL, fileName: String) throws {
        let relative = Self.stateDirectoryName + "/" + fileName
        try ensureExistingComponentsAreNotSymlinks(root: root, relativePath: relative)
        let url = stateFileURL(root: root, fileName: fileName)
        do {
            try io.writeDataAtomically(data, to: url)
        } catch {
            throw ControlledMirrorFailure(code: .ioWrite, relativePath: relative)
        }
    }

    fileprivate func stateFileURL(root: URL, fileName: String) -> URL {
        root.appendingPathComponent(Self.stateDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    fileprivate static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    fileprivate static var decoder: JSONDecoder { JSONDecoder() }

    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func firstDifference(expected: [ManifestEntry], actual: [ManifestEntry]) -> String? {
        let expectedByPath = Dictionary(uniqueKeysWithValues: expected.map { ($0.relativePath, $0) })
        let actualByPath = Dictionary(uniqueKeysWithValues: actual.map { ($0.relativePath, $0) })
        return Set(expectedByPath.keys).union(actualByPath.keys).sorted().first {
            expectedByPath[$0] != actualByPath[$0]
        }
    }
}
