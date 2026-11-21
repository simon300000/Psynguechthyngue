import Foundation

/// Everything `StatusMapper` needs to derive a user-facing folder state.
/// Collected from `/rest/db/status`, `/rest/db/completion?device=`,
/// `/rest/folder/errors`, `/rest/system/connections` and folder config.
public struct FolderStatusInputs: Hashable, Sendable {
    public struct RemoteCompletion: Hashable, Sendable {
        public var completion: Double
        /// Upstream `remoteState`: "valid" means the peer shares the folder and
        /// we have its index; "unknown"/"notSharing"/"paused" are ignored.
        public var remoteState: String
        public var connected: Bool

        public init(completion: Double, remoteState: String, connected: Bool) {
            self.completion = completion
            self.remoteState = remoteState
            self.connected = connected
        }
    }

    public var folderID: FolderID
    public var engineRunning: Bool
    public var folderPaused: Bool
    public var policyHeld: Bool
    /// Upstream folder state: idle, scanning, scan-waiting, syncing,
    /// sync-preparing, sync-waiting, cleaning, clean-waiting, starting, error.
    public var upstreamState: String
    public var upstreamError: String
    public var globalBytes: Int64
    public var localBytes: Int64
    public var needBytes: Int64
    public var needItems: Int64
    public var inProgressBytes: Int64
    /// Shared devices (excluding self), keyed by device.
    public var remotes: [DeviceID: RemoteCompletion]
    public struct FileError: Hashable, Sendable {
        public var path: String
        public var error: String
        public init(path: String, error: String) { self.path = path; self.error = error }
    }

    public var folderErrors: [FileError]
    /// Upstream conflict copies (`*.sync-conflict-*`) present in the global index.
    public struct Conflict: Hashable, Sendable {
        public var path: String
        public var modified: Date
        public init(path: String, modified: Date) { self.path = path; self.modified = modified }
    }

    public var conflicts: [Conflict]
    public var stateChanged: Date?
    public var now: Date

    public init(
        folderID: FolderID,
        engineRunning: Bool = true,
        folderPaused: Bool = false,
        policyHeld: Bool = false,
        upstreamState: String = "idle",
        upstreamError: String = "",
        globalBytes: Int64 = 0,
        localBytes: Int64 = 0,
        needBytes: Int64 = 0,
        needItems: Int64 = 0,
        inProgressBytes: Int64 = 0,
        remotes: [DeviceID: RemoteCompletion] = [:],
        folderErrors: [FileError] = [],
        conflicts: [Conflict] = [],
        stateChanged: Date? = nil,
        now: Date = Date()
    ) {
        self.folderID = folderID
        self.engineRunning = engineRunning
        self.folderPaused = folderPaused
        self.policyHeld = policyHeld
        self.upstreamState = upstreamState
        self.upstreamError = upstreamError
        self.globalBytes = globalBytes
        self.localBytes = localBytes
        self.needBytes = needBytes
        self.needItems = needItems
        self.inProgressBytes = inProgressBytes
        self.remotes = remotes
        self.folderErrors = folderErrors
        self.conflicts = conflicts
        self.stateChanged = stateChanged
        self.now = now
    }
}

/// Pure mapping from upstream folder state to `FolderStatus` (DESIGN.md §5.2).
///
/// Key property (fixes AUDIT P0): an offline device never makes a folder look
/// failed or stuck. If work is outstanding and *no* sharing peer is connected
/// the state is `waitingForDevices`; as soon as one peer is connected and up
/// to date, offline peers are ignored.
public enum StatusMapper {
    public static func map(_ i: FolderStatusInputs) -> FolderStatus {
        let validRemotes = relevantRemotes(i)
        let progress = SyncProgress(
            globalBytes: i.globalBytes,
            localBytes: i.localBytes,
            needBytes: i.needBytes,
            needItems: i.needItems,
            inProgressBytes: i.inProgressBytes,
            remoteCompletion: validRemotes.mapValues(\.completion)
        )
        let fileErrors = i.folderErrors.filter { !isTransientDisconnectError($0.error) }
        let state = state(i, validRemotes: validRemotes, fileErrors: fileErrors)
        // While waiting for devices every pull error is a symptom of the
        // missing peer, not a problem the user can act on.
        let issues = makeIssues(i, fileErrors: state == .waitingForDevices ? [] : fileErrors)
        return FolderStatus(
            folderID: i.folderID,
            state: state,
            progress: progress,
            issues: issues,
            lastScan: nil,
            lastSyncedFile: nil
        )
    }

    /// Peers whose completion we trust: connected peers that have sent a
    /// valid index for this folder, plus *disconnected* peers (upstream then
    /// reports "unknown"/"paused" but the last known completion still says
    /// what they are missing). Connected peers that do not share the folder
    /// back ("notSharing" / not yet "valid") are ignored.
    static func relevantRemotes(_ i: FolderStatusInputs) -> [DeviceID: FolderStatusInputs.RemoteCompletion] {
        i.remotes.filter { _, r in
            r.remoteState == "valid" || (!r.connected && r.remoteState != "notSharing")
        }
    }

    static func state(_ i: FolderStatusInputs, validRemotes: [DeviceID: FolderStatusInputs.RemoteCompletion],
                      fileErrors: [FolderStatusInputs.FileError]) -> FolderSyncState {
        guard i.engineRunning else { return .offline }
        if i.folderPaused || i.upstreamState == "paused" { return .paused }
        if i.policyHeld { return .heldByPolicy }

        let anyConnected = i.remotes.values.contains { $0.connected }
        let localNeeds = i.needBytes > 0 || i.needItems > 0
        let connectedRemoteBehind = validRemotes.values.contains { $0.connected && $0.completion < 100 }
        let anyRemoteBehind = validRemotes.values.contains { $0.completion < 100 }

        if i.upstreamState == "error" { return .error }
        // Pull errors that block every remaining item while a peer is online:
        // the folder cannot make progress on its own.
        if localNeeds, anyConnected, !fileErrors.isEmpty,
           Int64(fileErrors.count) >= i.needItems, isIdleLike(i.upstreamState) {
            return .error
        }
        switch i.upstreamState {
        case "scanning", "scan-waiting":
            return .scanning
        case "syncing", "sync-preparing":
            return .syncing
        default:
            break
        }
        if localNeeds {
            return anyConnected ? .syncing : .waitingForDevices
        }
        if connectedRemoteBehind { return .syncing }
        if anyRemoteBehind && !anyConnected { return .waitingForDevices }
        return .upToDate
    }

    private static func isIdleLike(_ s: String) -> Bool {
        ["idle", "sync-waiting", "clean-waiting", "cleaning", ""].contains(s)
    }

    /// Pull errors caused by a peer disconnecting mid-transfer (upstream
    /// lib/model folder_sendrecv.go, lib/protocol, net). Upstream retries them
    /// on its own once a peer is back, so they are not user-facing problems.
    static func isTransientDisconnectError(_ message: String) -> Bool {
        let m = message.lowercased()
        let markers = [
            "peers who had this file went away",
            "no connected device has the required version",
            "no device has the required version",
            "connection closed", "closed connection", "use of closed network connection",
            "connection reset", "broken pipe", "unexpected eof", "i/o timeout",
            "context canceled", "context deadline exceeded", "request timed out", "timeout waiting for",
            "device is not connected",
        ]
        if markers.contains(where: m.contains) { return true }
        return m == "eof" || m.hasSuffix(": eof")
    }

    static func makeIssues(_ i: FolderStatusInputs, fileErrors: [FolderStatusInputs.FileError]) -> [SyncIssue] {
        var issues: [SyncIssue] = []
        if !i.upstreamError.isEmpty {
            issues.append(SyncIssue(
                id: "\(i.folderID.rawValue):folder",
                kind: classify(i.upstreamError),
                folderID: i.folderID,
                path: nil,
                technicalDetail: i.upstreamError,
                occurredAt: i.stateChanged ?? i.now
            ))
        }
        for e in fileErrors {
            issues.append(SyncIssue(
                id: "\(i.folderID.rawValue):file:\(e.path)",
                kind: classifyFile(e.error),
                folderID: i.folderID,
                path: RelativePath(rawValue: e.path),
                technicalDetail: e.error,
                occurredAt: i.now
            ))
        }
        for c in i.conflicts {
            issues.append(SyncIssue(
                id: "\(i.folderID.rawValue):conflict:\(c.path)",
                kind: .conflict,
                folderID: i.folderID,
                path: RelativePath(rawValue: c.path),
                technicalDetail: c.path,
                occurredAt: c.modified
            ))
        }
        return issues
    }

    /// Upstream names conflict copies `<name>.sync-conflict-<date>-<time>-<device><.ext>`
    /// (lib/model/folder_sendrecv.go `conflictName`).
    public static func isConflictCopy(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.contains(".sync-conflict-")
    }

    /// Upstream folder-level error strings (lib/model/folder.go, lib/config).
    static func classify(_ message: String) -> SyncIssue.Kind {
        let m = message.lowercased()
        if m.contains("folder path missing") || m.contains("folder marker missing") || m.contains("no such file") {
            return .folderPathMissing
        }
        if m.contains("permission denied") || m.contains("operation not permitted") { return .permissionDenied }
        if m.contains("insufficient space") || m.contains("no space left") || m.contains("disk full") { return .outOfSpace }
        return .other
    }

    static func classifyFile(_ message: String) -> SyncIssue.Kind {
        switch classify(message) {
        case .other, .folderPathMissing: return .fileError
        case let k: return k
        }
    }
}
