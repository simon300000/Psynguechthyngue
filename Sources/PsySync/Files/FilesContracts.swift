import Foundation

// MARK: - Metadata projection (App writes, extension reads)

/// Stable File Provider item identifier. Random, assigned the first time a
/// (folder, path) is projected; preserved across local renames performed
/// through Files; remote renames appear as delete + create (upstream has no
/// rename identity). Replaces GoCore/mobilebridge/item_registry.go.
public struct ItemIdentifier: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// One row of the projection, everything an NSFileProviderItem needs.
public struct FileItemRecord: Hashable, Codable, Sendable {
    public var itemID: ItemIdentifier
    public var parentID: ItemIdentifier
    public var folderID: FolderID
    public var path: RelativePath
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    /// NSFileProviderItemVersion.contentVersion — changes only when bytes change.
    public var contentVersion: Data
    /// NSFileProviderItemVersion.metadataVersion — changes on rename/mtime/etc.
    public var metadataVersion: Data
    /// File exists locally at this version (on-demand: un-ignored and pulled).
    public var isLocal: Bool
    /// "Keep Downloaded" (pinned) — never evicted by us.
    public var isPinned: Bool
    /// Local change not yet scanned/announced by the engine.
    public var pendingUpload: Bool
    public var isReadOnly: Bool   // receive-only folder
    /// Monotonic per-domain anchor value at which this row last changed.
    public var changeAnchor: Int64

    public init(
        itemID: ItemIdentifier, parentID: ItemIdentifier, folderID: FolderID, path: RelativePath,
        isDirectory: Bool, size: Int64, modified: Date, contentVersion: Data, metadataVersion: Data,
        isLocal: Bool, isPinned: Bool, pendingUpload: Bool, isReadOnly: Bool, changeAnchor: Int64
    ) {
        self.itemID = itemID
        self.parentID = parentID
        self.folderID = folderID
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.isLocal = isLocal
        self.isPinned = isPinned
        self.pendingUpload = pendingUpload
        self.isReadOnly = isReadOnly
        self.changeAnchor = changeAnchor
    }
}

/// Read side used by the extension's enumerators. Pagination is keyset-based
/// (parent, name) and is NOT invalidated by unrelated changes.
public protocol FilesMetadataReader: Sendable {
    func item(_ id: ItemIdentifier) throws -> FileItemRecord?
    func children(of parent: ItemIdentifier, after cursor: String?, limit: Int) throws -> (items: [FileItemRecord], next: String?)
    /// Changes since `anchor` (inclusive of deletions as tombstones).
    func changes(since anchor: Int64, limit: Int) throws -> (updated: [FileItemRecord], deleted: [ItemIdentifier], newAnchor: Int64, more: Bool)
    func currentAnchor() throws -> Int64
    /// Working set = pinned + local + pendingUpload items only (not the whole index).
    func workingSet(after cursor: String?, limit: Int) throws -> (items: [FileItemRecord], next: String?)
}

/// Write side used by the App's projector (and, for local mutations, by the
/// extension — see `LocalMutationJournal`).
public protocol FilesMetadataWriter: Sendable {
    /// Apply a batch from `SyncEngine.globalIndex`; returns the new anchor.
    func applyIndexBatch(_ folder: FolderID, entries: [GlobalIndexEntry]) throws -> Int64
    func removeFolder(_ folder: FolderID) throws -> Int64
    func setPinned(_ id: ItemIdentifier, pinned: Bool) throws -> Int64
    /// Local rename through Files: keep the identifier.
    func moveIdentity(_ id: ItemIdentifier, to path: RelativePath, in folder: FolderID) throws -> Int64
}

// MARK: - Local mutations from Files (extension → App)

/// Every create/modify/delete/rename the extension performs on disk is
/// journaled here, then the extension posts `DarwinNotification.filesRequestPosted`.
/// The App (when running) turns entries into targeted `SyncEngine.scan` calls;
/// otherwise they are drained on next start / BG task. This is our "watcher":
/// iOS has no FSEvents, so upstream's fs watcher is disabled.
public struct LocalMutation: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case created
        case modified
        case deleted
        case moved
    }

    public var sequence: Int64
    public var folderID: FolderID
    public var kind: Kind
    public var path: RelativePath
    public var previousPath: RelativePath?
    public var recordedAt: Date

    public init(sequence: Int64, folderID: FolderID, kind: Kind, path: RelativePath, previousPath: RelativePath?, recordedAt: Date) {
        self.sequence = sequence
        self.folderID = folderID
        self.kind = kind
        self.path = path
        self.previousPath = previousPath
        self.recordedAt = recordedAt
    }
}

public protocol LocalMutationJournal: Sendable {
    func append(_ folder: FolderID, kind: LocalMutation.Kind, path: RelativePath, previousPath: RelativePath?) throws
    func pending(limit: Int) throws -> [LocalMutation]
    func acknowledge(through sequence: Int64) throws
}

// MARK: - Content requests (extension fetchContents)

public struct ContentRequest: Hashable, Codable, Sendable, Identifiable {
    /// Failure code: no device sharing the folder is connected; the App kept
    /// the download (presence rule) and the engine fetches it later.
    public static let queuedNoPeerCode = "no_peer_queued"
    /// Failure code: the App engine stopped (App left the foreground) before
    /// the file arrived; the extension continues with the restricted fetch.
    public static let appStoppingCode = "app_stopping"
    public enum State: String, Codable, Sendable {
        case posted       // written by extension
        case accepted     // App engine took it (un-ignored + prio)
        case completed    // file is local at the requested version
        case failed
    }

    public var id: UUID
    public var folderID: FolderID
    public var path: RelativePath
    public var requestedVersion: Data
    public var state: State
    public var failureCode: String?
    public var postedAt: Date
    /// Bytes the App engine has pulled for this file so far (DownloadProgress),
    /// 0 until the transfer starts; the extension moves Files' progress with it.
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public init(id: UUID, folderID: FolderID, path: RelativePath, requestedVersion: Data, state: State, failureCode: String?, postedAt: Date,
                bytesDone: Int64 = 0, bytesTotal: Int64 = 0) {
        self.id = id
        self.folderID = folderID
        self.path = path
        self.requestedVersion = requestedVersion
        self.state = state
        self.failureCode = failureCode
        self.postedAt = postedAt
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }
}

/// Shared table in files.sqlite. The App observes `filesRequestPosted`, the
/// extension observes `filesRequestUpdated`.
public protocol ContentRequestInbox: Sendable {
    func post(_ folder: FolderID, path: RelativePath, version: Data) throws -> ContentRequest
    func get(_ id: UUID) throws -> ContentRequest?
    func update(_ id: UUID, state: ContentRequest.State, failureCode: String?) throws
    func open(limit: Int) throws -> [ContentRequest]
    /// App side: transfer progress of an accepted request.
    func setProgress(_ id: UUID, done: Int64, total: Int64) throws
}

// MARK: - Restricted fetch (extension-only, App not running)

/// Budget for the extension's restricted core. Defaults mirror
/// psybridge/fetch.go; memory must be validated on device.
public struct RestrictedFetchBudget: Hashable, Sendable {
    public var deadline: Duration
    public var connectGrace: Duration
    public var maxFileBytes: Int64
    public var memory: MemoryProfile

    public init(deadline: Duration, connectGrace: Duration, maxFileBytes: Int64, memory: MemoryProfile) {
        self.deadline = deadline
        self.connectGrace = connectGrace
        self.maxFileBytes = maxFileBytes
        self.memory = memory
    }

    public static let `default` = RestrictedFetchBudget(
        deadline: .seconds(90),
        connectGrace: .seconds(20),
        maxFileBytes: 2 << 30,
        memory: .restrictedFetch
    )

    /// Headroom kept free for Swift/ObjC allocations next to the Go heap.
    public static let memoryReserveMiB: Int64 = 4
    /// Lowest GOMEMLIMIT handed to the core. GOMEMLIMIT is a soft target (GC
    /// works harder, allocations never fail), so a low value costs CPU, not
    /// correctness.
    public static let memoryFloorMiB: Int64 = 4
    /// Refuse ("open the App") only below this jetsam headroom. Measured on
    /// device (iPad Pro, iPadOS 27): a fetch adds ≈ 3 MiB of footprint before
    /// the first block (DB open + connect) and peaks ≈ 5–6 MiB above its
    /// start for 30–200 MB files; plus 1 MiB margin.
    public static let minimumHeadroomMiB: Int64 = 7

    /// Fits GOMEMLIMIT to the extension's current jetsam headroom
    /// (`os_proc_available_memory()`):
    /// `min(memory.limitMiB, max(available − reserve, floor))`. The device
    /// limit is ≈ 20 MiB, far below the static 40 MiB ceiling. Returns nil
    /// when the headroom itself is below `minimumHeadroomMiB`.
    /// (Until 2026-11-22 the refusal compared `available − reserve` with 6,
    /// i.e. required 10 MiB of headroom and refused every fetch on devices
    /// with a heavier extension baseline.) `availableBytes == 0` means
    /// "unknown" (simulator, macOS) and keeps the static profile.
    public func fitted(availableBytes: UInt64) -> RestrictedFetchBudget? {
        guard availableBytes > 0 else { return self }
        let availableMiB = Int64(clamping: availableBytes >> 20)
        guard availableMiB >= Self.minimumHeadroomMiB else { return nil }
        var budget = self
        budget.memory.limitMiB = min(memory.limitMiB, max(availableMiB - Self.memoryReserveMiB, Self.memoryFloorMiB))
        return budget
    }
}

public struct RestrictedFetchResult: Hashable, Sendable {
    public var stagedFile: URL
    public var size: Int64
    public var version: String
    public var servedBy: [DeviceID]

    public init(stagedFile: URL, size: Int64, version: String, servedBy: [DeviceID]) {
        self.stagedFile = stagedFile
        self.size = size
        self.version = version
        self.servedBy = servedBy
    }
}

/// Bridge facade for psybridge.FetchFile. Caller holds the engine lock.
public protocol RestrictedFetchBridge: Sendable {
    func fetch(
        homeDirectory: URL,
        identity: DeviceIdentity,
        folder: FolderID,
        path: RelativePath,
        expectedVersion: String?,
        destination: URL,
        budget: RestrictedFetchBudget,
        progress: @escaping @Sendable (_ completed: Int64, _ total: Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> RestrictedFetchResult

    /// Record a fetched file in the local index with the global `version`, so the
    /// App's next scan keeps the global version instead of minting a new one.
    /// Call order while holding the engine lock:
    /// fetch → rename into folder → recordFetchedFile → `.stignore` `!/path` → journal → unlock.
    /// Never call before the rename, or the next scan propagates a deletion.
    func recordFetchedFile(
        homeDirectory: URL,
        identity: DeviceIdentity,
        folder: FolderID,
        path: RelativePath,
        version: String
    ) throws
}

/// How the extension satisfies `fetchContents` (decision tree: local clone, delegate to the App, restricted fetch).
public enum ContentSource: Hashable, Sendable {
    /// File is local at the requested version → APFS clone to a temp URL.
    case localClone
    /// App engine running → post ContentRequest, wait for completion, then clone.
    case delegatedToApp
    /// App not running → take engine lock, restricted fetch, move into folder, clone.
    case restrictedFetch
}

/// The extension-side orchestrator (implements `LiveContentProvider`).
public protocol ContentProviding: Sendable {
    func provideContents(
        for item: ItemIdentifier,
        requestedVersion: Data?,
        progress: Progress
    ) async throws -> (url: URL, record: FileItemRecord, source: ContentSource)
}
