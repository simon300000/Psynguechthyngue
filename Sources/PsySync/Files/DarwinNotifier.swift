import Foundation

/// Payload-free cross-process signals (`DarwinNotification.*`) over
/// CFNotificationCenterGetDarwinNotifyCenter. Receivers re-read files.sqlite.
public enum DarwinNotifier {
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Observes `name`; the handler runs on an arbitrary thread. Keep the
    /// returned token alive; deallocating it removes the observer.
    public static func observe(_ name: String, handler: @escaping @Sendable () -> Void) -> DarwinObservation {
        DarwinObservation(name: name, handler: handler)
    }

    /// Async stream of notifications for `name` (buffering newest only).
    public static func stream(_ name: String) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observation = DarwinObservation(name: name) { continuation.yield(()) }
            continuation.onTermination = { _ in observation.cancel() }
        }
    }
}

public final class DarwinObservation: @unchecked Sendable {
    private let name: String
    private let handler: @Sendable () -> Void
    private let lock = NSLock()
    private var active = true

    init(name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinObservation>.fromOpaque(observer).takeUnretainedValue()
                me.fire()
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit { cancel() }

    private func fire() {
        guard lock.withLock({ active }) else { return }
        handler()
    }

    public func cancel() {
        let wasActive = lock.withLock {
            let value = active
            active = false
            return value
        }
        guard wasActive else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString), nil)
    }
}
