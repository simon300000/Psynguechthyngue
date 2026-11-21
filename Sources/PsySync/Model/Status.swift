import Foundation

/// User-facing folder state, derived from upstream folder state + need counts
/// + connection state. Mapping table lives in DESIGN.md §5.2.
public enum FolderSyncState: String, Codable, Sendable {
    /// Everything this device should have is present and peers are reachable.
    case upToDate
    /// Pulling or sending content.
    case syncing
    /// Local scan in progress.
    case scanning
    /// Work is pending but no device sharing this folder is connected.
    case waitingForDevices
    /// Paused by the user.
    case paused
    /// Paused by policy (network/power), see `EngineStatus.policy`.
    case heldByPolicy
    /// Engine not running (App in background / not started).
    case offline
    /// Folder error (path missing, permission, out of space, …).
    case error
}

/// Byte/item progress for a folder (REST `/rest/db/status` + `/rest/db/completion`).
public struct SyncProgress: Hashable, Codable, Sendable {
    public var globalBytes: Int64
    public var localBytes: Int64
    public var needBytes: Int64
    public var needItems: Int64
    /// Bytes downloaded in the current pull, if any (`FolderSummary`/`DownloadProgress`).
    public var inProgressBytes: Int64
    /// Remote devices' completion of *our* changes, 0...100 (upload side).
    public var remoteCompletion: [DeviceID: Double]

    public init(
        globalBytes: Int64 = 0,
        localBytes: Int64 = 0,
        needBytes: Int64 = 0,
        needItems: Int64 = 0,
        inProgressBytes: Int64 = 0,
        remoteCompletion: [DeviceID: Double] = [:]
    ) {
        self.globalBytes = globalBytes
        self.localBytes = localBytes
        self.needBytes = needBytes
        self.needItems = needItems
        self.inProgressBytes = inProgressBytes
        self.remoteCompletion = remoteCompletion
    }

    /// 0...1 for the local download side.
    public var fractionCompleted: Double {
        guard globalBytes > 0 else { return 1 }
        return min(1, max(0, Double(globalBytes - needBytes) / Double(globalBytes)))
    }
}

/// A user-presentable error attached to a folder or the engine.
public struct SyncIssue: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case folderPathMissing
        case permissionDenied
        case outOfSpace
        case fileError      // per-file pull/scan error (upstream FolderErrors)
        case conflict       // a .sync-conflict file appeared
        case engineFailure
        case other
    }

    public var id: String
    public var kind: Kind
    public var folderID: FolderID?
    public var path: RelativePath?
    /// Upstream message, kept for the "Details" disclosure only.
    public var technicalDetail: String
    public var occurredAt: Date

    public init(id: String, kind: Kind, folderID: FolderID?, path: RelativePath?, technicalDetail: String, occurredAt: Date) {
        self.id = id
        self.kind = kind
        self.folderID = folderID
        self.path = path
        self.technicalDetail = technicalDetail
        self.occurredAt = occurredAt
    }
}

public struct FolderStatus: Hashable, Codable, Sendable {
    public var folderID: FolderID
    public var state: FolderSyncState
    public var progress: SyncProgress
    public var issues: [SyncIssue]
    public var lastScan: Date?
    public var lastSyncedFile: RelativePath?

    public init(
        folderID: FolderID,
        state: FolderSyncState,
        progress: SyncProgress = .init(),
        issues: [SyncIssue] = [],
        lastScan: Date? = nil,
        lastSyncedFile: RelativePath? = nil
    ) {
        self.folderID = folderID
        self.state = state
        self.progress = progress
        self.issues = issues
        self.lastScan = lastScan
        self.lastSyncedFile = lastSyncedFile
    }
}
