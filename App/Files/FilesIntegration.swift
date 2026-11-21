import Foundation
import PsySync
import os

/// App-side Files services bound to the engine lifecycle (DESIGN.md §6.2–6.6):
/// `FilesProjector` (global index → files.sqlite → signalEnumerator),
/// `ContentRequestServer` (extension requests + local-mutation journal) and
/// `DomainManager` (one domain per managed folder).
///
/// Wiring for WP-D's EngineHost:
/// - after `engine.start(...)` succeeds → `await files.engineDidStart()`
/// - before `engine.stop(...)` (beginBackgroundTask) → `await files.engineWillStop()`
///   which closes files.sqlite (invariant I2: nothing held in the App Group
///   when suspended).
/// - on folder add/remove/update → `await files.foldersChanged()` (also
///   triggered automatically by `.configurationChanged`).
@MainActor
final class FilesIntegration {
    private let engine: any SyncEngine
    private let layout: AppGroupLayout
    private var store: FilesStore?
    private var projector: FilesProjector?
    private var server: ContentRequestServer?
    private var configTask: Task<Void, Never>?
    private let log = Logger(subsystem: FilesLog.subsystem, category: "integration")

    init(engine: any SyncEngine, layout: AppGroupLayout) {
        self.engine = engine
        self.layout = layout
    }

    var isRunning: Bool { store != nil }

    func engineDidStart() async {
        guard store == nil else { return }
        do {
            let store = try FilesStore(url: layout.filesDatabase)
            self.store = store
            let projector = FilesProjector(engine: engine, store: store) { folder in await DomainManager.signal(folder) }
            let server = ContentRequestServer(engine: engine, store: store, layout: layout) { [projector] folder in
                await projector.schedule(folder, after: .milliseconds(300))
            }
            self.projector = projector
            self.server = server
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
        server = nil
        projector = nil
        store?.close()
        store = nil
        log.info("files integration stopped")
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
        } catch {
            log.error("folders() failed: \(String(describing: error), privacy: .public)")
        }
    }
}
