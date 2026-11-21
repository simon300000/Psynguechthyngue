import Foundation
import Observation
import PsySync

/// Optional engine capability: respond to `didReceiveMemoryWarning`
/// (`psybridge.Engine.OnMemoryWarning`). `LiveSyncEngine` may adopt it.
protocol MemoryWarningResponding: AnyObject {
    func handleMemoryWarning()
}

/// Owns the one `SyncEngine` of the App process and drives it from lifecycle
/// signals and policy (DESIGN.md §4.1–4.4).
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
    /// `Stop` timed out → the process must not try to start again (DESIGN §4.3).
    private(set) var restartRequired = false
    var preferences = PolicyPreferences() {
        didSet { if preferences != oldValue { Task { await self.reevaluatePolicy() } } }
    }

    @ObservationIgnored private let policy: any SyncPolicy
    @ObservationIgnored private let tasks: any BackgroundTaskRunning
    @ObservationIgnored private let isOnMac: Bool
    @ObservationIgnored private let log = LifecycleLog.shared
    @ObservationIgnored private var inputs = PolicyInputs(network: .wifiOrWired)
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var backgroundExpired = false
    @ObservationIgnored private var lastBackgroundDeadlineMarker: ContinuousClock.Instant?
    @ObservationIgnored var onFailure: (@MainActor (String) -> Void)?

    init(
        engine: any SyncEngine,
        policy: any SyncPolicy = AppSyncPolicy(),
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
            return
        default:
            break
        }
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await self.process(signal)
        }
        chain = task
        await task.value
    }

    func policyInputsChanged(_ inputs: PolicyInputs) async {
        self.inputs = inputs
        await reevaluatePolicy()
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
            (engine as? MemoryWarningResponding)?.handleMemoryWarning()
        case .willTerminate:
            if phase == .foregroundRunning || isBackgroundRunning { await drain(reason: "willTerminate", requireTask: true) }
        }
    }

    private var isBackgroundRunning: Bool {
        if case .backgroundRunning = phase { return true }
        return false
    }

    private func becomeActive() async {
        if restartRequired { return }
        switch phase {
        case .foregroundRunning:
            return
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
        do {
            try await withTimeout(LifecycleBudget.foregroundStartTimeout) {
                try await self.engine.start(context: .foreground)
            }
            phase = .foregroundRunning
            lastFailure = nil
            await applyPolicy(force: true)
            log.record("engine-running")
        } catch {
            phase = .idle
            fail("start: \(error)")
        }
    }

    private func enterBackground() async {
        guard phase == .foregroundRunning else { return }
        if isOnMac {
            log.record("background-ignored", "isiOSAppOnMac: engine keeps running")
            return
        }
        await drain(reason: "didEnterBackground", requireTask: true)
    }

    private func startBackgroundTask(kind: BackgroundTaskKind, deadline: Duration) async {
        guard phase == .idle, !restartRequired else {
            log.record("bg-skip", "phase=\(phase) restartRequired=\(restartRequired)")
            return
        }
        log.record("bg-start", "kind=\(kind.rawValue) deadline=\(deadline)")
        backgroundExpired = false
        do {
            try await engine.start(context: .background)
            phase = .backgroundRunning(kind: kind)
            await applyPolicy(force: true)
        } catch {
            phase = .idle
            fail("bg-start: \(error)")
        }
    }

    /// Runs a BGTask to completion (§4.2): start → wait for idle grace /
    /// max runtime / expiry → stop. Returns true if the engine reached a
    /// settled state (all folders upToDate/waitingForDevices) before stopping.
    func runBackgroundTask(kind: BackgroundTaskKind) async -> Bool {
        let criteria: BackgroundCompletionCriteria = kind == .processing ? .processing : .appRefresh
        await handle(.backgroundTaskStarted(kind: kind, deadline: criteria.maximumRuntime))
        guard isBackgroundRunning else { return false }
        let clock = ContinuousClock()
        let started = clock.now
        var settledSince: ContinuousClock.Instant?
        var settled = false
        while isBackgroundRunning {
            if backgroundExpired { break }
            if clock.now - started >= criteria.maximumRuntime { break }
            if let status = try? await engine.snapshot() {
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
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            if self.isBackgroundRunning {
                await self.drain(reason: "bg-\(reason)", requireTask: false, deadline: .seconds(5))
            }
        }
        chain = task
        await task.value
        return settled
    }

    // MARK: Drain (stop under beginBackgroundTask)

    private func drain(reason: String, requireTask: Bool, deadline: Duration = LifecycleBudget.backgroundStopDeadline) async {
        let clock = ContinuousClock()
        let t0 = clock.now
        phase = .draining
        var token: Int?
        if requireTask {
            token = tasks.begin(name: "psy.engine.stop") { [weak self] in
                self?.log.record("bgtask-expired", "system expiration handler fired during drain")
            }
            log.record("beginBackgroundTask", "reason=\(reason) token=\(token ?? -1)")
        }
        log.record("engine-stop", "deadline=\(deadline)")
        do {
            try await engine.stop(deadline: deadline)
            log.record("lock-released", "engine stopped")
        } catch {
            if case let .bridge(code, _) = error as? EngineError, code == BridgeContract.Code.stopTimeout.rawValue {
                restartRequired = true
            }
            fail("stop: \(error)")
        }
        phase = .idle
        if let token {
            tasks.end(token)
            log.record("endBackgroundTask", "token=\(token)")
        }
        let elapsed = clock.now - t0
        log.record("drain-complete", "reason=\(reason) elapsed=\(elapsed)")
    }

    // MARK: Policy

    private func reevaluatePolicy() async {
        await applyPolicy(force: false)
    }

    private func applyPolicy(force: Bool) async {
        let next = policy.decide(inputs: inputs, preferences: preferences)
        let changed = next != decision
        decision = next
        guard phase == .foregroundRunning || isBackgroundRunning else { return }
        guard changed || force else { return }
        do {
            try await engine.apply(next)
            log.record("policy-applied", "hold=\(next.hold?.rawValue ?? "none")")
        } catch {
            fail("policy: \(error)")
        }
    }

    private func fail(_ message: String) {
        log.record("failure", message)
        lastFailure = message
        onFailure?(message)
    }

    private func withTimeout(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw EngineError.bridge(code: BridgeContract.Code.deadline.rawValue, detail: "engine start timed out")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
