import Foundation

public enum ExternalDirectoryMode: String, Codable, CaseIterable, Sendable {
    case direct
    case controlledMirror
    case importOnly
    case exportOnly
    case readOnly

    public static var productModes: [ExternalDirectoryMode] {
        [.controlledMirror, .importOnly, .exportOnly, .readOnly]
    }
}

public struct ExternalDirectoryCapabilities: Codable, Hashable, Sendable {
    public var canEnumerate: Bool
    public var canRead: Bool
    public var canCreate: Bool
    public var canWrite: Bool
    public var canAtomicallyReplace: Bool
    public var canRename: Bool
    public var canDelete: Bool
    public var canAccessRecursively: Bool
    public var cleanupSucceeded: Bool
    public var recommendedMode: ExternalDirectoryMode
    public var failures: [String]

    public init(
        canEnumerate: Bool = false,
        canRead: Bool = false,
        canCreate: Bool = false,
        canWrite: Bool = false,
        canAtomicallyReplace: Bool = false,
        canRename: Bool = false,
        canDelete: Bool = false,
        canAccessRecursively: Bool = false,
        cleanupSucceeded: Bool = true,
        recommendedMode: ExternalDirectoryMode = .readOnly,
        failures: [String] = []
    ) {
        self.canEnumerate = canEnumerate
        self.canRead = canRead
        self.canCreate = canCreate
        self.canWrite = canWrite
        self.canAtomicallyReplace = canAtomicallyReplace
        self.canRename = canRename
        self.canDelete = canDelete
        self.canAccessRecursively = canAccessRecursively
        self.cleanupSucceeded = cleanupSucceeded
        self.recommendedMode = recommendedMode
        self.failures = failures
    }
}

public enum ExternalDirectoryMirrorPhase: String, Codable, Hashable, Sendable {
    case neverRun
    case running
    case succeeded
    case requiresConfirmation
    case retryableFailure
    case cancelled
}

public enum ExternalDirectoryMirrorFailureCode: String, Codable, Hashable, Sendable {
    case interrupted
    case cancelled
    case bookmarkStale
    case authorizationRevoked
    case providerOffline
    case policyDenied
    case unsafePath
    case pathCollision
    case concurrentChange
    case stateCorrupt
    case mirrorIOFailure
    case rescanQueueFailed
}

public struct ExternalDirectoryMirrorStatus: Codable, Hashable, Sendable {
    public var phase: ExternalDirectoryMirrorPhase
    public var lastAttemptedAt: Date?
    public var lastCompletedAt: Date?
    public var importedFiles: Int
    public var exportedFiles: Int
    public var conflictCount: Int
    public var deleteConfirmationCount: Int
    public var failureCode: ExternalDirectoryMirrorFailureCode?

    public init(
        phase: ExternalDirectoryMirrorPhase = .neverRun,
        lastAttemptedAt: Date? = nil,
        lastCompletedAt: Date? = nil,
        importedFiles: Int = 0,
        exportedFiles: Int = 0,
        conflictCount: Int = 0,
        deleteConfirmationCount: Int = 0,
        failureCode: ExternalDirectoryMirrorFailureCode? = nil
    ) {
        self.phase = phase
        self.lastAttemptedAt = lastAttemptedAt
        self.lastCompletedAt = lastCompletedAt
        self.importedFiles = importedFiles
        self.exportedFiles = exportedFiles
        self.conflictCount = conflictCount
        self.deleteConfirmationCount = deleteConfirmationCount
        self.failureCode = failureCode
    }
}

public enum ExternalDirectoryAuthorizationState: String, Codable, Hashable, Sendable {
    case active
    case revoked
}

public enum ExternalDirectorySyncBindingPhase: String, Codable, Hashable, Sendable {
    /// A durable add-folder command is ready to be queued or is already pending.
    case queued
    /// The latest core snapshot contains the expected folder ID at the exact
    /// managed root as an active, local-only Send & Receive folder. This is the
    /// only state the UI may present as connected.
    case verified
    /// A previously verified folder disappeared. Re-adding it requires an
    /// explicit repair action because removal may have been intentional.
    case repairRequired
    /// An unsafe root, overlap, or folder-ID/path mismatch blocks configuration.
    case conflict
    /// The durable command reached a terminal failure and requires user retry.
    case failed
}

public struct ExternalDirectorySyncBinding: Codable, Hashable, Sendable {
    public var folderID: FolderID
    public var commandID: UUID
    public var phase: ExternalDirectorySyncBindingPhase
    /// Stable, path-free diagnostic code. Provider and filesystem descriptions
    /// are never persisted here.
    public var failureCode: String?
    public var lastCheckedAt: Date?

    public init(
        folderID: FolderID,
        commandID: UUID = UUID(),
        phase: ExternalDirectorySyncBindingPhase = .queued,
        failureCode: String? = nil,
        lastCheckedAt: Date? = nil
    ) {
        self.folderID = folderID
        self.commandID = commandID
        self.phase = phase
        self.failureCode = failureCode
        self.lastCheckedAt = lastCheckedAt
    }

    fileprivate static func initial(recordID: UUID) throws -> Self {
        guard let folderID = FolderID(rawValue: "external-\(recordID.uuidString.lowercased())") else {
            throw ExternalDirectoryError.invalidBindingIdentifier
        }
        return Self(folderID: folderID)
    }
}

public struct ExternalDirectoryBindingReconciliation: Hashable, Sendable {
    public var enqueuedCommandCount: Int
    public var verifiedRecordCount: Int
    public var attentionRecordCount: Int

    public init(
        enqueuedCommandCount: Int = 0,
        verifiedRecordCount: Int = 0,
        attentionRecordCount: Int = 0
    ) {
        self.enqueuedCommandCount = enqueuedCommandCount
        self.verifiedRecordCount = verifiedRecordCount
        self.attentionRecordCount = attentionRecordCount
    }
}

public struct ExternalDirectoryRecord: Codable, Hashable, Sendable, Identifiable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public let id: UUID
    public var displayName: String
    public var bookmark: Data
    public var authorizationState: ExternalDirectoryAuthorizationState
    /// Monotonic authorization generation captured by long-running work. A
    /// revocation advances it before clearing the bookmark, so a stale broker
    /// cannot commit a result produced under an older security scope.
    public var authorizationEpoch: UInt64
    /// Monotonic durable record revision. Every records-file transaction that
    /// changes an existing record advances this value.
    public var revision: UInt64
    public var mode: ExternalDirectoryMode
    public var capabilities: ExternalDirectoryCapabilities
    /// Opaque UUID component used below App Group/ManagedFolders/External.
    /// It never contains or derives from an absolute filesystem path.
    public var managedRootToken: String
    public var syncBinding: ExternalDirectorySyncBinding
    public var lastMirrorStatus: ExternalDirectoryMirrorStatus
    /// Relative-path-only prompts persisted across launches. Each prompt also
    /// carries the digest the user reviewed, so stale UI cannot authorize a
    /// changed file deletion.
    public var pendingDeletionConfirmations: [ControlledMirrorConfirmation]
    public var lastProbedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        displayName: String,
        bookmark: Data,
        authorizationState: ExternalDirectoryAuthorizationState = .active,
        authorizationEpoch: UInt64 = 1,
        revision: UInt64 = 1,
        mode: ExternalDirectoryMode,
        capabilities: ExternalDirectoryCapabilities,
        managedRootToken: String? = nil,
        syncBinding: ExternalDirectorySyncBinding? = nil,
        lastMirrorStatus: ExternalDirectoryMirrorStatus = .init(),
        pendingDeletionConfirmations: [ControlledMirrorConfirmation] = [],
        lastProbedAt: Date = .now
    ) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.authorizationState = authorizationState
        self.authorizationEpoch = authorizationEpoch
        self.revision = revision
        self.mode = mode
        self.capabilities = capabilities
        self.managedRootToken = managedRootToken ?? id.uuidString.lowercased()
        self.syncBinding = try syncBinding ?? .initial(recordID: id)
        self.lastMirrorStatus = lastMirrorStatus
        self.pendingDeletionConfirmations = pendingDeletionConfirmations
        self.lastProbedAt = lastProbedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case displayName
        case bookmark
        case authorizationState
        case authorizationEpoch
        case revision
        case mode
        case capabilities
        case managedRootToken
        case syncBinding
        case lastMirrorStatus
        case pendingDeletionConfirmations
        case lastProbedAt
        // Decode-only legacy field. It is deliberately never encoded.
        case lastResolvedPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        authorizationState =
            try container.decodeIfPresent(
                ExternalDirectoryAuthorizationState.self,
                forKey: .authorizationState
            ) ?? .active
        authorizationEpoch = try container.decodeIfPresent(UInt64.self, forKey: .authorizationEpoch) ?? 1
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 1
        mode = try container.decode(ExternalDirectoryMode.self, forKey: .mode)
        capabilities = try container.decode(ExternalDirectoryCapabilities.self, forKey: .capabilities)
        managedRootToken =
            try container.decodeIfPresent(String.self, forKey: .managedRootToken)
            ?? id.uuidString.lowercased()
        syncBinding =
            try container.decodeIfPresent(
                ExternalDirectorySyncBinding.self,
                forKey: .syncBinding
            ) ?? ExternalDirectorySyncBinding.initial(recordID: id)
        lastMirrorStatus =
            try container.decodeIfPresent(
                ExternalDirectoryMirrorStatus.self,
                forKey: .lastMirrorStatus
            ) ?? .init()
        pendingDeletionConfirmations =
            try container.decodeIfPresent(
                [ControlledMirrorConfirmation].self,
                forKey: .pendingDeletionConfirmations
            ) ?? []
        lastProbedAt = try container.decodeIfPresent(Date.self, forKey: .lastProbedAt) ?? .distantPast
        _ = try? container.decode(String.self, forKey: .lastResolvedPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(bookmark, forKey: .bookmark)
        try container.encode(authorizationState, forKey: .authorizationState)
        try container.encode(authorizationEpoch, forKey: .authorizationEpoch)
        try container.encode(revision, forKey: .revision)
        try container.encode(mode, forKey: .mode)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(managedRootToken, forKey: .managedRootToken)
        try container.encode(syncBinding, forKey: .syncBinding)
        try container.encode(lastMirrorStatus, forKey: .lastMirrorStatus)
        try container.encode(pendingDeletionConfirmations, forKey: .pendingDeletionConfirmations)
        try container.encode(lastProbedAt, forKey: .lastProbedAt)
    }
}

public enum ExternalDirectoryError: Error, Sendable, LocalizedError, Equatable {
    case authorizationDenied
    case bookmarkStale
    case unavailable
    case recordNotFound
    case unsupportedRecordSchema(Int)
    case capabilityProbeFailed([String])
    case deletionNotSupported
    case deletionConfirmationUnavailable
    case deletionConfirmationChanged
    case authorizationAlreadyRevoked
    case mirrorAlreadyRunning
    case bindingNotVerified
    case invalidBindingIdentifier
    case unsafeManagedRoot
    case bindingConflict
    case policyDenied
    case rescanQueueFailed
    case recoveryUnavailable
    case recoveryChanged
    case recoveryActive
    case recoveryExportFailed
    case recoveryDisposalFailed

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied: "Access to the selected directory was denied or revoked."
        case .bookmarkStale: "The saved directory permission is stale and must be selected again."
        case .unavailable: "The selected file provider or directory is currently unavailable."
        case .recordNotFound: "The external directory authorization record no longer exists."
        case .unsupportedRecordSchema(let version): "Unsupported external-directory record schema: \(version)."
        case .capabilityProbeFailed(let failures):
            "Directory capability probe failed: \(failures.joined(separator: "; "))"
        case .deletionNotSupported:
            "The external provider did not prove that it can delete this item safely. No deletion was attempted."
        case .deletionConfirmationUnavailable:
            "This deletion confirmation is no longer available. Refresh the mirror before deciding again."
        case .deletionConfirmationChanged:
            "Mirror content changed after this deletion was shown. No deletion was attempted; run the mirror again."
        case .authorizationAlreadyRevoked:
            "The external-directory authorization has already been removed."
        case .mirrorAlreadyRunning:
            "This external-directory mirror is already running in another process."
        case .bindingNotVerified:
            "The managed mirror is not verified in the latest Syncthing snapshot. Repair the binding before copying files."
        case .invalidBindingIdentifier:
            "The external directory cannot be assigned a safe Syncthing folder identifier."
        case .unsafeManagedRoot:
            "The managed mirror root is unsafe or unavailable. No Syncthing command was queued."
        case .bindingConflict:
            "The managed mirror conflicts with an existing Syncthing folder. No command was queued."
        case .policyDenied:
            "The external-directory operation was blocked by the current sync policy."
        case .rescanQueueFailed:
            "Mirror files changed, but the required Syncthing rescan could not be queued. The mirror is not reported as synchronized."
        case .recoveryUnavailable:
            "The retained recovery item is no longer available. Refresh before deciding again."
        case .recoveryChanged:
            "The retained recovery item changed after it was shown. No recovery data was removed."
        case .recoveryActive:
            "The retained recovery item is still required by an unfinished mirror journal. Resume the mirror before deleting it."
        case .recoveryExportFailed:
            "A safe temporary snapshot of the retained recovery item could not be created. The recovery item remains unchanged."
        case .recoveryDisposalFailed:
            "The retained recovery item could not be removed safely and remains available."
        }
    }
}

public struct ExternalDirectoryBookmarkResolution: Sendable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

public struct ExternalDirectoryBookmarkAccess: Sendable {
    public typealias Create = @Sendable (URL) throws -> Data
    public typealias Resolve = @Sendable (Data) throws -> ExternalDirectoryBookmarkResolution
    public typealias Begin = @Sendable (URL) -> Bool
    public typealias End = @Sendable (URL) -> Void

    private let createBody: Create
    private let resolveBody: Resolve
    private let beginBody: Begin
    private let endBody: End

    public init(
        create: @escaping Create,
        resolve: @escaping Resolve,
        beginAccess: @escaping Begin,
        endAccess: @escaping End
    ) {
        createBody = create
        resolveBody = resolve
        beginBody = beginAccess
        endBody = endAccess
    }

    public func createBookmark(for url: URL) throws -> Data { try createBody(url) }
    public func resolve(_ bookmark: Data) throws -> ExternalDirectoryBookmarkResolution { try resolveBody(bookmark) }
    public func beginAccess(to url: URL) -> Bool { beginBody(url) }
    public func endAccess(to url: URL) { endBody(url) }

    public static let system = ExternalDirectoryBookmarkAccess(
        create: { url in
            #if os(macOS)
                let options: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
                // iOS, including Designed for iPad on Apple silicon Mac, uses
                // the picker-provided recursive security scope. Apple documents
                // minimal bookmarks for persisting those directory/child URLs;
                // macOS-only withSecurityScope is unavailable in this branch.
                let options: URL.BookmarkCreationOptions = [.minimalBookmark]
            #endif
            return try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
                relativeTo: nil
            )
        },
        resolve: { bookmark in
            var stale = false
            #if os(macOS)
                let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
            #else
                let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutImplicitStartAccessing]
            #endif
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return ExternalDirectoryBookmarkResolution(url: url, isStale: stale)
        },
        beginAccess: { $0.startAccessingSecurityScopedResource() },
        endAccess: { $0.stopAccessingSecurityScopedResource() }
    )
}

public final class ExternalDirectoryMirrorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public struct ExternalDirectoryMirrorExecution: Hashable, Sendable {
    public let recordID: UUID
    public let status: ExternalDirectoryMirrorStatus

    public init(recordID: UUID, status: ExternalDirectoryMirrorStatus) {
        self.recordID = recordID
        self.status = status
    }
}

protocol ExternalDirectoryFileCoordinating: Sendable {
    func coordinateReading(
        at url: URL,
        operation: (URL) throws -> Void
    ) throws

    func coordinateWriting(
        at url: URL,
        operation: (URL) throws -> Void
    ) throws
}

public struct ExternalDirectoryCapabilityProbe: Sendable {
    private let fileAccess: any ExternalDirectoryFileCoordinating

    public init() {
        fileAccess = CoordinatedFileAccess()
    }

    init(fileAccess: any ExternalDirectoryFileCoordinating) {
        self.fileAccess = fileAccess
    }

    public func run(at root: URL) -> ExternalDirectoryCapabilities {
        var result = ExternalDirectoryCapabilities()
        let manager = FileManager.default
        let probeName = ".psynguechthyngue-capability-\(UUID().uuidString)"
        let payload = Data("psynguechthyngue-capability-probe-v1".utf8)

        func record(_ capability: String, _ operation: () throws -> Void) -> Bool {
            do {
                try operation()
                return true
            } catch {
                result.failures.append("\(capability): \(Self.safeDescription(error))")
                return false
            }
        }

        var readAccessorRan = false
        do {
            try fileAccess.coordinateReading(at: root) { coordinatedRoot in
                readAccessorRan = true
                result.canEnumerate = record("enumerate") {
                    _ = try manager.contentsOfDirectory(
                        at: coordinatedRoot,
                        includingPropertiesForKeys: [.isDirectoryKey]
                    )
                }
            }
            guard readAccessorRan else { throw ExternalDirectoryError.unavailable }
        } catch {
            result.canEnumerate = false
            result.failures.append("readCoordination: \(Self.safeDescription(error))")
        }

        var writeAccessorRan = false
        do {
            try fileAccess.coordinateWriting(at: root) { coordinatedRoot in
                writeAccessorRan = true
                let probeRoot = coordinatedRoot.appendingPathComponent(probeName, isDirectory: true)
                let first = probeRoot.appendingPathComponent("first.bin")
                let replacement = probeRoot.appendingPathComponent("replacement.bin")
                let renamed = probeRoot.appendingPathComponent("renamed.bin")

                result.canCreate = record("create") {
                    try manager.createDirectory(at: probeRoot, withIntermediateDirectories: false)
                    try payload.write(to: first, options: .withoutOverwriting)
                }
                if result.canCreate {
                    result.canRead = record("read") {
                        guard try Data(contentsOf: first) == payload else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                    }
                    result.canWrite = record("write") {
                        try Data(payload.reversed()).write(to: first, options: .atomic)
                    }
                    result.canAtomicallyReplace = record("atomicReplace") {
                        try payload.write(to: replacement, options: .withoutOverwriting)
                        _ = try manager.replaceItemAt(first, withItemAt: replacement)
                    }
                    result.canRename = record("rename") {
                        try manager.moveItem(at: first, to: renamed)
                    }
                    result.canAccessRecursively = record("recursive") {
                        guard
                            let enumerator = manager.enumerator(
                                at: probeRoot,
                                includingPropertiesForKeys: nil
                            )
                        else {
                            throw CocoaError(.fileReadUnknown)
                        }
                        guard enumerator.nextObject() != nil else {
                            throw CocoaError(.fileReadNoSuchFile)
                        }
                    }
                    result.canDelete = record("delete") {
                        try manager.removeItem(at: renamed)
                    }
                } else {
                    // A read-only provider may still expose existing readable children.
                    result.canRead = result.canEnumerate
                }

                if manager.fileExists(atPath: probeRoot.path) {
                    result.cleanupSucceeded = record("cleanup") {
                        try manager.removeItem(at: probeRoot)
                    }
                }
            }
            guard writeAccessorRan else { throw ExternalDirectoryError.unavailable }
        } catch {
            result.canCreate = false
            result.canWrite = false
            result.canAtomicallyReplace = false
            result.canRename = false
            result.canDelete = false
            result.canAccessRecursively = false
            result.cleanupSucceeded = false
            result.failures.append("writeCoordination: \(Self.safeDescription(error))")
        }

        let direct =
            result.canEnumerate && result.canRead && result.canCreate && result.canWrite
            && result.canAtomicallyReplace && result.canRename && result.canDelete
            && result.canAccessRecursively && result.cleanupSucceeded
        if direct {
            result.recommendedMode = .direct
        } else if result.canEnumerate, result.canRead, result.canCreate, result.canWrite {
            result.recommendedMode = .controlledMirror
        } else if result.canEnumerate, result.canRead {
            result.recommendedMode = .importOnly
        } else {
            result.recommendedMode = .readOnly
        }
        return result
    }

    private static func safeDescription(_ error: Error) -> String {
        let value = error as NSError
        // Provider errors can contain private paths. Persist only stable domain/code fields.
        return "\(value.domain)(\(value.code))"
    }
}

/// An advisory lease kept open for the complete mirror run. Mirror contenders
/// acquire it non-blockingly; revocation acquires it blocking on a detached
/// task. Thus revocation linearizes after every in-flight filesystem commit
/// and, once it returns, no old authorization epoch can copy or remove data.
/// The UUID-only filename is shared across broker instances and processes.
private final class ExternalDirectoryMirrorLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func tryAcquire(at url: URL) throws -> ExternalDirectoryMirrorLease? {
        try acquire(at: url, nonBlocking: true)
    }

    static func acquire(at url: URL) throws -> ExternalDirectoryMirrorLease {
        guard let lease = try acquire(at: url, nonBlocking: false) else {
            throw CocoaError(.fileLocking)
        }
        return lease
    }

    private static func acquire(
        at url: URL,
        nonBlocking: Bool
    ) throws -> ExternalDirectoryMirrorLease? {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let operation = nonBlocking ? LOCK_EX | LOCK_NB : LOCK_EX
        guard flock(descriptor, operation) == 0 else {
            let lockError = errno
            close(descriptor)
            if nonBlocking, lockError == EWOULDBLOCK || lockError == EAGAIN { return nil }
            throw CocoaError(.fileLocking)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw CocoaError(.fileWriteNoPermission)
        }
        return ExternalDirectoryMirrorLease(descriptor: descriptor)
    }

    func release() {
        stateLock.lock()
        let current = descriptor
        descriptor = -1
        stateLock.unlock()
        guard current >= 0 else { return }
        flock(current, LOCK_UN)
        close(current)
    }

    deinit {
        release()
    }
}

private enum ExternalDirectoryLivePolicyError: Error, Sendable {
    case denied
}

private struct ExternalDirectoryTransferAccountingPreparation: Sendable {
    let folderContext: FolderPolicyContext
    let budgetTimeZoneIdentifier: String
    let store: TransferAccountingStore
    let capturedAt: Date
    let runLimitBytes: Int64?
    let globalDailyLimitBytes: Int64?
    let folderDailyLimitBytes: Int64?
}

/// ControlledMirror's provider I/O seam is synchronous because it wraps
/// NSFileCoordinator. This gate performs a fresh async environment capture and
/// policy-file load for every checkpoint, then offers a narrow blocking bridge.
/// The bridge inherits the caller's task priority so a foreground provider
/// request never blocks on lower-priority policy work. No cached allow decision
/// survives to a later file read, copy swap, or delete commit.
private final class ExternalDirectoryLivePolicyGate: @unchecked Sendable {
    typealias CurrentEnvironment = @Sendable () async -> SyncEnvironmentSnapshot

    private let policyURL: URL
    private let folderIncarnationsURL: URL
    private let transferAccountingURL: URL
    private let folderID: FolderID
    private let trigger: SyncTrigger
    private let requestedTemporaryOverride: Bool
    private let currentEnvironment: CurrentEnvironment
    private let lock = NSLock()
    private var denied = false

    init(
        policyURL: URL,
        folderIncarnationsURL: URL,
        transferAccountingURL: URL,
        folderID: FolderID,
        trigger: SyncTrigger,
        requestedTemporaryOverride: Bool,
        currentEnvironment: @escaping CurrentEnvironment
    ) {
        self.policyURL = policyURL
        self.folderIncarnationsURL = folderIncarnationsURL
        self.transferAccountingURL = transferAccountingURL
        self.folderID = folderID
        self.trigger = trigger
        self.requestedTemporaryOverride = requestedTemporaryOverride
        self.currentEnvironment = currentEnvironment
    }

    var policyWasDenied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return denied
    }

    func prepareTransferAccounting(
        for plan: ControlledMirrorPreparedPlan,
        actions: Set<SyncAction>,
        managedRoot: URL
    ) async throws -> ExternalDirectoryTransferAccountingPreparation {
        do {
            let context = try currentFolderContext()
            let document = try SyncPolicyStore(url: policyURL).loadDocument()
            let resolvedPolicy = try document.resolvedPolicy(
                for: context.folderID,
                folderIncarnationDigest: context.folderIncarnationDigest
            )
            let store = TransferAccountingStore(
                url: transferAccountingURL,
                budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
            )
            let provisionalBinding = TransferAccountingGrantBinding(
                workKind: .externalMirror,
                folderID: context.folderID,
                folderIncarnationDigest: context.folderIncarnationDigest,
                taskID: plan.runID,
                runID: plan.runID,
                sessionID: UUID(),
                planDigest: plan.planDigest
            )
            var environment = await currentEnvironment()
            let usage = try store.usage(for: provisionalBinding, at: environment.capturedAt)
            let pending = plan.logicalTransfers.filter { !$0.isCompleted }
            let largestFileBytes = pending.map(\.byteCount).max() ?? 0
            let pendingDownloadBytes = try Self.sum(
                pending.compactMap {
                    $0.direction == .fromExternalProvider
                        || $0.direction == .readExternalProvider
                        ? $0.byteCount : nil
                }
            )
            let pendingInstallBytes = try Self.sum(
                pending.compactMap {
                    $0.direction == .fromExternalProvider ? $0.byteCount : nil
                }
            )
            environment.transfer = TransferEstimate(
                largestFileBytes: largestFileBytes,
                totalBytes: plan.remainingLogicalProviderBytes,
                pendingDownloadBytes: pendingDownloadBytes,
                alreadyTransferredTodayBytes: usage.effectiveBytes
            )
            try Self.validateAvailableCapacity(
                policy: resolvedPolicy,
                additionalDiskBytes: pendingInstallBytes,
                destinationVolume: managedRoot
            )
            try validatePolicy(
                document: document,
                resolvedPolicy: resolvedPolicy,
                environment: environment,
                actions: actions,
                additionalDiskBytes: pendingInstallBytes,
                globalAlreadyTransferredBytes: usage.effectiveBytes,
                folderAlreadyTransferredBytes: usage.folderEffectiveBytes
            )
            return ExternalDirectoryTransferAccountingPreparation(
                folderContext: context,
                budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier,
                store: store,
                capturedAt: environment.capturedAt,
                runLimitBytes: resolvedPolicy.maxExpensiveRunBytes,
                globalDailyLimitBytes: document.global.dailyExpensiveBytes,
                folderDailyLimitBytes: resolvedPolicy.dailyExpensiveBytes
            )
        } catch {
            if error is TransferAccountingError {
                recordAccountingDenial(for: error)
            } else {
                recordDenial()
            }
            throw ExternalDirectoryLivePolicyError.denied
        }
    }

    func validatePayload(
        _ transfer: ControlledMirrorLogicalTransfer,
        session: ExternalMirrorTransferSession,
        completedBytes: Int64,
        expectedBudgetTimeZoneIdentifier: String,
        managedRoot: URL,
        externalRoot: URL
    ) async throws {
        do {
            guard completedBytes >= 0 else {
                throw ExternalDirectoryLivePolicyError.denied
            }
            let context = try currentFolderContext()
            guard context.folderID == session.binding.folderID,
                context.folderIncarnationDigest == session.binding.folderIncarnationDigest
            else {
                throw ExternalDirectoryLivePolicyError.denied
            }
            let document = try SyncPolicyStore(url: policyURL).loadDocument()
            guard
                document.budgetTimeZoneIdentifier
                    == expectedBudgetTimeZoneIdentifier
            else {
                throw ExternalDirectoryLivePolicyError.denied
            }
            let resolvedPolicy = try document.resolvedPolicy(
                for: context.folderID,
                folderIncarnationDigest: context.folderIncarnationDigest
            )
            let store = TransferAccountingStore(
                url: transferAccountingURL,
                budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
            )
            var environment = await currentEnvironment()
            guard
                try Self.budgetDayKey(
                    at: environment.capturedAt,
                    timeZoneIdentifier: document.budgetTimeZoneIdentifier
                ) == session.reservation.dayKey
            else {
                throw ExternalDirectoryLivePolicyError.denied
            }
            let usage = try store.usage(for: session.binding, at: environment.capturedAt)
            let runUsage = try store.runUsage(for: session.binding)
            let ownGrant = session.reservation.grantBytes
            let globalBaseline = max(0, usage.effectiveBytes - ownGrant)
            let folderBaseline = max(0, usage.folderEffectiveBytes - ownGrant)
            let runBaseline = max(0, runUsage.effectiveBytes - ownGrant)
            let (projectedSessionBytes, sessionOverflow) =
                completedBytes
                .addingReportingOverflow(transfer.byteCount)
            let (projectedRunBytes, runOverflow) =
                runBaseline
                .addingReportingOverflow(projectedSessionBytes)
            guard !sessionOverflow, !runOverflow else {
                throw ExternalDirectoryLivePolicyError.denied
            }

            let actions: Set<SyncAction>
            let destinationVolume: URL
            let additionalDiskBytes: Int64
            switch transfer.direction {
            case .fromExternalProvider:
                actions = [.scan, .hash, .download]
                destinationVolume = managedRoot
                additionalDiskBytes = transfer.byteCount
            case .toExternalProvider:
                actions = [.scan, .hash, .upload]
                destinationVolume = externalRoot
                additionalDiskBytes = transfer.byteCount
            case .withinExternalProvider:
                actions = [.scan, .hash, .upload, .download]
                destinationVolume = externalRoot
                additionalDiskBytes = transfer.byteCount
            case .readExternalProvider:
                actions = [.scan, .hash, .download]
                destinationVolume = managedRoot
                additionalDiskBytes = 0
            }
            try Self.validateAvailableCapacity(
                policy: resolvedPolicy,
                additionalDiskBytes: additionalDiskBytes,
                destinationVolume: destinationVolume
            )
            environment.transfer = TransferEstimate(
                largestFileBytes: transfer.byteCount,
                totalBytes: projectedSessionBytes,
                pendingDownloadBytes: actions.contains(.download) ? transfer.byteCount : 0,
                alreadyTransferredTodayBytes: globalBaseline
            )
            if environment.network.isExpensive,
                let limit = resolvedPolicy.maxExpensiveRunBytes,
                projectedRunBytes > limit
            {
                throw ExternalDirectoryLivePolicyError.denied
            }
            try validatePolicy(
                document: document,
                resolvedPolicy: resolvedPolicy,
                environment: environment,
                actions: actions,
                additionalDiskBytes: additionalDiskBytes,
                globalAlreadyTransferredBytes: globalBaseline,
                folderAlreadyTransferredBytes: folderBaseline
            )
        } catch {
            if error is TransferAccountingError {
                recordAccountingDenial(for: error)
            } else {
                recordDenial()
            }
            throw ExternalDirectoryLivePolicyError.denied
        }
    }

    func validatePayloadSynchronously(
        _ transfer: ControlledMirrorLogicalTransfer,
        session: ExternalMirrorTransferSession,
        completedBytes: Int64,
        expectedBudgetTimeZoneIdentifier: String,
        managedRoot: URL,
        externalRoot: URL
    ) throws {
        let waiter = ExternalDirectoryPolicyValidationWaiter()
        let priority = Task.currentPriority
        Task.detached(priority: priority) { [self] in
            do {
                try await validatePayload(
                    transfer,
                    session: session,
                    completedBytes: completedBytes,
                    expectedBudgetTimeZoneIdentifier: expectedBudgetTimeZoneIdentifier,
                    managedRoot: managedRoot,
                    externalRoot: externalRoot
                )
                waiter.complete(allowed: true)
            } catch {
                waiter.complete(allowed: false)
            }
        }
        guard waiter.wait() else { throw ExternalDirectoryLivePolicyError.denied }
    }

    func recordAccountingDenial(for error: Error) {
        switch error as? TransferAccountingError {
        case .dailyLimitExceeded?, .folderDailyLimitExceeded?, .runLimitExceeded?,
            .runAlreadyFinished?:
            recordDenial()
        default:
            break
        }
    }

    func validate(
        actions: Set<SyncAction>,
        transferBytes: Int64 = 0,
        additionalDiskBytes: Int64 = 0,
        destinationVolume: URL? = nil
    ) async throws {
        do {
            let context = try FolderIncarnationStore(url: folderIncarnationsURL)
                .policyContext(for: folderID)
            let document = try SyncPolicyStore(url: policyURL).loadDocument()
            let resolvedPolicy = try document.resolvedPolicy(
                for: context.folderID,
                folderIncarnationDigest: context.folderIncarnationDigest
            )
            let calendar = try document.fixedBudgetCalendar()
            var environment = await currentEnvironment()
            let usageBinding = TransferAccountingGrantBinding(
                folderID: context.folderID,
                folderIncarnationDigest: context.folderIncarnationDigest,
                taskID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                sessionID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
                planDigest: context.folderIncarnationDigest
            )
            let usage = try TransferAccountingStore(
                url: transferAccountingURL,
                budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
            ).usage(for: usageBinding, at: environment.capturedAt)
            let bytes = max(0, transferBytes)
            environment.transfer.largestFileBytes = max(
                environment.transfer.largestFileBytes,
                bytes
            )
            environment.transfer.totalBytes = max(environment.transfer.totalBytes, bytes)

            let additionalBytes = max(0, additionalDiskBytes)
            if let destinationVolume, additionalBytes > 0 {
                guard let available = Self.availableCapacity(at: destinationVolume) else {
                    throw ExternalDirectoryLivePolicyError.denied
                }
                let (required, overflow) = max(0, resolvedPolicy.minimumFreeDiskBytes)
                    .addingReportingOverflow(additionalBytes)
                guard !overflow, available >= required else {
                    throw ExternalDirectoryLivePolicyError.denied
                }
            }

            for (policy, alreadyTransferredBytes) in [
                (document.global, usage.effectiveBytes),
                (resolvedPolicy, usage.folderEffectiveBytes),
            ] {
                environment.transfer.alreadyTransferredTodayBytes = alreadyTransferredBytes
                let input = environment.policyInput(
                    trigger: trigger,
                    requestedActions: actions,
                    additionalDiskBytes: additionalBytes,
                    requestedTemporaryOverride: requestedTemporaryOverride
                )
                let decision = SyncPolicyEngine().evaluate(
                    input,
                    policy: policy,
                    calendar: calendar
                )
                guard decision.blockedActions.isEmpty else {
                    throw ExternalDirectoryLivePolicyError.denied
                }
            }
        } catch {
            if error is TransferAccountingError {
                recordAccountingDenial(for: error)
            } else {
                recordDenial()
            }
            throw ExternalDirectoryLivePolicyError.denied
        }
    }

    func validateSynchronously(
        actions: Set<SyncAction>,
        transferBytes: Int64 = 0,
        additionalDiskBytes: Int64 = 0,
        destinationVolume: URL? = nil
    ) throws {
        let waiter = ExternalDirectoryPolicyValidationWaiter()
        let priority = Task.currentPriority
        Task.detached(priority: priority) { [self] in
            do {
                try await validate(
                    actions: actions,
                    transferBytes: transferBytes,
                    additionalDiskBytes: additionalDiskBytes,
                    destinationVolume: destinationVolume
                )
                waiter.complete(allowed: true)
            } catch {
                waiter.complete(allowed: false)
            }
        }
        guard waiter.wait() else { throw ExternalDirectoryLivePolicyError.denied }
    }

    func rejectUnknownTransferSize() throws -> Never {
        recordDenial()
        throw ExternalDirectoryLivePolicyError.denied
    }

    private func currentFolderContext() throws -> FolderPolicyContext {
        try FolderIncarnationStore(url: folderIncarnationsURL)
            .policyContext(for: folderID)
    }

    private func validatePolicy(
        document: SyncPolicyDocumentV2,
        resolvedPolicy: SyncPolicy,
        environment: SyncEnvironmentSnapshot,
        actions: Set<SyncAction>,
        additionalDiskBytes: Int64,
        globalAlreadyTransferredBytes: Int64,
        folderAlreadyTransferredBytes: Int64
    ) throws {
        let calendar = try document.fixedBudgetCalendar()
        for (policy, alreadyTransferredBytes) in [
            (document.global, globalAlreadyTransferredBytes),
            (resolvedPolicy, folderAlreadyTransferredBytes),
        ] {
            var current = environment
            current.transfer.alreadyTransferredTodayBytes = alreadyTransferredBytes
            let input = current.policyInput(
                trigger: trigger,
                requestedActions: actions,
                additionalDiskBytes: max(0, additionalDiskBytes),
                requestedTemporaryOverride: requestedTemporaryOverride
            )
            let decision = SyncPolicyEngine().evaluate(
                input,
                policy: policy,
                calendar: calendar
            )
            guard decision.blockedActions.isEmpty else {
                throw ExternalDirectoryLivePolicyError.denied
            }
        }
    }

    private func recordDenial() {
        lock.lock()
        denied = true
        lock.unlock()
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        var candidates: [Int64] = []
        if let value = try? url.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ]
        ) {
            if let important = value.volumeAvailableCapacityForImportantUsage {
                candidates.append(max(0, important))
            }
            if let general = value.volumeAvailableCapacity,
                let exact = Int64(exactly: general)
            {
                candidates.append(max(0, exact))
            }
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        if let filesystem = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value {
            candidates.append(max(0, filesystem))
        }
        return candidates.max()
    }

    private static func validateAvailableCapacity(
        policy: SyncPolicy,
        additionalDiskBytes: Int64,
        destinationVolume: URL
    ) throws {
        let additionalBytes = max(0, additionalDiskBytes)
        guard additionalBytes > 0 else { return }
        guard let available = availableCapacity(at: destinationVolume) else {
            throw ExternalDirectoryLivePolicyError.denied
        }
        let (required, overflow) = max(0, policy.minimumFreeDiskBytes)
            .addingReportingOverflow(additionalBytes)
        guard !overflow, available >= required else {
            throw ExternalDirectoryLivePolicyError.denied
        }
    }

    private static func sum(_ values: [Int64]) throws -> Int64 {
        var result: Int64 = 0
        for value in values {
            guard value >= 0 else { throw ExternalDirectoryLivePolicyError.denied }
            let (next, overflow) = result.addingReportingOverflow(value)
            guard !overflow else { throw ExternalDirectoryLivePolicyError.denied }
            result = next
        }
        return result
    }

    private static func budgetDayKey(
        at date: Date,
        timeZoneIdentifier: String
    ) throws -> String {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw ExternalDirectoryLivePolicyError.denied
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            throw ExternalDirectoryLivePolicyError.denied
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

private final class ExternalDirectoryPolicyValidationWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Bool?

    func complete(allowed: Bool) {
        condition.lock()
        guard result == nil else {
            condition.unlock()
            return
        }
        result = allowed
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while result == nil { condition.wait() }
        return result == true
    }
}

/// Composes the durable reservation meter with the broker's live authorization,
/// binding, incarnation, calendar, and policy fences. Completed bytes are
/// tracked only to project the current session at the next payload checkpoint;
/// the accounting session remains the sole source of settlement truth.
private final class ExternalDirectoryAccountingMeter: @unchecked Sendable {
    typealias ValidateFence = @Sendable () throws -> Void

    private let session: ExternalMirrorTransferSession
    private let sessionMeter: ControlledMirrorTransferMeter
    private let livePolicyGate: ExternalDirectoryLivePolicyGate
    private let expectedBudgetTimeZoneIdentifier: String
    private let managedRoot: URL
    private let externalRoot: URL
    private let validateFence: ValidateFence
    private let lock = NSLock()
    private var currentTransfer: ControlledMirrorLogicalTransfer?
    private var authorizedPendingBytes: [UUID: Int64] = [:]
    private var completedTransferIDs: Set<UUID> = []
    private var completedBytes: Int64 = 0

    init(
        session: ExternalMirrorTransferSession,
        livePolicyGate: ExternalDirectoryLivePolicyGate,
        expectedBudgetTimeZoneIdentifier: String,
        managedRoot: URL,
        externalRoot: URL,
        validateFence: @escaping ValidateFence
    ) {
        self.session = session
        sessionMeter = session.meter
        self.livePolicyGate = livePolicyGate
        self.expectedBudgetTimeZoneIdentifier = expectedBudgetTimeZoneIdentifier
        self.managedRoot = managedRoot
        self.externalRoot = externalRoot
        self.validateFence = validateFence
    }

    var meter: ControlledMirrorTransferMeter {
        ControlledMirrorTransferMeter(
            authorize: { [weak self] transfer in
                guard let self else {
                    throw ExternalMirrorTransferAccountingError.sessionUnavailable
                }
                try self.authorize(transfer)
            },
            complete: { [weak self] transfer in
                guard let self else {
                    throw ExternalMirrorTransferAccountingError.sessionUnavailable
                }
                try self.complete(transfer)
            },
            markUncertain: { [weak self] transfer in
                self?.markUncertain(transfer)
            }
        )
    }

    func revalidateCurrentPayloadSynchronously() throws {
        let state = try lock.withLock { () throws -> (ControlledMirrorLogicalTransfer?, Int64) in
            guard let currentTransfer else { return (nil, completedBytes) }
            var projected = completedBytes
            for (id, value) in authorizedPendingBytes where id != currentTransfer.id {
                let (next, overflow) = projected.addingReportingOverflow(value)
                guard !overflow else {
                    throw ExternalMirrorTransferAccountingError.arithmeticOverflow
                }
                projected = next
            }
            return (currentTransfer, projected)
        }
        guard let transfer = state.0 else {
            throw ExternalMirrorTransferAccountingError.sessionUnavailable
        }
        try validate(
            transfer,
            completedBytes: state.1
        )
    }

    private func authorize(_ transfer: ControlledMirrorLogicalTransfer) throws {
        let projected = try lock.withLock { () throws -> Int64 in
            var value = completedBytes
            for pending in authorizedPendingBytes.values {
                let (next, overflow) = value.addingReportingOverflow(pending)
                guard !overflow else {
                    throw ExternalMirrorTransferAccountingError.arithmeticOverflow
                }
                value = next
            }
            return value
        }
        try validate(transfer, completedBytes: projected)
        try sessionMeter.authorize(transfer)
        lock.withLock {
            authorizedPendingBytes[transfer.id] = transfer.byteCount
            currentTransfer = transfer
        }
    }

    private func complete(_ transfer: ControlledMirrorLogicalTransfer) throws {
        let nextBytes: Int64 = try lock.withLock {
            guard !completedTransferIDs.contains(transfer.id) else {
                return completedBytes
            }
            let (next, overflow) = completedBytes.addingReportingOverflow(transfer.byteCount)
            guard !overflow else {
                throw ExternalMirrorTransferAccountingError.arithmeticOverflow
            }
            return next
        }
        try sessionMeter.complete(transfer)
        lock.withLock {
            if completedTransferIDs.insert(transfer.id).inserted {
                completedBytes = nextBytes
            }
            authorizedPendingBytes.removeValue(forKey: transfer.id)
            if currentTransfer?.id == transfer.id {
                currentTransfer = nil
            }
        }
    }

    private func markUncertain(_ transfer: ControlledMirrorLogicalTransfer) {
        sessionMeter.markUncertain(transfer)
        lock.withLock {
            authorizedPendingBytes.removeValue(forKey: transfer.id)
            if currentTransfer?.id == transfer.id {
                currentTransfer = nil
            }
        }
    }

    private func validate(
        _ transfer: ControlledMirrorLogicalTransfer,
        completedBytes: Int64
    ) throws {
        try validateFence()
        try livePolicyGate.validatePayloadSynchronously(
            transfer,
            session: session,
            completedBytes: completedBytes,
            expectedBudgetTimeZoneIdentifier: expectedBudgetTimeZoneIdentifier,
            managedRoot: managedRoot,
            externalRoot: externalRoot
        )
        // Environment capture is allowed to suspend. Re-establish all durable
        // broker fences immediately before authorizing provider payload I/O.
        try validateFence()
    }
}

public actor ExternalDirectoryAccessBroker {
    public typealias CapabilityProbe = @Sendable (URL) -> ExternalDirectoryCapabilities
    public typealias CurrentEnvironment = @Sendable () async -> SyncEnvironmentSnapshot

    private let recordsURL: URL
    private let containerRoot: URL
    private let policyURL: URL
    private let folderIncarnationsURL: URL
    private let transferAccountingURL: URL
    private let managedRootsURL: URL
    private let snapshotStore: SharedSnapshotStore
    private let commandQueue: CoreCommandQueue
    private let bookmarkAccess: ExternalDirectoryBookmarkAccess
    private let mirrorIO: ControlledMirrorIO
    private let capabilityProbe: CapabilityProbe
    private let now: @Sendable () -> Date
    private var recordsByID: [UUID: ExternalDirectoryRecord] = [:]
    private struct AuthorizationRootReservation: Sendable {
        let identity: ExternalDirectoryRootIdentity
        let resolvedPathComponents: [String]
    }
    private var pendingAuthorizationRoots: [UUID: AuthorizationRootReservation] = [:]
    private var recordsTransactionActive = false
    private var recordsTransactionBaseline: [UUID: ExternalDirectoryRecord]?

    public init(
        recordsURL: URL,
        managedRootsURL: URL? = nil,
        commandQueueURL: URL? = nil,
        bookmarkAccess: ExternalDirectoryBookmarkAccess = .system,
        mirrorIO: ControlledMirrorIO = .coordinated,
        capabilityProbe: @escaping CapabilityProbe = { ExternalDirectoryCapabilityProbe().run(at: $0) },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.recordsURL = recordsURL
        let containerRoot = recordsURL.deletingLastPathComponent().deletingLastPathComponent()
        self.containerRoot = containerRoot
        policyURL = containerRoot.appendingPathComponent("Metadata/sync-policy.json")
        folderIncarnationsURL = containerRoot.appendingPathComponent(
            "Metadata/folder-incarnations.json"
        )
        transferAccountingURL = containerRoot.appendingPathComponent(
            "Metadata/transfer-accounting.json"
        )
        self.managedRootsURL =
            managedRootsURL
            ?? recordsURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ManagedFolders/External", isDirectory: true)
        snapshotStore = SharedSnapshotStore(
            snapshotURL: containerRoot.appendingPathComponent("Metadata/core-snapshot.json")
        )
        commandQueue = CoreCommandQueue(
            root: commandQueueURL
                ?? containerRoot.appendingPathComponent("Coordination/Commands", isDirectory: true)
        )
        self.bookmarkAccess = bookmarkAccess
        self.mirrorIO = mirrorIO
        self.capabilityProbe = capabilityProbe
        self.now = now
    }

    public func load() throws {
        try withRecordsTransaction {
            var migrated = false
            for id in recordsByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard var record = recordsByID[id] else { continue }
                if record.schemaVersion != ExternalDirectoryRecord.currentSchemaVersion {
                    record.schemaVersion = ExternalDirectoryRecord.currentSchemaVersion
                    migrated = true
                }
                let expectedBinding = try ExternalDirectorySyncBinding.initial(recordID: record.id)
                if record.syncBinding.folderID != expectedBinding.folderID {
                    record.syncBinding.phase = .conflict
                    record.syncBinding.failureCode = "invalid_binding_identifier"
                    record.syncBinding.lastCheckedAt = now()
                    migrated = true
                }
                let expectedToken = record.id.uuidString.lowercased()
                if UUID(uuidString: record.managedRootToken) == nil {
                    record.managedRootToken = expectedToken
                    migrated = true
                } else if record.managedRootToken.caseInsensitiveCompare(expectedToken) != .orderedSame {
                    record.syncBinding.phase = .conflict
                    record.syncBinding.failureCode = "managed_root_token_mismatch"
                    record.syncBinding.lastCheckedAt = now()
                    migrated = true
                }
                let safeMode = Self.safeMode(requested: record.mode, capabilities: record.capabilities)
                if record.mode != safeMode {
                    record.mode = safeMode
                    migrated = true
                }
                if record.authorizationState == .revoked {
                    if !record.bookmark.isEmpty || !record.pendingDeletionConfirmations.isEmpty {
                        record.bookmark = Data()
                        record.pendingDeletionConfirmations = []
                        migrated = true
                    }
                    if record.lastMirrorStatus.phase == .running {
                        record.lastMirrorStatus.phase = .retryableFailure
                        record.lastMirrorStatus.failureCode = .authorizationRevoked
                        record.lastMirrorStatus.lastCompletedAt = now()
                        migrated = true
                    }
                }
                if record.lastMirrorStatus.phase == .running,
                    let lease = try ExternalDirectoryMirrorLease.tryAcquire(at: mirrorLockURL(for: id))
                {
                    lease.release()
                    record.lastMirrorStatus.phase = .retryableFailure
                    record.lastMirrorStatus.failureCode = .interrupted
                    record.lastMirrorStatus.lastCompletedAt = now()
                    migrated = true
                }
                try FileManager.default.createDirectory(
                    at: try managedRoot(for: record.managedRootToken),
                    withIntermediateDirectories: true
                )
                recordsByID[id] = record
            }
            if migrated { try persist() }
        }
    }

    public func allRecords() -> [ExternalDirectoryRecord] {
        if recordsTransactionActive { return sortedRecords() }
        return (try? withRecordsTransaction { sortedRecords() }) ?? sortedRecords()
    }

    /// Reconciles persisted binding intent against the latest durable snapshot.
    /// Missing queued commands are recreated with the same command ID, while a
    /// formerly verified-but-missing folder always requires explicit repair.
    @discardableResult
    public func reconcileSyncBindings(
        snapshot: CoreSnapshot
    ) throws -> ExternalDirectoryBindingReconciliation {
        try withRecordsTransaction {
            try reconcileSyncBindingsLocked(snapshot: snapshot)
        }
    }

    private func reconcileSyncBindingsLocked(
        snapshot: CoreSnapshot
    ) throws -> ExternalDirectoryBindingReconciliation {
        let pending = try commandQueue.pending(limit: 4_096)
        let pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        var result = ExternalDirectoryBindingReconciliation()
        var needsPersist = false

        for id in recordsByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var record = recordsByID[id] else { continue }
            let previous = record.syncBinding
            record.syncBinding.lastCheckedAt = now()

            guard record.authorizationState == .active else {
                if record.syncBinding.phase == .queued {
                    record.syncBinding.phase = .repairRequired
                    record.syncBinding.failureCode = "authorization_revoked"
                }
                recordsByID[id] = record
                needsPersist = needsPersist || record.syncBinding != previous
                result.attentionRecordCount += record.syncBinding.phase == .verified ? 0 : 1
                continue
            }

            let managedRoot: URL
            do {
                managedRoot = try validatedManagedRoot(for: record)
            } catch {
                record.syncBinding.phase = .conflict
                record.syncBinding.failureCode = "unsafe_managed_root"
                recordsByID[id] = record
                needsPersist = true
                result.attentionRecordCount += 1
                continue
            }

            let configuredMatches = snapshot.folders.filter {
                $0.id == record.syncBinding.folderID
            }
            if !configuredMatches.isEmpty {
                if configuredMatches.count != 1 {
                    record.syncBinding.phase = .conflict
                    record.syncBinding.failureCode = "folder_identity_ambiguous"
                    result.attentionRecordCount += 1
                } else if let failureCode = Self.authoritativeBindingFailureCode(
                    folder: configuredMatches[0],
                    managedRoot: managedRoot
                ) {
                    record.syncBinding.phase = .conflict
                    record.syncBinding.failureCode = failureCode
                    result.attentionRecordCount += 1
                } else {
                    if let pendingCommand = pendingByID[record.syncBinding.commandID],
                        !Self.isValidBindingCommand(
                            pendingCommand,
                            for: record,
                            managedRoot: managedRoot
                        )
                    {
                        record.syncBinding.phase = .conflict
                        record.syncBinding.failureCode = "binding_command_collision"
                        result.attentionRecordCount += 1
                    } else {
                        if let pendingCommand = pendingByID[record.syncBinding.commandID] {
                            try commandQueue.acknowledge(pendingCommand)
                        }
                        record.syncBinding.phase = .verified
                        record.syncBinding.failureCode = nil
                        result.verifiedRecordCount += 1
                    }
                }
                recordsByID[id] = record
                needsPersist = needsPersist || record.syncBinding != previous
                continue
            }

            if snapshot.folders.contains(where: { Self.pathsOverlap($0.localPath, managedRoot.path) }) {
                record.syncBinding.phase = .conflict
                record.syncBinding.failureCode = "folder_path_overlap"
                recordsByID[id] = record
                needsPersist = true
                result.attentionRecordCount += 1
                continue
            }

            switch record.syncBinding.phase {
            case .verified:
                record.syncBinding.phase = .repairRequired
                record.syncBinding.failureCode = "verified_folder_missing"
                result.attentionRecordCount += 1
            case .repairRequired, .conflict, .failed:
                result.attentionRecordCount += 1
            case .queued:
                let command: CoreCommand
                if let existing = pendingByID[record.syncBinding.commandID] {
                    guard
                        Self.isValidBindingCommand(
                            existing,
                            for: record,
                            managedRoot: managedRoot
                        )
                    else {
                        record.syncBinding.phase = .conflict
                        record.syncBinding.failureCode = "binding_command_collision"
                        result.attentionRecordCount += 1
                        recordsByID[id] = record
                        needsPersist = true
                        continue
                    }
                    command = existing
                } else {
                    command = try bindingCommand(for: record, managedRoot: managedRoot)
                }
                let sameFolderCommands = pending.filter {
                    $0.kind == .addFolder && $0.folderID == record.syncBinding.folderID
                }
                guard sameFolderCommands.allSatisfy({ $0.id == command.id }) else {
                    record.syncBinding.phase = .conflict
                    record.syncBinding.failureCode = "duplicate_binding_command"
                    result.attentionRecordCount += 1
                    recordsByID[id] = record
                    needsPersist = true
                    continue
                }
                if pendingByID[command.id] == nil {
                    if let commandResult = try commandQueue.result(for: command.id) {
                        switch commandResult.status {
                        case .succeeded:
                            record.syncBinding.phase = .repairRequired
                            record.syncBinding.failureCode = "snapshot_missing_after_success"
                            result.attentionRecordCount += 1
                        case .blocked, .failed:
                            record.syncBinding.phase = .failed
                            record.syncBinding.failureCode = Self.safeBindingFailureCode(
                                commandResult.errorCode
                            )
                            result.attentionRecordCount += 1
                        case .retryable:
                            try commandQueue.enqueue(command)
                            result.enqueuedCommandCount += 1
                        }
                    } else {
                        try commandQueue.enqueue(command)
                        result.enqueuedCommandCount += 1
                    }
                }
            }
            recordsByID[id] = record
            needsPersist = needsPersist || record.syncBinding != previous
        }
        if needsPersist { try persist() }
        return result
    }

    /// Rechecks all safety invariants and creates a fresh durable command only
    /// after an explicit user repair. It never removes or edits a configured
    /// folder whose path does not match this record.
    public func repairSyncBinding(id: UUID, snapshot: CoreSnapshot) throws {
        try withRecordsTransaction {
            try repairSyncBindingLocked(id: id, snapshot: snapshot)
        }
    }

    private func repairSyncBindingLocked(id: UUID, snapshot: CoreSnapshot) throws {
        guard var record = recordsByID[id] else { throw ExternalDirectoryError.recordNotFound }
        guard record.authorizationState == .active else {
            throw ExternalDirectoryError.authorizationAlreadyRevoked
        }
        let managedRoot = try validatedManagedRoot(for: record)
        let configuredMatches = snapshot.folders.filter {
            $0.id == record.syncBinding.folderID
        }
        if !configuredMatches.isEmpty {
            let failureCode: String?
            if configuredMatches.count == 1 {
                failureCode = Self.authoritativeBindingFailureCode(
                    folder: configuredMatches[0],
                    managedRoot: managedRoot
                )
            } else {
                failureCode = "folder_identity_ambiguous"
            }
            if let failureCode {
                record.syncBinding.phase = .conflict
                record.syncBinding.failureCode = failureCode
                record.syncBinding.lastCheckedAt = now()
                recordsByID[id] = record
                try persist()
                throw ExternalDirectoryError.bindingConflict
            }
            record.syncBinding.phase = .verified
            record.syncBinding.failureCode = nil
            record.syncBinding.lastCheckedAt = now()
            recordsByID[id] = record
            try persist()
            return
        }
        guard !snapshot.folders.contains(where: { Self.pathsOverlap($0.localPath, managedRoot.path) }) else {
            record.syncBinding.phase = .conflict
            record.syncBinding.failureCode = "folder_path_overlap"
            record.syncBinding.lastCheckedAt = now()
            recordsByID[id] = record
            try persist()
            throw ExternalDirectoryError.bindingConflict
        }

        let pendingForFolder = try commandQueue.pending(limit: 4_096).filter {
            $0.kind == .addFolder && $0.folderID == record.syncBinding.folderID
        }
        if let existing = pendingForFolder.first {
            guard pendingForFolder.count == 1,
                existing.id == record.syncBinding.commandID,
                Self.isValidBindingCommand(existing, for: record, managedRoot: managedRoot)
            else {
                record.syncBinding.phase = .conflict
                record.syncBinding.failureCode = "duplicate_binding_command"
                record.syncBinding.lastCheckedAt = now()
                recordsByID[id] = record
                try persist()
                throw ExternalDirectoryError.bindingConflict
            }
            record.syncBinding.phase = .queued
            record.syncBinding.failureCode = nil
            record.syncBinding.lastCheckedAt = now()
            recordsByID[id] = record
            try persist()
            return
        }

        if record.syncBinding.phase != .queued {
            record.syncBinding.commandID = UUID()
        }
        record.syncBinding.phase = .queued
        record.syncBinding.failureCode = nil
        record.syncBinding.lastCheckedAt = now()
        recordsByID[id] = record
        // Persist the fresh command ID before touching the queue so a crash can
        // always reconstruct the identical command on the next launch.
        try persist()
        try commandQueue.enqueue(try bindingCommand(for: record, managedRoot: managedRoot))
    }

    public func authorize(
        url: URL,
        requestedMode: ExternalDirectoryMode,
        expectedRootIdentity: ExternalDirectoryRootIdentity? = nil
    ) async throws -> ExternalDirectoryRecord {
        guard bookmarkAccess.beginAccess(to: url) else {
            throw ExternalDirectoryError.authorizationDenied
        }
        defer { bookmarkAccess.endAccess(to: url) }

        let baselineIdentity = try checkedRootIdentity(at: url, expected: expectedRootIdentity)
        let authorizedRoot = try validatedExternalRoot(url)
        try requireRootIdentity(baselineIdentity, at: url)
        let reservation = try reserveAuthorizationRoot(
            identity: baselineIdentity,
            root: authorizedRoot
        )
        defer { pendingAuthorizationRoots.removeValue(forKey: reservation) }

        let probeBody = capabilityProbe
        let probe = await Task.detached(priority: .userInitiated) {
            probeBody(authorizedRoot)
        }.value
        try requireRootIdentity(baselineIdentity, at: url)
        guard probe.canEnumerate, probe.canRead else {
            throw ExternalDirectoryError.capabilityProbeFailed(probe.failures)
        }

        let effectiveMode = Self.safeMode(requested: requestedMode, capabilities: probe)
        try requireRootIdentity(baselineIdentity, at: url)
        let bookmark: Data
        do {
            bookmark = try bookmarkAccess.createBookmark(for: url)
        } catch {
            throw ExternalDirectoryError.authorizationDenied
        }
        try requireRootIdentity(baselineIdentity, at: url)
        let bookmarkResolution: ExternalDirectoryBookmarkResolution
        do {
            bookmarkResolution = try bookmarkAccess.resolve(bookmark)
        } catch {
            throw ExternalDirectoryError.authorizationDenied
        }
        guard !bookmarkResolution.isStale,
            bookmarkAccess.beginAccess(to: bookmarkResolution.url)
        else {
            throw ExternalDirectoryError.authorizationDenied
        }
        do {
            defer { bookmarkAccess.endAccess(to: bookmarkResolution.url) }
            try requireRootIdentity(baselineIdentity, at: bookmarkResolution.url)
            try requireRootIdentity(baselineIdentity, at: url)
        }
        let id = UUID()
        let record = try ExternalDirectoryRecord(
            id: id,
            displayName: url.lastPathComponent,
            bookmark: bookmark,
            mode: effectiveMode,
            capabilities: probe,
            managedRootToken: id.uuidString.lowercased(),
            lastProbedAt: now()
        )
        try withRecordsTransaction {
            guard bookmarkAccess.beginAccess(to: bookmarkResolution.url) else {
                throw ExternalDirectoryError.authorizationDenied
            }
            defer { bookmarkAccess.endAccess(to: bookmarkResolution.url) }
            try requireRootIdentity(baselineIdentity, at: url)
            try requireRootIdentity(baselineIdentity, at: bookmarkResolution.url)
            // Cross-process final gate: reload the durable records while the
            // records lock is held, then prove no active bookmark is the same,
            // an ancestor, or a descendant before creating a managed root.
            try rejectOverlappingAuthorization(
                identity: baselineIdentity,
                root: authorizedRoot,
                excludingRecordID: nil
            )
            guard recordsByID[record.id] == nil else { throw ExternalDirectoryError.unavailable }
            try FileManager.default.createDirectory(
                at: try managedRoot(for: record.managedRootToken),
                withIntermediateDirectories: true
            )
            try requireRootIdentity(baselineIdentity, at: url)
            try requireRootIdentity(baselineIdentity, at: bookmarkResolution.url)
            recordsByID[record.id] = record
            try persist()
        }
        return record
    }

    public func remove(id: UUID) async throws {
        let lockURL = mirrorLockURL(for: id)
        // Do not block this actor's executor: an in-flight run on the same
        // broker must be able to finish its result transaction and release the
        // lease before revocation advances the authorization epoch.
        let mirrorLease = try await Task.detached(priority: .userInitiated) {
            try ExternalDirectoryMirrorLease.acquire(at: lockURL)
        }.value
        defer { mirrorLease.release() }
        try withRecordsTransaction {
            try removeLocked(id: id)
        }
    }

    private func removeLocked(id: UUID) throws {
        guard var record = recordsByID[id] else { throw ExternalDirectoryError.recordNotFound }
        guard record.authorizationState == .active else {
            throw ExternalDirectoryError.authorizationAlreadyRevoked
        }
        record.authorizationEpoch = try Self.increment(record.authorizationEpoch)
        record.authorizationState = .revoked
        record.bookmark = Data()
        record.pendingDeletionConfirmations = []
        record.lastMirrorStatus = ExternalDirectoryMirrorStatus(
            phase: .retryableFailure,
            lastAttemptedAt: record.lastMirrorStatus.lastAttemptedAt,
            lastCompletedAt: now(),
            failureCode: .authorizationRevoked
        )
        recordsByID[id] = record
        // Revoking a bookmark never destroys the managed copy and never queues
        // removeFolder. Keeping the record preserves the durable mapping so the
        // UI can disclose any still-configured core folder.
        try persist()
    }

    @discardableResult
    public func updateMode(id: UUID, requestedMode: ExternalDirectoryMode) throws -> ExternalDirectoryRecord {
        try withRecordsTransaction {
            try updateModeLocked(id: id, requestedMode: requestedMode)
        }
    }

    private func updateModeLocked(
        id: UUID,
        requestedMode: ExternalDirectoryMode
    ) throws -> ExternalDirectoryRecord {
        guard var record = recordsByID[id] else { throw ExternalDirectoryError.recordNotFound }
        guard record.authorizationState == .active else {
            throw ExternalDirectoryError.authorizationAlreadyRevoked
        }
        record.mode = Self.safeMode(requested: requestedMode, capabilities: record.capabilities)
        recordsByID[id] = record
        try persist()
        return record
    }

    public func resolve(id: UUID) throws -> URL {
        let record = try withRecordsTransaction {
            try authorizedRecord(id: id)
        }
        let resolution = try bookmarkAccess.resolve(record.bookmark)
        guard !resolution.isStale else { throw ExternalDirectoryError.bookmarkStale }
        return resolution.url
    }

    public func withAccess<T: Sendable>(
        id: UUID,
        operation: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        let record = try withRecordsTransaction {
            try authorizedRecord(id: id)
        }
        let resolution = try bookmarkAccess.resolve(record.bookmark)
        guard !resolution.isStale else { throw ExternalDirectoryError.bookmarkStale }
        guard bookmarkAccess.beginAccess(to: resolution.url) else {
            throw ExternalDirectoryError.authorizationDenied
        }
        defer { bookmarkAccess.endAccess(to: resolution.url) }
        try Self.validateAuthorizationFence(
            recordsURL: recordsURL,
            recordID: id,
            expectedAuthorizationEpoch: record.authorizationEpoch
        )
        let root = try requireExclusiveExternalRoot(for: record, resolvedURL: resolution.url)
        return try operation(root)
    }

    public func runMirror(
        id: UUID,
        cancellation: ExternalDirectoryMirrorCancellation = .init(),
        trigger: SyncTrigger = .user,
        requestedTemporaryOverride: Bool = false,
        currentEnvironment: CurrentEnvironment? = nil
    ) async throws -> ExternalDirectoryMirrorStatus {
        let initialRecord = try withRecordsTransaction {
            let current = try authorizedRecord(id: id)
            guard current.syncBinding.phase == .verified else {
                throw ExternalDirectoryError.bindingNotVerified
            }
            return current
        }
        guard let mirrorLease = try ExternalDirectoryMirrorLease.tryAcquire(at: mirrorLockURL(for: id)) else {
            throw ExternalDirectoryError.mirrorAlreadyRunning
        }
        defer { mirrorLease.release() }
        let record = try withRecordsTransaction {
            let current = try authorizedRecord(
                id: id,
                expectedAuthorizationEpoch: initialRecord.authorizationEpoch
            )
            guard current.syncBinding.phase == .verified else {
                throw ExternalDirectoryError.bindingNotVerified
            }
            return current
        }
        let authorizationEpoch = record.authorizationEpoch
        let livePolicyGate = makeLivePolicyGate(
            folderID: record.syncBinding.folderID,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            currentEnvironment: currentEnvironment
        )
        try requireLatestAuthoritativeBinding(
            for: record,
            expectedAuthorizationEpoch: authorizationEpoch
        )
        let attemptedAt = now()
        guard !Self.isCancelled(cancellation) else {
            return try finishCancelled(
                id: id,
                expectedAuthorizationEpoch: authorizationEpoch,
                attemptedAt: attemptedAt
            )
        }

        let resolution: ExternalDirectoryBookmarkResolution
        do {
            resolution = try bookmarkAccess.resolve(record.bookmark)
        } catch {
            return try finishFailure(
                id: id,
                expectedAuthorizationEpoch: authorizationEpoch,
                attemptedAt: attemptedAt,
                code: .providerOffline
            )
        }
        guard !resolution.isStale else {
            return try finishFailure(
                id: id,
                expectedAuthorizationEpoch: authorizationEpoch,
                attemptedAt: attemptedAt,
                code: .bookmarkStale
            )
        }
        guard bookmarkAccess.beginAccess(to: resolution.url) else {
            return try finishFailure(
                id: id,
                expectedAuthorizationEpoch: authorizationEpoch,
                attemptedAt: attemptedAt,
                code: .authorizationRevoked
            )
        }
        defer { bookmarkAccess.endAccess(to: resolution.url) }
        do {
            try Self.validateAuthorizationFence(
                recordsURL: recordsURL,
                recordID: id,
                expectedAuthorizationEpoch: authorizationEpoch
            )
            _ = try requireExclusiveExternalRoot(
                for: record,
                resolvedURL: resolution.url
            )
        } catch {
            return try finishFailure(
                id: id,
                expectedAuthorizationEpoch: authorizationEpoch,
                attemptedAt: attemptedAt,
                code: .mirrorIOFailure
            )
        }
        do {
            try await livePolicyGate.validate(actions: Self.policyActions(for: record.mode))
        } catch {
            return try finishFailure(
                id: id,
                expectedAuthorizationEpoch: authorizationEpoch,
                attemptedAt: attemptedAt,
                code: .policyDenied
            )
        }
        guard !Self.isCancelled(cancellation) else {
            return try finishCancelled(
                id: id,
                expectedAuthorizationEpoch: authorizationEpoch,
                attemptedAt: attemptedAt
            )
        }

        let running = ExternalDirectoryMirrorStatus(phase: .running, lastAttemptedAt: attemptedAt)
        try updateStatus(
            id: id,
            expectedAuthorizationEpoch: authorizationEpoch,
            status: running
        )

        do {
            try Self.validateAuthorizationFence(
                recordsURL: recordsURL,
                recordID: id,
                expectedAuthorizationEpoch: authorizationEpoch
            )
            let externalRoot = try requireExclusiveExternalRoot(
                for: record,
                resolvedURL: resolution.url
            )
            let managedRoot = try validatedManagedRoot(for: record)
            let planningMirror = ControlledMirror(
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                io: fencedMirrorIO(
                    cancellation: cancellation,
                    record: record,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    managedRoot: managedRoot,
                    externalRoot: externalRoot,
                    mode: record.mode,
                    livePolicyGate: livePolicyGate,
                    accountingMeter: nil
                )
            )
            try await reconcileStaleExternalAccounting(
                mirror: planningMirror,
                record: record,
                at: attemptedAt
            )
            let initialPlan = try await planningMirror.prepareSynchronization()
            let applyPlan = try await observeAndCommitSynchronizationIfNeeded(
                initialPlan,
                mirror: planningMirror,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                livePolicyGate: livePolicyGate,
                actions: Self.policyActions(for: record.mode),
                cancellation: cancellation
            )
            let result = try await applyPreparedExternalPlan(
                applyPlan,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                livePolicyGate: livePolicyGate,
                actions: Self.policyActions(for: record.mode),
                cancellation: cancellation
            )
            guard !Self.isCancelled(cancellation) else {
                return try finishCancelled(
                    id: id,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    attemptedAt: attemptedAt
                )
            }
            let status = ExternalDirectoryMirrorStatus(
                phase: result.confirmationRequired.isEmpty ? .succeeded : .requiresConfirmation,
                lastAttemptedAt: attemptedAt,
                lastCompletedAt: now(),
                importedFiles: result.copiedToManaged,
                exportedFiles: result.copiedToExternal,
                conflictCount: result.conflicts.count,
                deleteConfirmationCount: result.confirmationRequired.count
            )
            if Self.managedRootChanged(in: result) {
                do {
                    try requireLatestAuthoritativeBinding(
                        for: record,
                        expectedAuthorizationEpoch: authorizationEpoch
                    )
                    try enqueueScopedRescan(
                        folderID: record.syncBinding.folderID,
                        trigger: trigger
                    )
                } catch {
                    return try finishFailure(
                        id: id,
                        expectedAuthorizationEpoch: authorizationEpoch,
                        attemptedAt: attemptedAt,
                        code: .rescanQueueFailed
                    )
                }
            }
            try updateMirrorResult(
                id: id,
                expectedAuthorizationEpoch: authorizationEpoch,
                status: status,
                confirmations: result.confirmationRequired
            )
            return status
        } catch {
            if Self.isCancelled(cancellation) {
                return try finishCancelled(
                    id: id,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    attemptedAt: attemptedAt
                )
            }
            if livePolicyGate.policyWasDenied {
                return try finishFailure(
                    id: id,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    attemptedAt: attemptedAt,
                    code: .policyDenied
                )
            }
            if let failure = error as? ControlledMirrorFailure {
                return try finishFailure(
                    id: id,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    attemptedAt: attemptedAt,
                    code: Self.failureCode(for: failure.code)
                )
            }
            return try finishFailure(
                id: id,
                expectedAuthorizationEpoch: authorizationEpoch,
                attemptedAt: attemptedAt,
                code: .mirrorIOFailure
            )
        }
    }

    /// Lists relative-path-only recovery metadata under the same per-record
    /// lease, security scope, authorization epoch, binding, and live-policy
    /// fences used by a mirror run. No bookmark, root URL, or payload locator
    /// crosses this API boundary.
    public func recoverySummaries(
        recordID: UUID,
        cancellation: ExternalDirectoryMirrorCancellation = .init(),
        trigger: SyncTrigger = .user,
        requestedTemporaryOverride: Bool = false,
        currentEnvironment: CurrentEnvironment? = nil
    ) async throws -> [ControlledMirrorRecoverySummary] {
        let initialRecord = try withRecordsTransaction {
            let current = try authorizedRecord(id: recordID)
            guard current.syncBinding.phase == .verified else {
                throw ExternalDirectoryError.bindingNotVerified
            }
            return current
        }
        guard
            let mirrorLease = try ExternalDirectoryMirrorLease.tryAcquire(
                at: mirrorLockURL(for: recordID)
            )
        else {
            throw ExternalDirectoryError.mirrorAlreadyRunning
        }
        defer { mirrorLease.release() }
        let record = try withRecordsTransaction {
            try authorizedRecord(
                id: recordID,
                expectedAuthorizationEpoch: initialRecord.authorizationEpoch
            )
        }
        let authorizationEpoch = record.authorizationEpoch
        guard record.syncBinding.phase == .verified else {
            throw ExternalDirectoryError.bindingNotVerified
        }
        try Self.checkCancellation(cancellation)
        try requireLatestAuthoritativeBinding(
            for: record,
            expectedAuthorizationEpoch: authorizationEpoch
        )
        let resolution: ExternalDirectoryBookmarkResolution
        do {
            resolution = try bookmarkAccess.resolve(record.bookmark)
        } catch {
            throw ExternalDirectoryError.unavailable
        }
        guard !resolution.isStale else { throw ExternalDirectoryError.bookmarkStale }
        guard bookmarkAccess.beginAccess(to: resolution.url) else {
            throw ExternalDirectoryError.authorizationDenied
        }
        defer { bookmarkAccess.endAccess(to: resolution.url) }
        _ = try requireExclusiveExternalRoot(
            for: record,
            resolvedURL: resolution.url
        )
        let livePolicyGate = makeLivePolicyGate(
            folderID: record.syncBinding.folderID,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            currentEnvironment: currentEnvironment
        )
        do {
            try await livePolicyGate.validate(actions: [.scan, .hash])
        } catch {
            throw ExternalDirectoryError.policyDenied
        }
        try Self.checkCancellation(cancellation)

        let managedRoot = try validatedManagedRoot(for: record)
        let externalRoot = try requireExclusiveExternalRoot(
            for: record,
            resolvedURL: resolution.url
        )
        try Self.validateRecoveryFence(
            cancellation: cancellation,
            recordsURL: recordsURL,
            snapshotStore: snapshotStore,
            record: record,
            expectedAuthorizationEpoch: authorizationEpoch,
            managedRoot: managedRoot,
            livePolicyGate: livePolicyGate,
            actions: [.scan, .hash]
        )
        let planningMirror = ControlledMirror(
            managedRoot: managedRoot,
            externalRoot: externalRoot,
            mode: record.mode,
            io: fencedMirrorIO(
                cancellation: cancellation,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                livePolicyGate: livePolicyGate
            )
        )
        do {
            let prepared: ControlledMirrorPreparedRecovery
            do {
                prepared = try await planningMirror.prepareRecoverySummaries()
            } catch ControlledMirrorPreparedRecoveryError.unboundedExternalPayload {
                try livePolicyGate.rejectUnknownTransferSize()
            }
            let accountingActions: Set<SyncAction> =
                prepared.plan.remainingLogicalProviderBytes > 0
                ? [.scan, .hash, .download] : [.scan, .hash]
            let accounting = try await beginPreparedExternalAccounting(
                prepared.plan,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                livePolicyGate: livePolicyGate,
                actions: accountingActions,
                cancellation: cancellation
            )
            let applyingMirror = ControlledMirror(
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                io: fencedMirrorIO(
                    cancellation: cancellation,
                    record: record,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    managedRoot: managedRoot,
                    externalRoot: externalRoot,
                    mode: record.mode,
                    livePolicyGate: livePolicyGate,
                    accountingMeter: accounting.meter
                )
            )
            do {
                let summaries = try await applyingMirror.recoverySummaries(
                    prepared,
                    meter: accounting.meter.meter
                )
                try Self.validateRecoveryFence(
                    cancellation: cancellation,
                    recordsURL: recordsURL,
                    snapshotStore: snapshotStore,
                    record: record,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    managedRoot: managedRoot,
                    livePolicyGate: livePolicyGate,
                    actions: [.scan, .hash]
                )
                _ = try accounting.session.settleSuccessful(at: now())
                return summaries
            } catch {
                _ = try accounting.session.settleTerminalFailure(at: now())
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExternalDirectoryError {
            throw error
        } catch let error as ControlledMirrorRecoveryError {
            if livePolicyGate.policyWasDenied {
                throw ExternalDirectoryError.policyDenied
            }
            throw Self.externalDirectoryError(for: error)
        } catch {
            if livePolicyGate.policyWasDenied {
                throw ExternalDirectoryError.policyDenied
            }
            throw ExternalDirectoryError.recoveryUnavailable
        }
    }

    /// Creates a private, streaming snapshot of the exact recovery item for an
    /// explicit system share or Files export. The source remains retained and
    /// no internal recovery locator crosses the API boundary.
    public func prepareRecoveryExport(
        recordID: UUID,
        summary: ControlledMirrorRecoverySummary,
        outputDirectory: URL,
        cancellation: ExternalDirectoryMirrorCancellation = .init(),
        trigger: SyncTrigger = .user,
        requestedTemporaryOverride: Bool = false,
        currentEnvironment: CurrentEnvironment? = nil
    ) async throws -> ControlledMirrorRecoveryExport {
        let initialRecord = try withRecordsTransaction {
            let current = try authorizedRecord(id: recordID)
            guard current.syncBinding.phase == .verified else {
                throw ExternalDirectoryError.bindingNotVerified
            }
            return current
        }
        guard
            let mirrorLease = try ExternalDirectoryMirrorLease.tryAcquire(
                at: mirrorLockURL(for: recordID)
            )
        else {
            throw ExternalDirectoryError.mirrorAlreadyRunning
        }
        defer { mirrorLease.release() }
        let record = try withRecordsTransaction {
            try authorizedRecord(
                id: recordID,
                expectedAuthorizationEpoch: initialRecord.authorizationEpoch
            )
        }
        let authorizationEpoch = record.authorizationEpoch
        guard record.syncBinding.phase == .verified else {
            throw ExternalDirectoryError.bindingNotVerified
        }
        try Self.checkCancellation(cancellation)
        try requireLatestAuthoritativeBinding(
            for: record,
            expectedAuthorizationEpoch: authorizationEpoch
        )
        let resolution: ExternalDirectoryBookmarkResolution
        do {
            resolution = try bookmarkAccess.resolve(record.bookmark)
        } catch {
            throw ExternalDirectoryError.unavailable
        }
        guard !resolution.isStale else { throw ExternalDirectoryError.bookmarkStale }
        guard bookmarkAccess.beginAccess(to: resolution.url) else {
            throw ExternalDirectoryError.authorizationDenied
        }
        defer { bookmarkAccess.endAccess(to: resolution.url) }
        _ = try requireExclusiveExternalRoot(
            for: record,
            resolvedURL: resolution.url
        )
        let livePolicyGate = makeLivePolicyGate(
            folderID: record.syncBinding.folderID,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            currentEnvironment: currentEnvironment
        )
        let policyActions = Self.policyActions(
            for: summary,
            decision: .retain
        )
        let policyTransferBytes =
            summary.side == .external && summary.payloadKind == .file
            ? summary.byteCount : 0
        do {
            try await livePolicyGate.validate(
                actions: policyActions,
                transferBytes: policyTransferBytes,
                additionalDiskBytes: summary.byteCount,
                destinationVolume: outputDirectory.deletingLastPathComponent()
            )
        } catch {
            throw ExternalDirectoryError.policyDenied
        }
        try Self.checkCancellation(cancellation)

        let managedRoot = try validatedManagedRoot(for: record)
        let externalRoot = try requireExclusiveExternalRoot(
            for: record,
            resolvedURL: resolution.url
        )
        let recordsURL = recordsURL
        let snapshotStore = snapshotStore
        let authorization: @Sendable (ControlledMirrorRecoverySummary) throws -> Bool = {
            current in
            guard current == summary else { return false }
            try Self.validateRecoveryFence(
                cancellation: cancellation,
                recordsURL: recordsURL,
                snapshotStore: snapshotStore,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                livePolicyGate: livePolicyGate,
                actions: policyActions,
                transferBytes: policyTransferBytes
            )
            try livePolicyGate.validateSynchronously(
                actions: policyActions,
                transferBytes: policyTransferBytes,
                additionalDiskBytes: summary.byteCount,
                destinationVolume: outputDirectory.deletingLastPathComponent()
            )
            return true
        }
        let planningMirror = ControlledMirror(
            managedRoot: managedRoot,
            externalRoot: externalRoot,
            mode: record.mode,
            io: fencedMirrorIO(
                cancellation: cancellation,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                livePolicyGate: livePolicyGate
            )
        )
        do {
            let prepared: ControlledMirrorPreparedRecovery
            do {
                prepared = try await planningMirror.prepareRecoveryExport(summary)
            } catch ControlledMirrorPreparedRecoveryError.unboundedExternalPayload {
                try livePolicyGate.rejectUnknownTransferSize()
            }
            let accounting = try await beginPreparedExternalAccounting(
                prepared.plan,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                livePolicyGate: livePolicyGate,
                actions: policyActions,
                cancellation: cancellation
            )
            let applyingMirror = ControlledMirror(
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                io: fencedMirrorIO(
                    cancellation: cancellation,
                    record: record,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    managedRoot: managedRoot,
                    externalRoot: externalRoot,
                    mode: record.mode,
                    livePolicyGate: livePolicyGate,
                    accountingMeter: accounting.meter
                )
            )
            do {
                let export = try await applyingMirror.exportRecovery(
                    prepared,
                    to: outputDirectory,
                    authorization: authorization,
                    meter: accounting.meter.meter
                )
                _ = try accounting.session.settleSuccessful(at: now())
                return export
            } catch {
                _ = try accounting.session.settleTerminalFailure(at: now())
                throw error
            }
        } catch {
            if Self.isCancelled(cancellation) { throw CancellationError() }
            if livePolicyGate.policyWasDenied {
                throw ExternalDirectoryError.policyDenied
            }
            if let recoveryError = error as? ControlledMirrorRecoveryError {
                throw Self.externalDirectoryError(for: recoveryError)
            }
            throw ExternalDirectoryError.recoveryExportFailed
        }
    }

    public nonisolated func discardRecoveryExport(
        _ export: ControlledMirrorRecoveryExport,
        from outputDirectory: URL
    ) throws {
        try ControlledMirror.removeRecoveryExport(export, from: outputDirectory)
    }

    public nonisolated func discardTemporaryRecoveryExports(
        from outputDirectory: URL
    ) throws {
        try ControlledMirror.removeTemporaryRecoveryExports(from: outputDirectory)
    }

    /// Retains or disposes the exact recovery payload represented by `summary`.
    /// ControlledMirror invokes `authorization` repeatedly immediately before
    /// destructive commits; every invocation rechecks cancellation, the
    /// durable authorization epoch, the latest binding, and a freshly loaded
    /// SyncPolicyEngine decision with a freshly captured environment.
    public func resolveRecovery(
        recordID: UUID,
        summary: ControlledMirrorRecoverySummary,
        decision: ControlledMirrorRecoveryDecision,
        cancellation: ExternalDirectoryMirrorCancellation = .init(),
        trigger: SyncTrigger = .user,
        requestedTemporaryOverride: Bool = false,
        currentEnvironment: CurrentEnvironment? = nil
    ) async throws {
        let initialRecord = try withRecordsTransaction {
            let current = try authorizedRecord(id: recordID)
            guard current.syncBinding.phase == .verified else {
                throw ExternalDirectoryError.bindingNotVerified
            }
            return current
        }
        guard
            let mirrorLease = try ExternalDirectoryMirrorLease.tryAcquire(
                at: mirrorLockURL(for: recordID)
            )
        else {
            throw ExternalDirectoryError.mirrorAlreadyRunning
        }
        defer { mirrorLease.release() }
        let record = try withRecordsTransaction {
            try authorizedRecord(
                id: recordID,
                expectedAuthorizationEpoch: initialRecord.authorizationEpoch
            )
        }
        let authorizationEpoch = record.authorizationEpoch
        guard record.syncBinding.phase == .verified else {
            throw ExternalDirectoryError.bindingNotVerified
        }
        try Self.checkCancellation(cancellation)
        try requireLatestAuthoritativeBinding(
            for: record,
            expectedAuthorizationEpoch: authorizationEpoch
        )
        let resolution: ExternalDirectoryBookmarkResolution
        do {
            resolution = try bookmarkAccess.resolve(record.bookmark)
        } catch {
            throw ExternalDirectoryError.unavailable
        }
        guard !resolution.isStale else { throw ExternalDirectoryError.bookmarkStale }
        guard bookmarkAccess.beginAccess(to: resolution.url) else {
            throw ExternalDirectoryError.authorizationDenied
        }
        defer { bookmarkAccess.endAccess(to: resolution.url) }
        _ = try requireExclusiveExternalRoot(
            for: record,
            resolvedURL: resolution.url
        )
        let livePolicyGate = makeLivePolicyGate(
            folderID: record.syncBinding.folderID,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            currentEnvironment: currentEnvironment
        )
        let policyActions = Self.policyActions(for: summary, decision: decision)
        let policyTransferBytes =
            summary.side == .external && summary.payloadKind == .file
            ? summary.byteCount : 0
        do {
            try await livePolicyGate.validate(
                actions: policyActions,
                transferBytes: policyTransferBytes
            )
        } catch {
            throw ExternalDirectoryError.policyDenied
        }
        try Self.checkCancellation(cancellation)

        let managedRoot = try validatedManagedRoot(for: record)
        let externalRoot = try requireExclusiveExternalRoot(
            for: record,
            resolvedURL: resolution.url
        )
        let recordsURL = recordsURL
        let snapshotStore = snapshotStore
        let authorization: @Sendable (ControlledMirrorRecoverySummary) throws -> Bool = {
            current in
            guard current == summary else { return false }
            try Self.validateRecoveryFence(
                cancellation: cancellation,
                recordsURL: recordsURL,
                snapshotStore: snapshotStore,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                livePolicyGate: livePolicyGate,
                actions: policyActions
            )
            return true
        }
        let planningMirror = ControlledMirror(
            managedRoot: managedRoot,
            externalRoot: externalRoot,
            mode: record.mode,
            io: fencedMirrorIO(
                cancellation: cancellation,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                livePolicyGate: livePolicyGate
            )
        )
        do {
            let prepared: ControlledMirrorPreparedRecovery
            do {
                prepared = try await planningMirror.prepareRecoveryResolution(
                    summary,
                    decision: decision
                )
            } catch ControlledMirrorPreparedRecoveryError.unboundedExternalPayload {
                try livePolicyGate.rejectUnknownTransferSize()
            }
            let accounting = try await beginPreparedExternalAccounting(
                prepared.plan,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                livePolicyGate: livePolicyGate,
                actions: policyActions,
                cancellation: cancellation
            )
            let applyingMirror = ControlledMirror(
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                io: fencedMirrorIO(
                    cancellation: cancellation,
                    record: record,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    managedRoot: managedRoot,
                    externalRoot: externalRoot,
                    mode: record.mode,
                    livePolicyGate: livePolicyGate,
                    accountingMeter: accounting.meter
                )
            )
            do {
                try await applyingMirror.resolveRecovery(
                    prepared,
                    authorization: authorization,
                    meter: accounting.meter.meter
                )
                _ = try accounting.session.settleSuccessful(at: now())
            } catch {
                _ = try accounting.session.settleTerminalFailure(at: now())
                throw error
            }
        } catch {
            if Self.isCancelled(cancellation) { throw CancellationError() }
            if livePolicyGate.policyWasDenied {
                throw ExternalDirectoryError.policyDenied
            }
            if let recoveryError = error as? ControlledMirrorRecoveryError {
                throw Self.externalDirectoryError(for: recoveryError)
            }
            throw ExternalDirectoryError.recoveryUnavailable
        }
    }

    public func resolveDeletionConfirmation(
        recordID: UUID,
        confirmation: ControlledMirrorConfirmation,
        decision: ControlledMirrorConfirmationDecision,
        trigger: SyncTrigger = .user,
        requestedTemporaryOverride: Bool = false,
        currentEnvironment: CurrentEnvironment? = nil
    ) async throws -> ExternalDirectoryMirrorStatus {
        let initialRecord = try withRecordsTransaction {
            try authorizedRecord(id: recordID)
        }
        guard
            let mirrorLease = try ExternalDirectoryMirrorLease.tryAcquire(
                at: mirrorLockURL(for: recordID)
            )
        else {
            throw ExternalDirectoryError.mirrorAlreadyRunning
        }
        defer { mirrorLease.release() }
        let record = try withRecordsTransaction {
            try authorizedRecord(
                id: recordID,
                expectedAuthorizationEpoch: initialRecord.authorizationEpoch
            )
        }
        let authorizationEpoch = record.authorizationEpoch
        guard record.syncBinding.phase == .verified else {
            throw ExternalDirectoryError.bindingNotVerified
        }
        try requireLatestAuthoritativeBinding(
            for: record,
            expectedAuthorizationEpoch: authorizationEpoch
        )
        guard record.pendingDeletionConfirmations.contains(confirmation) else {
            throw ExternalDirectoryError.deletionConfirmationUnavailable
        }
        if decision == .propagateDeletion,
            confirmation.kind == .deleteExternal,
            !record.capabilities.canDelete
        {
            throw ExternalDirectoryError.deletionNotSupported
        }
        let resolution: ExternalDirectoryBookmarkResolution
        do {
            resolution = try bookmarkAccess.resolve(record.bookmark)
        } catch {
            throw ExternalDirectoryError.unavailable
        }
        guard !resolution.isStale else { throw ExternalDirectoryError.bookmarkStale }
        guard bookmarkAccess.beginAccess(to: resolution.url) else {
            throw ExternalDirectoryError.authorizationDenied
        }
        defer { bookmarkAccess.endAccess(to: resolution.url) }
        _ = try requireExclusiveExternalRoot(
            for: record,
            resolvedURL: resolution.url
        )
        let livePolicyGate = makeLivePolicyGate(
            folderID: record.syncBinding.folderID,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            currentEnvironment: currentEnvironment
        )
        do {
            try await livePolicyGate.validate(
                actions: Self.policyActions(
                    for: confirmation,
                    decision: decision
                )
            )
        } catch {
            throw ExternalDirectoryError.policyDenied
        }

        do {
            try Self.validateAuthorizationFence(
                recordsURL: recordsURL,
                recordID: recordID,
                expectedAuthorizationEpoch: authorizationEpoch
            )
            let externalRoot = try requireExclusiveExternalRoot(
                for: record,
                resolvedURL: resolution.url
            )
            let managedRoot = try validatedManagedRoot(for: record)
            let planningMirror = ControlledMirror(
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                io: fencedMirrorIO(
                    cancellation: nil,
                    record: record,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    managedRoot: managedRoot,
                    externalRoot: externalRoot,
                    mode: record.mode,
                    livePolicyGate: livePolicyGate
                )
            )
            if let interrupted = try await planningMirror.prepareInterruptedSynchronization() {
                _ = try await applyPreparedExternalPlan(
                    interrupted,
                    record: record,
                    expectedAuthorizationEpoch: authorizationEpoch,
                    managedRoot: managedRoot,
                    externalRoot: externalRoot,
                    livePolicyGate: livePolicyGate,
                    actions: Self.policyActions(for: record.mode),
                    cancellation: nil
                )
            }
            let preparedConfirmation = try await planningMirror.prepareConfirmation(
                confirmation,
                decision: decision
            )
            let confirmationActions = Self.policyActions(
                for: confirmation,
                decision: decision
            )
            let confirmationApplyPlan = try await observeAndCommitConfirmation(
                preparedConfirmation,
                mirror: planningMirror,
                confirmation: confirmation,
                decision: decision,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                livePolicyGate: livePolicyGate,
                actions: confirmationActions
            )
            let result = try await applyPreparedExternalPlan(
                confirmationApplyPlan,
                record: record,
                expectedAuthorizationEpoch: authorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                livePolicyGate: livePolicyGate,
                actions: confirmationActions,
                cancellation: nil
            )
            let status = ExternalDirectoryMirrorStatus(
                phase: result.confirmationRequired.isEmpty ? .succeeded : .requiresConfirmation,
                lastAttemptedAt: now(),
                lastCompletedAt: now(),
                importedFiles: result.copiedToManaged,
                exportedFiles: result.copiedToExternal,
                conflictCount: result.conflicts.count,
                deleteConfirmationCount: result.confirmationRequired.count
            )
            if Self.managedRootChanged(
                in: result,
                confirmation: confirmation,
                decision: decision
            ) {
                do {
                    try requireLatestAuthoritativeBinding(
                        for: record,
                        expectedAuthorizationEpoch: authorizationEpoch
                    )
                    try enqueueScopedRescan(
                        folderID: record.syncBinding.folderID,
                        trigger: trigger
                    )
                } catch {
                    try updateStatus(
                        id: recordID,
                        expectedAuthorizationEpoch: authorizationEpoch,
                        status: ExternalDirectoryMirrorStatus(
                            phase: .retryableFailure,
                            lastAttemptedAt: status.lastAttemptedAt,
                            lastCompletedAt: now(),
                            failureCode: .rescanQueueFailed
                        )
                    )
                    throw ExternalDirectoryError.rescanQueueFailed
                }
            }
            try updateMirrorResult(
                id: recordID,
                expectedAuthorizationEpoch: authorizationEpoch,
                status: status,
                confirmations: result.confirmationRequired
            )
            return status
        } catch let failure as ControlledMirrorFailure {
            if livePolicyGate.policyWasDenied {
                throw ExternalDirectoryError.policyDenied
            }
            switch failure.code {
            case .confirmationNotFound:
                throw ExternalDirectoryError.deletionConfirmationUnavailable
            case .confirmationChanged, .sourceChangedDuringRun,
                .destinationChangedDuringRun, .rootChangedDuringRun,
                .directoryNotEmpty:
                throw ExternalDirectoryError.deletionConfirmationChanged
            default:
                throw ExternalDirectoryError.unavailable
            }
        } catch {
            if livePolicyGate.policyWasDenied {
                throw ExternalDirectoryError.policyDenied
            }
            throw error
        }
    }

    public func runEligibleMirrors(
        trigger: SyncTrigger = .backgroundProcessing,
        maximumRecords: Int = 2,
        cancellation: ExternalDirectoryMirrorCancellation = .init(),
        currentEnvironment: CurrentEnvironment? = nil
    ) async -> [ExternalDirectoryMirrorExecution] {
        guard maximumRecords > 0 else { return [] }
        let ids = allRecords().filter {
            $0.authorizationState == .active
                && $0.syncBinding.phase == .verified
                && $0.mode != .readOnly
        }.map(\.id)
        var executions: [ExternalDirectoryMirrorExecution] = []
        executions.reserveCapacity(min(maximumRecords, ids.count))
        for id in ids {
            guard executions.count < min(maximumRecords, 8), !Self.isCancelled(cancellation),
                recordsByID[id] != nil
            else {
                break
            }
            if let status = try? await runMirror(
                id: id,
                cancellation: cancellation,
                trigger: trigger,
                currentEnvironment: currentEnvironment
            ) {
                executions.append(.init(recordID: id, status: status))
            }
        }
        return executions
    }

    public nonisolated static func allowedModes(
        for capabilities: ExternalDirectoryCapabilities
    ) -> [ExternalDirectoryMode] {
        var values: [ExternalDirectoryMode] = [.readOnly]
        if canImport(capabilities) { values.insert(.importOnly, at: 0) }
        if canExport(capabilities) { values.insert(.exportOnly, at: 0) }
        if canImport(capabilities), canExport(capabilities) {
            values.insert(.controlledMirror, at: 0)
        }
        return values
    }

    /// Serializes every records-file mutation across processes. The latest
    /// durable set is reloaded while holding the lock, then the caller mutates
    /// that set and `persist()` writes the merged result before unlocking.
    private func withRecordsTransaction<T>(_ body: () throws -> T) throws -> T {
        if recordsTransactionActive { return try body() }
        return try FileLock.withExclusiveLock(at: recordsURL.appendingPathExtension("lock")) {
            recordsByID = try Self.readPersistedRecordsLocked(from: recordsURL)
            recordsTransactionActive = true
            recordsTransactionBaseline = recordsByID
            defer {
                recordsTransactionBaseline = nil
                recordsTransactionActive = false
            }
            return try body()
        }
    }

    private func persist() throws {
        guard recordsTransactionActive, let baseline = recordsTransactionBaseline else {
            throw ExternalDirectoryError.unavailable
        }

        // Revocation is one-way. Even an accidental stale in-memory mutation
        // cannot restore a bookmark once the transaction baseline is revoked.
        for (id, previous) in baseline where previous.authorizationState == .revoked {
            guard var current = recordsByID[id] else {
                recordsByID[id] = previous
                continue
            }
            current.authorizationState = .revoked
            current.authorizationEpoch = max(current.authorizationEpoch, previous.authorizationEpoch)
            current.bookmark = Data()
            current.pendingDeletionConfirmations = []
            recordsByID[id] = current
        }

        for id in recordsByID.keys {
            guard var current = recordsByID[id] else { continue }
            if let previous = baseline[id], current != previous {
                if current.revision <= previous.revision {
                    current.revision = try Self.increment(previous.revision)
                }
            } else if baseline[id] == nil, current.revision == 0 {
                current.revision = 1
            }
            recordsByID[id] = current
        }

        try FileManager.default.createDirectory(
            at: recordsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #if os(iOS)
            let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
        #else
            let writeOptions: Data.WritingOptions = [.atomic]
        #endif
        try Self.encoder.encode(sortedRecords()).write(to: recordsURL, options: writeOptions)
        recordsTransactionBaseline = recordsByID
    }

    private func sortedRecords() -> [ExternalDirectoryRecord] {
        recordsByID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private nonisolated static func readPersistedRecordsLocked(
        from recordsURL: URL
    ) throws -> [UUID: ExternalDirectoryRecord] {
        guard FileManager.default.fileExists(atPath: recordsURL.path) else { return [:] }
        let records = try decoder.decode(
            [ExternalDirectoryRecord].self,
            from: Data(contentsOf: recordsURL)
        )
        var result: [UUID: ExternalDirectoryRecord] = [:]
        result.reserveCapacity(records.count)
        for record in records {
            guard record.schemaVersion <= ExternalDirectoryRecord.currentSchemaVersion else {
                throw ExternalDirectoryError.unsupportedRecordSchema(record.schemaVersion)
            }
            guard record.authorizationEpoch > 0, record.revision > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard result.updateValue(record, forKey: record.id) == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return result
    }

    private func authorizedRecord(
        id: UUID,
        expectedAuthorizationEpoch: UInt64? = nil
    ) throws -> ExternalDirectoryRecord {
        guard let record = recordsByID[id] else { throw ExternalDirectoryError.recordNotFound }
        guard record.authorizationState == .active, !record.bookmark.isEmpty else {
            throw ExternalDirectoryError.authorizationAlreadyRevoked
        }
        if let expectedAuthorizationEpoch,
            record.authorizationEpoch != expectedAuthorizationEpoch
        {
            throw ExternalDirectoryError.authorizationAlreadyRevoked
        }
        return record
    }

    private func mirrorLockURL(for id: UUID) -> URL {
        recordsURL.deletingLastPathComponent()
            .appendingPathComponent("MirrorRuns", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased() + ".lock")
    }

    private nonisolated static func validateAuthorizationFence(
        recordsURL: URL,
        recordID: UUID,
        expectedAuthorizationEpoch: UInt64
    ) throws {
        try FileLock.withExclusiveLock(at: recordsURL.appendingPathExtension("lock")) {
            let records = try readPersistedRecordsLocked(from: recordsURL)
            guard let record = records[recordID] else {
                throw ExternalDirectoryError.recordNotFound
            }
            guard record.authorizationState == .active,
                !record.bookmark.isEmpty,
                record.authorizationEpoch == expectedAuthorizationEpoch
            else {
                throw ExternalDirectoryError.authorizationAlreadyRevoked
            }
        }
    }

    private nonisolated static func increment(_ value: UInt64) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw ExternalDirectoryError.unavailable }
        return next
    }

    public nonisolated static func safeMode(
        requested: ExternalDirectoryMode,
        capabilities: ExternalDirectoryCapabilities
    ) -> ExternalDirectoryMode {
        switch requested {
        case .direct, .controlledMirror:
            if canImport(capabilities), canExport(capabilities) { return .controlledMirror }
            if canImport(capabilities) { return .importOnly }
            return .readOnly
        case .importOnly:
            return canImport(capabilities) ? .importOnly : .readOnly
        case .exportOnly:
            return canExport(capabilities) ? .exportOnly : .readOnly
        case .readOnly:
            return .readOnly
        }
    }

    private nonisolated static func canImport(_ capabilities: ExternalDirectoryCapabilities) -> Bool {
        capabilities.canEnumerate && capabilities.canRead
    }

    private nonisolated static func canExport(_ capabilities: ExternalDirectoryCapabilities) -> Bool {
        canImport(capabilities)
            && capabilities.canCreate
            && capabilities.canWrite
            && capabilities.canAtomicallyReplace
            && capabilities.canRename
    }

    private func bindingCommand(
        for record: ExternalDirectoryRecord,
        managedRoot: URL
    ) throws -> CoreCommand {
        guard
            let command = try ScopedCoreCommandProducer(
                paths: SharedContainerPaths(root: containerRoot)
            ).prepareCommands(
                invocationID: record.syncBinding.commandID,
                kind: .addFolder,
                folderID: record.syncBinding.folderID,
                arguments: Self.bindingArguments(for: record, managedRoot: managedRoot),
                trigger: .user
            ).first
        else {
            throw ScopedCoreCommandProducerError.configurationRevisionUnavailable
        }
        return command
    }

    private func enqueueScopedRescan(
        folderID: FolderID,
        trigger: SyncTrigger
    ) throws {
        guard
            let command = try ScopedCoreCommandProducer(
                paths: SharedContainerPaths(root: containerRoot)
            ).prepareCommands(
                kind: .rescan,
                folderID: folderID,
                trigger: trigger
            ).first
        else {
            throw ScopedCoreCommandProducerError.folderScopeRequired(.rescan)
        }
        if trigger == .backgroundRefresh || trigger == .backgroundProcessing {
            _ = try commandQueue.enqueueIfNoPendingCommandInSameFolderAndKind(command)
        } else {
            try commandQueue.enqueue(command)
        }
    }

    private nonisolated static func isValidBindingCommand(
        _ command: CoreCommand,
        for record: ExternalDirectoryRecord,
        managedRoot: URL
    ) -> Bool {
        guard let revision = command.commandConfigurationRevision,
            CoreSessionDigest.isLowercaseSHA256(revision)
        else {
            return false
        }
        let expected = CoreCommand(
            id: record.syncBinding.commandID,
            kind: .addFolder,
            folderID: record.syncBinding.folderID,
            arguments: bindingArguments(for: record, managedRoot: managedRoot),
            commandConfigurationRevision: revision,
            trigger: .user
        )
        return sameBindingCommand(command, expected)
    }

    private nonisolated static func bindingArguments(
        for record: ExternalDirectoryRecord,
        managedRoot: URL
    ) -> [String: String] {
        [
            "label": "External \(record.id.uuidString.lowercased().prefix(8))",
            "path": managedRoot.standardizedFileURL.path,
            "type": FolderType.sendReceive.rawValue,
            "paused": "false",
            // Binding is deliberately local-only. Selecting a Files folder
            // must never silently disclose it to every configured peer.
            "deviceIDs": "[]",
            "rescanIntervalS": "3600",
        ]
    }

    private nonisolated static func sameBindingCommand(
        _ lhs: CoreCommand,
        _ rhs: CoreCommand
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.folderID == rhs.folderID
            && lhs.itemID == rhs.itemID
            && lhs.arguments == rhs.arguments
            && lhs.folderIncarnationDigest == rhs.folderIncarnationDigest
            && lhs.commandConfigurationRevision == rhs.commandConfigurationRevision
            && lhs.trigger == rhs.trigger
    }

    private nonisolated static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.hasPrefix("/"), rhs.hasPrefix("/"), !lhs.contains("\0"), !rhs.contains("\0") else {
            return false
        }
        return URL(fileURLWithPath: lhs, isDirectory: true).standardizedFileURL
            == URL(fileURLWithPath: rhs, isDirectory: true).standardizedFileURL
    }

    /// A managed external mirror is deliberately a local-only core folder.
    /// Legacy snapshots have `deviceIDs == nil`; treating that as `[]` would
    /// silently authorize copying after a peer may already have been added.
    private nonisolated static func authoritativeBindingFailureCode(
        folder: FolderRecord,
        managedRoot: URL
    ) -> String? {
        guard samePath(folder.localPath, managedRoot.path) else {
            return "folder_path_mismatch"
        }
        guard let deviceIDs = folder.deviceIDs else {
            return "folder_devices_unavailable"
        }
        guard deviceIDs.isEmpty else {
            return "folder_shared_with_peers"
        }
        guard folder.type == .sendReceive else {
            return "folder_type_mismatch"
        }
        guard !folder.isPaused else {
            return "folder_paused"
        }
        return nil
    }

    private nonisolated static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.hasPrefix("/"), rhs.hasPrefix("/"), !lhs.contains("\0"), !rhs.contains("\0") else {
            return true
        }
        let left = URL(fileURLWithPath: lhs, isDirectory: true).standardizedFileURL.pathComponents
        let right = URL(fileURLWithPath: rhs, isDirectory: true).standardizedFileURL.pathComponents
        return (left.count <= right.count && Array(right.prefix(left.count)) == left)
            || (right.count <= left.count && Array(left.prefix(right.count)) == right)
    }

    private nonisolated static func safeBindingFailureCode(_ value: String?) -> String {
        guard let value,
            !value.isEmpty,
            value.utf8.count <= 128,
            value.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)
            })
        else {
            return "binding_command_failed"
        }
        return value
    }

    private func managedRoot(for token: String) throws -> URL {
        guard let uuid = UUID(uuidString: token),
            uuid.uuidString.caseInsensitiveCompare(token) == .orderedSame
        else {
            throw SharedContainerError.invalidManagedRootToken
        }
        let base = managedRootsURL.standardizedFileURL
        let candidate = base.appendingPathComponent(uuid.uuidString.lowercased(), isDirectory: true).standardizedFileURL
        let baseComponents = base.pathComponents
        guard candidate.pathComponents.count == baseComponents.count + 1,
            Array(candidate.pathComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw SharedContainerError.managedFolderEscapesContainer
        }
        return candidate
    }

    private func validatedManagedRoot(for record: ExternalDirectoryRecord) throws -> URL {
        let expectedBinding = try ExternalDirectorySyncBinding.initial(recordID: record.id)
        guard record.syncBinding.folderID == expectedBinding.folderID,
            record.managedRootToken.caseInsensitiveCompare(record.id.uuidString) == .orderedSame
        else {
            throw ExternalDirectoryError.invalidBindingIdentifier
        }
        let candidate = try managedRoot(for: record.managedRootToken)
        let manager = FileManager.default
        guard let baseAttributes = try? manager.attributesOfItem(atPath: managedRootsURL.path),
            baseAttributes[.type] as? FileAttributeType == .typeDirectory,
            (try? manager.destinationOfSymbolicLink(atPath: managedRootsURL.path)) == nil,
            let candidateAttributes = try? manager.attributesOfItem(atPath: candidate.path),
            candidateAttributes[.type] as? FileAttributeType == .typeDirectory,
            (try? manager.destinationOfSymbolicLink(atPath: candidate.path)) == nil
        else {
            throw ExternalDirectoryError.unsafeManagedRoot
        }
        let resolvedBase = managedRootsURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let baseComponents = resolvedBase.pathComponents
        guard resolvedCandidate.pathComponents.count == baseComponents.count + 1,
            Array(resolvedCandidate.pathComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw ExternalDirectoryError.unsafeManagedRoot
        }
        return candidate.standardizedFileURL
    }

    private func validatedExternalRoot(_ value: URL) throws -> URL {
        let root = value.standardizedFileURL
        let manager = FileManager.default
        guard root.path != "/",
            let attributes = try? manager.attributesOfItem(atPath: root.path),
            attributes[.type] as? FileAttributeType == .typeDirectory,
            (try? manager.destinationOfSymbolicLink(atPath: root.path)) == nil
        else {
            throw ExternalDirectoryError.bindingConflict
        }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedManagedBase = managedRootsURL.resolvingSymlinksInPath().standardizedFileURL
        guard !Self.pathsOverlap(resolved.path, resolvedManagedBase.path) else {
            throw ExternalDirectoryError.bindingConflict
        }
        return root
    }

    private func requireExclusiveExternalRoot(
        for record: ExternalDirectoryRecord,
        resolvedURL: URL
    ) throws -> URL {
        let root = try validatedExternalRoot(resolvedURL)
        let identity = try checkedRootIdentity(at: root, expected: nil)
        try requireRootIdentity(identity, at: root)
        try withRecordsTransaction {
            _ = try authorizedRecord(
                id: record.id,
                expectedAuthorizationEpoch: record.authorizationEpoch
            )
            try rejectOverlappingAuthorization(
                identity: identity,
                root: root,
                excludingRecordID: record.id
            )
            try requireRootIdentity(identity, at: root)
        }
        return root
    }

    private func checkedRootIdentity(
        at url: URL,
        expected: ExternalDirectoryRootIdentity?
    ) throws -> ExternalDirectoryRootIdentity {
        let identity: ExternalDirectoryRootIdentity
        do {
            identity = try ExternalDirectoryRootIdentityFence.capture(at: url)
        } catch {
            throw ExternalDirectoryError.bindingConflict
        }
        if let expected, expected != identity {
            throw ExternalDirectoryError.bindingConflict
        }
        return identity
    }

    private func requireRootIdentity(
        _ expected: ExternalDirectoryRootIdentity,
        at url: URL
    ) throws {
        guard try checkedRootIdentity(at: url, expected: expected) == expected else {
            throw ExternalDirectoryError.bindingConflict
        }
    }

    private func reserveAuthorizationRoot(
        identity: ExternalDirectoryRootIdentity,
        root: URL
    ) throws -> UUID {
        try rejectOverlappingAuthorization(
            identity: identity,
            root: root,
            excludingRecordID: nil
        )
        let components = try resolvedExternalPathComponents(root)
        for pending in pendingAuthorizationRoots.values {
            if pending.identity == identity
                || Self.pathComponentsOverlap(pending.resolvedPathComponents, components)
            {
                throw ExternalDirectoryError.bindingConflict
            }
        }
        let reservationID = UUID()
        pendingAuthorizationRoots[reservationID] = AuthorizationRootReservation(
            identity: identity,
            resolvedPathComponents: components
        )
        return reservationID
    }

    private func rejectOverlappingAuthorization(
        identity candidateIdentity: ExternalDirectoryRootIdentity,
        root candidateRoot: URL,
        excludingRecordID: UUID?
    ) throws {
        let candidateComponents = try resolvedExternalPathComponents(candidateRoot)
        for record in recordsByID.values
        where record.authorizationState == .active && record.id != excludingRecordID {
            let resolution: ExternalDirectoryBookmarkResolution
            do {
                resolution = try bookmarkAccess.resolve(record.bookmark)
            } catch {
                throw ExternalDirectoryError.bindingConflict
            }
            guard !resolution.isStale,
                bookmarkAccess.beginAccess(to: resolution.url)
            else {
                throw ExternalDirectoryError.bindingConflict
            }
            let existingIdentity: ExternalDirectoryRootIdentity
            let existingRoot: URL
            do {
                defer { bookmarkAccess.endAccess(to: resolution.url) }
                existingIdentity = try checkedRootIdentity(at: resolution.url, expected: nil)
                existingRoot = try validatedExternalRoot(resolution.url)
                try requireRootIdentity(existingIdentity, at: resolution.url)
            } catch {
                throw ExternalDirectoryError.bindingConflict
            }
            let existingComponents = try resolvedExternalPathComponents(existingRoot)
            if existingIdentity == candidateIdentity
                || Self.pathComponentsOverlap(existingComponents, candidateComponents)
            {
                throw ExternalDirectoryError.bindingConflict
            }
        }
    }

    private func resolvedExternalPathComponents(_ root: URL) throws -> [String] {
        // The caller has already traversed this exact URL with O_NOFOLLOW.
        // Only fixed, root-owned Darwin aliases are normalized; arbitrary
        // symlinks remain rejected by the identity fence.
        do {
            return try ExternalDirectoryRootIdentityFence.validatedPathComponents(at: root)
        } catch {
            throw ExternalDirectoryError.bindingConflict
        }
    }

    private nonisolated static func pathComponentsOverlap(
        _ left: [String],
        _ right: [String]
    ) -> Bool {
        (left.count <= right.count && Array(right.prefix(left.count)) == left)
            || (right.count <= left.count && Array(left.prefix(right.count)) == right)
    }

    private func requireLatestAuthoritativeBinding(
        for record: ExternalDirectoryRecord,
        expectedAuthorizationEpoch: UInt64
    ) throws {
        let managedRoot: URL
        do {
            managedRoot = try validatedManagedRoot(for: record)
        } catch {
            try invalidateBinding(
                id: record.id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch,
                phase: .conflict,
                failureCode: "unsafe_managed_root"
            )
            throw ExternalDirectoryError.bindingNotVerified
        }

        let snapshot: CoreSnapshot?
        do {
            snapshot = try snapshotStore.read()
        } catch {
            try invalidateBinding(
                id: record.id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch,
                phase: .conflict,
                failureCode: "latest_snapshot_unavailable"
            )
            throw ExternalDirectoryError.bindingNotVerified
        }
        guard let snapshot else {
            try invalidateBinding(
                id: record.id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch,
                phase: .conflict,
                failureCode: "latest_snapshot_unavailable"
            )
            throw ExternalDirectoryError.bindingNotVerified
        }

        let matches = snapshot.folders.filter { $0.id == record.syncBinding.folderID }
        guard !matches.isEmpty else {
            try invalidateBinding(
                id: record.id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch,
                phase: .repairRequired,
                failureCode: "verified_folder_missing"
            )
            throw ExternalDirectoryError.bindingNotVerified
        }
        guard matches.count == 1 else {
            try invalidateBinding(
                id: record.id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch,
                phase: .conflict,
                failureCode: "folder_identity_ambiguous"
            )
            throw ExternalDirectoryError.bindingNotVerified
        }
        if let failureCode = Self.authoritativeBindingFailureCode(
            folder: matches[0],
            managedRoot: managedRoot
        ) {
            try invalidateBinding(
                id: record.id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch,
                phase: .conflict,
                failureCode: failureCode
            )
            throw ExternalDirectoryError.bindingNotVerified
        }
    }

    private func invalidateBinding(
        id: UUID,
        expectedAuthorizationEpoch: UInt64,
        phase: ExternalDirectorySyncBindingPhase,
        failureCode: String
    ) throws {
        try withRecordsTransaction {
            var current = try authorizedRecord(
                id: id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch
            )
            current.syncBinding.phase = phase
            current.syncBinding.failureCode = failureCode
            current.syncBinding.lastCheckedAt = now()
            recordsByID[id] = current
            try persist()
        }
    }

    private func updateStatus(
        id: UUID,
        expectedAuthorizationEpoch: UInt64,
        status: ExternalDirectoryMirrorStatus
    ) throws {
        try withRecordsTransaction {
            var current = try authorizedRecord(
                id: id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch
            )
            current.lastMirrorStatus = status
            recordsByID[id] = current
            try persist()
        }
    }

    private func updateMirrorResult(
        id: UUID,
        expectedAuthorizationEpoch: UInt64,
        status: ExternalDirectoryMirrorStatus,
        confirmations: [ControlledMirrorConfirmation]
    ) throws {
        try withRecordsTransaction {
            var current = try authorizedRecord(
                id: id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch
            )
            current.lastMirrorStatus = status
            current.pendingDeletionConfirmations = confirmations
            recordsByID[id] = current
            try persist()
        }
    }

    private func finishCancelled(
        id: UUID,
        expectedAuthorizationEpoch: UInt64,
        attemptedAt: Date
    ) throws -> ExternalDirectoryMirrorStatus {
        let status = ExternalDirectoryMirrorStatus(
            phase: .cancelled,
            lastAttemptedAt: attemptedAt,
            lastCompletedAt: now(),
            failureCode: .cancelled
        )
        try updateStatus(
            id: id,
            expectedAuthorizationEpoch: expectedAuthorizationEpoch,
            status: status
        )
        return status
    }

    private func finishFailure(
        id: UUID,
        expectedAuthorizationEpoch: UInt64,
        attemptedAt: Date,
        code: ExternalDirectoryMirrorFailureCode
    ) throws -> ExternalDirectoryMirrorStatus {
        let status = ExternalDirectoryMirrorStatus(
            phase: .retryableFailure,
            lastAttemptedAt: attemptedAt,
            lastCompletedAt: now(),
            failureCode: code
        )
        try updateStatus(
            id: id,
            expectedAuthorizationEpoch: expectedAuthorizationEpoch,
            status: status
        )
        return status
    }

    private func makeLivePolicyGate(
        folderID: FolderID,
        trigger: SyncTrigger,
        requestedTemporaryOverride: Bool,
        currentEnvironment: CurrentEnvironment?
    ) -> ExternalDirectoryLivePolicyGate {
        let provider: CurrentEnvironment
        if let currentEnvironment {
            provider = currentEnvironment
        } else {
            #if os(iOS)
                let paths = SharedContainerPaths(root: containerRoot)
                provider = {
                    await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                }
            #else
                // The shipping app target is iOS. Package tests run on macOS
                // and inject live conditions when exercising policy behavior.
                provider = { .permissiveForTesting }
            #endif
        }
        return ExternalDirectoryLivePolicyGate(
            policyURL: policyURL,
            folderIncarnationsURL: folderIncarnationsURL,
            transferAccountingURL: transferAccountingURL,
            folderID: folderID,
            trigger: trigger,
            requestedTemporaryOverride: requestedTemporaryOverride,
            currentEnvironment: provider
        )
    }

    private func reconcileStaleExternalAccounting(
        mirror: ControlledMirror,
        record: ExternalDirectoryRecord,
        at date: Date
    ) async throws {
        let document = try SyncPolicyStore(url: policyURL).loadDocument()
        let store = TransferAccountingStore(
            url: transferAccountingURL,
            budgetTimeZoneIdentifier: document.budgetTimeZoneIdentifier
        )
        _ = try store.recoverStaleReservations(at: date)
        let context = try FolderIncarnationStore(url: folderIncarnationsURL)
            .policyContext(for: record.syncBinding.folderID)
        let ledger = try store.snapshot()
        for usage in ledger.runUsages
        where usage.workKind == .externalMirror
            && usage.folderID == context.folderID
            && usage.folderIncarnationDigest == context.folderIncarnationDigest
            && usage.finishedAt == nil
        {
            let hasActiveReservation = ledger.activeReservations.contains {
                $0.workKind == usage.workKind
                    && $0.folderID == usage.folderID
                    && $0.folderIncarnationDigest == usage.folderIncarnationDigest
                    && $0.taskID == usage.taskID
                    && $0.runID == usage.runID
            }
            guard !hasActiveReservation else { continue }
            let resumable = try await mirror.hasResumableJournal(
                runID: usage.runID,
                planDigest: usage.planDigest
            )
            if !resumable {
                try store.markRunFinished(binding: usage.binding, at: date)
            }
        }
    }

    /// Applies one already-durable mirror journal under a distinct live-owner
    /// reservation. This is also used for each leg of confirmation recovery so
    /// an interrupted journal cannot borrow or bypass the confirmation grant.
    private func observeAndCommitSynchronizationIfNeeded(
        _ plan: ControlledMirrorPreparedPlan,
        mirror: ControlledMirror,
        record: ExternalDirectoryRecord,
        expectedAuthorizationEpoch: UInt64,
        managedRoot: URL,
        externalRoot: URL,
        livePolicyGate: ExternalDirectoryLivePolicyGate,
        actions: Set<SyncAction>,
        cancellation: ExternalDirectoryMirrorCancellation?
    ) async throws -> ControlledMirrorPreparedPlan {
        guard plan.stage == .observation else {
            guard plan.stage == .apply else {
                throw ControlledMirrorPreparedPlanError.changed
            }
            return plan
        }
        let accounting = try await beginPreparedExternalAccounting(
            plan,
            record: record,
            expectedAuthorizationEpoch: expectedAuthorizationEpoch,
            managedRoot: managedRoot,
            externalRoot: externalRoot,
            livePolicyGate: livePolicyGate,
            actions: actions,
            cancellation: cancellation
        )
        var observationSettled = false
        do {
            let observed = try await mirror.observeSynchronization(
                plan,
                meter: accounting.meter.meter
            )
            _ = try accounting.session.settleStageSuccessful(at: now())
            observationSettled = true
            do {
                return try await mirror.commitObservedPlan(observed)
            } catch {
                try accounting.session.finalizeSettledRun(at: now())
                throw error
            }
        } catch {
            if !observationSettled {
                // No journal exists yet, so this failure is terminal and must
                // settle+finalize atomically instead of leaking a run slot.
                _ = try accounting.session.settleTerminalFailure(at: now())
            }
            throw error
        }
    }

    private func observeAndCommitConfirmation(
        _ plan: ControlledMirrorPreparedPlan,
        mirror: ControlledMirror,
        confirmation: ControlledMirrorConfirmation,
        decision: ControlledMirrorConfirmationDecision,
        record: ExternalDirectoryRecord,
        expectedAuthorizationEpoch: UInt64,
        managedRoot: URL,
        externalRoot: URL,
        livePolicyGate: ExternalDirectoryLivePolicyGate,
        actions: Set<SyncAction>
    ) async throws -> ControlledMirrorPreparedPlan {
        guard plan.stage == .observation else {
            throw ControlledMirrorPreparedPlanError.changed
        }
        let accounting = try await beginPreparedExternalAccounting(
            plan,
            record: record,
            expectedAuthorizationEpoch: expectedAuthorizationEpoch,
            managedRoot: managedRoot,
            externalRoot: externalRoot,
            livePolicyGate: livePolicyGate,
            actions: actions,
            cancellation: nil
        )
        var observationSettled = false
        do {
            let observed = try await mirror.observeConfirmation(
                plan,
                requestedConfirmation: confirmation,
                decision: decision,
                meter: accounting.meter.meter
            )
            _ = try accounting.session.settleStageSuccessful(at: now())
            observationSettled = true
            do {
                return try await mirror.commitObservedPlan(observed)
            } catch {
                try accounting.session.finalizeSettledRun(at: now())
                throw error
            }
        } catch {
            if !observationSettled {
                _ = try accounting.session.settleTerminalFailure(at: now())
            }
            throw error
        }
    }

    private func applyPreparedExternalPlan(
        _ plan: ControlledMirrorPreparedPlan,
        record: ExternalDirectoryRecord,
        expectedAuthorizationEpoch: UInt64,
        managedRoot: URL,
        externalRoot: URL,
        livePolicyGate: ExternalDirectoryLivePolicyGate,
        actions: Set<SyncAction>,
        cancellation: ExternalDirectoryMirrorCancellation?
    ) async throws -> ControlledMirrorRunResult {
        let accounting = try await beginPreparedExternalAccounting(
            plan,
            record: record,
            expectedAuthorizationEpoch: expectedAuthorizationEpoch,
            managedRoot: managedRoot,
            externalRoot: externalRoot,
            livePolicyGate: livePolicyGate,
            actions: actions,
            cancellation: cancellation
        )
        let session = accounting.session
        let accountingMeter = accounting.meter
        let applyingMirror = ControlledMirror(
            managedRoot: managedRoot,
            externalRoot: externalRoot,
            mode: record.mode,
            io: fencedMirrorIO(
                cancellation: cancellation,
                record: record,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch,
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                livePolicyGate: livePolicyGate,
                accountingMeter: accountingMeter
            )
        )
        do {
            let result = try await applyingMirror.apply(plan, meter: accountingMeter.meter)
            _ = try session.settleSuccessful(at: now())
            return result
        } catch {
            // Settlement failure intentionally supersedes the apply error: the
            // caller must not observe success while a live grant is unresolved.
            let journalMirror = ControlledMirror(
                managedRoot: managedRoot,
                externalRoot: externalRoot,
                mode: record.mode,
                io: mirrorIO
            )
            if (try? await journalMirror.isResumableJournal(for: plan)) == true {
                _ = try session.settleFailed(at: now())
            } else {
                _ = try session.settleTerminalFailure(at: now())
            }
            throw error
        }
    }

    private func beginPreparedExternalAccounting(
        _ plan: ControlledMirrorPreparedPlan,
        record: ExternalDirectoryRecord,
        expectedAuthorizationEpoch: UInt64,
        managedRoot: URL,
        externalRoot: URL,
        livePolicyGate: ExternalDirectoryLivePolicyGate,
        actions: Set<SyncAction>,
        cancellation: ExternalDirectoryMirrorCancellation?
    ) async throws -> (
        session: ExternalMirrorTransferSession,
        meter: ExternalDirectoryAccountingMeter
    ) {
        let preparation = try await livePolicyGate.prepareTransferAccounting(
            for: plan,
            actions: actions,
            managedRoot: managedRoot
        )
        let session: ExternalMirrorTransferSession
        do {
            session = try ExternalMirrorTransferCoordinator(store: preparation.store).begin(
                preparedPlan: plan,
                folderID: preparation.folderContext.folderID,
                folderIncarnationDigest: preparation.folderContext.folderIncarnationDigest,
                taskID: plan.runID,
                expiresAt: preparation.capturedAt.addingTimeInterval(24 * 60 * 60),
                at: preparation.capturedAt,
                configuredRunLimitBytes: preparation.runLimitBytes,
                globalDailyLimitBytes: preparation.globalDailyLimitBytes,
                folderDailyLimitBytes: preparation.folderDailyLimitBytes
            )
        } catch {
            livePolicyGate.recordAccountingDenial(for: error)
            throw error
        }

        let recordsURL = recordsURL
        let snapshotStore = snapshotStore
        let accountingMeter = ExternalDirectoryAccountingMeter(
            session: session,
            livePolicyGate: livePolicyGate,
            expectedBudgetTimeZoneIdentifier: preparation.budgetTimeZoneIdentifier,
            managedRoot: managedRoot,
            externalRoot: externalRoot,
            validateFence: {
                if let cancellation { try Self.checkCancellation(cancellation) }
                try Self.validateAuthorizationFence(
                    recordsURL: recordsURL,
                    recordID: record.id,
                    expectedAuthorizationEpoch: expectedAuthorizationEpoch
                )
                try Self.validateAuthoritativeBindingFence(
                    snapshotStore: snapshotStore,
                    record: record,
                    managedRoot: managedRoot
                )
            }
        )
        return (session, accountingMeter)
    }

    private func fencedMirrorIO(
        cancellation: ExternalDirectoryMirrorCancellation?,
        record: ExternalDirectoryRecord,
        expectedAuthorizationEpoch: UInt64,
        managedRoot: URL,
        externalRoot: URL,
        mode: ExternalDirectoryMode,
        livePolicyGate: ExternalDirectoryLivePolicyGate,
        accountingMeter: ExternalDirectoryAccountingMeter? = nil
    ) -> ControlledMirrorIO {
        let base = mirrorIO
        let recordsURL = recordsURL
        let snapshotStore = snapshotStore
        let validateFence: @Sendable () throws -> Void = {
            if let cancellation { try Self.checkCancellation(cancellation) }
            try Self.validateAuthorizationFence(
                recordsURL: recordsURL,
                recordID: record.id,
                expectedAuthorizationEpoch: expectedAuthorizationEpoch
            )
        }
        return ControlledMirrorIO(
            readData: { url in
                try validateFence()
                let actions = Self.policyActionsForRead(
                    at: url,
                    managedRoot: managedRoot,
                    externalRoot: externalRoot,
                    mode: mode
                )
                try livePolicyGate.validateSynchronously(
                    actions: actions
                )
                return try base.readData(at: url)
            },
            readDataBounded: { url, exactByteCount, expectedIdentity in
                try validateFence()
                let actions = Self.policyActionsForRead(
                    at: url,
                    managedRoot: managedRoot,
                    externalRoot: externalRoot,
                    mode: mode
                )
                try livePolicyGate.validateSynchronously(actions: actions)
                return try base.readData(
                    at: url,
                    exactByteCount: exactByteCount,
                    expectedIdentity: expectedIdentity
                )
            },
            writeDataAtomically: { data, url in
                try validateFence()
                try livePolicyGate.validateSynchronously(
                    actions: [.scan, .hash],
                    additionalDiskBytes: Int64(data.count),
                    destinationVolume: managedRoot
                )
                try base.writeDataAtomically(data, to: url)
            },
            createDirectory: { url in
                try validateFence()
                try livePolicyGate.validateSynchronously(
                    actions: Self.policyActionsForDestination(
                        url,
                        managedRoot: managedRoot,
                        externalRoot: externalRoot,
                        mode: mode
                    )
                )
                try base.createDirectory(at: url)
            },
            copyFileAtomically: { source, destination, staging in
                try validateFence()
                if let accountingMeter {
                    try accountingMeter.revalidateCurrentPayloadSynchronously()
                } else {
                    throw ExternalMirrorTransferAccountingError.sessionUnavailable
                }
                try base.copyFileAtomically(from: source, to: destination, stagingAt: staging)
            },
            removeItem: { url in
                try validateFence()
                try livePolicyGate.validateSynchronously(
                    actions: Self.policyActionsForDestination(
                        url,
                        managedRoot: managedRoot,
                        externalRoot: externalRoot,
                        mode: mode
                    )
                )
                try base.removeItem(at: url)
            },
            beforeAtomicCopyCommit: { source, destination, staging in
                try validateFence()
                try base.beforeAtomicCopyCommit(
                    source: source,
                    destination: destination,
                    staging: staging
                )
                try validateFence()
            },
            beforeDeleteCommit: { destination in
                try validateFence()
                try livePolicyGate.validateSynchronously(
                    actions: Self.policyActionsForDestination(
                        destination,
                        managedRoot: managedRoot,
                        externalRoot: externalRoot,
                        mode: mode
                    )
                )
            },
            beforeRecoveryPayloadRead: { side, kind, byteCount in
                let actions: Set<SyncAction>
                let boundedTransferBytes: Int64
                switch side {
                case .managed:
                    actions = [.scan, .hash]
                    boundedTransferBytes = max(0, byteCount ?? 0)
                case .external:
                    guard accountingMeter != nil else {
                        throw ExternalMirrorTransferAccountingError.sessionUnavailable
                    }
                    guard kind == .file, let byteCount, byteCount >= 0 else {
                        // Validate all durable fences and a fresh environment
                        // before failing closed for an unbounded provider read.
                        try Self.validateRecoveryFence(
                            cancellation: cancellation ?? .init(),
                            recordsURL: recordsURL,
                            snapshotStore: snapshotStore,
                            record: record,
                            expectedAuthorizationEpoch: expectedAuthorizationEpoch,
                            managedRoot: managedRoot,
                            livePolicyGate: livePolicyGate,
                            actions: [.scan, .hash]
                        )
                        try livePolicyGate.rejectUnknownTransferSize()
                    }
                    actions = [.scan, .hash, .download]
                    boundedTransferBytes = byteCount
                }
                try Self.validateRecoveryFence(
                    cancellation: cancellation ?? .init(),
                    recordsURL: recordsURL,
                    snapshotStore: snapshotStore,
                    record: record,
                    expectedAuthorizationEpoch: expectedAuthorizationEpoch,
                    managedRoot: managedRoot,
                    livePolicyGate: livePolicyGate,
                    actions: actions,
                    transferBytes: boundedTransferBytes
                )
                try base.beforeRecoveryPayloadRead(
                    side: side,
                    kind: kind,
                    byteCount: byteCount
                )
            },
            afterRecoveryPayloadRead: { side, kind, byteCount in
                try base.afterRecoveryPayloadRead(
                    side: side,
                    kind: kind,
                    byteCount: byteCount
                )
            },
            beforeProviderPayloadIO: { transfer in
                try validateFence()
                if let accountingMeter {
                    try accountingMeter.revalidateCurrentPayloadSynchronously()
                }
                try base.beforeProviderPayloadIO(transfer)
                try validateFence()
                if let accountingMeter {
                    try accountingMeter.revalidateCurrentPayloadSynchronously()
                }
            }
        )
    }

    private nonisolated static func checkCancellation(
        _ cancellation: ExternalDirectoryMirrorCancellation
    ) throws {
        if isCancelled(cancellation) { throw CancellationError() }
    }

    private nonisolated static func isCancelled(
        _ cancellation: ExternalDirectoryMirrorCancellation
    ) -> Bool {
        cancellation.isCancelled || withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    private nonisolated static func policyActions(for mode: ExternalDirectoryMode) -> Set<SyncAction> {
        switch mode {
        case .controlledMirror, .direct: [.scan, .hash, .upload, .download]
        case .importOnly: [.scan, .hash, .download]
        case .exportOnly: [.scan, .hash, .upload]
        case .readOnly: [.scan, .hash]
        }
    }

    private nonisolated static func policyActions(
        for confirmation: ControlledMirrorConfirmation,
        decision: ControlledMirrorConfirmationDecision
    ) -> Set<SyncAction> {
        let direction: SyncAction
        switch (confirmation.kind, decision) {
        case (.deleteManaged, .propagateDeletion), (.deleteExternal, .keepSurvivingCopy):
            direction = .download
        case (.deleteExternal, .propagateDeletion), (.deleteManaged, .keepSurvivingCopy):
            direction = .upload
        }
        return [.scan, .hash, direction]
    }

    private nonisolated static func policyActions(
        for summary: ControlledMirrorRecoverySummary,
        decision: ControlledMirrorRecoveryDecision
    ) -> Set<SyncAction> {
        var actions: Set<SyncAction> = [.scan, .hash]
        switch summary.side {
        case .managed:
            break
        case .external:
            // Full recovery fingerprints read provider bytes even when the
            // user's decision is only retain. Each descriptor capture adds a
            // fresh exact byte-count fence before the actual read.
            actions.insert(.download)
            // Removing bytes from a provider-backed directory may itself be
            // uploaded by that provider, so apply the upload policy as well.
            if decision == .deleteAfterUserConfirmation {
                actions.insert(.upload)
            }
        }
        return actions
    }

    private nonisolated static func managedRootChanged(
        in result: ControlledMirrorRunResult
    ) -> Bool {
        result.copiedToManaged > 0 || !result.conflicts.isEmpty
    }

    private nonisolated static func managedRootChanged(
        in result: ControlledMirrorRunResult,
        confirmation: ControlledMirrorConfirmation,
        decision: ControlledMirrorConfirmationDecision
    ) -> Bool {
        if managedRootChanged(in: result) { return true }
        return confirmation.kind == .deleteManaged && decision == .propagateDeletion
    }

    private nonisolated static func externalDirectoryError(
        for error: ControlledMirrorRecoveryError
    ) -> ExternalDirectoryError {
        switch error {
        case .notFound: .recoveryUnavailable
        case .changed: .recoveryChanged
        case .activeJournal: .recoveryActive
        case .authorizationDenied: .authorizationDenied
        case .exportFailed: .recoveryExportFailed
        case .disposalFailed: .recoveryDisposalFailed
        }
    }

    private nonisolated static func validateRecoveryFence(
        cancellation: ExternalDirectoryMirrorCancellation,
        recordsURL: URL,
        snapshotStore: SharedSnapshotStore,
        record: ExternalDirectoryRecord,
        expectedAuthorizationEpoch: UInt64,
        managedRoot: URL,
        livePolicyGate: ExternalDirectoryLivePolicyGate,
        actions: Set<SyncAction>,
        transferBytes: Int64 = 0
    ) throws {
        try checkCancellation(cancellation)
        try validateAuthorizationFence(
            recordsURL: recordsURL,
            recordID: record.id,
            expectedAuthorizationEpoch: expectedAuthorizationEpoch
        )
        try validateAuthoritativeBindingFence(
            snapshotStore: snapshotStore,
            record: record,
            managedRoot: managedRoot
        )
        try livePolicyGate.validateSynchronously(
            actions: actions,
            transferBytes: transferBytes
        )
        // Capturing the live environment may suspend on another executor.
        // Recheck every durable fence after it returns, immediately before the
        // caller is allowed to inspect or dispose recovery state.
        try checkCancellation(cancellation)
        try validateAuthorizationFence(
            recordsURL: recordsURL,
            recordID: record.id,
            expectedAuthorizationEpoch: expectedAuthorizationEpoch
        )
        try validateAuthoritativeBindingFence(
            snapshotStore: snapshotStore,
            record: record,
            managedRoot: managedRoot
        )
    }

    private nonisolated static func validateAuthoritativeBindingFence(
        snapshotStore: SharedSnapshotStore,
        record: ExternalDirectoryRecord,
        managedRoot: URL
    ) throws {
        guard record.syncBinding.phase == .verified,
            let snapshot = try snapshotStore.read()
        else {
            throw ExternalDirectoryError.bindingNotVerified
        }
        let matches = snapshot.folders.filter { $0.id == record.syncBinding.folderID }
        guard matches.count == 1,
            authoritativeBindingFailureCode(folder: matches[0], managedRoot: managedRoot) == nil
        else {
            throw ExternalDirectoryError.bindingNotVerified
        }
    }

    private nonisolated static func policyActionsForRead(
        at url: URL,
        managedRoot: URL,
        externalRoot: URL,
        mode: ExternalDirectoryMode
    ) -> Set<SyncAction> {
        if contains(url, within: externalRoot) {
            return [.scan, .hash, .download]
        }
        if contains(url, within: managedRoot) {
            return [.scan, .hash]
        }
        return policyActions(for: mode)
    }

    private nonisolated static func policyActionsForDestination(
        _ url: URL,
        managedRoot: URL,
        externalRoot: URL,
        mode: ExternalDirectoryMode
    ) -> Set<SyncAction> {
        if contains(url, within: externalRoot) {
            return [.scan, .hash, .upload]
        }
        if contains(url, within: managedRoot) {
            if contains(
                url,
                within: managedRoot.appendingPathComponent(
                    ControlledMirror.stateDirectoryName,
                    isDirectory: true
                )
            ) {
                return [.scan, .hash]
            }
            return [.scan, .hash, .download]
        }
        return policyActions(for: mode)
    }

    private nonisolated static func destinationVolume(
        for url: URL,
        managedRoot: URL,
        externalRoot: URL
    ) -> URL? {
        if contains(url, within: managedRoot) { return managedRoot }
        if contains(url, within: externalRoot) { return externalRoot }
        return nil
    }

    private nonisolated static func contains(_ url: URL, within root: URL) -> Bool {
        let candidate = url.standardizedFileURL.pathComponents
        let parent = root.standardizedFileURL.pathComponents
        return candidate.count >= parent.count
            && Array(candidate.prefix(parent.count)) == parent
    }

    private nonisolated static func fileByteCount(at url: URL) -> Int64? {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            let exact = Int64(exactly: size)
        {
            return max(0, exact)
        }
        if let value = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber {
            return max(0, value.int64Value)
        }
        return nil
    }

    private nonisolated static func failureCode(
        for code: ControlledMirrorErrorCode
    ) -> ExternalDirectoryMirrorFailureCode {
        switch code {
        case .symbolicLinkRejected, .pathOutsideRoot, .invalidRelativePath,
            .rootsOverlap, .invalidRoot, .unsupportedEntryType, .entryTypeConflict:
            .unsafePath
        case .pathCollision:
            .pathCollision
        case .sourceChangedDuringRun, .destinationChangedDuringRun, .rootChangedDuringRun:
            .concurrentChange
        case .stateCorrupt, .unsupportedSchema:
            .stateCorrupt
        case .confirmationChanged, .directoryNotEmpty:
            .concurrentChange
        case .confirmationNotFound:
            .stateCorrupt
        case .unsupportedMode, .ioEnumerate, .ioRead, .ioWrite, .atomicReplaceFailed:
            .mirrorIOFailure
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct CoordinatedFileAccess: Sendable {
    public init() {}

    public func read<T>(at url: URL, operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ExternalDirectoryError.unavailable }
        return try result.get()
    }

    public func write<T>(at url: URL, operation: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ExternalDirectoryError.unavailable }
        return try result.get()
    }
}

extension CoordinatedFileAccess: ExternalDirectoryFileCoordinating {
    func coordinateReading(
        at url: URL,
        operation: (URL) throws -> Void
    ) throws {
        try read(at: url, operation: operation)
    }

    func coordinateWriting(
        at url: URL,
        operation: (URL) throws -> Void
    ) throws {
        try write(at: url, operation: operation)
    }
}
