import Foundation
import Observation
import PsySync

/// Owns the one `SyncEngine` of the App process and drives it from lifecycle
/// signals and policy.
///
///   idle ─didBecomeActive→ foregroundRunning ─didEnterBackground→ draining → idle
///   idle ─backgroundTaskStarted→ backgroundRunning ─done/expired→ draining → idle
///
/// Signals are processed strictly in order (a return to foreground while
/// draining waits for the drain to finish and then restarts the engine).
/// On Mac (Designed for iPad) the process is not suspended, so backgrounding
/// never stops the engine.
@MainActor
@Observable
final class LiveEngineHost: EngineHosting {
    let engine: any SyncEngine
    private(set) var phase: HostPhase = .idle
    /// Last policy decision pushed to the engine (UI shows the hold reason).
    private(set) var decision: PolicyDecision = .run
    /// Set when the engine failed to start/stop; the UI surfaces it.
    private(set) var lastFailure: String?
    /// A user-initiated BGContinuedProcessingTask is running: the
    /// engine keeps going when the app is backgrounded.
    private(set) var continuedProcessing = false
    var preferences = PolicyPreferences() {
        didSet { if preferences != oldValue { Task { await self.enqueue { await self.applyPolicy(force: false) } } } }
    }

    @ObservationIgnored private let policy: any SyncPolicy
    @ObservationIgnored private let tasks: any BackgroundTaskRunning
    @ObservationIgnored private let isOnMac: Bool
    @ObservationIgnored private let log = LifecycleLog.shared
    @ObservationIgnored private var inputs = PolicyInputs(network: .wifiOrWired)
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var backgroundExpired = false
    /// True from the moment `start` is called until a `stop` succeeds. The
    /// engine (and its lock) may be live even when `phase == .idle`, e.g. after
    /// a start timeout or a failed stop, so draining keys off this flag.
    @ObservationIgnored private var engineMaybeLive = false
    /// beginBackgroundTask token taken synchronously in the didEnterBackground
    /// callback, before any queued work (see `prepareForBackground`).
    @ObservationIgnored private var pendingBackgroundToken: Int?
    /// Tracks foreground state independently of `phase` (signals are queued).
    @ObservationIgnored private var appActive = false
    @ObservationIgnored var onFailure: (@MainActor (Error) -> Void)?
    /// After every successful start (foreground or BG): Files projector + request server.
    @ObservationIgnored var onEngineStarted: (@MainActor () async -> Void)?
    /// Before every stop: close files.sqlite etc. so nothing is held when suspended (I2).
    @ObservationIgnored var onEngineWillStop: (@MainActor () async -> Void)?
    /// `didReceiveMemoryWarning` → `psybridge.Engine.OnMemoryWarning`.
    @ObservationIgnored var onMemoryWarning: (@MainActor () -> Void)?
    /// Watches engine state so a dead engine is restarted in the foreground.
    @ObservationIgnored private var failureWatch: Task<Void, Never>?
    @ObservationIgnored private var restartBackoff = EngineRestartBackoff()
    @ObservationIgnored private var restartScheduled = false

    init(
        engine: any SyncEngine,
        policy: any SyncPolicy = DefaultSyncPolicy(),
        tasks: any BackgroundTaskRunning,
        isOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac
    ) {
        self.engine = engine
        self.policy = policy
        self.tasks = tasks
        self.isOnMac = isOnMac
    }

    // MARK: EngineHosting

    func handle(_ signal: LifecycleSignal) async {
        switch signal {
        case .backgroundTaskExpiring:
            // Out of band: must not queue behind the running task.
            log.record("bg-expiring")
            backgroundExpired = true
            // Start the stop now, under its own background-time assertion:
            // waiting for runBackgroundTask's poll loop (a snapshot can take
            // 2 s) plus the stop could overrun the expiration grace period.
            Task { @MainActor in
                await self.enqueue {
                    guard self.isBackgroundRunning, !self.continuedProcessing else { return }
                    await self.drain(reason: "bg-expired", requireTask: true)
                }
            }
            return
        case .didBecomeActive:
            appActive = true
        case .didEnterBackground:
            appActive = false
        default:
            break
        }
        await enqueue { await self.process(signal) }
    }

    func policyInputsChanged(_ inputs: PolicyInputs) async {
        await enqueue {
            self.inputs = inputs
            await self.applyPolicy(force: false)
        }
    }

    /// Serialises every engine-affecting operation (lifecycle + policy).
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        chain = task
        await task.value
    }

    /// Call synchronously from the didEnterBackground callback: takes the
    /// background-time assertion *before* queued work (a slow start) runs, so
    /// the drain is always covered (I2).
    func prepareForBackground() {
        guard !isOnMac, pendingBackgroundToken == nil else { return }
        let token = beginTask(reason: "didEnterBackground")
        pendingBackgroundToken = token
    }

    // MARK: Processing

    private func process(_ signal: LifecycleSignal) async {
        switch signal {
        case .didBecomeActive:
            await becomeActive()
        case .didEnterBackground:
            await enterBackground()
        case let .backgroundTaskStarted(kind, deadline):
            await startBackgroundTask(kind: kind, deadline: deadline)
        case .backgroundTaskExpiring:
            break
        case .memoryWarning:
            log.record("memory-warning")
            onMemoryWarning?()
        case .willTerminate:
            if phase == .foregroundRunning || isBackgroundRunning { await drain(reason: "willTerminate", requireTask: true) }
        }
    }

    /// The app is in the foreground (signals are queued; `phase` lags).
    var isAppActive: Bool { appActive }

    private var isBackgroundRunning: Bool {
        if case .backgroundRunning = phase { return true }
        return false
    }

    private func becomeActive() async {
        if let token = pendingBackgroundToken {
            // Back in the foreground before the drain ran: nothing to cover.
            pendingBackgroundToken = nil
            endTask(token)
        }
        watchEngineFailures()
        switch phase {
        case .foregroundRunning:
            // Normally nothing to do, but the engine may have died meanwhile.
            guard case .failed = await engine.state else { return }
            log.record("engine-restart", "failed engine found on didBecomeActive")
            await onEngineWillStop?()
            await stopQuietly()
            phase = .idle
        case .backgroundRunning:
            // BG task still owns the engine; promote it to the foreground run.
            log.record("foreground-promote")
            phase = .foregroundRunning
            backgroundExpired = false
            return
        case .draining, .idle:
            break
        }
        log.record("engine-start", "context=foreground")
        engineMaybeLive = true
        do {
            try await withTimeout(LifecycleBudget.foregroundStartTimeout) {
                try await self.engine.start(context: .foreground)
            }
            phase = .foregroundRunning
            lastFailure = nil
            restartBackoff.noteStarted(at: .now)
            await applyPolicy(force: true)
            log.record("engine-running")
            await onEngineStarted?()
        } catch {
            phase = .idle
            fail("start", error)
            // A timed-out start may still complete later: make sure it is stopped.
            await stopQuietly()
            if appActive { scheduleRestart(reason: "start-failed") }
        }
    }

    // MARK: Restart after failure (foreground)

    /// Subscribes once to engine events: a `.failed` state while running in
    /// the foreground (bridge exit, REST unreachable) schedules stop + start
    /// with exponential backoff.
    private func watchEngineFailures() {
        guard failureWatch == nil else { return }
        let stream = engine.events()
        failureWatch = Task { [weak self] in
            for await event in stream {
                guard case .engineStateChanged(.failed(let code, _)) = event else { continue }
                guard let self else { return }
                if self.phase == .foregroundRunning && self.appActive {
                    self.scheduleRestart(reason: "engine-failed code=\(code)")
                }
            }
        }
    }

    private func scheduleRestart(reason: String) {
        guard !restartScheduled else { return }
        restartScheduled = true
        let delay = restartBackoff.nextDelay(now: .now)
        log.record("engine-restart-scheduled", "\(reason) in \(delay) attempt=\(restartBackoff.attemptCount)")
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            await self.enqueue {
                self.restartScheduled = false
                guard self.appActive, self.phase == .foregroundRunning || self.phase == .idle else { return }
                if self.phase == .foregroundRunning {
                    guard case .failed = await self.engine.state else { return }   // recovered meanwhile
                    await self.onEngineWillStop?()
                    await self.stopQuietly()
                    self.phase = .idle
                }
                await self.becomeActive()
            }
        }
    }

    private func enterBackground() async {
        defer {
            if let token = pendingBackgroundToken { pendingBackgroundToken = nil; endTask(token) }
        }
        if isOnMac {
            log.record("background-ignored", "isiOSAppOnMac: engine keeps running")
            return
        }
        if isBackgroundRunning { return }   // the BG task owns the engine
        if continuedProcessing, phase == .foregroundRunning {
            // User-initiated continued processing: keep syncing under the system progress UI.
            phase = .backgroundRunning(kind: .continuedProcessing)
            log.record("background-continued", "engine keeps running for BGContinuedProcessingTask")
            return
        }
        guard phase == .foregroundRunning || engineMaybeLive else { return }
        await drain(reason: "didEnterBackground", requireTask: true)
    }

    private func startBackgroundTask(kind: BackgroundTaskKind, deadline: Duration) async {
        guard phase == .idle else {
            log.record("bg-skip", "phase=\(phase)")
            return
        }
        log.record("bg-start", "kind=\(kind.rawValue) deadline=\(deadline)")
        engineMaybeLive = true
        do {
            try await withTimeout(LifecycleBudget.foregroundStartTimeout) {
                try await self.engine.start(context: .background)
            }
            phase = .backgroundRunning(kind: kind)
            await applyPolicy(force: true)
            await onEngineStarted?()
            if backgroundExpired { log.record("bg-expired-during-start") }
        } catch {
            phase = .idle
            fail("bg-start", error)
            await stopQuietly()
        }
    }

    /// Runs a BGTask to completion: start → wait for idle grace /
    /// max runtime / expiry → stop. Returns true if the engine reached a
    /// settled state (all folders upToDate/waitingForDevices) before stopping.
    func runBackgroundTask(kind: BackgroundTaskKind) async -> Bool {
        let criteria: BackgroundCompletionCriteria = kind == .processing ? .processing : .appRefresh
        backgroundExpired = false   // reset here, never after start (an expiry may arrive while queued)
        await handle(.backgroundTaskStarted(kind: kind, deadline: criteria.maximumRuntime))
        guard isBackgroundRunning else { return false }
        let clock = ContinuousClock()
        let started = clock.now
        var settledSince: ContinuousClock.Instant?
        var settled = false
        while isBackgroundRunning {
            if backgroundExpired { break }
            if clock.now - started >= criteria.maximumRuntime { break }
            if let status = try? await withTimeoutValue(.seconds(2), { try await self.engine.snapshot() }) {
                let quiet = !status.folders.isEmpty
                    && status.folders.allSatisfy { $0.state == .upToDate || $0.state == .waitingForDevices }
                if quiet {
                    settledSince = settledSince ?? clock.now
                    if clock.now - settledSince! >= criteria.idleGrace { settled = true; break }
                } else {
                    settledSince = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let reason = backgroundExpired ? "expired" : (settled ? "settled" : "max-runtime")
        await enqueue {
            if self.isBackgroundRunning {
                // requireTask: the BG task's own time may be nearly gone
                // (expiry); an assertion covers the stop (0xdead10cc).
                await self.drain(reason: "bg-\(reason)", requireTask: true)
            }
        }
        return settled
    }

    // MARK: Drain (stop under beginBackgroundTask)

    /// `deadline` nil: from the background time left once the assertion is
    /// held (`LifecycleBudget.stopDeadline`).
    private func drain(reason: String, requireTask: Bool, deadline: Duration? = nil) async {
        let clock = ContinuousClock()
        let t0 = clock.now
        phase = .draining
        var token: Int?
        if requireTask {
            if let pending = pendingBackgroundToken {
                token = pending
                pendingBackgroundToken = nil
                log.record("beginBackgroundTask", "reason=\(reason) token=\(pending) (taken in callback)")
            } else {
                token = beginTask(reason: reason)
            }
        }
        await onEngineWillStop?()
        let deadline = deadline ?? LifecycleBudget.stopDeadline(remaining: tasks.remaining)
        log.record("engine-stop", "deadline=\(deadline) remaining=\(Int(min(tasks.remaining, 9999)))s")
        do {
            try await engine.stop(deadline: deadline)
            engineMaybeLive = false
            log.record("lock-released", "engine stopped remaining=\(Int(min(tasks.remaining, 9999)))s")
        } catch {
            // A stop_timeout no longer poisons the engine: it is
            // simply started again on the next didBecomeActive. engineMaybeLive
            // stays true so the next background transition retries the stop.
            fail("stop", error)
        }
        phase = .idle
        let elapsed = clock.now - t0
        log.record("drain-complete", "reason=\(reason) elapsed=\(elapsed)")
        if let token { endTask(token) }
    }

    // MARK: Background-time assertions

    @ObservationIgnored private var liveTokens = Set<Int>()

    private func beginTask(reason: String) -> Int {
        let box = TokenRef()
        let token = tasks.begin(name: "psy.engine.stop") { [weak self] in
            // Out of time: end the assertion now so the watchdog does not kill us.
            self?.log.record("bgtask-expired", "system expiration handler fired")
            self?.endTask(box.value)
        }
        box.value = token
        liveTokens.insert(token)
        log.record("beginBackgroundTask", "reason=\(reason) token=\(token) remaining=\(Int(min(tasks.remaining, 9999)))s")
        return token
    }

    /// Idempotent per token.
    private func endTask(_ token: Int) {
        guard liveTokens.remove(token) != nil else { return }
        // Log first: ending the last assertion may suspend the process immediately.
        log.record("endBackgroundTask", "token=\(token)")
        tasks.end(token)
    }

    private func stopQuietly() async {
        do {
            try await engine.stop(deadline: LifecycleBudget.backgroundStopDeadline)
            engineMaybeLive = false
        } catch {
            log.record("stop-after-failure", "\(error)")
        }
    }

    // MARK: Policy

    private func applyPolicy(force: Bool) async {
        let next = policy.decide(inputs: inputs, preferences: preferences)
        let changed = next != decision
        decision = next
        guard phase == .foregroundRunning || isBackgroundRunning else { return }
        guard changed || force else { return }
        do {
            try await engine.apply(next)
            log.record("policy-applied", "hold=\(next.hold?.rawValue ?? "none") send=\(next.sendLimitKiBps) recv=\(next.receiveLimitKiBps) reduced=\(next.reducedResourceUsage)")
        } catch {
            fail("policy", error)
        }
    }

    private func fail(_ operation: String, _ error: Error) {
        var message = "\(operation): \(error)"
        if case EngineError.lockUnavailable = error, let holder = (engine as? any EngineLockDiagnosing)?.lockHolderDescription {
            // Who holds the engine lock (device: repeated lockUnavailable
            // after a clean stop, holder unknown).
            message += " holder=\(holder)"
        }
        log.record("failure", message)
        lastFailure = message
        onFailure?(error)
    }

    // MARK: Continued processing (user initiated)

    /// Called when the system starts the user's BGContinuedProcessingTask.
    func beginContinuedProcessing() {
        continuedProcessing = true
        log.record("continued-begin", "phase=\(phase)")
    }

    /// Task finished or expired: if the app is in the background, drain now.
    func endContinuedProcessing(reason: String) async {
        continuedProcessing = false
        log.record("continued-end", "reason=\(reason) appActive=\(appActive)")
        await enqueue {
            guard !self.appActive, case .backgroundRunning(.continuedProcessing) = self.phase else { return }
            await self.drain(reason: "continued-\(reason)", requireTask: true)
        }
    }

    private func withTimeout(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withTimeoutValue(timeout, body)
    }

    /// Returns when `body` finishes or `timeout` elapses, whichever is first.
    /// Unlike a task group it does not wait for a body that ignores cancellation
    /// (the body keeps running detached; callers compensate via `engineMaybeLive`).
    private func withTimeoutValue<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = ResumeGate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.set(continuation)
            let work = Task { do { gate.resume(.success(try await body())) } catch { gate.resume(.failure(error)) } }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(.failure(EngineError.bridge(code: BridgeContract.Code.deadline.rawValue, detail: "timed out after \(timeout)")))
                work.cancel()
            }
        }
    }
}

/// Resumes a continuation exactly once.
private final class ResumeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) { lock.lock(); continuation = c; lock.unlock() }

    func resume(_ result: Result<T, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }
}

/// Lets an expiration handler refer to the token returned by the call that installs it.
@MainActor
private final class TokenRef {
    var value = -1
}
