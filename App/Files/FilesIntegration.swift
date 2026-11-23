import Foundation
import PsySync
import os

/// App-side Files services bound to the engine lifecycle (DESIGN.md §6.2–6.6):
/// `FilesProjector` (global index → files.sqlite → signalEnumerator),
/// `ContentRequestServer` (delegatedToApp requests + local-mutation journal)
/// and `DomainManager` (one domain per managed folder).
///
/// Wiring (see Docs/REWRITE/notes/wp-c-integration.md):
/// - Create once with the *same* engine the host drives and call `attach()`;
///   it follows `.engineStateChanged` (running → start services, stopping /
///   stopped / failed → stop them and close files.sqlite, invariant I2).
/// - Optionally call `engineWillStop()` from the host right before
///   `engine.stop(...)` so files.sqlite is closed before the lock is released.
/// - Folder changes are picked up from `.configurationChanged`;
///   `foldersChanged()` forces a reconcile.
@MainActor
final class FilesIntegration {
    private let engine: any SyncEngine
    private let layout: AppGroupLayout
    private var store: FilesStore?
    private var projector: FilesProjector?
    private var server: ContentRequestServer?
    private var materializer: FilesMaterializer?
    private var mirror: FilesDownloadMirror?
    private var configTask: Task<Void, Never>?
    private let log = Logger(subsystem: FilesLog.subsystem, category: "integration")

    /// Files list progress per folder (FolderStatusComposer), set by the host.
    var onListing: (@MainActor (FolderID, FilesListingProgress?) -> Void)?

    init(engine: any SyncEngine, layout: AppGroupLayout) {
        self.engine = engine
        self.layout = layout
    }

    var isRunning: Bool { store != nil }
    private var lifecycleTask: Task<Void, Never>?

    /// Follows the engine's lifecycle events. Idempotent.
    func attach() {
        guard lifecycleTask == nil else { return }
        let events = engine.events()
        lifecycleTask = Task { [weak self, engine] in
            if case .running = await engine.state { await self?.engineDidStart() }
            for await event in events {
                guard case .engineStateChanged(let state) = event else { continue }
                switch state {
                case .running: await self?.engineDidStart()
                case .stopping, .stopped, .failed: await self?.engineWillStop()
                case .starting: break
                }
            }
        }
    }

    func detach() async {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        await engineWillStop()
    }

    func engineDidStart() async {
        guard store == nil else { return }
        do {
            let store = try FilesStore(url: layout.filesDatabase)
            self.store = store
            #if DEBUG
            let trace: FilesProjector.Trace? = { LifecycleLog.shared.record("files-projection", $0) }
            let materializeTrace: FilesMaterializer.Trace? = { LifecycleLog.shared.record("files-materialize", $0) }
            #else
            let trace: FilesProjector.Trace? = nil
            let materializeTrace: FilesMaterializer.Trace? = nil
            #endif
            let materializer = FilesMaterializer(store: store, width: 4, trace: materializeTrace) { folder, id in
                try await DomainManager.materialize(folder, item: id)
            }
            let mirror = FilesDownloadMirror(store: store, trace: materializeTrace) { folder, id in
                try await DomainManager.materializeWhileDownloading(folder, item: id)
            }
            // Hops to the main actor may reorder; a sequence number drops
            // stale updates (a late "N of M" after the pass ended would
            // leave the folder stuck as "preparing").
            let sequence = listingSequence
            let listing: FilesProjector.Listing = { [weak self] folder, progress in
                let n = sequence.next()
                Task { @MainActor in self?.deliverListing(folder, progress, n) }
            }
            let projector = FilesProjector(engine: engine, store: store, trace: trace, listing: listing) { folder in
                await DomainManager.signal(folder)
                await materializer.refresh(folder)
            }
            let server = ContentRequestServer(engine: engine, store: store, layout: layout) { [projector] folder in
                await projector.schedule(folder, after: .milliseconds(300), reason: "content")
            }
            self.projector = projector
            self.server = server
            self.materializer = materializer
            self.mirror = mirror
            // Subscribe before the first reconcile: a folder accepted while it
            // and the drain run (seconds after engine start) changed the
            // configuration unseen, and it got no domain and no projection
            // until the next change (perf measurement, master 0384f15).
            let events = engine.events()
            await foldersChanged()
            await projector.start()
            await server.start()
            await server.drain()
            // The stream keeps only the newest events; a busy start (index
            // batches, downloads) could push an early configuration change
            // out of it. One more reconcile is idempotent.
            await foldersChanged()
            configTask = Task { [weak self] in
                for await event in events {
                    switch event {
                    case .configurationChanged:
                        await self?.foldersChanged()
                    case .deviceConnectionChanged(let c) where c.state == .connected:
                        // Files backs off after "server unreachable" until
                        // told otherwise; a device is back, so retry now.
                        await self?.deviceConnected()
                    case .downloadProgress, .itemFinished:
                        await mirror.handle(event)
                    default:
                        break
                    }
                }
            }
            log.info("files integration started")
        } catch {
            log.error("files integration failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    private var listingSeen: [FolderID: UInt64] = [:]
    private let listingSequence = ListingSequence()   // survives engine restarts, like listingSeen

    private func deliverListing(_ folder: FolderID, _ progress: FilesListingProgress?, _ n: UInt64) {
        guard n > listingSeen[folder, default: 0] else { return }
        listingSeen[folder] = n
        onListing?(folder, progress)
    }

    func engineWillStop() async {
        configTask?.cancel()
        configTask = nil
        await server?.stop()
        await projector?.stop()
        await materializer?.stop()
        materializer = nil
        await mirror?.stop()
        mirror = nil
        server = nil
        projector = nil
        store?.close()
        store = nil
        log.info("files integration stopped")
    }

    /// For the UI (WP-D): whether each managed folder's Files location is enabled.
    /// On Mac (Designed for iPad) new domains start disabled by the user; show
    /// a hint to enable "Psynguechthyngue" under System Settings → Login Items &
    /// Extensions → File Providers (Docs/REWRITE/MAC_SPIKE.md).
    private(set) var domainStatuses: [FolderID: FilesDomainStatus] = [:]

    func refreshDomainStatuses() async -> [FolderID: FilesDomainStatus] {
        let folders = (try? await engine.folders()) ?? []
        let managed = folders.filter { if case .managed = $0.location { return true } else { return false } }
        domainStatuses = await DomainManager.statuses(for: managed.map(\.id))
        return domainStatuses
    }

    /// Local files Files has not materialized yet (FolderDetailView hint).
    func notYetInFiles(_ folder: FolderID) -> Int {
        (try? store?.unmaterializedLocalFileCount(folder)) ?? 0
    }

    private func deviceConnected() async {
        let folders = (try? await engine.folders()) ?? []
        let managed = folders.filter { if case .managed = $0.location { return true } else { return false } }
        await DomainManager.resolveErrors(managed.map(\.id))
    }

    func foldersChanged() async {
        guard let store, let projector else { return }
        do {
            let folders = try await engine.folders()
            await DomainManager.reconcile(folders: folders, store: store)
            let managed = folders.filter { if case .managed = $0.location { return true } else { return false } }
            for folder in managed {
                try? FileManager.default.createDirectory(at: layout.managedFolder(folder.id), withIntermediateDirectories: true)
            }
            await projector.setFolders(managed.map(\.id))
            domainStatuses = await DomainManager.statuses(for: managed.map(\.id))
            // Engine is running: lift any "paused" back-off from earlier failures.
            await DomainManager.resolveErrors(managed.map(\.id))
            // Files already on the device (e.g. synced while the App was
            // away, or from before a mode switch) become offline in Files.
            if let materializer { for folder in managed { await materializer.refresh(folder.id) } }
            #if DEBUG
            await DomainManager.logDomainStates()
            #endif
        } catch {
            log.error("folders() failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Monotonic counter shared by the projector's listing callbacks.
private final class ListingSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.withLock { value += 1; return value } }
}
