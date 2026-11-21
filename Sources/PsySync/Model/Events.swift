import Foundation

/// Typed projection of upstream `/rest/events` that the app cares about.
/// The REST client long-polls `/rest/events?since=<id>&events=<mask>` and maps
/// each upstream event into one of these; unknown types are dropped.
public enum EngineEvent: Hashable, Sendable {
    // Engine lifecycle (synthesised by SyncEngine, not upstream events)
    case engineStateChanged(EngineState)

    // Devices — DeviceConnected/DeviceDisconnected/DevicePaused/DeviceResumed
    case deviceConnectionChanged(DeviceConnection)
    // PendingDevicesChanged
    case pendingDevicesChanged([PendingDevice])
    // PendingFoldersChanged
    case pendingFoldersChanged([PendingFolder])

    // Folders — StateChanged / FolderSummary / FolderCompletion / FolderErrors / FolderPaused / FolderResumed
    case folderStatusChanged(FolderStatus)

    // ConfigSaved — devices or folders changed (e.g. by an introducer)
    case configurationChanged

    // LocalIndexUpdated / RemoteIndexUpdated — index changed for a folder.
    // `paths` is best-effort (upstream caps the list); nil means "unknown, rescan
    // projection". Consumed by the File Provider metadata projector.
    case indexChanged(folderID: FolderID, paths: [RelativePath]?)

    // ItemStarted / ItemFinished — per-file transfer, used to complete
    // File Provider content requests.
    case itemStarted(folderID: FolderID, path: RelativePath)
    case itemFinished(folderID: FolderID, path: RelativePath, error: String?)

    // DownloadProgress (aggregated, emitted at most 1 Hz)
    case downloadProgress(folderID: FolderID, path: RelativePath, bytesDone: Int64, bytesTotal: Int64)
}

/// Overall engine state.
public enum EngineState: Hashable, Codable, Sendable {
    case stopped
    case starting
    /// REST reachable; `since` = start time.
    case running(since: Date)
    /// Graceful stop in progress (backgrounding or policy).
    case stopping
    /// Start failed or engine exited; `code` is a bridge/engine error code.
    case failed(code: String, detail: String)
}

/// Snapshot for the "Sync" home screen.
public struct EngineStatus: Hashable, Sendable {
    public var state: EngineState
    public var localDeviceID: DeviceID?
    public var policy: PolicyDecision
    public var connectedDevices: Int
    public var totalDevices: Int
    public var folders: [FolderStatus]

    public init(
        state: EngineState,
        localDeviceID: DeviceID?,
        policy: PolicyDecision,
        connectedDevices: Int,
        totalDevices: Int,
        folders: [FolderStatus]
    ) {
        self.state = state
        self.localDeviceID = localDeviceID
        self.policy = policy
        self.connectedDevices = connectedDevices
        self.totalDevices = totalDevices
        self.folders = folders
    }
}
