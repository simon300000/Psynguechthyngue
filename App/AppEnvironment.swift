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
    /// WP-C Files services (nil in fixtures or when the App Group is unavailable).
    let files: FilesIntegration?
    let bridge: PsyBridgeAdapter?

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
            // `-psy.<key> YES` launch arguments override via the argument domain.
        } else {
            defaults = .standard
        }
        let settings = AppSettings(defaults: defaults)
        self.settings = settings

        if fixture {
            let name = Self.argument("-PsyUITestScenario", in: args) ?? "populated"
            let fake = FakeSyncEngine(named: name)
            if let ms = Self.argument("-PsyUITestStartDelayMS", in: args).flatMap(Int.init) { fake.startDelay = .milliseconds(ms) }
            if let ms = Self.argument("-PsyUITestStopDelayMS", in: args).flatMap(Int.init) { fake.stopDelay = .milliseconds(ms) }
            if args.contains("-PsyUITestStopTimeout") {
                fake.nextStopFailure = .bridge(code: BridgeContract.Code.stopTimeout.rawValue, detail: "simulated")
            }
            engine = fake
            files = nil
            bridge = nil
        } else {
            // Used only on the very first start; afterwards the name lives in the engine config.
            let live = EngineFactory.makeLiveEngine(deviceName: DefaultDeviceName.current)
            engine = live.engine
            bridge = live.bridge
            files = live.layout.map { FilesIntegration(engine: live.engine, layout: $0) }
        }
        // `-PsySimulateMac` (fixture only) exercises the isiOSAppOnMac branch on the simulator.
        let onMac = ProcessInfo.processInfo.isiOSAppOnMac || (fixture && args.contains("-PsySimulateMac"))
        let host = LiveEngineHost(engine: engine, tasks: UIKitBackgroundTaskRunner(), isOnMac: onMac)
        host.preferences = settings.policyPreferences
        self.host = host
        scheduler = BackgroundScheduler(host: host, defaults: defaults, isOnMac: onMac)
        policyMonitor = PolicyMonitor(host: host)
        model = AppModel(engine: engine, host: host, settings: settings,
                         notifier: AppNotifier(enabled: !fixture), isFixture: fixture, isOnMac: onMac)
        let filesDisabled = fixture && args.contains("-PsyUITestFilesDisabled")
        model.scheduler = scheduler
        scheduler.simulateContinuedProcessing = fixture && args.contains("-PsyUITestSimulateContinued")
        if let files {
            // WP-C: FilesIntegration follows engine state itself (attach); the host
            // additionally closes files.sqlite right before stop (I2).
            files.attach()
            model.filesStatus = FilesLocationStatusProvider(files: files)
            files.onListing = { [weak model] folder, progress in model?.setListing(folder, progress) }
            host.onEngineStarted = { [weak model] in await model?.refreshFilesLocation() }
            host.onEngineWillStop = { await files.engineWillStop() }
        } else {
            model.filesStatus = StaticFilesLocationStatus(filesDisabled ? .disabled : .unknown)
        }
        if let bridge {
            host.onMemoryWarning = { Task { await PsyBridgeThread.shared.run { bridge.onMemoryWarning() } } }
        }
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
        #if DEBUG
        scheduler.installDebugTrigger()
        #endif
        if !isFixture {
            policyMonitor.start()
            SearchAlias.register()
        }
        model.startObserving()
    }
}
