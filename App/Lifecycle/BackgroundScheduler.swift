import BackgroundTasks
import Foundation
import PsySync

/// Registers and schedules BGAppRefresh / BGProcessing tasks (DESIGN.md §4.2).
/// Both reuse the single `LiveEngineHost`; only the run context differs.
///
/// Debug: with the app running under Xcode/simulator, pause in the debugger and run
///   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"<bundle>.refresh"]
@MainActor
final class BackgroundScheduler {
    static let lastRunKey = "psy.background.lastRun"
    static let enabledKey = "psy.background.enabled"

    private let host: LiveEngineHost
    private let defaults: UserDefaults
    private let log = LifecycleLog.shared

    init(host: LiveEngineHost, defaults: UserDefaults = .standard) {
        self.host = host
        self.defaults = defaults
    }

    nonisolated static var refreshIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "PsyRefreshTaskIdentifier") as? String
    }
    nonisolated static var processingIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "PsyProcessingTaskIdentifier") as? String
    }

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey) }

    /// Must be called before `application(_:didFinishLaunchingWithOptions:)` returns.
    func register() {
        if let id = Self.refreshIdentifier {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main, launchHandler: Self.launchHandler(self, kind: .appRefresh))
            log.record("bgtask-register", "\(id) ok=\(ok)")
        }
        if let id = Self.processingIdentifier {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main, launchHandler: Self.launchHandler(self, kind: .processing))
            log.record("bgtask-register", "\(id) ok=\(ok)")
        }
    }

    /// Built outside the main actor so the closure carries no actor-isolation
    /// check: the system may invoke handlers on any queue.
    private nonisolated static func launchHandler(_ scheduler: BackgroundScheduler, kind: BackgroundTaskKind) -> @Sendable (BGTask) -> Void {
        { [weak scheduler] task in
            nonisolated(unsafe) let unsafeTask = task
            Task { @MainActor in scheduler?.run(unsafeTask, kind: kind) }
        }
    }

    private nonisolated static func expirationHandler(host: LiveEngineHost, work: Task<Void, Never>) -> @Sendable () -> Void {
        {
            Task { @MainActor in
                await host.handle(.backgroundTaskExpiring)
                _ = work   // keep the run task alive until it finishes stopping the engine
            }
        }
    }

    #if DEBUG
    /// Simulator stand-in for `_simulateLaunchForTaskWithIdentifier` (BGTaskScheduler is
    /// unavailable in the Simulator). Trigger with
    ///   xcrun simctl spawn booted notifyutil -p app.psynguechthyngue.debug.bg-refresh
    /// Runs the same host path as a real BGAppRefreshTask under a background assertion.
    static let debugRefreshNotification = "app.psynguechthyngue.debug.bg-refresh"

    func installDebugTrigger() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let scheduler = Unmanaged<BackgroundScheduler>.fromOpaque(observer).takeUnretainedValue()
            nonisolated(unsafe) let s = scheduler
            Task { @MainActor in s.debugRun(kind: .appRefresh) }
        }, Self.debugRefreshNotification as CFString, nil, .deliverImmediately)
    }

    private func debugRun(kind: BackgroundTaskKind) {
        log.record("bgtask-launched", "debug-trigger kind=\(kind.rawValue)")
        let runner = UIKitBackgroundTaskRunner()
        var token = 0
        token = runner.begin(name: "psy.debug.bgtask") { runner.end(token) }
        Task { @MainActor in
            let ok = await self.host.runBackgroundTask(kind: kind)
            self.defaults.set(Date(), forKey: Self.lastRunKey)
            self.log.record("bgtask-completed", "debug-trigger settled=\(ok)")
            runner.end(token)
        }
    }
    #endif

    /// Called when the app enters the background and whenever the setting changes.
    func scheduleNext() {
        let scheduler = BGTaskScheduler.shared
        guard isEnabled else {
            scheduler.cancelAllTaskRequests()
            return
        }
        if let id = Self.refreshIdentifier {
            let request = BGAppRefreshTaskRequest(identifier: id)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            submit(request)
        }
        if let id = Self.processingIdentifier {
            let request = BGProcessingTaskRequest(identifier: id)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
            submit(request)
        }
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
            log.record("bgtask-scheduled", request.identifier)
        } catch {
            log.record("bgtask-schedule-failed", "\(request.identifier): \(error)")
        }
    }

    private func run(_ task: BGTask, kind: BackgroundTaskKind) {
        log.record("bgtask-launched", "\(task.identifier) kind=\(kind.rawValue)")
        scheduleNext()
        guard isEnabled else {
            task.setTaskCompleted(success: true)
            return
        }
        nonisolated(unsafe) let unsafeTask = task
        let work = Task { @MainActor in
            let ok = await self.host.runBackgroundTask(kind: kind)
            self.defaults.set(Date(), forKey: Self.lastRunKey)
            self.log.record("bgtask-completed", "\(unsafeTask.identifier) settled=\(ok)")
            unsafeTask.setTaskCompleted(success: true)
        }
        task.expirationHandler = Self.expirationHandler(host: host, work: work)
    }
}
