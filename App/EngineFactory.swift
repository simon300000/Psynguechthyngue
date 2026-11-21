import Foundation
import PsySync

/// Seam for the production engine. WP-B's `LiveSyncEngine` (REST + event pump
/// over the PsyBridge adapter from WP-A) plugs in here during integration; until
/// then the app falls back to an engine that reports a clear failure instead of crashing.
enum EngineFactory {
    static func makeLiveEngine() -> any SyncEngine {
        // TODO(integration): LiveSyncEngine(bridge: PsyBridgeAdapter(), layout: ..., identityStore: KeychainIdentityStore(...))
        UnavailableSyncEngine()
    }
}

/// Placeholder until `LiveSyncEngine` is integrated: every call fails with
/// `not_implemented`, which the UI shows as an ordinary error banner.
final class UnavailableSyncEngine: SyncEngine, @unchecked Sendable {
    private let failure = EngineError.bridge(code: BridgeContract.Code.notImplemented.rawValue, detail: "LiveSyncEngine not linked")
    func start(context: EngineRunContext) async throws { throw failure }
    func stop(deadline: Duration) async throws {}
    var state: EngineState { get async { .failed(code: BridgeContract.Code.notImplemented.rawValue, detail: "LiveSyncEngine not linked") } }
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
