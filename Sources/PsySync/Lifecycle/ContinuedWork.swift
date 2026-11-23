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
/// - The reported progress (`units` of `unitScale`) never goes back and moves
///   whenever anything changed (statuses, Files list): the system expires a
///   continued task whose progress looks stalled, and does so within seconds
///   of the app leaving the foreground (device: 3 of 44 tasks expired 3-17 s
///   after backgrounding while folders were busy but the bar had not moved).
/// - Work that shows no change at all for `stuckPeriod` while the app is in
///   the background ends the task (`stuck`) before the system expires it;
///   the regular background tasks pick the sync up later.
public struct ContinuedWorkTracker: Sendable {
    public enum Phase: String, Sendable {
        case fetchingIndex, preparingFiles, syncing, idle
    }

    /// Reported progress is `units` out of this.
    public static let unitScale: Int64 = 1_000_000

    public struct Step: Equatable, Sendable {
        public var phase: Phase
        /// Folder the title names (the first one doing the phase's work).
        public var folder: FolderID?
        public var otherFolders: Int
        /// Raw measure of the current phase (entries, rows or bytes).
        public var completed: Int64
        public var total: Int64
        /// What the task reports: monotonic, out of `unitScale`.
        public var units: Int64
        /// Quiet long enough, or stuck in the background: end the task.
        public var finished: Bool
        /// Ended with downloads outstanding (no device, on hold).
        public var stalled: Bool
        /// Ended because work showed no change for `stuckPeriod` in the background.
        public var stuck: Bool
    }

    public var quietPeriod: TimeInterval
    public var stuckPeriod: TimeInterval
    private var quietSince: Date?
    private var lastActivity: Date?
    private var lastSignature: Int?
    private var lastPhase: Phase?
    /// Reported fraction when the current phase began, and the phase's raw
    /// fraction then: each phase fills the part of the bar still left.
    private var phaseBase: Double = 0
    private var phaseStartRaw: Double = 0
    private var units: Int64 = 0

    public init(quietPeriod: TimeInterval = 10, stuckPeriod: TimeInterval = 20) {
        self.quietPeriod = quietPeriod
        self.stuckPeriod = stuckPeriod
    }

    /// - Parameters:
    ///   - appActivity: App-side work counter the statuses do not show
    ///     (Files list rows processed); any change counts as activity.
    ///   - inBackground: the app is not in the foreground (only then may
    ///     stuck work end the task: in the foreground the system waits).
    public mutating func step(_ statuses: [FolderStatus], appActivity: Int64 = 0, inBackground: Bool = false,
                              now: Date = Date()) -> Step {
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
        completed = min(completed, total)

        // Activity: anything in the statuses or the App's own work changed.
        var hasher = Hasher()
        hasher.combine(statuses)
        hasher.combine(appActivity)
        let signature = hasher.finalize()
        let active = lastSignature.map { $0 != signature } ?? true
        lastSignature = signature
        if active { lastActivity = now }

        let reported = report(phase: phase, raw: Double(completed) / Double(total), active: active)

        var finished = false
        var stuck = false
        if phase == .idle {
            let since = quietSince ?? now
            quietSince = since
            finished = now.timeIntervalSince(since) >= quietPeriod
        } else {
            quietSince = nil
            if inBackground, now.timeIntervalSince(lastActivity ?? now) >= stuckPeriod {
                finished = true
                stuck = true
            }
        }
        return Step(phase: phase, folder: current.first?.folderID, otherFolders: max(current.count - 1, 0),
                    completed: completed, total: total, units: reported, finished: finished,
                    stalled: finished && !stuck && need > 0, stuck: stuck)
    }

    /// Monotonic units: the phase's raw fraction maps onto the part of the
    /// bar not yet used; activity that did not move it nudges it by a small
    /// share of what is left (never reaching the end).
    private mutating func report(phase: Phase, raw: Double, active: Bool) -> Int64 {
        let scale = Self.unitScale
        if phase != lastPhase {
            phaseBase = Double(units) / Double(scale)
            phaseStartRaw = raw
            lastPhase = phase
        }
        // Idle (a gap between phases, or the end) does not fill the bar:
        // the next phase still needs the room.
        let span = max(1 - phaseStartRaw, 1e-9)
        let phaseFraction = phase == .idle ? 0 : min(max((raw - phaseStartRaw) / span, 0), 1)
        let target = phaseBase + (1 - phaseBase) * phaseFraction
        // Keep one unit back: the bar is full only when the task is done.
        var next = min(Int64(target * Double(scale)), scale - 1)
        if next <= units, active {
            next = min(units + max((scale - units) / 500, 1), scale - 1)
        }
        units = max(units, next)
        return units
    }
}

/// Why a continued-processing task ended, and whether that is a failure
/// the system should show ("couldn't finish") or a normal end.
public enum ContinuedEnd: String, Sendable, CaseIterable {
    /// Nothing left to do.
    case done
    /// Quiet with downloads outstanding (device offline, paused, on hold):
    /// nothing this task can do; the regular sync finishes them later.
    case stalled
    /// Work showed no change in the background for a while (peer not
    /// sending): ended before the system expires it.
    case stuck
    /// The system expired the task (stalled-looking progress, resources, or
    /// the user stopped it) while work was left.
    case expired
    /// The system expired the task, but nothing was left to do anyway.
    case expiredIdle = "expired-idle"
    /// The engine stayed unreachable past the retry window.
    case engineUnavailable = "engine-unavailable"

    /// `setTaskCompleted(success:)`: false only when transfers that could
    /// have run were cut short. "Failed" for a peer that is offline or a
    /// sync the regular background tasks finish later was a false alarm.
    public var success: Bool {
        switch self {
        case .done, .stalled, .stuck, .expiredIdle: return true
        case .expired, .engineUnavailable: return false
        }
    }

    public static func expired(lastPhase: ContinuedWorkTracker.Phase?, needBytes: Int64) -> ContinuedEnd {
        (lastPhase ?? .idle) == .idle && needBytes <= 0 ? .expiredIdle : .expired
    }
}

/// Tolerates engine status failures for a while: a snapshot fails when a
/// folder is removed between listing folders and reading its status, and
/// while the engine restarts (device: two tasks ended as
/// "engine-unavailable" on one such failure, in the foreground).
public struct SnapshotFailureWindow: Sendable {
    public var window: TimeInterval
    private var failingSince: Date?

    public init(window: TimeInterval = 20) {
        self.window = window
    }

    public mutating func succeeded() { failingSince = nil }

    /// Records a failure; true when failures have lasted past `window`.
    public mutating func failed(now: Date = Date()) -> Bool {
        let since = failingSince ?? now
        failingSince = since
        return now.timeIntervalSince(since) >= window
    }

    public var isFailing: Bool { failingSince != nil }
}
