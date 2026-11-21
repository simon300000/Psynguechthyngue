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
    /// Prefix for BGContinuedProcessingTask identifiers ("<bundle>.continued");
    /// Info.plist permits "<prefix>.*".
    nonisolated static var continuedPrefix: String? {
        Bundle.main.object(forInfoDictionaryKey: "PsyContinuedTaskPrefix") as? String
    }

    /// UI tests: run the continued-processing path without BGTaskScheduler
    /// (unavailable in the Simulator).
    var simulateContinuedProcessing = false
    private(set) var continuedRunning = false

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
        // BGContinuedProcessingTask: Info.plist permits "<prefix>.*", but the
        // wildcard itself cannot be registered (device: "Registration rejected;
        // … is not advertised"). Each concrete identifier is registered right
        // before it is submitted, in `continueInBackground`.
    }

    // MARK: Continued processing

    /// Whether "Keep syncing in background" can be offered (not on Mac).
    var canContinueInBackground: Bool {
        if simulateContinuedProcessing { return true }
        guard !ProcessInfo.processInfo.isiOSAppOnMac, Self.continuedPrefix != nil else { return false }
        return true
    }

    /// User action: keep the current transfers going after leaving the app,
    /// with the system's progress UI. Must be called while in the foreground.
    /// Returns false when the system refused (e.g. too busy, or unsupported).
    @discardableResult
    func continueInBackground(title: String, subtitle: String) async -> Bool {
        guard !continuedRunning else { return true }
        if simulateContinuedProcessing {
            log.record("continued-submit", "simulated")
            let progress = Progress(totalUnitCount: 100)
            Task { @MainActor in await self.runContinued(progress: progress, isExpired: { false }, finish: { _ in }) }
            return true
        }
        guard let prefix = Self.continuedPrefix else { return false }
        let id = "\(prefix).sync-\(UUID().uuidString.prefix(8))"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main,
                                                         launchHandler: Self.continuedLaunchHandler(self))
        log.record("bgtask-register", "\(id) ok=\(registered)")
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
        request.strategy = .fail
        return await submitRequest(request, kind: "continued")
    }

    private nonisolated static func continuedLaunchHandler(_ scheduler: BackgroundScheduler) -> @Sendable (BGTask) -> Void {
        { [weak scheduler] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            nonisolated(unsafe) let unsafeTask = task
            Task { @MainActor in scheduler?.runContinued(task: unsafeTask) }
        }
    }

    private func runContinued(task: BGContinuedProcessingTask) {
        log.record("bgtask-launched", "\(task.identifier) kind=continuedProcessing")
        let expired = ExpiryFlag()
        task.expirationHandler = { expired.set() }
        nonisolated(unsafe) let unsafeTask = task
        Task { @MainActor in
            await self.runContinued(progress: task.progress, isExpired: { expired.isSet }, finish: { ok in
                unsafeTask.setTaskCompleted(success: ok)
            })
        }
    }

    /// Shared by the real task and the UI-test simulation: report byte progress
    /// until every folder is settled (or cannot progress), then end.
    private func runContinued(progress: Progress, isExpired: @escaping () -> Bool, finish: @escaping (Bool) -> Void) async {
        continuedRunning = true
        host.beginContinuedProcessing()
        var reason = "done"
        while true {
            if isExpired() { reason = "expired"; break }
            guard let status = try? await host.engine.snapshot() else { reason = "engine-unavailable"; break }
            let total = status.folders.reduce(Int64(0)) { $0 + max($1.progress.globalBytes, 0) }
            let need = status.folders.reduce(Int64(0)) { $0 + max($1.progress.needBytes, 0) }
            progress.totalUnitCount = max(total, 1)
            progress.completedUnitCount = max(total - need, 0)
            let active = status.folders.contains { $0.state == .syncing || $0.state == .scanning }
            if !active {
                // Up to date, or waiting for devices / on hold: nothing more to do in background.
                reason = need == 0 ? "done" : "stalled"
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        log.record("continued-finished", "reason=\(reason)")
        finish(reason == "done")
        continuedRunning = false
        await host.endContinuedProcessing(reason: reason)
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
            Task { @MainActor in scheduler.debugRun(kind: .appRefresh) }
        }, Self.debugRefreshNotification as CFString, nil, .deliverImmediately)
    }

    private func debugRun(kind: BackgroundTaskKind) {
        log.record("bgtask-launched", "debug-trigger kind=\(kind.rawValue)")
        let runner = UIKitBackgroundTaskRunner()
        let box = TokenBox()
        box.token = runner.begin(name: "psy.debug.bgtask") { runner.end(box.token) }
        let token = box.token
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
        nonisolated(unsafe) let request = request
        Task { @MainActor in await self.submitRequest(request, kind: "scheduled") }
    }

    /// iOS 27 deprecates the synchronous `submit(_:)` because it cannot report
    /// every error; the async `submitTaskRequest(_:)` does. Errors are logged in
    /// full (domain, code name, message, userInfo).
    @discardableResult
    private func submitRequest(_ request: BGTaskRequest, kind: String) async -> Bool {
        nonisolated(unsafe) let request = request
        do {
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            log.record("bgtask-\(kind)", request.identifier)
            return true
        } catch {
            log.record("bgtask-\(kind)-failed", "\(request.identifier): \(Self.describe(error))")
            return false
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var code = "\(ns.code)"
        if ns.domain == BGTaskScheduler.errorDomain, let c = BGTaskScheduler.Error.Code(rawValue: ns.code) {
            switch c {
            case .unavailable: code = "unavailable"
            case .tooManyPendingTaskRequests: code = "tooManyPendingTaskRequests"
            case .notPermitted: code = "notPermitted"
            case .immediateRunIneligible: code = "immediateRunIneligible"
            @unknown default: code = "\(ns.code)"
            }
        }
        let info = ns.userInfo.filter { $0.key != NSLocalizedDescriptionKey }
        return "\(ns.domain)#\(code) \(ns.localizedDescription)" + (info.isEmpty ? "" : " userInfo=\(info)")
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

/// Thread-safe one-way flag for expiration handlers.
private final class ExpiryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
private final class TokenBox {
    var token = 0
}
