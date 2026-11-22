import Foundation
import OSLog
import PsySync

/// Production engine: WP-B's `LiveSyncEngine` (REST + event pump) over WP-A's
/// `PsyBridgeAdapter` (gomobile `PsyBridge.xcframework`), with the App Group
/// layout, the cross-process `FlockEngineLock` and the Keychain identity.
struct LiveEngineComponents {
    let engine: any SyncEngine
    let bridge: PsyBridgeAdapter?
    let layout: AppGroupLayout?
}

enum EngineFactory {
    static func makeLiveEngine(deviceName: String) -> LiveEngineComponents {
        let layout: AppGroupLayout
        do {
            try PsyBridgeAdapter.checkAPIVersion()
            layout = try AppGroupResolver.layout()
        } catch {
            LifecycleLog.shared.record("engine-unavailable", "\(error)")
            return LiveEngineComponents(engine: UnavailableSyncEngine(detail: "\(error)"), bridge: nil, layout: nil)
        }
        let bridgeLog = Logger(subsystem: "app.psynguechthyngue", category: "bridge")
        let exitTarget = ExitTarget()
        let bridge = PsyBridgeAdapter(
            log: { level, message in bridgeLog.log(level: level == "error" ? .error : .info, "\(message, privacy: .public)") },
            onExit: { code, detail in
                LifecycleLog.shared.record("engine-exited", "code=\(code?.rawValue ?? "-") \(detail)")
                // Mark the engine failed now; LiveEngineHost restarts it.
                if let engine = exitTarget.engine {
                    Task { await engine.bridgeExited(code: code?.rawValue, detail: detail) }
                }
            }
        )
        let accessGroup = Bundle.main.object(forInfoDictionaryKey: "PsyKeychainAccessGroup") as? String
        var config = LiveSyncEngineConfiguration(layout: layout, deviceName: deviceName)
        config.fsWatcherEnabled = ProcessInfo.processInfo.isiOSAppOnMac
        let engine = LiveSyncEngine(
            bridge: bridge,
            lock: FlockEngineLock(layout: layout),
            identityStore: KeychainIdentityStore(accessGroup: accessGroup.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }),
            configuration: config
        )
        exitTarget.engine = engine
        return LiveEngineComponents(engine: engine, bridge: bridge, layout: layout)
    }
}

/// Lets the bridge's exit callback (created before the engine) reach it.
private final class ExitTarget: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _engine: LiveSyncEngine?
    var engine: LiveSyncEngine? {
        get { lock.withLock { _engine } }
        set { lock.withLock { _engine = newValue } }
    }
}

/// Used when the engine cannot be constructed (bridge API mismatch, App Group
/// missing): every call fails, which the UI shows as an ordinary error.
final class UnavailableSyncEngine: SyncEngine, @unchecked Sendable {
    private let detail: String
    private var failure: EngineError { .bridge(code: BridgeContract.Code.config.rawValue, detail: detail) }
    init(detail: String) { self.detail = detail }
    func start(context: EngineRunContext) async throws { throw failure }
    func stop(deadline: Duration) async throws {}
    var state: EngineState { get async { .failed(code: BridgeContract.Code.config.rawValue, detail: detail) } }
    func events() -> AsyncStream<EngineEvent> { AsyncStream { _ in } }
    func snapshot() async throws -> EngineStatus { throw failure }
    var localDeviceID: DeviceID? { get async { nil } }
    func devices() async throws -> [Device] { throw failure }
    func connections() async throws -> [DeviceConnection] { throw failure }
    func addDevice(_ device: Device) async throws { throw failure }
    func updateDevice(_ device: Device) async throws { throw failure }
    func removeDevice(_ id: DeviceID) async throws { throw failure }
    func pendingDevices() async throws -> [PendingDevice] { throw failure }
    func dismissPendingDevice(_ id: DeviceID) async throws { throw failure }
    func folders() async throws -> [Folder] { throw failure }
    func folderStatus(_ id: FolderID) async throws -> FolderStatus { throw failure }
    func addFolder(_ folder: Folder) async throws { throw failure }
    func updateFolder(_ folder: Folder) async throws { throw failure }
    func removeFolder(_ id: FolderID, deleteLocalFiles: Bool) async throws { throw failure }
    func pendingFolders() async throws -> [PendingFolder] { throw failure }
    func acceptPendingFolder(_ pending: PendingFolder, as folder: Folder) async throws { throw failure }
    func dismissPendingFolder(_ pending: PendingFolder) async throws { throw failure }
    func scan(_ folder: FolderID, paths: [RelativePath]?) async throws { throw failure }
    func prioritize(_ folder: FolderID, path: RelativePath) async throws { throw failure }
    func setLocalPresence(_ folder: FolderID, paths: [RelativePath], present: Bool) async throws { throw failure }
    func apply(_ decision: PolicyDecision) async throws { throw failure }
    func globalIndex(_ folder: FolderID, pageSize: Int) -> AsyncThrowingStream<[GlobalIndexEntry], Error> {
        AsyncThrowingStream { $0.finish(throwing: EngineError.bridge(code: BridgeContract.Code.notImplemented.rawValue, detail: "")) }
    }
}
