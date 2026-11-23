import Foundation
import SQLite3

/// What "Remove Download" does for one selected item in an on-demand folder:
/// which paths drop their engine copy (`requestPresence(false)`) and have the
/// Files copy evicted, and which are left alone.
///
/// The item need not be pinned: a file downloaded on demand (or present from
/// before the switch to on-demand) is removable too, like iCloud's "Remove
/// Download". The engine copy is dropped by re-ignoring the path, never by a
/// delete that syncs (LiveSyncEngine.setLocalPresence: rules first, then
/// the file), so the item stays in Files as a cloud item and downloads again
/// on open.
///
/// Never loses data:
/// - a file with a local change the engine has not scanned yet
///   (`pendingUpload`) keeps its engine copy; a directory holding one is
///   handled file by file, skipping those;
/// - edits the system has not handed to the extension yet stay in the Files
///   copy: the system refuses to evict them (NSFileProviderErrorUnsyncedEdits).
///
/// Below a pinned ("Keep Downloaded") directory nothing drops alone: the pin
/// is the user's intent for the whole directory (and an evicted copy would be
/// brought back by the materializer). Such paths are skipped; removing the
/// download of the pinned directory removes them. Below a directory kept as
/// one rule only because it was fully local at the switch to on-demand, the
/// engine splits that rule (LiveSyncEngine.splitKept), so the path drops.
public struct RemoveDownloadPlan: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public var itemID: ItemIdentifier
        public var path: RelativePath
        public var isDirectory: Bool
    }

    public enum SkipReason: String, Equatable, Sendable {
        case pendingUpload
        case pinnedAncestor
    }

    public struct Skip: Equatable, Sendable {
        public var path: RelativePath
        public var reason: SkipReason
    }

    /// Request presence false and evict, in this order.
    public var targets: [Target] = []
    public var skipped: [Skip] = []

    /// The selected item itself is removed (not only parts of it): only then
    /// does it lose its pin.
    public func removesItem(_ id: ItemIdentifier) -> Bool { targets.contains { $0.itemID == id } }
}

extension FilesStore {
    public func removeDownloadPlan(_ folder: FolderID, item id: ItemIdentifier) throws -> RemoveDownloadPlan {
        try read { db in
            guard let record = try Self.fetchRecord(db, id: id), record.folderID == folder else {
                throw FilesStoreError.noSuchItem
            }
            var plan = RemoveDownloadPlan()
            if !record.path.isRoot, try Self.hasPinnedAncestor(db, record) {
                plan.skipped.append(.init(path: record.path, reason: .pinnedAncestor))
                return plan
            }
            guard record.isDirectory else {
                if record.pendingUpload {
                    plan.skipped.append(.init(path: record.path, reason: .pendingUpload))
                } else {
                    plan.targets.append(.init(itemID: record.itemID, path: record.path, isDirectory: false))
                }
                return plan
            }
            // The root has no rule of its own; and a directory with a pending
            // file below cannot drop as a whole (that deletes the pending file).
            let files = try Self.subtreeFiles(db, folder: folder, under: record.path)
            if !record.path.isRoot, !files.contains(where: \.pendingUpload) {
                plan.targets.append(.init(itemID: record.itemID, path: record.path, isDirectory: true))
                return plan
            }
            for f in files where f.isLocal || f.pendingUpload {
                if f.pendingUpload {
                    plan.skipped.append(.init(path: f.path, reason: .pendingUpload))
                } else if try Self.hasPinnedAncestor(db, f) {
                    plan.skipped.append(.init(path: f.path, reason: .pinnedAncestor))
                } else {
                    plan.targets.append(.init(itemID: f.itemID, path: f.path, isDirectory: false))
                }
            }
            return plan
        }
    }

    private static func subtreeFiles(_ db: SQLiteConnection, folder: FolderID, under path: RelativePath) throws
        -> [FileItemRecord]
    {
        let s: SQLiteStatement
        if path.isRoot {
            s = try db.prepare("SELECT \(columns) FROM items WHERE folder_id=? AND is_dir=0 ORDER BY path")
            try s.bind([.text(folder.rawValue)])
        } else {
            s = try db.prepare(
                "SELECT \(columns) FROM items WHERE folder_id=? AND is_dir=0 AND path>? AND path<? ORDER BY path")
            try s.bind([.text(folder.rawValue), .text(path.rawValue + "/"), .text(path.rawValue + "0")])
        }
        var out: [FileItemRecord] = []
        while try s.step() == SQLITE_ROW { out.append(record(from: s)) }
        return out
    }
}
