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
    private var configTask: Task<Void, Never>?
    private let log = Logger(subsystem: FilesLog.subsystem, category: "integration")

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
            let materializer = FilesMaterializer(store: store, trace: materializeTrace) { folder, id in
                try await DomainManager.requestDownload(folder, item: id)
            }
            let projector = FilesProjector(engine: engine, store: store, trace: trace) { folder in
                await DomainManager.signal(folder)
                await materializer.refresh(folder)
            }
            let server = ContentRequestServer(engine: engine, store: store, layout: layout) { [projector] folder in
                await projector.schedule(folder, after: .milliseconds(300), reason: "content")
            }
            self.projector = projector
            self.server = server
            self.materializer = materializer
            await foldersChanged()
            await projector.start()
            await server.start()
            await server.drain()
            let events = engine.events()
            configTask = Task { [weak self] in
                for await event in events {
                    if case .configurationChanged = event { await self?.foldersChanged() }
                }
            }
            log.info("files integration started")
        } catch {
            log.error("files integration failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    func engineWillStop() async {
        configTask?.cancel()
        configTask = nil
        await server?.stop()
        await projector?.stop()
        await materializer?.stop()
        materializer = nil
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
