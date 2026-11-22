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
final class AppDelegate: UIResponder, UIApplicationDelegate {
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
                    Task {
                        await env.host.handle(.didBecomeActive)
                        await env.model.refreshAll()
                        await env.model.refreshFilesLocation()
                    }
                }
            }
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { env.model.willResignActive() }
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
                MainActor.assumeIsolated { _ = Task { await env.host.handle(.memoryWarning) } }
            }
            // Mac (Designed for iPad): keep the closure confirmation in step with the
            // number of windows while transfers run.
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    ClosureConfirmation.update(transfersActive: env.model.hasActiveTransfers, isOnMac: env.model.isOnMac)
                }
            }
            // Closing one of several windows: the remaining one may now need the confirmation.
            center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    ClosureConfirmation.update(transfersActive: env.model.hasActiveTransfers, isOnMac: env.model.isOnMac)
                }
            }
            // Closing the last window on Mac terminates the app without a
            // `UIScene.didDisconnectNotification`; `willTerminate` is delivered and
            // drains the engine (measured on macOS 27: drain ≈0.8 s, then exit;
            // Docs/REWRITE/notes/accept-mac/README.md).
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { _ = Task { await env.host.handle(.willTerminate) } }
            }
        }
        return true
    }

    // MARK: Menu bar (Mac) / keyboard shortcuts (iPad)

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        AppMenu.build(with: builder)
    }

    @objc func menuSyncNow(_ sender: Any?) { send(.syncNow) }
    @objc func menuAddDevice(_ sender: Any?) { send(.addDevice) }
    @objc func menuNewFolder(_ sender: Any?) { send(.newFolder) }

    override func validate(_ command: UICommand) {
        super.validate(command)
        if command.action == #selector(menuSyncNow(_:)) {
            let model = MainActor.assumeIsolated { AppEnvironment.shared.model }
            let enabled = MainActor.assumeIsolated { model.isRunning && !model.folders.isEmpty }
            command.attributes = enabled ? [] : [.disabled]
        }
    }

    private func send(_ command: AppCommand) {
        MainActor.assumeIsolated { AppEnvironment.shared.model.pendingCommand = command }
    }
}
