import FileProvider
import PsySync
import SwiftUI
import os

/// DEV/TEST ONLY host app for the Files acceptance run (WP-C). Plays the part
/// of WP-D's EngineHost: holds the engine lock while "the engine runs"
/// (foreground), wires `FilesIntegration`, and releases everything on
/// background (invariant I2). Config comes from launch arguments once and is
/// remembered: `-PsyHarnessREST http://127.0.0.1:8484 -PsyHarnessKey <key>`.
@main
struct FilesHarnessApp: App {
    @StateObject private var model = HarnessModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            List {
                Section("Engine") {
                    Text(model.status).accessibilityIdentifier("harness.status")
                    Text("lock: \(model.lockHolder)").accessibilityIdentifier("harness.lock")
                }
                Section("Files") {
                    Text("journal: \(model.journalCount)  requests: \(model.openRequests)")
                    ForEach(model.log, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            .refreshable { model.refresh() }
        }
        .onChange(of: phase) { _, newPhase in
            Task {
                if newPhase == .active { await model.activate() } else if newPhase == .background { await model.backgrounded() }
            }
        }
    }
}

@MainActor
final class HarnessModel: ObservableObject {
    @Published var status = "idle"
    @Published var lockHolder = "-"
    @Published var journalCount = 0
    @Published var openRequests = 0
    @Published var log: [String] = []

    private var layout: AppGroupLayout?
    private var engine: RESTDevEngine?
    private var files: FilesIntegration?
    private var lease: (any EngineLockLease)?
    private let logger = Logger(subsystem: FilesLog.subsystem, category: "harness")

    init() {
        let defaults = UserDefaults.standard
        for key in ["PsyHarnessREST", "PsyHarnessKey"] {
            if let value = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String {
                defaults.set(value, forKey: "persisted." + key)
            }
        }
    }

    func activate() async {
        guard files == nil else { return }
        do {
            let layout = try AppGroupResolver.layout()
            self.layout = layout
            try FileManager.default.createDirectory(at: layout.engineHome, withIntermediateDirectories: true)
            guard let rest = UserDefaults.standard.string(forKey: "persisted.PsyHarnessREST").flatMap(URL.init(string:)),
                let key = UserDefaults.standard.string(forKey: "persisted.PsyHarnessKey")
            else {
                status = "not configured"
                return
            }
            status = "acquiring lock"
            guard let lease = await FlockEngineLock(layout: layout).acquire(owner: .app, timeout: .seconds(5)) else {
                status = "lock unavailable"
                return
            }
            self.lease = lease
            let engine = RESTDevEngine(baseURL: rest, apiKey: key, layout: layout)
            try await engine.start(context: .foreground)
            let files = FilesIntegration(engine: engine, layout: layout)
            self.engine = engine
            self.files = files
            await files.engineDidStart()
            status = "running"
            await performEditIfRequested()
            logger.info("harness active root=\(layout.root.path(percentEncoded: false), privacy: .public)")
        } catch {
            status = "error: \(error)"
        }
        refresh()
    }

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func argument(_ key: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
    }

    /// Production behaviour: stop on background (I2). `-PsyHarnessKeepAlive 1`
    /// keeps serving within a background task so the UI test can exercise
    /// delegatedToApp from the Files app (as on iPad split view / Mac).
    func backgrounded() async {
        guard argument("PsyHarnessKeepAlive") == "1" else {
            await deactivate()
            return
        }
        logger.info("harness backgrounded; keep-alive")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "files-harness") { [weak self] in
            Task { @MainActor in
                await self?.deactivate()
                if let task = self?.backgroundTask { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    /// `-PsyHarnessEdit <path> -PsyHarnessEditText <text>`: rewrite an item through
    /// its user-visible URL with NSFileCoordinator, like another app editing
    /// the document → the system calls the extension's modifyItem(contents).
    private func performEditIfRequested() async {
        guard let layout, let path = argument("PsyHarnessEdit"), let text = argument("PsyHarnessEditText") else { return }
        let folder = FolderID(rawValue: argument("PsyHarnessFolder") ?? "psy-test-wpc-files")
        do {
            let store = try FilesStore(url: layout.filesDatabase)
            defer { store.close() }
            guard let record = try store.record(folder: folder, path: RelativePath(rawValue: path)) else {
                logger.error("edit: no such item \(path, privacy: .public)")
                return
            }
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(folder.rawValue), displayName: "")
            guard let manager = NSFileProviderManager(for: domain) else { return }
            let url = try await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(record.itemID.rawValue))
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do { try Data(text.utf8).write(to: target) } catch { writeError = error }
            }
            logger.info("edit \(path, privacy: .public) via \(url.path(percentEncoded: false), privacy: .public) error=\(String(describing: coordinationError ?? writeError as NSError?), privacy: .public)")
            log.append("edited \(path)")
        } catch {
            logger.error("edit failed: \(String(describing: error), privacy: .public)")
        }
    }

    func deactivate() async {
        await files?.engineWillStop()
        try? await engine?.stop(deadline: .seconds(5))
        lease?.release()
        files = nil
        engine = nil
        lease = nil
        status = "stopped"
        logger.info("harness stopped; lock released")
        refresh()
    }

    func refresh() {
        guard let layout else { return }
        lockHolder = FlockEngineLock(layout: layout).currentHolder()?.rawValue ?? "free"
        if let store = try? FilesStore(url: layout.filesDatabase) {
            journalCount = (try? store.pending(limit: 1000).count) ?? 0
            openRequests = (try? store.open(limit: 1000).count) ?? 0
            store.close()
        }
    }
}
