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
    /// Global files + directories + symlinks (0 when unknown).
    public var globalItems: Int64
    /// Last upstream RemoteIndexUpdated for this folder: a peer is still
    /// sending its file list (index batches arrive back to back).
    public var lastRemoteIndexAt: Date?
    /// Per peer: is its index (file list) still arriving? From the bridge's
    /// protocol-level tracker (psybridge indexstate.go: upstream sends its
    /// backlog in full batches and the one that drains it is short). nil when
    /// unavailable; the timing heuristics then apply.
    public var indexPeers: [DeviceID: IndexPeer]?
    public struct IndexPeer: Hashable, Sendable {
        public enum Phase: String, Hashable, Sendable {
            case receiving, awaiting, complete, disconnected
        }
        public var phase: Phase
        /// The peer's index entries stored here (deletions included).
        public var entries: Int64
        public var deletions: Int64
        public init(phase: Phase, entries: Int64 = 0, deletions: Int64 = 0) {
            self.phase = phase
            self.entries = entries
            self.deletions = deletions
        }
        public var isArriving: Bool { phase == .receiving || phase == .awaiting }
    }
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
        globalItems: Int64 = 0,
        lastRemoteIndexAt: Date? = nil,
        indexPeers: [DeviceID: IndexPeer]? = nil,
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
        self.globalItems = globalItems
        self.lastRemoteIndexAt = lastRemoteIndexAt
        self.indexPeers = indexPeers
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
        let arriving = arrivingIndexPeers(i)
        let progress = SyncProgress(
            globalBytes: i.globalBytes,
            localBytes: i.localBytes,
            needBytes: i.needBytes,
            needItems: i.needItems,
            inProgressBytes: i.inProgressBytes,
            remoteCompletion: validRemotes.mapValues(\.completion),
            globalItems: i.globalItems,
            indexEntriesReceived: arriving.values.reduce(0) { $0 + $1.entries },
            indexDeletionsReceived: arriving.values.reduce(0) { $0 + $1.deletions },
            sizeIsPartial: !arriving.isEmpty
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

    /// Peers whose index is still arriving (and that share the folder).
    static func arrivingIndexPeers(_ i: FolderStatusInputs) -> [DeviceID: FolderStatusInputs.IndexPeer] {
        guard i.engineRunning, !i.folderPaused, let peers = i.indexPeers else { return [:] }
        return peers.filter { id, p in p.isArriving && i.remotes[id]?.remoteState != "notSharing" }
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
        // Index batches still arriving and nothing actually transferring:
        // upstream's needs are transient (the puller has not applied the
        // ignore rules to the new entries yet — an on-demand folder showed
        // "Syncing, 5,000 items left, 0 KB of 83 KB"); the honest state is
        // that the file list is still coming in.
        // Over a slow link batches arrive tens of seconds apart (simulator,
        // 60k entries at 30 KB/s: "Syncing, 7,127 items, 0 KB" between
        // batches), hence the longer window here.
        if i.indexPeers != nil {
            // The real signal: a peer's index is complete only once its
            // sender drained its backlog. Until then nothing is "up to date"
            // and no size is final; a transfer already running still shows.
            if !arrivingIndexPeers(i).isEmpty, i.inProgressBytes == 0, i.upstreamState != "scanning" {
                return .fetchingIndex
            }
        } else {
            let indexArriving = i.lastRemoteIndexAt.map { i.now.timeIntervalSince($0) < indexActiveInterval } ?? false
            if indexArriving, localNeeds, anyConnected, i.inProgressBytes == 0, i.upstreamState != "scanning" {
                return .fetchingIndex
            }
        }
        // Upstream works through the new list before pulling anything: an
        // on-demand folder spent minutes in sync-preparing over 38k entries
        // its rules ignore (count falling ~200/s, 0 bytes moving). That is
        // still the file list being processed, not a transfer.
        if i.upstreamState == "sync-preparing", i.inProgressBytes == 0 { return .fetchingIndex }
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
        // A connected peer shares the folder but its index is not in yet
        // (upstream remoteState "unknown" until the first index arrives), or
        // index batches are still arriving: the folder may look empty or
        // complete while most of it is unknown (seen on a re-added folder:
        // "Up to date, 0 KB" while 1059 files were still on their way).
        if i.indexPeers == nil {
            let awaitingIndex = i.remotes.values.contains { $0.connected && $0.remoteState == "unknown" }
            if awaitingIndex { return .fetchingIndex }
            if let at = i.lastRemoteIndexAt, i.now.timeIntervalSince(at) < indexSettleInterval, anyConnected {
                return .fetchingIndex
            }
        }
        if connectedRemoteBehind { return .syncing }
        if anyRemoteBehind && !anyConnected { return .waitingForDevices }
        // Never heard from anyone and nobody is connected: an empty folder is
        // unknown, not up to date.
        let knowsAnything = i.globalBytes > 0 || i.globalItems > 0 || i.remotes.values.contains { $0.remoteState == "valid" }
        if !i.remotes.isEmpty && !anyConnected && !knowsAnything { return .waitingForDevices }
        return .upToDate
    }

    /// How long after the last RemoteIndexUpdated a folder still counts as
    /// receiving its file list. LiveSyncEngine refreshes the status once this
    /// has passed.
    public static let indexSettleInterval: TimeInterval = 3
    /// While needs exist but nothing transfers, a folder that received index
    /// data this recently is still getting its file list (not "syncing").
    public static let indexActiveInterval: TimeInterval = 30

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
