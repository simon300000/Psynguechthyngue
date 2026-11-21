import CryptoKit
import Foundation
import SQLite3

public enum FilesStoreError: Error, Hashable, Sendable {
    /// The caller's anchor predates pruned tombstones; re-enumerate from scratch
    /// (maps to NSFileProviderError.syncAnchorExpired).
    case anchorExpired
    case noSuchItem
    case invalidPath(String)
    case collision(RelativePath)
}

/// Per-folder attributes the extension needs without asking the engine.
/// Written by the App (`DomainManager`), read by the extension.
public struct FilesFolderInfo: Hashable, Codable, Sendable {
    public var folderID: FolderID
    public var label: String
    public var isReadOnly: Bool
    public var contentMode: ContentMode

    public init(folderID: FolderID, label: String, isReadOnly: Bool, contentMode: ContentMode) {
        self.folderID = folderID
        self.label = label
        self.isReadOnly = isReadOnly
        self.contentMode = contentMode
    }
}

/// Pin / evict intent recorded by the extension (custom actions), drained by the App.
public struct PresenceRequest: Hashable, Sendable {
    public var folderID: FolderID
    public var path: RelativePath
    public var present: Bool
}

/// `Files/files.sqlite` (WAL). Holds the File Provider projection of the
/// global index, stable item identity, tombstones for change enumeration,
/// the local-mutation journal and the content-request inbox
/// (DESIGN.md §6.1–6.6).
///
/// Ownership (invariant I3): only the App's `FilesProjector` writes the global
/// projection (`applyIndexBatch`, full-sync sweep). The extension writes the
/// journal, requests, pins/presence, materialized set and local-write rows
/// (`recordLocalWrite/recordLocalDelete/moveIdentity`).
///
/// Anchors are a per-database monotonic sequence; every changed row gets its
/// own value, so `changes(since:limit:)` can page through any batch size
/// without a compound cursor. Unchanged rows never get a new anchor.
public final class FilesStore: @unchecked Sendable {
    public static let schemaVersion: Int64 = 1
    /// Tombstones kept before pruning; older anchors become `.anchorExpired`.
    public var tombstoneRetention = 200_000

    private let lock = NSLock()
    private let connection: SQLiteConnection
    public let url: URL
    /// Full-sync generation per folder (App process only).
    /// Paths (and their ancestors) seen during the active full-sync pass.
    private var activeSync: [FolderID: Set<String>] = [:]

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            connection = try Self.openAndMigrate(url)
        } catch let error as SQLiteError where Self.isCorruption(error.code) {
            Self.removeDatabaseFiles(url)
            connection = try Self.openAndMigrate(url)
        }
    }

    public func close() {
        lock.withLock { connection.close() }
    }

    public static func rootItemID(_ folder: FolderID) -> ItemIdentifier {
        ItemIdentifier(rawValue: "root:" + folder.rawValue)
    }

    public func reader(folder: FolderID) -> FolderFilesReader {
        FolderFilesReader(store: self, folder: folder)
    }

    // MARK: Schema

    private static func isCorruption(_ code: Int32) -> Bool {
        let primary = code & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    private static func removeDatabaseFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path(percentEncoded: false) + suffix)
        }
    }

    private static func openAndMigrate(_ url: URL) throws -> SQLiteConnection {
        let connection = try SQLiteConnection(path: url.path(percentEncoded: false))
        try connection.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=OFF;")
        let version = try connection.scalarInt64("PRAGMA user_version") ?? 0
        if version != schemaVersion {
            try connection.transaction {
                if version != 0 {
                    for table in ["items", "tombstones", "meta", "journal", "requests", "folders", "materialized", "presence"] {
                        try connection.execute("DROP TABLE IF EXISTS \(table)")
                    }
                }
                try connection.execute(schemaSQL)
                try connection.execute("PRAGMA user_version = \(schemaVersion)")
            }
        }
        return connection
    }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        INSERT OR IGNORE INTO meta(key, value) VALUES ('anchor', 0), ('min_anchor', 0), ('sync_token', 0);
        CREATE TABLE IF NOT EXISTS folders(
            folder_id TEXT PRIMARY KEY, label TEXT NOT NULL, read_only INTEGER NOT NULL, content_mode TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS items(
            item_id TEXT PRIMARY KEY,
            folder_id TEXT NOT NULL,
            path TEXT NOT NULL,
            parent_id TEXT NOT NULL,
            name TEXT NOT NULL,
            is_dir INTEGER NOT NULL,
            size INTEGER NOT NULL,
            modified REAL NOT NULL,
            content_version BLOB NOT NULL,
            metadata_version BLOB NOT NULL,
            is_local INTEGER NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            pending_upload INTEGER NOT NULL DEFAULT 0,
            read_only INTEGER NOT NULL DEFAULT 0,
            change_anchor INTEGER NOT NULL,
            seen_token INTEGER NOT NULL DEFAULT 0,
            UNIQUE(folder_id, path));
        CREATE INDEX IF NOT EXISTS items_children ON items(parent_id, name);
        CREATE INDEX IF NOT EXISTS items_changes ON items(folder_id, change_anchor);
        CREATE TABLE IF NOT EXISTS tombstones(
            item_id TEXT PRIMARY KEY, folder_id TEXT NOT NULL, change_anchor INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS tombstones_changes ON tombstones(folder_id, change_anchor);
        CREATE TABLE IF NOT EXISTS materialized(item_id TEXT PRIMARY KEY, folder_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS journal(
            seq INTEGER PRIMARY KEY AUTOINCREMENT, folder_id TEXT NOT NULL, kind TEXT NOT NULL,
            path TEXT NOT NULL, previous_path TEXT, recorded_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS requests(
            id TEXT PRIMARY KEY, folder_id TEXT NOT NULL, path TEXT NOT NULL, requested_version BLOB NOT NULL,
            state TEXT NOT NULL, failure_code TEXT, posted_at REAL NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS presence(
            folder_id TEXT NOT NULL, path TEXT NOT NULL, present INTEGER NOT NULL, PRIMARY KEY(folder_id, path));
        """

    // MARK: Locking helpers

    func read<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try lock.withLock {
            defer { connection.resetStatements() }
            return try body(connection)
        }
    }

    func write<T>(_ body: (WriteContext) throws -> T) throws -> T {
        try lock.withLock {
            try connection.transaction {
                let context = try WriteContext(connection: connection)
                let value = try body(context)
                try context.finish()
                return value
            }
        }
    }

    /// One write transaction. Hands out anchors and records tombstones.
    final class WriteContext {
        let db: SQLiteConnection
        private(set) var anchor: Int64
        private let startAnchor: Int64

        init(connection: SQLiteConnection) throws {
            db = connection
            anchor = try connection.scalarInt64("SELECT value FROM meta WHERE key='anchor'") ?? 0
            startAnchor = anchor
        }

        func nextAnchor() -> Int64 {
            anchor += 1
            return anchor
        }

        func finish() throws {
            if anchor != startAnchor {
                try db.run("UPDATE meta SET value=? WHERE key='anchor'", [.int(anchor)])
            }
        }
    }

    // MARK: Row helpers

    static let columns = """
        item_id, parent_id, folder_id, path, is_dir, size, modified, content_version, metadata_version,
        is_local, is_pinned, pending_upload, read_only, change_anchor
        """

    static func record(from s: SQLiteStatement, offset: Int32 = 0) -> FileItemRecord {
        FileItemRecord(
            itemID: ItemIdentifier(rawValue: s.text(at: offset)),
            parentID: ItemIdentifier(rawValue: s.text(at: offset + 1)),
            folderID: FolderID(rawValue: s.text(at: offset + 2)),
            path: RelativePath(rawValue: s.text(at: offset + 3)),
            isDirectory: s.bool(at: offset + 4),
            size: s.int64(at: offset + 5),
            modified: Date(timeIntervalSince1970: s.double(at: offset + 6)),
            contentVersion: s.data(at: offset + 7),
            metadataVersion: s.data(at: offset + 8),
            isLocal: s.bool(at: offset + 9),
            isPinned: s.bool(at: offset + 10),
            pendingUpload: s.bool(at: offset + 11),
            isReadOnly: s.bool(at: offset + 12),
            changeAnchor: s.int64(at: offset + 13)
        )
    }

    static func fetchRecord(_ db: SQLiteConnection, id: ItemIdentifier) throws -> FileItemRecord? {
        let s = try db.prepare("SELECT \(columns) FROM items WHERE item_id=?")
        try s.bind([.text(id.rawValue)])
        return try s.step() == SQLITE_ROW ? record(from: s) : nil
    }

    static func fetchRecord(_ db: SQLiteConnection, folder: FolderID, path: RelativePath) throws -> FileItemRecord? {
        let s = try db.prepare("SELECT \(columns) FROM items WHERE folder_id=? AND path=?")
        try s.bind([.text(folder.rawValue), .text(path.rawValue)])
        return try s.step() == SQLITE_ROW ? record(from: s) : nil
    }

    private static func insert(_ ctx: WriteContext, _ r: FileItemRecord, seenToken: Int64) throws {
        try ctx.db.run(
            """
            INSERT INTO items(item_id, parent_id, folder_id, path, name, is_dir, size, modified, content_version,
              metadata_version, is_local, is_pinned, pending_upload, read_only, change_anchor, seen_token)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(r.itemID.rawValue), .text(r.parentID.rawValue), .text(r.folderID.rawValue),
                .text(r.path.rawValue), .text(r.path.lastComponent), .bool(r.isDirectory), .int(r.size),
                .real(r.modified.timeIntervalSince1970), .blob(r.contentVersion), .blob(r.metadataVersion),
                .bool(r.isLocal), .bool(r.isPinned), .bool(r.pendingUpload), .bool(r.isReadOnly),
                .int(r.changeAnchor), .int(seenToken),
            ])
        try ctx.db.run("DELETE FROM tombstones WHERE item_id=?", [.text(r.itemID.rawValue)])
    }

    private static func update(_ ctx: WriteContext, _ r: FileItemRecord) throws {
        try ctx.db.run(
            """
            UPDATE items SET parent_id=?, path=?, name=?, is_dir=?, size=?, modified=?, content_version=?,
              metadata_version=?, is_local=?, is_pinned=?, pending_upload=?, read_only=?, change_anchor=?
            WHERE item_id=?
            """,
            [
                .text(r.parentID.rawValue), .text(r.path.rawValue), .text(r.path.lastComponent),
                .bool(r.isDirectory), .int(r.size), .real(r.modified.timeIntervalSince1970),
                .blob(r.contentVersion), .blob(r.metadataVersion), .bool(r.isLocal), .bool(r.isPinned),
                .bool(r.pendingUpload), .bool(r.isReadOnly), .int(r.changeAnchor), .text(r.itemID.rawValue),
            ])
    }

    /// Deletes `path` and its descendants, writing tombstones.
    private static func deleteSubtree(_ ctx: WriteContext, folder: FolderID, path: RelativePath) throws {
        var ids: [String] = []
        let s = try ctx.db.prepare(
            "SELECT item_id FROM items WHERE folder_id=? AND (path=? OR (path>? AND path<?))")
        let prefix = path.rawValue + "/"
        try s.bind([.text(folder.rawValue), .text(path.rawValue), .text(prefix), .text(path.rawValue + "0")])
        while try s.step() == SQLITE_ROW { ids.append(s.text(at: 0)) }
        for id in ids {
            try deleteRow(ctx, folder: folder, id: id)
        }
    }

    private static func deleteRow(_ ctx: WriteContext, folder: FolderID, id: String) throws {
        try ctx.db.run("DELETE FROM items WHERE item_id=?", [.text(id)])
        try ctx.db.run("DELETE FROM materialized WHERE item_id=?", [.text(id)])
        try ctx.db.run(
            "INSERT OR REPLACE INTO tombstones(item_id, folder_id, change_anchor) VALUES (?,?,?)",
            [.text(id), .text(folder.rawValue), .int(ctx.nextAnchor())])
    }

    /// Returns the item id of directory `path`, creating placeholder rows for
    /// missing ancestors.
    private static func ensureDirectory(
        _ ctx: WriteContext, folder: FolderID, path: RelativePath, readOnly: Bool, seenToken: Int64,
        cache: inout [String: ItemIdentifier]
    ) throws -> ItemIdentifier {
        if path.isRoot { return rootItemID(folder) }
        if let cached = cache[path.rawValue] { return cached }
        if let existing = try fetchRecord(ctx.db, folder: folder, path: path) {
            cache[path.rawValue] = existing.itemID
            return existing.itemID
        }
        let parentID = try ensureDirectory(
            ctx, folder: folder, path: path.parent, readOnly: readOnly, seenToken: seenToken, cache: &cache)
        let record = FileItemRecord(
            itemID: newItemID(), parentID: parentID, folderID: folder, path: path, isDirectory: true, size: 0,
            modified: Date(timeIntervalSince1970: 0), contentVersion: directoryContentVersion,
            metadataVersion: Data("placeholder".utf8), isLocal: true, isPinned: false, pendingUpload: false,
            isReadOnly: readOnly, changeAnchor: ctx.nextAnchor())
        try insert(ctx, record, seenToken: seenToken)
        cache[path.rawValue] = record.itemID
        return record.itemID
    }

    static func newItemID() -> ItemIdentifier { ItemIdentifier(rawValue: UUID().uuidString.lowercased()) }

    static let directoryContentVersion = Data("dir".utf8)

    static func digest(_ string: String) -> Data {
        Data(SHA256.hash(data: Data(string.utf8)))
    }

    /// contentVersion = blocksHash (content only). Falls back to the version
    /// token when the engine did not supply blocksHash.
    static func contentVersion(for entry: GlobalIndexEntry) -> Data {
        if entry.type == .directory { return directoryContentVersion }
        if !entry.blocksHash.isEmpty {
            return Data(base64Encoded: entry.blocksHash) ?? digest(entry.blocksHash)
        }
        return digest("v:" + entry.version)
    }

    /// metadataVersion = version vector token + mtime (DESIGN.md §6.2).
    static func metadataVersion(version: String, modified: Date) -> Data {
        digest(version + "|" + String(Int64((modified.timeIntervalSince1970 * 1000).rounded())))
    }

    static func isValidPath(_ path: RelativePath) -> Bool {
        let raw = path.rawValue
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.hasSuffix("/") else { return false }
        return !raw.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0.isEmpty || $0 == "." || $0 == ".."
        }
    }

    /// Engine-internal names never shown in Files.
    static func isHidden(_ path: RelativePath) -> Bool {
        let first = path.rawValue.split(separator: "/").first.map(String.init) ?? ""
        return [".stfolder", ".stignore", ".stversions", ".stignore-user"].contains(first)
            || path.lastComponent.hasPrefix(".syncthing.") && path.lastComponent.hasSuffix(".tmp")
    }

    // MARK: Folders

    public func upsertFolder(_ info: FilesFolderInfo) throws {
        try write { ctx in
            try ctx.db.run(
                "INSERT OR REPLACE INTO folders(folder_id, label, read_only, content_mode) VALUES (?,?,?,?)",
                [.text(info.folderID.rawValue), .text(info.label), .bool(info.isReadOnly), .text(info.contentMode.rawValue)])
            let rootID = Self.rootItemID(info.folderID)
            let existing = try Self.fetchRecord(ctx.db, id: rootID)
            let metadata = Self.digest("root|" + info.label + "|" + String(info.isReadOnly))
            if existing == nil {
                try Self.insert(
                    ctx,
                    FileItemRecord(
                        itemID: rootID, parentID: rootID, folderID: info.folderID, path: .root, isDirectory: true,
                        size: 0, modified: Date(timeIntervalSince1970: 0), contentVersion: Self.directoryContentVersion,
                        metadataVersion: metadata, isLocal: true, isPinned: false, pendingUpload: false,
                        isReadOnly: info.isReadOnly, changeAnchor: ctx.nextAnchor()),
                    seenToken: 0)
            } else if existing?.metadataVersion != metadata {
                try ctx.db.run(
                    "UPDATE items SET metadata_version=?, read_only=?, change_anchor=? WHERE item_id=?",
                    [.blob(metadata), .bool(info.isReadOnly), .int(ctx.nextAnchor()), .text(rootID.rawValue)])
                try ctx.db.run(
                    "UPDATE items SET read_only=? WHERE folder_id=? AND read_only<>?",
                    [.bool(info.isReadOnly), .text(info.folderID.rawValue), .bool(info.isReadOnly)])
            }
        }
    }

    public func folderInfo(_ folder: FolderID) throws -> FilesFolderInfo? {
        try read { db in
            let s = try db.prepare("SELECT label, read_only, content_mode FROM folders WHERE folder_id=?")
            try s.bind([.text(folder.rawValue)])
            guard try s.step() == SQLITE_ROW else { return nil }
            return FilesFolderInfo(
                folderID: folder, label: s.text(at: 0), isReadOnly: s.bool(at: 1),
                contentMode: ContentMode(rawValue: s.text(at: 2)) ?? .everything)
        }
    }

    public func allFolders() throws -> [FilesFolderInfo] {
        let ids: [FolderID] = try read { db in
            let s = try db.prepare("SELECT folder_id FROM folders ORDER BY folder_id")
            var result: [FolderID] = []
            while try s.step() == SQLITE_ROW { result.append(FolderID(rawValue: s.text(at: 0))) }
            return result
        }
        return try ids.compactMap { try folderInfo($0) }
    }

    // MARK: Full-sync (mark & sweep) — App projector only

    /// Starts a full projection pass; rows not touched by `applyIndexBatch`
    /// before `finishFullSync` are deleted (except pending local writes).
    public func beginFullSync(_ folder: FolderID) throws {
        lock.withLock { activeSync[folder] = [] }
    }

    @discardableResult
    public func finishFullSync(_ folder: FolderID) throws -> Int64 {
        guard let seen = lock.withLock({ activeSync.removeValue(forKey: folder) }) else {
            return try currentAnchor()
        }
        return try write { ctx in
            var stale: [(String, String)] = []
            let s = try ctx.db.prepare(
                "SELECT item_id, path FROM items WHERE folder_id=? AND pending_upload=0 AND path<>''")
            try s.bind([.text(folder.rawValue)])
            while try s.step() == SQLITE_ROW {
                let path = s.text(at: 1)
                if !seen.contains(path) { stale.append((s.text(at: 0), path)) }
            }
            let suppressed = try Self.suppressedPaths(ctx.db, folder: folder)
            for (id, path) in stale where !Self.isUnder(RelativePath(rawValue: path), suppressed.pending) {
                try Self.deleteRow(ctx, folder: folder, id: id)
            }
            try Self.pruneTombstones(ctx, retention: tombstoneRetention)
            return ctx.anchor
        }
    }

    public func cancelFullSync(_ folder: FolderID) {
        lock.withLock { _ = activeSync.removeValue(forKey: folder) }
    }

    /// Paths with unacknowledged local mutations: deletions/moves (old path)
    /// must not be resurrected from a stale global index; new paths are
    /// protected by `pending_upload`.
    private static func suppressedPaths(_ db: SQLiteConnection, folder: FolderID) throws
        -> (removed: Set<String>, pending: Set<String>)
    {
        var removed = Set<String>()
        var pending = Set<String>()
        let s = try db.prepare("SELECT kind, path, previous_path FROM journal WHERE folder_id=?")
        try s.bind([.text(folder.rawValue)])
        while try s.step() == SQLITE_ROW {
            let kind = s.text(at: 0)
            if kind == LocalMutation.Kind.deleted.rawValue { removed.insert(s.text(at: 1)) }
            if kind == LocalMutation.Kind.moved.rawValue, let previous = s.optionalText(at: 2) { removed.insert(previous) }
            pending.insert(s.text(at: 1))
        }
        return (removed, pending)
    }

    private static func isUnder(_ path: RelativePath, _ set: Set<String>) -> Bool {
        guard !set.isEmpty else { return false }
        var current = path
        while !current.isRoot {
            if set.contains(current.rawValue) { return true }
            current = current.parent
        }
        return false
    }

    private static func pruneTombstones(_ ctx: WriteContext, retention: Int) throws {
        let count = try ctx.db.scalarInt64("SELECT COUNT(*) FROM tombstones") ?? 0
        guard count > Int64(retention) else { return }
        let excess = count - Int64(retention)
        guard
            let cutoff = try ctx.db.scalarInt64(
                "SELECT change_anchor FROM tombstones ORDER BY change_anchor LIMIT 1 OFFSET ?", [.int(excess - 1)])
        else { return }
        try ctx.db.run("DELETE FROM tombstones WHERE change_anchor<=?", [.int(cutoff)])
        try ctx.db.run("UPDATE meta SET value=MAX(value, ?) WHERE key='min_anchor'", [.int(cutoff)])
    }

    // MARK: Local writes (extension)

    /// Records a create/modify performed on disk by the extension. Keeps the
    /// identifier if the path already has one. contentVersion becomes a fresh
    /// local token (the engine's blocksHash replaces it after upload).
    @discardableResult
    public func recordLocalWrite(
        _ folder: FolderID, path: RelativePath, isDirectory: Bool, size: Int64, modified: Date
    ) throws -> FileItemRecord {
        guard Self.isValidPath(path) else { throw FilesStoreError.invalidPath(path.rawValue) }
        let readOnly = try folderInfo(folder)?.isReadOnly ?? false
        return try write { ctx in
            var cache: [String: ItemIdentifier] = [:]
            let parentID = try Self.ensureDirectory(
                ctx, folder: folder, path: path.parent, readOnly: readOnly, seenToken: 0, cache: &cache)
            let token = UUID().uuidString
            let content = isDirectory ? Self.directoryContentVersion : Self.digest("local:" + token)
            let metadata = Self.metadataVersion(version: "local:" + token, modified: modified)
            if var existing = try Self.fetchRecord(ctx.db, folder: folder, path: path) {
                if existing.isDirectory != isDirectory {
                    throw FilesStoreError.collision(path)
                }
                existing.size = size
                existing.modified = modified
                existing.contentVersion = content
                existing.metadataVersion = metadata
                existing.isLocal = true
                existing.pendingUpload = true
                existing.changeAnchor = ctx.nextAnchor()
                try Self.update(ctx, existing)
                return existing
            }
            let record = FileItemRecord(
                itemID: Self.newItemID(), parentID: parentID, folderID: folder, path: path, isDirectory: isDirectory,
                size: size, modified: modified, contentVersion: content, metadataVersion: metadata, isLocal: true,
                isPinned: false, pendingUpload: true, isReadOnly: readOnly, changeAnchor: ctx.nextAnchor())
            try Self.insert(ctx, record, seenToken: 0)
            return record
        }
    }

    @discardableResult
    public func recordLocalDelete(_ id: ItemIdentifier) throws -> Int64 {
        try write { ctx in
            guard let record = try Self.fetchRecord(ctx.db, id: id) else { throw FilesStoreError.noSuchItem }
            guard !record.path.isRoot else { throw FilesStoreError.invalidPath("") }
            try Self.deleteSubtree(ctx, folder: record.folderID, path: record.path)
            return ctx.anchor
        }
    }

    /// Restricted fetch / delegated download finished: the file is local at
    /// the record's version (no new content version).
    public func markLocal(_ id: ItemIdentifier, isLocal: Bool) throws {
        try write { ctx in
            guard var record = try Self.fetchRecord(ctx.db, id: id), record.isLocal != isLocal else { return }
            record.isLocal = isLocal
            record.changeAnchor = ctx.nextAnchor()
            try Self.update(ctx, record)
        }
    }

    /// App: the engine scanned these paths; stop shielding them from the projection.
    public func clearPendingUpload(_ folder: FolderID, paths: [RelativePath]) throws {
        guard !paths.isEmpty else { return }
        try write { ctx in
            for path in paths {
                let s = try ctx.db.prepare(
                    "SELECT item_id FROM items WHERE folder_id=? AND pending_upload=1 AND (path=? OR (path>? AND path<?))")
                try s.bind([
                    .text(folder.rawValue), .text(path.rawValue), .text(path.rawValue + "/"), .text(path.rawValue + "0"),
                ])
                var ids: [String] = []
                while try s.step() == SQLITE_ROW { ids.append(s.text(at: 0)) }
                for id in ids {
                    try ctx.db.run(
                        "UPDATE items SET pending_upload=0, change_anchor=? WHERE item_id=?",
                        [.int(ctx.nextAnchor()), .text(id)])
                }
            }
        }
    }

    /// Replaces the set of items the system has materialized for `folder`
    /// (from `NSFileProviderManager.enumeratorForMaterializedItems`).
    public func setMaterialized(_ folder: FolderID, ids: [ItemIdentifier]) throws {
        try write { ctx in
            try ctx.db.run("DELETE FROM materialized WHERE folder_id=?", [.text(folder.rawValue)])
            for id in ids {
                try ctx.db.run(
                    "INSERT OR IGNORE INTO materialized(item_id, folder_id) VALUES (?,?)",
                    [.text(id.rawValue), .text(folder.rawValue)])
            }
        }
    }

    // MARK: Presence requests (pin / remove download)

    public func requestPresence(_ folder: FolderID, path: RelativePath, present: Bool) throws {
        try write { ctx in
            try ctx.db.run(
                "INSERT OR REPLACE INTO presence(folder_id, path, present) VALUES (?,?,?)",
                [.text(folder.rawValue), .text(path.rawValue), .bool(present)])
        }
    }

    public func pendingPresence() throws -> [PresenceRequest] {
        try read { db in
            let s = try db.prepare("SELECT folder_id, path, present FROM presence ORDER BY folder_id, path")
            var result: [PresenceRequest] = []
            while try s.step() == SQLITE_ROW {
                result.append(
                    PresenceRequest(
                        folderID: FolderID(rawValue: s.text(at: 0)), path: RelativePath(rawValue: s.text(at: 1)),
                        present: s.bool(at: 2)))
            }
            return result
        }
    }

    public func acknowledgePresence(_ requests: [PresenceRequest]) throws {
        try write { ctx in
            for r in requests {
                try ctx.db.run(
                    "DELETE FROM presence WHERE folder_id=? AND path=? AND present=?",
                    [.text(r.folderID.rawValue), .text(r.path.rawValue), .bool(r.present)])
            }
        }
    }

    public func currentAnchor() throws -> Int64 {
        try read { db in try db.scalarInt64("SELECT value FROM meta WHERE key='anchor'") ?? 0 }
    }

    func minimumAnchor() throws -> Int64 {
        try read { db in try db.scalarInt64("SELECT value FROM meta WHERE key='min_anchor'") ?? 0 }
    }

    /// Diagnostics / tests.
    public func itemCount(_ folder: FolderID) throws -> Int {
        try read { db in
            Int(try db.scalarInt64("SELECT COUNT(*) FROM items WHERE folder_id=?", [.text(folder.rawValue)]) ?? 0)
        }
    }

    public func record(folder: FolderID, path: RelativePath) throws -> FileItemRecord? {
        try read { db in try Self.fetchRecord(db, folder: folder, path: path) }
    }
}

// MARK: - FilesMetadataWriter

extension FilesStore: FilesMetadataWriter {
    public func applyIndexBatch(_ folder: FolderID, entries: [GlobalIndexEntry]) throws -> Int64 {
        let token: Int64 = 0
        let tracking = lock.withLock { activeSync[folder] != nil }
        var seen = Set<String>()
        defer {
            if tracking { lock.withLock { activeSync[folder]?.formUnion(seen) } }
        }
        let info = try folderInfo(folder)
        let readOnly = info?.isReadOnly ?? false
        return try write { ctx in
            let suppressed = try Self.suppressedPaths(ctx.db, folder: folder)
            var cache: [String: ItemIdentifier] = [:]
            for entry in entries {
                let path = entry.name
                guard Self.isValidPath(path), !Self.isHidden(path), entry.type != .symlink else { continue }
                let existing = try Self.fetchRecord(ctx.db, folder: folder, path: path)
                if tracking && !entry.deleted && !entry.invalid {
                    var p = path
                    while !p.isRoot, seen.insert(p.rawValue).inserted { p = p.parent }
                }
                if let existing, existing.pendingUpload { continue }
                if entry.deleted || entry.invalid {
                    if existing != nil { try Self.deleteSubtree(ctx, folder: folder, path: path) }
                    continue
                }
                if Self.isUnder(path, suppressed.removed) { continue }

                let isDirectory = entry.type == .directory
                let content = Self.contentVersion(for: entry)
                let metadata = Self.metadataVersion(version: entry.version, modified: entry.modified)
                if var row = existing, row.isDirectory == isDirectory {
                    let size = isDirectory ? 0 : entry.size
                    let changed =
                        row.size != size || row.contentVersion != content || row.metadataVersion != metadata
                        || row.isLocal != entry.localPresent || row.isReadOnly != readOnly
                    if changed {
                        row.size = size
                        row.modified = entry.modified
                        row.contentVersion = content
                        row.metadataVersion = metadata
                        row.isLocal = entry.localPresent
                        row.isReadOnly = readOnly
                        row.changeAnchor = ctx.nextAnchor()
                        try Self.update(ctx, row)
                    }
                    cache[path.rawValue] = row.itemID
                    continue
                }
                if existing != nil {
                    // Type changed (file <-> directory): new identity.
                    try Self.deleteSubtree(ctx, folder: folder, path: path)
                }
                let parentID = try Self.ensureDirectory(
                    ctx, folder: folder, path: path.parent, readOnly: readOnly, seenToken: token, cache: &cache)
                let record = FileItemRecord(
                    itemID: Self.newItemID(), parentID: parentID, folderID: folder, path: path,
                    isDirectory: isDirectory, size: isDirectory ? 0 : entry.size, modified: entry.modified,
                    contentVersion: content, metadataVersion: metadata, isLocal: entry.localPresent, isPinned: false,
                    pendingUpload: false, isReadOnly: readOnly, changeAnchor: ctx.nextAnchor())
                try Self.insert(ctx, record, seenToken: token)
                if isDirectory { cache[path.rawValue] = record.itemID }
            }
            return ctx.anchor
        }
    }

    public func removeFolder(_ folder: FolderID) throws -> Int64 {
        try write { ctx in
            for table in ["items", "tombstones", "materialized", "journal", "requests", "presence", "folders"] {
                try ctx.db.run("DELETE FROM \(table) WHERE folder_id=?", [.text(folder.rawValue)])
            }
            return ctx.anchor
        }
    }

    public func setPinned(_ id: ItemIdentifier, pinned: Bool) throws -> Int64 {
        try write { ctx in
            guard var record = try Self.fetchRecord(ctx.db, id: id) else { throw FilesStoreError.noSuchItem }
            if record.isPinned != pinned {
                record.isPinned = pinned
                record.changeAnchor = ctx.nextAnchor()
                try Self.update(ctx, record)
            }
            return ctx.anchor
        }
    }

    /// Local rename/move through Files: keeps the identifier, rewrites the
    /// subtree's paths and marks the subtree pending until the App scans it.
    public func moveIdentity(_ id: ItemIdentifier, to path: RelativePath, in folder: FolderID) throws -> Int64 {
        guard Self.isValidPath(path) else { throw FilesStoreError.invalidPath(path.rawValue) }
        let readOnly = try folderInfo(folder)?.isReadOnly ?? false
        return try write { ctx in
            guard var record = try Self.fetchRecord(ctx.db, id: id), !record.path.isRoot else {
                throw FilesStoreError.noSuchItem
            }
            guard record.folderID == folder else { throw FilesStoreError.invalidPath("cross-folder move") }
            let oldPath = record.path
            if oldPath == path { return ctx.anchor }
            if path.rawValue.hasPrefix(oldPath.rawValue + "/") { throw FilesStoreError.invalidPath("move into itself") }
            if let occupant = try Self.fetchRecord(ctx.db, folder: folder, path: path) {
                guard occupant.itemID != id else { return ctx.anchor }
                try Self.deleteSubtree(ctx, folder: folder, path: path)
            }
            var cache: [String: ItemIdentifier] = [:]
            record.parentID = try Self.ensureDirectory(
                ctx, folder: folder, path: path.parent, readOnly: readOnly, seenToken: 0, cache: &cache)
            record.path = path
            record.pendingUpload = true
            record.metadataVersion = Self.digest(UUID().uuidString)
            record.changeAnchor = ctx.nextAnchor()
            try Self.update(ctx, record)
            if record.isDirectory {
                // Descendants keep their ids/parents; only stored paths move.
                let oldPrefix = oldPath.rawValue + "/"
                try ctx.db.run(
                    """
                    UPDATE items SET path = ? || substr(path, ?), pending_upload = 1
                    WHERE folder_id=? AND path>? AND path<?
                    """,
                    [
                        .text(path.rawValue + "/"), .int(Int64(oldPrefix.utf8.count + 1)), .text(folder.rawValue),
                        .text(oldPrefix), .text(oldPath.rawValue + "0"),
                    ])
            }
            return ctx.anchor
        }
    }
}

// MARK: - LocalMutationJournal

extension FilesStore: LocalMutationJournal {
    public func append(_ folder: FolderID, kind: LocalMutation.Kind, path: RelativePath, previousPath: RelativePath?) throws {
        try write { ctx in
            try ctx.db.run(
                "INSERT INTO journal(folder_id, kind, path, previous_path, recorded_at) VALUES (?,?,?,?,?)",
                [
                    .text(folder.rawValue), .text(kind.rawValue), .text(path.rawValue),
                    .optionalText(previousPath?.rawValue), .real(Date().timeIntervalSince1970),
                ])
        }
    }

    public func pending(limit: Int) throws -> [LocalMutation] {
        try read { db in
            let s = try db.prepare(
                "SELECT seq, folder_id, kind, path, previous_path, recorded_at FROM journal ORDER BY seq LIMIT ?")
            try s.bind([.int(Int64(limit))])
            var result: [LocalMutation] = []
            while try s.step() == SQLITE_ROW {
                result.append(
                    LocalMutation(
                        sequence: s.int64(at: 0), folderID: FolderID(rawValue: s.text(at: 1)),
                        kind: LocalMutation.Kind(rawValue: s.text(at: 2)) ?? .modified,
                        path: RelativePath(rawValue: s.text(at: 3)),
                        previousPath: s.optionalText(at: 4).map(RelativePath.init(rawValue:)),
                        recordedAt: Date(timeIntervalSince1970: s.double(at: 5))))
            }
            return result
        }
    }

    public func acknowledge(through sequence: Int64) throws {
        try write { ctx in try ctx.db.run("DELETE FROM journal WHERE seq<=?", [.int(sequence)]) }
    }
}

// MARK: - ContentRequestInbox

extension FilesStore: ContentRequestInbox {
    public func post(_ folder: FolderID, path: RelativePath, version: Data) throws -> ContentRequest {
        let request = ContentRequest(
            id: UUID(), folderID: folder, path: path, requestedVersion: version, state: .posted, failureCode: nil,
            postedAt: Date())
        try write { ctx in
            // Superseded requests for the same path are dropped.
            try ctx.db.run(
                "DELETE FROM requests WHERE folder_id=? AND path=? AND state IN ('completed','failed')",
                [.text(folder.rawValue), .text(path.rawValue)])
            try ctx.db.run(
                """
                INSERT INTO requests(id, folder_id, path, requested_version, state, failure_code, posted_at, updated_at)
                VALUES (?,?,?,?,?,NULL,?,?)
                """,
                [
                    .text(request.id.uuidString), .text(folder.rawValue), .text(path.rawValue), .blob(version),
                    .text(request.state.rawValue), .real(request.postedAt.timeIntervalSince1970),
                    .real(request.postedAt.timeIntervalSince1970),
                ])
        }
        return request
    }

    public func get(_ id: UUID) throws -> ContentRequest? {
        try read { db in
            let s = try db.prepare(
                "SELECT id, folder_id, path, requested_version, state, failure_code, posted_at FROM requests WHERE id=?")
            try s.bind([.text(id.uuidString)])
            return try s.step() == SQLITE_ROW ? Self.request(from: s) : nil
        }
    }

    public func update(_ id: UUID, state: ContentRequest.State, failureCode: String?) throws {
        try write { ctx in
            try ctx.db.run(
                "UPDATE requests SET state=?, failure_code=?, updated_at=? WHERE id=?",
                [.text(state.rawValue), .optionalText(failureCode), .real(Date().timeIntervalSince1970), .text(id.uuidString)])
        }
    }

    public func open(limit: Int) throws -> [ContentRequest] {
        try read { db in
            let s = try db.prepare(
                """
                SELECT id, folder_id, path, requested_version, state, failure_code, posted_at FROM requests
                WHERE state IN ('posted','accepted') ORDER BY posted_at LIMIT ?
                """)
            try s.bind([.int(Int64(limit))])
            var result: [ContentRequest] = []
            while try s.step() == SQLITE_ROW { result.append(Self.request(from: s)) }
            return result
        }
    }

    /// Housekeeping: drop finished requests older than `age`.
    public func pruneRequests(olderThan age: TimeInterval) throws {
        try write { ctx in
            try ctx.db.run(
                "DELETE FROM requests WHERE state IN ('completed','failed') AND updated_at<?",
                [.real(Date().timeIntervalSince1970 - age)])
        }
    }

    private static func request(from s: SQLiteStatement) -> ContentRequest {
        ContentRequest(
            id: UUID(uuidString: s.text(at: 0)) ?? UUID(), folderID: FolderID(rawValue: s.text(at: 1)),
            path: RelativePath(rawValue: s.text(at: 2)), requestedVersion: s.data(at: 3),
            state: ContentRequest.State(rawValue: s.text(at: 4)) ?? .failed, failureCode: s.optionalText(at: 5),
            postedAt: Date(timeIntervalSince1970: s.double(at: 6)))
    }
}

// MARK: - Reader (one per folder / File Provider domain)

/// `FilesMetadataReader` scoped to one folder (= one NSFileProvider domain).
public struct FolderFilesReader: FilesMetadataReader {
    let store: FilesStore
    public let folder: FolderID

    public var rootID: ItemIdentifier { FilesStore.rootItemID(folder) }

    public func item(_ id: ItemIdentifier) throws -> FileItemRecord? {
        try store.read { db in
            guard let record = try FilesStore.fetchRecord(db, id: id), record.folderID == folder else { return nil }
            return record
        }
    }

    public func item(at path: RelativePath) throws -> FileItemRecord? {
        try store.read { db in try FilesStore.fetchRecord(db, folder: folder, path: path) }
    }

    public func children(of parent: ItemIdentifier, after cursor: String?, limit: Int) throws
        -> (items: [FileItemRecord], next: String?)
    {
        try store.read { db in
            let s = try db.prepare(
                """
                SELECT \(FilesStore.columns), name FROM items
                WHERE parent_id=? AND name>? AND item_id<>? ORDER BY name LIMIT ?
                """)
            try s.bind([.text(parent.rawValue), .text(cursor ?? ""), .text(rootID.rawValue), .int(Int64(limit + 1))])
            var items: [FileItemRecord] = []
            var lastName = ""
            while try s.step() == SQLITE_ROW {
                if items.count == limit { return (items, lastName) }
                items.append(FilesStore.record(from: s))
                lastName = s.text(at: 14)
            }
            return (items, nil)
        }
    }

    public func changes(since anchor: Int64, limit: Int) throws
        -> (updated: [FileItemRecord], deleted: [ItemIdentifier], newAnchor: Int64, more: Bool)
    {
        try changes(since: anchor, limit: limit, workingSetOnly: false)
    }

    /// Working-set changes: only rows the system can know about (materialized,
    /// children of materialized directories, pinned, pending, local in
    /// on-demand folders) plus all tombstones.
    public func changes(since anchor: Int64, limit: Int, workingSetOnly: Bool) throws
        -> (updated: [FileItemRecord], deleted: [ItemIdentifier], newAnchor: Int64, more: Bool)
    {
        if anchor < (try store.minimumAnchor()) { throw FilesStoreError.anchorExpired }
        let onDemand = try store.folderInfo(folder)?.contentMode == .onDemand
        return try store.read { db in
            let filter = workingSetOnly ? "AND (\(Self.workingSetPredicate(onDemand: onDemand)))" : ""
            let s = try db.prepare(
                """
                SELECT kind, item_id, change_anchor FROM (
                  SELECT 0 AS kind, item_id, change_anchor FROM items
                    WHERE folder_id=?1 AND change_anchor>?2 \(filter)
                  UNION ALL
                  SELECT 1 AS kind, item_id, change_anchor FROM tombstones WHERE folder_id=?1 AND change_anchor>?2
                ) ORDER BY change_anchor LIMIT ?3
                """)
            try s.bind([.text(folder.rawValue), .int(anchor), .int(Int64(limit + 1))])
            var rows: [(Bool, String, Int64)] = []
            while try s.step() == SQLITE_ROW {
                rows.append((s.int64(at: 0) == 1, s.text(at: 1), s.int64(at: 2)))
            }
            let more = rows.count > limit
            if more { rows.removeLast() }
            var updated: [FileItemRecord] = []
            var deleted: [ItemIdentifier] = []
            for (isTombstone, id, _) in rows {
                if isTombstone {
                    deleted.append(ItemIdentifier(rawValue: id))
                } else if let record = try FilesStore.fetchRecord(db, id: ItemIdentifier(rawValue: id)) {
                    updated.append(record)
                }
            }
            let current = try db.scalarInt64("SELECT value FROM meta WHERE key='anchor'") ?? 0
            let newAnchor = more ? (rows.last?.2 ?? anchor) : max(current, anchor)
            return (updated, deleted, newAnchor, more)
        }
    }

    private static func workingSetPredicate(onDemand: Bool) -> String {
        var terms = [
            "is_pinned=1", "pending_upload=1",
            "item_id IN (SELECT item_id FROM materialized)",
            "parent_id IN (SELECT item_id FROM materialized)",
        ]
        if onDemand { terms.append("(is_local=1 AND is_dir=0)") }
        return terms.joined(separator: " OR ")
    }

    public func currentAnchor() throws -> Int64 { try store.currentAnchor() }

    public func workingSet(after cursor: String?, limit: Int) throws -> (items: [FileItemRecord], next: String?) {
        let onDemand = try store.folderInfo(folder)?.contentMode == .onDemand
        return try store.read { db in
            let s = try db.prepare(
                """
                SELECT \(FilesStore.columns) FROM items
                WHERE folder_id=? AND item_id>? AND item_id<>? AND (\(Self.workingSetPredicate(onDemand: onDemand)))
                ORDER BY item_id LIMIT ?
                """)
            try s.bind([.text(folder.rawValue), .text(cursor ?? ""), .text(rootID.rawValue), .int(Int64(limit + 1))])
            var items: [FileItemRecord] = []
            while try s.step() == SQLITE_ROW {
                if items.count == limit { return (items, items.last?.itemID.rawValue) }
                items.append(FilesStore.record(from: s))
            }
            return (items, nil)
        }
    }
}
