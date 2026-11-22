import Darwin
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
    /// iCloud Drive / a cloud or third-party File Provider location (DESIGN.md §6.7, Q2).
    /// "On My iPhone / iPad" (LocalStorage) is allowed.
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

    /// True for iCloud Drive and any location served by a cloud / third-party
    /// File Provider (including our own domain): content there can be
    /// dataless, so Syncthing reading it would trigger downloads or fail.
    /// "On My iPhone / iPad" (the system LocalStorage provider) is local disk
    /// and allowed (DESIGN.md §6.7, Q2).
    public static func isFileProviderBacked(_ url: URL) -> Bool {
        classify(LocationFacts.probe(url)) == .cloud
    }

    public enum Kind: Hashable, Sendable { case local, cloud }

    /// Observable properties of a picked directory; `probe` reads them from
    /// the file system, tests build them directly.
    public struct LocationFacts: Hashable, Sendable {
        public var path: String
        /// `URLResourceValues.isUbiquitousItem` (iCloud).
        public var isUbiquitous: Bool
        /// The directory or one of its direct children is a dataless
        /// (not materialized) File Provider placeholder.
        public var hasDatalessContent: Bool
        /// Container-manager identifier of the `Containers/Shared/AppGroup/<UUID>`
        /// container the path lives in, if any and readable.
        public var groupContainerIdentifier: String?
        /// File Provider that serves the directory, read from its bookmark
        /// (`fp:/…/<provider>//…`). On a device the sandbox cannot read the
        /// container-manager identifier (EPERM), so this is what identifies
        /// "On My iPhone / iPad" there.
        public var fileProviderIdentifier: String?

        public init(path: String, isUbiquitous: Bool = false, hasDatalessContent: Bool = false,
                    groupContainerIdentifier: String? = nil, fileProviderIdentifier: String? = nil) {
            self.path = path
            self.isUbiquitous = isUbiquitous
            self.hasDatalessContent = hasDatalessContent
            self.groupContainerIdentifier = groupContainerIdentifier
            self.fileProviderIdentifier = fileProviderIdentifier
        }

        public static func probe(_ url: URL) -> LocationFacts {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            let ubiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            let group = groupContainer(of: path)
            let groupID = group.flatMap(ExternalLocation.containerIdentifier(atGroupPath:))
            // Only needed where ownership decides the outcome.
            let provider = (group != nil && groupID == nil)
                ? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
                    .flatMap(ExternalLocation.fileProviderIdentifier(bookmark:))
                : nil
            return LocationFacts(
                path: path,
                isUbiquitous: ubiquitous,
                hasDatalessContent: ExternalLocation.hasDatalessContent(url),
                groupContainerIdentifier: groupID,
                fileProviderIdentifier: provider
            )
        }
    }

    /// Group container of the system "On My iPhone / iPad" provider.
    public static let localStorageGroup = "group.com.apple.FileProvider.LocalStorage"
    /// Provider identifier of "On My iPhone / iPad" as it appears in bookmarks.
    public static let localStorageProvider = "com.apple.FileProvider.LocalStorage"

    public static func classify(_ facts: LocationFacts) -> Kind {
        let path = facts.path.hasSuffix("/") ? facts.path : facts.path + "/"
        let cloudMarkers = [
            "/Library/Mobile Documents/",                 // iCloud Drive (macOS & iOS)
            "/com~apple~CloudDocs/",
            "/Library/CloudStorage/",                     // macOS File Provider domains
            "/Library/Application Support/FileProvider/", // replicated (FPFS) domains, incl. ours
        ]
        if cloudMarkers.contains(where: path.contains) { return .cloud }
        if facts.isUbiquitous || facts.hasDatalessContent { return .cloud }
        // Inside another app's group container (where File Provider
        // extensions keep "File Provider Storage"): only the system local
        // storage provider is real local disk. Unknown owner → refuse.
        if groupContainer(of: facts.path) != nil || path.contains("/File Provider Storage/") {
            if let id = facts.groupContainerIdentifier { return id == localStorageGroup ? .local : .cloud }
            return facts.fileProviderIdentifier == localStorageProvider ? .local : .cloud
        }
        return .local
    }

    /// `…/Containers/Shared/AppGroup/<UUID>` prefix of `path`, if any.
    static func groupContainer(of path: String) -> String? {
        let marker = "/Containers/Shared/AppGroup/"
        guard let r = path.range(of: marker) else { return nil }
        let uuid = path[r.upperBound...].prefix(while: { $0 != "/" })
        guard !uuid.isEmpty else { return nil }
        return String(path[..<r.upperBound]) + uuid
    }

    /// Reads the container manager's identifier for a group container: the
    /// `com.apple.containermanager.identifier` xattr, else its metadata plist.
    static func containerIdentifier(atGroupPath group: String) -> String? {
        let name = "com.apple.containermanager.identifier"
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = getxattr(group, name, &buffer, buffer.count, 0, 0)
        if n > 0 {
            let id = String(decoding: buffer[..<n], as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
            if !id.isEmpty { return id }
        }
        let plist = URL(filePath: group).appending(path: ".com.apple.mobile_container_manager.metadata.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["MCMMetadataIdentifier"] as? String
    }

    /// Provider identifier from the File Provider token a bookmark carries
    /// (`fp:/<domain-hash>/<provider>//fid=…`, observed on iOS 27). The
    /// format is not documented: anything unexpected yields nil, which
    /// `classify` treats as "unknown owner" and refuses.
    static func fileProviderIdentifier(bookmark: Data) -> String? {
        var run: [UInt8] = []
        func provider() -> String? {
            let token = String(decoding: run, as: UTF8.self)
            guard token.hasPrefix("fp:/"), let head = token.components(separatedBy: "//").first,
                  head.count < token.count,
                  let last = head.split(separator: "/").last, last.contains(".") else { return nil }
            return String(last)
        }
        for byte in bookmark + [0] {
            if byte >= 0x20 && byte < 0x7f { run.append(byte); continue }
            if let id = provider() { return id }
            run.removeAll(keepingCapacity: true)
        }
        return nil
    }

    /// True if `url` or one of its direct children carries `SF_DATALESS`.
    static func hasDatalessContent(_ url: URL) -> Bool {
        func dataless(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0 && (st.st_flags & UInt32(SF_DATALESS)) != 0
        }
        let path = url.path(percentEncoded: false)
        if dataless(path) { return true }
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return children.prefix(256).contains { dataless((path as NSString).appendingPathComponent($0)) }
    }

    static func displayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~/" + path.dropFirst(home.count).drop(while: { $0 == "/" }) }
        return path
    }
}
