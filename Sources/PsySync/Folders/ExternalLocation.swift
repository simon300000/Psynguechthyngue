import Foundation

/// Security-scoped bookmark primitives, injectable for tests.
/// Extracted from the legacy `ExternalDirectoryBookmarkAccess` (DESIGN.md §8.2).
public struct ExternalLocationAccess: Sendable {
    public typealias Create = @Sendable (URL) throws -> Data
    public typealias Resolve = @Sendable (Data) throws -> (url: URL, isStale: Bool)
    public typealias Begin = @Sendable (URL) -> Bool
    public typealias End = @Sendable (URL) -> Void

    public var create: Create
    public var resolve: Resolve
    public var beginAccess: Begin
    public var endAccess: End

    public init(create: @escaping Create, resolve: @escaping Resolve, beginAccess: @escaping Begin, endAccess: @escaping End) {
        self.create = create
        self.resolve = resolve
        self.beginAccess = beginAccess
        self.endAccess = endAccess
    }

    public static let system = ExternalLocationAccess(
        create: { url in
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
            // iOS (incl. Designed for iPad on Mac): picker URLs carry a recursive
            // security scope; Apple documents minimal bookmarks for persisting them.
            let options: URL.BookmarkCreationOptions = [.minimalBookmark]
            #endif
            return try url.bookmarkData(options: options, includingResourceValuesForKeys: [.nameKey, .isDirectoryKey], relativeTo: nil)
        },
        resolve: { data in
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
            #else
            let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutImplicitStartAccessing]
            #endif
            let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        },
        beginAccess: { $0.startAccessingSecurityScopedResource() },
        endAccess: { $0.stopAccessingSecurityScopedResource() }
    )

    /// Plain paths, no security scope (macOS tests / E2E harness).
    public static let unscoped = ExternalLocationAccess(
        create: { url in Data(url.path(percentEncoded: false).utf8) },
        resolve: { data in (URL(filePath: String(decoding: data, as: UTF8.self), directoryHint: .isDirectory), false) },
        beginAccess: { _ in true },
        endAccess: { _ in }
    )
}

public enum ExternalLocationError: Error, Hashable, Sendable {
    case notADirectory
    /// iCloud Drive / another File Provider backed location (DESIGN.md §6.7, Q2).
    case cloudBacked
    case accessDenied
    case unresolvable(String)
}

/// A resolved external folder location with an active security scope.
/// Call `stop()` exactly once when the engine no longer needs the path.
public final class ExternalLocationScope: @unchecked Sendable {
    public let url: URL
    /// Non-nil when the stored bookmark was stale and has been re-created;
    /// the caller must persist it.
    public let refreshedBookmark: Data?
    private let access: ExternalLocationAccess
    private let started: Bool
    private let lock = NSLock()
    private var stopped = false

    init(url: URL, refreshedBookmark: Data?, access: ExternalLocationAccess, started: Bool) {
        self.url = url
        self.refreshedBookmark = refreshedBookmark
        self.access = access
        self.started = started
    }

    public var path: String { url.standardizedFileURL.path(percentEncoded: false) }

    public func stop() {
        let shouldEnd = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped && started
        }
        if shouldEnd { access.endAccess(url) }
    }

    deinit { stop() }
}

/// Bookmark creation/resolution and cloud-location detection for
/// `FolderLocation.external`.
public enum ExternalLocation {
    /// Validates a directory picked by the user and returns a bookmark +
    /// display path suitable for `FolderLocation.external`.
    public static func makeLocation(for url: URL, access: ExternalLocationAccess = .system) throws -> FolderLocation {
        let started = access.beginAccess(url)
        defer { if started { access.endAccess(url) } }
        try validate(url)
        let bookmark: Data
        do {
            bookmark = try access.create(url)
        } catch {
            throw ExternalLocationError.unresolvable(String(describing: error))
        }
        return .external(bookmark: bookmark, displayPath: displayPath(for: url))
    }

    /// Resolves a stored bookmark and starts security-scoped access.
    public static func open(bookmark: Data, access: ExternalLocationAccess = .system) throws -> ExternalLocationScope {
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try access.resolve(bookmark)
        } catch {
            throw ExternalLocationError.unresolvable(String(describing: error))
        }
        let started = access.beginAccess(resolved.url)
        var refreshed: Data?
        if resolved.isStale {
            refreshed = try? access.create(resolved.url)
        }
        do {
            try validate(resolved.url)
        } catch {
            if started { access.endAccess(resolved.url) }
            throw error
        }
        return ExternalLocationScope(url: resolved.url, refreshedBookmark: refreshed, access: access, started: started)
    }

    static func validate(_ url: URL) throws {
        if isFileProviderBacked(url) { throw ExternalLocationError.cloudBacked }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey, .isWritableKey])
        } catch {
            throw ExternalLocationError.accessDenied
        }
        guard values.isDirectory == true else { throw ExternalLocationError.notADirectory }
        if values.isReadable == false || values.isWritable == false { throw ExternalLocationError.accessDenied }
    }

    /// True for iCloud Drive and any location served by a File Provider
    /// (including our own domain): content there can be dataless, so
    /// Syncthing reading it would trigger downloads or fail.
    public static func isFileProviderBacked(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let markers = [
            "/Library/Mobile Documents/",          // iCloud Drive (macOS & iOS)
            "/Library/CloudStorage/",              // macOS File Provider domains
            "/File Provider Storage/",             // iOS File Provider extensions' storage
            "/Containers/Shared/AppGroup/",        // other apps' group containers (incl. FP backing)
            "/com~apple~CloudDocs/",
        ]
        if markers.contains(where: { (path + "/").contains($0) }) { return true }
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true {
            return true
        }
        return false
    }

    static func displayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~/" + path.dropFirst(home.count).drop(while: { $0 == "/" }) }
        return path
    }
}
