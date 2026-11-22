import Foundation

/// App-side: makes "on this device" mean "available offline in Files".
///
/// A file the engine already has locally (`is_local`) is served to Files by a
/// cheap APFS clone (`localClone`), but the system only calls `fetchContents`
/// when the item is opened, so until then Files shows it as not downloaded
/// (cloud badge) although the App reports it as on this device. This asks the
/// system to download such items now (`NSFileProviderManager
/// .requestDownloadForItem`); the extension answers each with a clone, so the
/// Files copy shares blocks with the Syncthing copy instead of doubling storage.
///
/// Applies to every content mode: in "Download everything" all files are
/// local; in "On demand" the local ones are those downloaded, kept or still
/// present from before a mode switch. "Remove Download" drops the engine copy
/// (no longer local) and evicts the Files copy.
///
/// Each (item, content version) is requested at most once per App run, so an
/// item the system refuses or evicts again is not hammered; a new version or
/// the next App start retries it.
public actor FilesMaterializer {
    public typealias Request = @Sendable (FolderID, ItemIdentifier) async throws -> Void
    public typealias Trace = @Sendable (String) -> Void

    private let store: FilesStore
    private let request: Request
    private let trace: Trace?
    private let batchLimit: Int
    private var requested: [String: Data] = [:]
    private var running: [FolderID: Task<Void, Never>] = [:]
    private var again: Set<FolderID> = []

    public init(store: FilesStore, batchLimit: Int = 20_000, trace: Trace? = nil, request: @escaping Request) {
        self.store = store
        self.request = request
        self.trace = trace
        self.batchLimit = batchLimit
    }

    /// Requests downloads for the folder's local, not yet materialized files.
    /// Coalesces: a call while a run is active schedules one more run after it.
    public func refresh(_ folder: FolderID) {
        if running[folder] != nil {
            again.insert(folder)
            return
        }
        running[folder] = Task { [weak self] in
            await self?.run(folder)
        }
    }

    /// Waits for the folder's current run (tests).
    public func settle(_ folder: FolderID) async {
        while let task = running[folder] { await task.value }
    }

    public func stop() {
        for task in running.values { task.cancel() }
        running.removeAll()
        again.removeAll()
    }

    private func run(_ folder: FolderID) async {
        var asked = 0
        var failed = 0
        var lastError = ""
        defer {
            running[folder] = nil
            if again.remove(folder) != nil, !Task.isCancelled { refresh(folder) }
        }
        let candidates: [(id: ItemIdentifier, contentVersion: Data)]
        do {
            candidates = try store.unmaterializedLocalFiles(folder, limit: batchLimit)
        } catch {
            trace?("folder=\(folder.rawValue) failed=\(error)")
            return
        }
        for item in candidates where requested[item.id.rawValue] != item.contentVersion {
            if Task.isCancelled { break }
            requested[item.id.rawValue] = item.contentVersion
            do {
                try await request(folder, item.id)
                asked += 1
            } catch {
                failed += 1
                lastError = String(describing: error)
            }
        }
        if asked > 0 || failed > 0 {
            trace?("folder=\(folder.rawValue) candidates=\(candidates.count) requested=\(asked) failed=\(failed)"
                   + (failed > 0 ? " error=\(lastError)" : ""))
        }
    }
}
