import Foundation

/// Paths inside the App Group container. Single source of truth for both
/// the App and the File Provider extension.
public struct AppGroupLayout: Hashable, Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    /// Syncthing home: config.xml + database (shared so the restricted fetch can read it).
    public var engineHome: URL { root.appending(path: "Engine", directoryHint: .isDirectory) }
    /// flock(2) target; see `EngineLock`.
    public var engineLock: URL { root.appending(path: "Engine/engine.lock", directoryHint: .notDirectory) }
    /// Managed folders live at Folders/<folderID>/.
    public var foldersRoot: URL { root.appending(path: "Folders", directoryHint: .isDirectory) }
    /// Restricted fetch writes here, then Swift moves into the folder.
    public var staging: URL { root.appending(path: "Staging", directoryHint: .isDirectory) }
    /// SQLite: File Provider metadata projection + item identity + request inbox + change journal.
    public var filesDatabase: URL { root.appending(path: "Files/files.sqlite", directoryHint: .notDirectory) }

    public func managedFolder(_ id: FolderID) -> URL {
        foldersRoot.appending(path: id.rawValue, directoryHint: .isDirectory)
    }
}

/// Cross-process exclusive ownership of the Syncthing home (DB + config).
/// Exactly one of {App engine, extension restricted fetch} may hold it.
///
/// Implementation: `flock(LOCK_EX|LOCK_NB)` on `AppGroupLayout.engineLock`,
/// polled with backoff until `timeout`. iOS kills a *suspended* process that
/// holds a lock in a shared container (0xdead10cc), so the App must release it
/// before suspension (EngineHost stops the engine under beginBackgroundTask).
public protocol EngineLock: Sendable {
    /// Returns nil on timeout.
    func acquire(owner: EngineLockOwner, timeout: Duration) async -> (any EngineLockLease)?
    /// Non-blocking probe used by the extension to decide "App is running →
    /// delegate". Returns the current holder (owner + pid are written into the
    /// lock file after acquiring), or nil if the lock is free.
    func currentHolder() -> EngineLockOwner?
}

public enum EngineLockOwner: String, Codable, Sendable {
    case app
    case fileProviderExtension
}

public protocol EngineLockLease: AnyObject, Sendable {
    var owner: EngineLockOwner { get }
    func release()
}

/// Darwin notification names (CFNotificationCenterGetDarwinNotifyCenter).
/// Payload-free; receivers read state from the files database.
public enum DarwinNotification {
    /// Extension → App: new row in content_requests or change_journal.
    public static let filesRequestPosted = "app.psynguechthyngue.files.request-posted"
    /// App → Extension: a content request row changed state.
    public static let filesRequestUpdated = "app.psynguechthyngue.files.request-updated"
    /// Extension → App: please stop the engine soon (restricted fetch waiting);
    /// only honoured while the App is in background draining.
    public static let engineYieldRequested = "app.psynguechthyngue.engine.yield-requested"
    /// Either side: engine lock released.
    public static let engineLockReleased = "app.psynguechthyngue.engine.lock-released"
}

/// App start while the extension's restricted fetch holds the lock (device:
/// opening the App during a Files download failed with "Sync is busy").
///
/// The App marks that it wants the lock (a file next to the lock, fresh for
/// `freshness`) and repeats `engineYieldRequested` while it waits. The
/// extension cancels its restricted fetch on the notification, and while the
/// mark is fresh it does not take the lock again: it waits for the App and
/// hands the same `fetchContents` to it (delegated path), so Files sees no
/// failed download.
public struct EngineYield: Sendable {
    public static let freshness: TimeInterval = 30
    public let marker: URL

    public init(lockURL: URL) {
        marker = lockURL.deletingLastPathComponent().appending(path: lockURL.lastPathComponent + ".app-wants")
    }

    public func markAppWantsLock() {
        FileManager.default.createFile(atPath: marker.path(percentEncoded: false), contents: Data())
    }

    public func clear() {
        try? FileManager.default.removeItem(at: marker)
    }

    public func appWantsLock(now: Date = Date()) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: marker.path(percentEncoded: false)),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(modified) < Self.freshness
    }

    /// App side: acquire, asking an extension holder to yield. Waits up to
    /// `yieldTimeout` when the extension holds the lock, `timeout` otherwise.
    public func acquireForApp(_ lock: any EngineLock, timeout: Duration, yieldTimeout: Duration = .seconds(15))
        async -> (any EngineLockLease)?
    {
        guard lock.currentHolder() == .fileProviderExtension else {
            if let lease = await lock.acquire(owner: .app, timeout: timeout) { return lease }
            guard lock.currentHolder() == .fileProviderExtension else { return nil }
            return await acquireForApp(lock, timeout: timeout, yieldTimeout: yieldTimeout)
        }
        markAppWantsLock()
        defer { clear() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(timeout, yieldTimeout))
        while clock.now < deadline, !Task.isCancelled {
            // Repeated: an extension still acquiring when the first one went
            // out only starts observing after it holds the lock.
            if lock.currentHolder() == .fileProviderExtension {
                DarwinNotifier.post(DarwinNotification.engineYieldRequested)
            }
            if let lease = await lock.acquire(owner: .app, timeout: min(.seconds(1), clock.now.duration(to: deadline))) {
                return lease
            }
        }
        return nil
    }
}
