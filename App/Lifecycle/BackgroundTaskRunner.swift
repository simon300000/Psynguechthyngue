import UIKit

/// Thin wrapper around `UIApplication.beginBackgroundTask` so the host can be
/// unit-tested without UIKit.
@MainActor
protocol BackgroundTaskRunning: AnyObject {
    /// Returns an opaque token. `expiration` runs on the main actor when the
    /// system is about to suspend the app.
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int
    func end(_ token: Int)
}

@MainActor
final class UIKitBackgroundTaskRunner: BackgroundTaskRunning {
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // The handler is invoked on the main thread.
            MainActor.assumeIsolated { expiration() }
        }
        return identifier.rawValue
    }

    func end(_ token: Int) {
        let identifier = UIBackgroundTaskIdentifier(rawValue: token)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
