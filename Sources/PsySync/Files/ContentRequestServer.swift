import Foundation
import os

/// App-side counterpart of the extension (DESIGN.md §6.2 delegatedToApp, §6.5).
///
/// - `ContentRequestInbox`: posted → accepted (un-ignore + prio) → completed
///   when the engine reports `itemFinished` (or the file is already local).
/// - `LocalMutationJournal`: un-ignore new paths in on-demand folders,
///   targeted `scan`, clear `pendingUpload`, acknowledge, re-project.
/// - Presence requests (Keep Downloaded / Remove Download).
///
/// Woken by `DarwinNotification.filesRequestPosted`, by engine events and by a
/// slow safety poll. Call `drain()` after the engine starts to process the
/// backlog accumulated while the App was not running.
public actor ContentRequestServer {
    public typealias ProjectionHook = @Sendable (FolderID) async -> Void

    private let engine: any SyncEngine
    private let store: FilesStore
    private let layout: AppGroupLayout
    private let requestProjection: ProjectionHook
    private let requestTimeout: TimeInterval
    private let pollInterval: Duration
    private var inFlight: [UUID: (request: ContentRequest, acceptedAt: Date)] = [:]
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var observation: DarwinObservation?
    private var draining = false
    private var drainAgain = false
    private let log = Logger(subsystem: "app.psynguechthyngue.files", category: "server")

    public init(
        engine: any SyncEngine, store: FilesStore, layout: AppGroupLayout, requestTimeout: TimeInterval = 600,
        pollInterval: Duration = .seconds(5), requestProjection: @escaping ProjectionHook
    ) {
        self.engine = engine
        self.store = store
        self.layout = layout
        self.requestTimeout = requestTimeout
        self.pollInterval = pollInterval
        self.requestProjection = requestProjection
    }

    public func start() {
        guard eventTask == nil else { return }
        let stream = engine.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        observation = DarwinNotifier.observe(DarwinNotification.filesRequestPosted) { [weak self] in
            Task { await self?.drain() }
        }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                await self?.drain()
            }
        }
        Task { await self.drain() }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        pollTask?.cancel()
        pollTask = nil
        observation?.cancel()
        observation = nil
        // Requests left "accepted" are failed so the extension stops waiting
        // and falls back to the restricted fetch once the lock is free.
        for (id, _) in inFlight {
            try? store.update(id, state: .failed, failureCode: "app_stopping")
        }
        if !inFlight.isEmpty { DarwinNotifier.post(DarwinNotification.filesRequestUpdated) }
        inFlight.removeAll()
    }

    /// Processes requests, journal and presence intents until empty.
    public func drain() async {
        if draining {
            drainAgain = true
            return
        }
        draining = true
        defer { draining = false }
        repeat {
            drainAgain = false
            await processRequests()
            await processJournal()
            await processPresence()
            expireRequests()
        } while drainAgain
    }

    // MARK: Requests

    private func processRequests() async {
        guard let open = try? store.open(limit: 100) else { return }
        var changed = false
        for request in open where inFlight[request.id] == nil {
            if request.state == .accepted {
                // Accepted by a previous App run that died; take it again.
                log.info("re-adopting request \(request.id, privacy: .public)")
            }
            do {
                try store.update(request.id, state: .accepted, failureCode: nil)
                inFlight[request.id] = (request, Date())
                changed = true
                DarwinNotifier.post(DarwinNotification.filesRequestUpdated)
                if try store.folderInfo(request.folderID)?.contentMode == .onDemand {
                    try await engine.setLocalPresence(request.folderID, paths: [request.path], present: true)
                }
                if try completeIfLocal(request) { continue }
                try await engine.prioritize(request.folderID, path: request.path)
                // Nobody to download from: do not keep Files waiting (up to
                // `requestTimeout`). The presence rule stays, so the engine
                // fetches it when a device connects; the extension says so.
                if try await noPeerConnected(for: request.folderID) {
                    fail(request.id, code: ContentRequest.queuedNoPeerCode)
                    continue
                }
                log.info("accepted request \(request.id, privacy: .public) path=\(request.path.rawValue, privacy: .private)")
            } catch {
                fail(request.id, code: Self.code(for: error))
            }
        }
        if changed { DarwinNotifier.post(DarwinNotification.filesRequestUpdated) }
    }

    /// True only when the folder is known and none of its devices is
    /// connected (unknown folder / engine data: keep waiting as before).
    private func noPeerConnected(for folder: FolderID) async throws -> Bool {
        guard let config = try await engine.folders().first(where: { $0.id == folder }), !config.devices.isEmpty
        else { return false }
        let connected = Set(try await engine.connections().filter { $0.state == .connected }.map(\.deviceID))
        return connected.isDisjoint(with: config.devices)
    }

    /// Completes when the file is present and the engine considers it local.
    private func completeIfLocal(_ request: ContentRequest) throws -> Bool {
        guard let record = try store.record(folder: request.folderID, path: request.path), record.isLocal else {
            return false
        }
        let url = try PathContainment(root: layout.managedFolder(request.folderID)).url(for: request.path)
        guard LiveContentProvider.isLocallyAvailable(record, at: url) else { return false }
        complete(request.id)
        return true
    }

    private func handle(_ event: EngineEvent) async {
        switch event {
        case .itemFinished(let folder, let path, let error):
            let matches = inFlight.filter { $0.value.request.folderID == folder && $0.value.request.path == path }
            guard !matches.isEmpty else { return }
            if error == nil {
                // Mark local immediately; the projector refreshes versions later.
                if let record = try? store.record(folder: folder, path: path) {
                    try? store.markLocal(record.itemID, isLocal: true)
                }
            }
            for (id, _) in matches {
                if let error { fail(id, code: error) } else { complete(id) }
            }
            await requestProjection(folder)
        case .indexChanged:
            // Projection may have flipped isLocal for something we wait for.
            for (_, entry) in inFlight { _ = try? completeIfLocal(entry.request) }
        case .engineStateChanged(let state):
            if case .stopping = state { stop() }
        default:
            break
        }
    }

    private func complete(_ id: UUID) {
        try? store.update(id, state: .completed, failureCode: nil)
        inFlight[id] = nil
        DarwinNotifier.post(DarwinNotification.filesRequestUpdated)
        log.info("completed request \(id, privacy: .public)")
    }

    private func fail(_ id: UUID, code: String) {
        try? store.update(id, state: .failed, failureCode: code)
        inFlight[id] = nil
        DarwinNotifier.post(DarwinNotification.filesRequestUpdated)
        log.error("failed request \(id, privacy: .public): \(code, privacy: .public)")
    }

    private func expireRequests() {
        let now = Date()
        for (id, entry) in inFlight where now.timeIntervalSince(entry.acceptedAt) > requestTimeout {
            fail(id, code: BridgeContract.Code.deadline.rawValue)
        }
        try? store.pruneRequests(olderThan: 3600)
    }

    static func code(for error: Error) -> String {
        switch error {
        case EngineError.bridge(let code, _): return code
        case EngineError.notRunning: return "not_running"
        case EngineError.lockUnavailable: return "lock_unavailable"
        default: return "engine_error"
        }
    }

    // MARK: Journal ("watcher")

    private func processJournal() async {
        while true {
            guard let batch = try? store.pending(limit: 500), !batch.isEmpty else { return }
            let byFolder = Dictionary(grouping: batch, by: \.folderID)
            for (folder, mutations) in byFolder {
                do {
                    try await apply(mutations, in: folder)
                } catch {
                    log.error("journal scan failed folder=\(folder.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                    return  // keep entries; retry on next drain
                }
            }
            if let last = batch.last?.sequence { try? store.acknowledge(through: last) }
            for folder in byFolder.keys { await requestProjection(folder) }
        }
    }

    private func apply(_ mutations: [LocalMutation], in folder: FolderID) async throws {
        guard let info = try store.folderInfo(folder) else { return }  // folder removed
        var present: [RelativePath] = []
        var gone: [RelativePath] = []
        var scan: [RelativePath] = []
        for m in mutations {
            switch m.kind {
            case .created, .modified:
                present.append(m.path)
                scan.append(m.path)
            case .deleted:
                gone.append(m.path)
                scan.append(m.path)
            case .moved:
                present.append(m.path)
                scan.append(m.path)
                if let previous = m.previousPath {
                    gone.append(previous)
                    scan.append(previous)
                }
            }
        }
        let onDemand = info.contentMode == .onDemand
        if onDemand && !present.isEmpty {
            try await engine.setLocalPresence(folder, paths: Self.unique(present), present: true)
        }
        try await engine.scan(folder, paths: Self.minimalScanSet(scan))
        // Deleted / moved-away paths are deliberately NOT re-ignored here: if
        // the `!/path` rule disappears before upstream has announced the
        // deletion, the deletion is recorded as "ignored" and never propagates
        // (observed against Syncthing 2.1.6). A leftover rule for a
        // nonexistent path is harmless; the generated .stignore is rebuilt
        // from files.sqlite (DESIGN.md §6.3) and drops it.
        _ = gone
        try store.clearPendingUpload(folder, paths: Self.unique(present))
        log.info("journal folder=\(folder.rawValue, privacy: .public) scanned=\(scan.count)")
    }

    static func unique(_ paths: [RelativePath]) -> [RelativePath] {
        var seen = Set<RelativePath>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Drops paths already covered by a scanned ancestor.
    static func minimalScanSet(_ paths: [RelativePath]) -> [RelativePath] {
        let unique = Set(paths)
        return unique.filter { path in
            var ancestor = path.parent
            while !ancestor.isRoot {
                if unique.contains(ancestor) { return false }
                ancestor = ancestor.parent
            }
            return true
        }.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: Presence

    private func processPresence() async {
        guard let requests = try? store.pendingPresence(), !requests.isEmpty else { return }
        var handled: [PresenceRequest] = []
        for request in requests {
            do {
                if try store.folderInfo(request.folderID)?.contentMode == .onDemand {
                    try await engine.setLocalPresence(request.folderID, paths: [request.path], present: request.present)
                    if !request.present, let record = try store.record(folder: request.folderID, path: request.path) {
                        try store.markLocal(record.itemID, isLocal: false)
                    }
                }
                handled.append(request)
            } catch {
                log.error("presence failed: \(String(describing: error), privacy: .public)")
            }
        }
        try? store.acknowledgePresence(handled)
        for folder in Set(handled.map(\.folderID)) { await requestProjection(folder) }
    }
}
