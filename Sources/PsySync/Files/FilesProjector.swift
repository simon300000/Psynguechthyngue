import Foundation
import os

/// App-side: keeps `files.sqlite` in sync with the engine's global index
/// Subscribes to `indexChanged`, debounces per folder, runs a
/// full mark-and-sweep pass over `engine.globalIndex`, then signals the
/// folder's File Provider domain. Unchanged rows keep their anchors, so a pass
/// over an unchanged index produces no enumeration work in the system.
public actor FilesProjector {
    public typealias Signal = @Sendable (FolderID) async -> Void
    /// One line per pass (source, entries, rows swept, outcome); the App
    /// writes it to the DEBUG diagnostics log.
    public typealias Trace = @Sendable (String) -> Void
    /// Progress of the running pass per folder (nil when it ends), for the
    /// App's honest status ("Preparing file list… N of M").
    public typealias Listing = @Sendable (FolderID, FilesListingProgress?) -> Void

    private let engine: any SyncEngine
    private let store: FilesStore
    private let signal: Signal
    private let trace: Trace?
    private let listing: Listing?
    private let debounce: Duration
    private let pageSize: Int
    private var folders: Set<FolderID> = []
    private var scheduled: [FolderID: Task<Void, Never>] = [:]
    private var reasons: [FolderID: String] = [:]
    private var running: [FolderID: Task<Void, Never>] = [:]
    /// Duration of the folder's last pass: index-triggered passes wait at
    /// least twice that, so a folder whose pass takes seconds is not
    /// re-walked back to back while its index keeps arriving.
    private var lastPassDuration: [FolderID: Duration] = [:]
    private var eventTask: Task<Void, Never>?
    private let log = Logger(subsystem: "app.psynguechthyngue.files", category: "projector")
    /// Completed passes (tests/diagnostics).
    public private(set) var passCount = 0

    public init(engine: any SyncEngine, store: FilesStore, debounce: Duration = .seconds(2), pageSize: Int = 1000,
                trace: Trace? = nil, listing: Listing? = nil, signal: @escaping Signal)
    {
        self.trace = trace
        self.listing = listing
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
            // A pass still running would write rows for a folder whose rows
            // were just removed (finding A8).
            running.removeValue(forKey: removed)?.cancel()
            reasons[removed] = nil
        }
        let added = new.subtracting(folders)
        folders = new
        for folder in added { schedule(folder, after: .zero, reason: "folders") }
    }

    public func start() {
        guard eventTask == nil else { return }
        let stream = engine.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if case .indexChanged(let folder, _) = event {
                    await self.schedule(folder, reason: "index")
                }
            }
        }
        for folder in folders { schedule(folder, after: .zero, reason: "start") }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        for task in scheduled.values { task.cancel() }
        scheduled.removeAll()
        for task in running.values { task.cancel() }
        running.removeAll()
    }

    /// Debounced projection request.
    public func schedule(_ folder: FolderID, after delay: Duration? = nil, reason: String = "request") {
        guard folders.contains(folder) else { return }
        scheduled[folder]?.cancel()
        if let pending = reasons[folder] {
            if !pending.split(separator: "+").contains(Substring(reason)) { reasons[folder] = pending + "+" + reason }
        } else {
            reasons[folder] = reason
        }
        let wait = delay ?? max(debounce, min(.seconds(30), (lastPassDuration[folder] ?? .zero) * 2))
        scheduled[folder] = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self else { return }
            await self.runPass(folder)
        }
    }

    /// Runs a pass now and waits for it (serialised per folder).
    public func projectNow(_ folder: FolderID) async {
        reasons[folder] = "now"
        await runPass(folder)
    }

    private func runPass(_ folder: FolderID) async {
        scheduled.removeValue(forKey: folder)
        let reason = reasons.removeValue(forKey: folder) ?? "request"
        // Strictly one pass per folder at a time: passes share the store's
        // mark-and-sweep set, so two overlapping passes sweep rows the other
        // one marked. Each pass chains on the one before it (read and
        // replaced without a suspension point); cancelling the newest
        // cancels the whole chain.
        let previous = running[folder]
        let task = Task {
            await withTaskCancellationHandler {
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            guard !Task.isCancelled else { return }
            await self.project(folder, reason: reason)
        }
        running[folder] = task
        await task.value
        if running[folder] == task { running[folder] = nil }
    }

    /// Reasons that only say "the index may have changed": a pass over an
    /// index already projected (same fingerprint) is skipped. Explicit
    /// requests always run.
    private static func isSkippable(_ reason: String) -> Bool {
        reason.split(separator: "+").allSatisfy { ["start", "folders", "index"].contains($0) }
    }

    private func project(_ folder: FolderID, reason: String) async {
        let before = (try? store.currentAnchor()) ?? 0
        let started = ContinuousClock.now
        // Taken before reading: a change during the pass makes the next
        // fingerprint differ, so it is not lost.
        let fingerprint = await engine.indexFingerprint(folder)
        if Self.isSkippable(reason), let fingerprint, fingerprint == (try? store.projectedFingerprint(folder)) {
            let line = Self.describe(folder, reason, 0, "unchanged", started)
            log.info("projection \(line, privacy: .public)")
            trace?(line)
            return
        }
        defer { lastPassDuration[folder] = ContinuousClock.now - started }
        var count = 0
        let listedAtStart = (try? store.itemCount(folder)) ?? 0
        listing?(folder, FilesListingProgress(processed: 0, listedAtStart: listedAtStart))
        defer { listing?(folder, nil) }
        do {
            try store.beginFullSync(folder)
            for try await page in engine.globalIndex(folder, pageSize: pageSize) {
                try Task.checkCancellation()
                _ = try store.applyIndexBatch(folder, entries: page)
                count += page.count
                listing?(folder, FilesListingProgress(processed: count, listedAtStart: listedAtStart))
            }
            // A cancelled consumer sees the stream *end* (next() returns nil),
            // not throw. Sweeping then would delete every row the pass had not
            // reached yet — which is what an engine stop (App backgrounded)
            // mid-pass did to large folders.
            try Task.checkCancellation()
            let (after, swept) = try store.finishFullSyncCounting(folder)
            try? store.setProjectedFingerprint(folder, fingerprint)
            passCount += 1
            let line = Self.describe(folder, reason, count, "swept=\(swept) anchor=\(before)->\(after)", started)
            log.info("projected \(line, privacy: .public)")
            trace?(line)
            if after != before { await signal(folder) }
        } catch {
            store.cancelFullSync(folder)
            let outcome = error is CancellationError ? "cancelled" : "failed=\(String(describing: error))"
            let line = Self.describe(folder, reason, count, outcome, started)
            log.error("projection \(line, privacy: .public)")
            trace?(line)
        }
    }

    private static func describe(_ folder: FolderID, _ reason: String, _ entries: Int, _ outcome: String,
                                 _ started: ContinuousClock.Instant) -> String
    {
        let elapsed = (ContinuousClock.now - started).components
        let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        return "folder=\(folder.rawValue) reason=\(reason) entries=\(entries) \(outcome) ms=\(ms)"
    }
}
