import PsySync
import SwiftUI
import UIKit

@main
struct PsynguechthyngueApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppEnvironment.shared.model)
                .environment(AppEnvironment.shared.settings)
        }
    }
}

/// Launch plumbing: BGTask handlers must be registered before launch finishes,
/// and lifecycle signals are app-level (not per scene) so a second iPad window
/// cannot stop the engine.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            let env = AppEnvironment.shared
            env.bootstrap()
            let center = NotificationCenter.default
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    env.model.isActive = true
                    Task { await env.host.handle(.didBecomeActive); await env.model.refreshAll() }
                }
            }
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    env.model.isActive = false
                    env.host.prepareForBackground()   // assertion first, before any queued work
                    env.scheduler.scheduleNext()
                    Task { await env.host.handle(.didEnterBackground) }
                }
            }
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Task { await env.host.handle(.memoryWarning) } }
            }
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Task { await env.host.handle(.willTerminate) } }
            }
        }
        return true
    }
}
