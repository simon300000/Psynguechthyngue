import Foundation

/// What a "keep syncing in background" task (BGContinuedProcessingTask)
/// reports and when it ends, from the folders' composed statuses.
///
/// - Work = the file list arriving (fetchingIndex), the Files list being
///   built (preparingFiles), scanning or syncing. A folder accepted a moment
///   ago goes through all of them; the task keeps going until none is left.
/// - Ends only after `quietPeriod` without work: between phases (index done,
///   projection not started yet; folder just added, no status yet) the
///   folders look idle for a moment. A user who accepts a share and closes the
///   app at once lost the task that way.
/// - Progress moves in every phase: during the index the bytes are all 0, so
///   it counts index entries received. The peer announces no total (upstream
///   keeps no copy of it), so the total stays ahead of what was received and
///   the bar never claims "almost done" while the list is still coming.
public struct ContinuedWorkTracker: Sendable {
    public enum Phase: String, Sendable {
        case fetchingIndex, preparingFiles, syncing, idle
    }

    public struct Step: Equatable, Sendable {
        public var phase: Phase
        /// Folder the title names (the first one doing the phase's work).
        public var folder: FolderID?
        public var otherFolders: Int
        public var completed: Int64
        public var total: Int64
        /// Quiet long enough: end the task.
        public var finished: Bool
        /// Ended with downloads outstanding (no device, on hold).
        public var stalled: Bool
    }

    public var quietPeriod: TimeInterval
    private var quietSince: Date?

    public init(quietPeriod: TimeInterval = 10) {
        self.quietPeriod = quietPeriod
    }

    public mutating func step(_ statuses: [FolderStatus], now: Date = Date()) -> Step {
        let fetching = statuses.filter { $0.state == .fetchingIndex }
        let preparing = statuses.filter { $0.state == .preparingFiles }
        let syncing = statuses.filter { $0.state == .syncing || $0.state == .scanning }
        let need = statuses.reduce(Int64(0)) { $0 + max($1.progress.needBytes, 0) }

        let phase: Phase
        let current: [FolderStatus]
        var completed: Int64
        var total: Int64
        if !fetching.isEmpty {
            phase = .fetchingIndex
            current = fetching
            completed = fetching.reduce(Int64(0)) {
                $0 + max($1.progress.indexEntriesReceived, $1.progress.globalItems)
            }
            // Always 20,000 ahead: moves with every batch, approaches but
            // never reaches the end while the list is still arriving.
            total = completed + 20_000
        } else if !preparing.isEmpty {
            phase = .preparingFiles
            current = preparing
            total = max(preparing.reduce(Int64(0)) { $0 + $1.progress.globalItems }, 1)
            completed = total * 9 / 10
        } else if !syncing.isEmpty {
            phase = .syncing
            current = syncing
            total = max(statuses.reduce(Int64(0)) { $0 + max($1.progress.globalBytes, 0) }, 1)
            completed = max(total - need, 0)
        } else {
            phase = .idle
            current = []
            total = max(statuses.reduce(Int64(0)) { $0 + max($1.progress.globalBytes, 0) }, 1)
            completed = max(total - need, 0)
        }

        var finished = false
        if phase == .idle {
            let since = quietSince ?? now
            quietSince = since
            finished = now.timeIntervalSince(since) >= quietPeriod
        } else {
            quietSince = nil
        }
        return Step(phase: phase, folder: current.first?.folderID, otherFolders: max(current.count - 1, 0),
                    completed: min(completed, total), total: total, finished: finished,
                    stalled: finished && need > 0)
    }
}
