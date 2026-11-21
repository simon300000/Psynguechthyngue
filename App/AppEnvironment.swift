import Foundation
import PsySync
import UIKit

/// Composition root. Created once per process (also when the system launches
/// the app only to run a BGTask, before any scene exists).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let engine: any SyncEngine
    let host: LiveEngineHost
    let scheduler: BackgroundScheduler
    let policyMonitor: PolicyMonitor
    let settings: AppSettings
    let model: AppModel
    let isFixture: Bool

    private init() {
        let args = ProcessInfo.processInfo.arguments
        let fixture = args.contains("-PsyUITestFixture")
        isFixture = fixture
        let defaults: UserDefaults
        if fixture {
            // Deterministic UI tests: never read the user's real preferences.
            let suite = "psy.uitest"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
            for (i, a) in args.enumerated() where a.hasPrefix("-psy.") && i + 1 < args.count {
                defaults.set(args[i + 1] == "YES", forKey: String(a.dropFirst()))
            }
        } else {
            defaults = .standard
        }
        let settings = AppSettings(defaults: defaults)
        self.settings = settings

        if fixture {
            let name = Self.argument("-PsyUITestScenario", in: args) ?? "populated"
            let fake = FakeSyncEngine(named: name)
            if let ms = Self.argument("-PsyUITestStartDelayMS", in: args).flatMap(Int.init) { fake.startDelay = .milliseconds(ms) }
            engine = fake
        } else {
            engine = EngineFactory.makeLiveEngine()
        }
        let host = LiveEngineHost(engine: engine, tasks: UIKitBackgroundTaskRunner())
        host.preferences = settings.policyPreferences
        self.host = host
        scheduler = BackgroundScheduler(host: host, defaults: defaults)
        policyMonitor = PolicyMonitor(host: host)
        model = AppModel(engine: engine, host: host, settings: settings,
                         notifier: AppNotifier(enabled: !fixture), isFixture: fixture)
        settings.onChange = { [weak self] in
            guard let self else { return }
            self.host.preferences = self.settings.policyPreferences
            self.scheduler.scheduleNext()
        }
    }

    private static func argument(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Called from `application(_:didFinishLaunchingWithOptions:)`.
    func bootstrap() {
        scheduler.register()
        if !isFixture { policyMonitor.start() }
        model.startObserving()
    }
}
