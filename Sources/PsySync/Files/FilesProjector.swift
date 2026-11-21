import Foundation
import os

/// App-side: keeps `files.sqlite` in sync with the engine's global index
/// (DESIGN.md §6.2). Subscribes to `indexChanged`, debounces per folder, runs a
/// full mark-and-sweep pass over `engine.globalIndex`, then signals the
/// folder's File Provider domain. Unchanged rows keep their anchors, so a pass
/// over an unchanged index produces no enumeration work in the system.
public actor FilesProjector {
    public typealias Signal = @Sendable (FolderID) async -> Void

    private let engine: any SyncEngine
    private let store: FilesStore
    private let signal: Signal
    private let debounce: Duration
    private let pageSize: Int
    private var folders: Set<FolderID> = []
    private var scheduled: [FolderID: Task<Void, Never>] = [:]
    private var running: [FolderID: Task<Void, Never>] = [:]
    private var eventTask: Task<Void, Never>?
    private let log = Logger(subsystem: "app.psynguechthyngue.files", category: "projector")
    /// Completed passes (tests/diagnostics).
    public private(set) var passCount = 0

    public init(engine: any SyncEngine, store: FilesStore, debounce: Duration = .seconds(2), pageSize: Int = 1000,
                signal: @escaping Signal)
    {
        self.engine = engine
        self.store = store
        self.debounce = debounce
        self.pageSize = pageSize
        self.signal = signal
    }

    /// Folders exposed through Files (managed folders only).
    public func setFolders(_ ids: [FolderID]) {
        let new = Set(ids)
        for removed in folders.subtracting(new) {
            scheduled.removeValue(forKey: removed)?.cancel()
        }
        let added = new.subtracting(folders)
        folders = new
        for folder in added { schedule(folder, after: .zero) }
    }

    public func start() {
        guard eventTask == nil else { return }
        let stream = engine.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if case .indexChanged(let folder, _) = event {
                    await self.schedule(folder)
                }
            }
        }
        for folder in folders { schedule(folder, after: .zero) }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        for task in scheduled.values { task.cancel() }
        scheduled.removeAll()
        for task in running.values { task.cancel() }
    }

    /// Debounced projection request.
    public func schedule(_ folder: FolderID, after delay: Duration? = nil) {
        guard folders.contains(folder) else { return }
        scheduled[folder]?.cancel()
        let wait = delay ?? debounce
        scheduled[folder] = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self else { return }
            await self.runPass(folder)
        }
    }

    /// Runs a pass now and waits for it (serialised per folder).
    public func projectNow(_ folder: FolderID) async {
        await runPass(folder)
    }

    private func runPass(_ folder: FolderID) async {
        scheduled.removeValue(forKey: folder)
        if let previous = running[folder] {
            await previous.value
        }
        let task = Task { await self.project(folder) }
        running[folder] = task
        await task.value
        running[folder] = nil
    }

    private func project(_ folder: FolderID) async {
        let before = (try? store.currentAnchor()) ?? 0
        do {
            try store.beginFullSync(folder)
            var count = 0
            for try await page in engine.globalIndex(folder, pageSize: pageSize) {
                try Task.checkCancellation()
                _ = try store.applyIndexBatch(folder, entries: page)
                count += page.count
            }
            let after = try store.finishFullSync(folder)
            passCount += 1
            log.info("projected folder=\(folder.rawValue, privacy: .public) entries=\(count) anchor=\(before)->\(after)")
            if after != before { await signal(folder) }
        } catch {
            store.cancelFullSync(folder)
            log.error("projection failed folder=\(folder.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
