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

    private let width: Int
    private let timeout: Duration

    /// `width` requests are in flight at once; one that the system does not
    /// acknowledge within `timeout` counts as failed (seen on iOS 26: an
    /// item the system has not enumerated yet is never acknowledged), so a
    /// stalled request cannot hold up the rest.
    public init(store: FilesStore, batchLimit: Int = 20_000, width: Int = 8, timeout: Duration = .seconds(20),
                trace: Trace? = nil, request: @escaping Request)
    {
        self.store = store
        self.request = request
        self.trace = trace
        self.batchLimit = batchLimit
        self.width = max(1, width)
        self.timeout = timeout
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
        let todo = candidates.filter { requested[$0.id.rawValue] != $0.contentVersion }
        guard !todo.isEmpty else { return }
        for item in todo { requested[item.id.rawValue] = item.contentVersion }
        let request = request
        let timeout = timeout
        await withTaskGroup(of: String?.self) { group in
            var next = 0
            func add() {
                let id = todo[next].id
                next += 1
                group.addTask {
                    do {
                        try await Self.withTimeout(timeout) { try await request(folder, id) }
                        return nil
                    } catch {
                        return String(describing: error)
                    }
                }
            }
            while next < min(width, todo.count) { add() }
            while let outcome = await group.next() {
                if let outcome {
                    failed += 1
                    lastError = outcome
                } else {
                    asked += 1
                }
                if Task.isCancelled {
                    group.cancelAll()
                } else if next < todo.count {
                    add()
                }
            }
        }
        trace?("folder=\(folder.rawValue) candidates=\(candidates.count) requested=\(asked) failed=\(failed)"
               + (failed > 0 ? " error=\(lastError)" : ""))
    }

    struct TimedOut: Error, CustomStringConvertible {
        var description: String { "timed out" }
    }

    /// Races `body` against `limit`. Not a task group: that would wait for a
    /// request whose completion handler never runs (it ignores cancellation),
    /// so such a request is abandoned instead.
    static func withTimeout(_ limit: Duration, _ body: @escaping @Sendable () async throws -> Void) async throws {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Error>?
            init(_ c: CheckedContinuation<Void, Error>) { continuation = c }
            func resume(_ error: Error?) {
                let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    defer { continuation = nil }
                    return continuation
                }
                if let error { c?.resume(throwing: error) } else { c?.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            let work = Task {
                do { try await body(); once.resume(nil) } catch { once.resume(error) }
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(TimedOut())
                work.cancel()
            }
        }
    }
}
