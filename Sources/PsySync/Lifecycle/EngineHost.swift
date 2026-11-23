import Foundation

/// App lifecycle inputs the host reacts to. The App target translates
/// UIKit/SwiftUI/BGTaskScheduler callbacks into these.
public enum LifecycleSignal: Hashable, Sendable {
    case didBecomeActive
    /// scenePhase → .background. Host calls `beginBackgroundTask`, stops the
    /// engine gracefully, ends the task. Must not leave the engine lock held.
    case didEnterBackground
    /// BG task launched. `deadline` is the host's own cap (system may expire sooner).
    case backgroundTaskStarted(kind: BackgroundTaskKind, deadline: Duration)
    /// System expiration handler fired.
    case backgroundTaskExpiring
    case memoryWarning
    case willTerminate
}

public enum BackgroundTaskKind: String, Codable, Sendable {
    /// BGAppRefreshTask (~30 s): connect, exchange indexes, small pulls.
    case appRefresh
    /// BGProcessingTask (minutes, usually on charger + network).
    case processing
    /// BGContinuedProcessingTask (iOS 26+): user-initiated long transfer with
    /// system progress UI; continues after the app is backgrounded.
    case continuedProcessing
}

/// Phases of the single engine owned by the App process.
public enum HostPhase: Hashable, Sendable {
    case idle
    case foregroundRunning
    case backgroundRunning(kind: BackgroundTaskKind)
    /// Stopping under a beginBackgroundTask assertion.
    case draining
}

/// Owns the one `SyncEngine` in the App and drives it from lifecycle +
/// policy. Foreground and BG tasks reuse the same engine object; only the
/// memory profile and stop deadline differ.
@MainActor
public protocol EngineHosting: AnyObject {
    var engine: any SyncEngine { get }
    var phase: HostPhase { get }
    func handle(_ signal: LifecycleSignal) async
    /// Re-evaluate policy (called by the NWPathMonitor/power observers).
    func policyInputsChanged(_ inputs: PolicyInputs) async
}

/// BG task completion criteria (when the host may stop early in background).
public struct BackgroundCompletionCriteria: Hashable, Sendable {
    /// Stop when every folder is upToDate or waitingForDevices for this long.
    public var idleGrace: Duration
    /// Hard cap independent of system budget.
    public var maximumRuntime: Duration

    public init(idleGrace: Duration, maximumRuntime: Duration) {
        self.idleGrace = idleGrace
        self.maximumRuntime = maximumRuntime
    }

    public static let appRefresh = BackgroundCompletionCriteria(idleGrace: .seconds(5), maximumRuntime: .seconds(25))
    public static let processing = BackgroundCompletionCriteria(idleGrace: .seconds(30), maximumRuntime: .seconds(15 * 60))
}

/// Stop deadline used under `beginBackgroundTask` (system gives ~30 s; keep margin).
public enum LifecycleBudget {
    public static let backgroundStopDeadline: Duration = .seconds(10)
    public static let foregroundStartTimeout: Duration = .seconds(20)
}

/// Decides when "Keep syncing in background automatically" submits the
/// BGContinuedProcessingTask request: once per sync burst (transfers
/// becoming active), only in the foreground (the system requires the request
/// to come from the foreground), never while one is already running, and at
/// most once per `minimumInterval` so a burst that flaps between files does
/// not spam requests.
public struct AutoContinueGate: Hashable, Sendable {
    public var minimumInterval: Duration = .seconds(60)
    private var burstHandled = false
    private var lastRequest: ContinuousClock.Instant?

    public init() {}

    public mutating func shouldRequest(enabled: Bool, appActive: Bool, canContinue: Bool, transfersActive: Bool,
                                       alreadyContinuing: Bool, now: ContinuousClock.Instant) -> Bool {
        guard transfersActive else {
            burstHandled = false   // burst over: the next one may request again
            return false
        }
        guard enabled, appActive, canContinue, !alreadyContinuing, !burstHandled else { return false }
        if let lastRequest, now - lastRequest < minimumInterval { return false }
        burstHandled = true
        lastRequest = now
        return true
    }
}

/// Exponential backoff for restarting an engine that died or failed to start
/// while the app is in the foreground: 1, 2, 4 … 60 s. A run that lasted at
/// least `stableAfter` resets the sequence.
public struct EngineRestartBackoff: Hashable, Sendable {
    public var base: Duration = .seconds(1)
    public var cap: Duration = .seconds(60)
    public var stableAfter: Duration = .seconds(60)
    private var attempts = 0
    private var lastStart: ContinuousClock.Instant?

    public init() {}

    /// The engine reached `.running` at `now`.
    public mutating func noteStarted(at now: ContinuousClock.Instant) { lastStart = now }

    /// Delay before the next restart after a failure observed at `now`.
    public mutating func nextDelay(now: ContinuousClock.Instant) -> Duration {
        if let lastStart, now - lastStart >= stableAfter { attempts = 0 }
        lastStart = nil
        let factor = 1 << min(attempts, 16)
        attempts += 1
        return min(base * factor, cap)
    }

    public var attemptCount: Int { attempts }
}
