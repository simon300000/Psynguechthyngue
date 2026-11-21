import Foundation

/// Why the engine is being started. Affects memory profile and how long
/// callers may wait; never affects *what* Syncthing does.
public enum EngineRunContext: String, Codable, Sendable {
    /// App in foreground — the normal, long-lived case.
    case foreground
    /// BGAppRefreshTask / BGProcessingTask / BGContinuedProcessingTask.
    case background
}

public enum EngineError: Error, Hashable, Sendable {
    /// Another process (the File Provider extension's restricted fetch) holds
    /// the engine lock and did not yield within the timeout.
    case lockUnavailable
    case notRunning
    /// Bridge error with stable code (GoBridge/psybridge/errors.go Code*).
    case bridge(code: String, detail: String)
    /// REST call failed: HTTP status (0 = transport) and upstream body.
    case rest(status: Int, body: String)
    case invalidArgument(String)
}

/// The single owner of "the" Syncthing instance inside the App process.
///
/// Implementation (WP-B): `LiveSyncEngine` = bridge (`SyncthingBridge`) for
/// start/stop + `SyncthingRESTClient` for everything else + an event pump that
/// turns `/rest/events` into `events`. All methods are safe to call from any
/// actor; long-running bridge calls run on a dedicated thread, never on the
/// cooperative pool.
public protocol SyncEngine: AnyObject, Sendable {
    // MARK: Lifecycle (called by EngineHost only)

    /// Acquire the engine lock, start Syncthing, wait for REST. Idempotent.
    func start(context: EngineRunContext) async throws
    /// Graceful stop; releases the lock. Must complete within `deadline`
    /// (beginBackgroundTask budget). Idempotent.
    func stop(deadline: Duration) async throws
    var state: EngineState { get async }

    // MARK: Observation

    /// Hot stream; each subscriber gets events from subscription time on.
    /// Call `snapshot()` first, then apply events.
    func events() -> AsyncStream<EngineEvent>
    func snapshot() async throws -> EngineStatus
    var localDeviceID: DeviceID? { get async }

    // MARK: Devices

    func devices() async throws -> [Device]
    func connections() async throws -> [DeviceConnection]
    func addDevice(_ device: Device) async throws
    func updateDevice(_ device: Device) async throws
    func removeDevice(_ id: DeviceID) async throws
    func pendingDevices() async throws -> [PendingDevice]
    func dismissPendingDevice(_ id: DeviceID) async throws

    // MARK: Folders

    func folders() async throws -> [Folder]
    func folderStatus(_ id: FolderID) async throws -> FolderStatus
    /// Creates the directory (managed) or validates the bookmark (external),
    /// writes `.stignore` for on-demand mode, then adds to config.
    func addFolder(_ folder: Folder) async throws
    func updateFolder(_ folder: Folder) async throws
    /// Removes from config. `deleteLocalFiles` only applies to managed folders.
    func removeFolder(_ id: FolderID, deleteLocalFiles: Bool) async throws
    func pendingFolders() async throws -> [PendingFolder]
    func acceptPendingFolder(_ pending: PendingFolder, as folder: Folder) async throws
    func dismissPendingFolder(_ pending: PendingFolder) async throws

    // MARK: Operations

    /// `paths == nil` → full scan; otherwise `POST /rest/db/scan?sub=` per path.
    func scan(_ folder: FolderID, paths: [RelativePath]?) async throws
    /// `POST /rest/db/prio` — move a file to the front of the pull queue.
    func prioritize(_ folder: FolderID, path: RelativePath) async throws
    /// On-demand folders: make `paths` local (un-ignore) or evict them.
    func setLocalPresence(_ folder: FolderID, paths: [RelativePath], present: Bool) async throws
    /// Apply policy output (pause/resume all devices + rate limits).
    func apply(_ decision: PolicyDecision) async throws
    /// Global index stream for the File Provider projection (bridge `IndexStream`).
    func globalIndex(_ folder: FolderID, pageSize: Int) -> AsyncThrowingStream<[GlobalIndexEntry], Error>
}
