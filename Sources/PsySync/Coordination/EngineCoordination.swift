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
/// Implementation (WP-C): `flock(LOCK_EX|LOCK_NB)` on `AppGroupLayout.engineLock`,
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
