import Foundation
import SQLite3

public enum IndexedMetadataStoreError: Error, Equatable, Sendable {
    case sqlite(code: Int32, message: String)
    case databaseClosed
    case readOnly
    case unsupportedSnapshotSchema(Int)
    case unsupportedDatabaseSchema(Int)
    case generationRegression(current: UInt64, proposed: UInt64)
    case generationCollision(UInt64)
    case generationOutOfRange(UInt64)
    case invalidPageSize(Int)
    case emptySearchQuery
    case invalidStoredValue(String)
    case integrityCheckFailed(String)
}

public enum IndexedMetadataAccessMode: Sendable {
    case readWrite
    case readOnly
}

public enum IndexedMetadataRecoveryPolicy: Sendable {
    case fail
    case backupAndRecreate
}

public enum IndexedMetadataSearchBackend: String, Sendable {
    case fullText
    case likeFallback
}

public struct IndexedItemPageCursor: Codable, Hashable, Sendable {
    public let relativePath: String
    public let itemID: String

    public init(relativePath: String, itemID: String) {
        self.relativePath = relativePath
        self.itemID = itemID
    }
}

public struct IndexedItemPage: Hashable, Sendable {
    public let items: [IndexedItem]
    public let nextCursor: IndexedItemPageCursor?

    public init(items: [IndexedItem], nextCursor: IndexedItemPageCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum IndexedMetadataChangeKind: Int, Codable, Hashable, Sendable {
    case upsert = 1
    case delete = 2
}

/// The minimum prior metadata needed to route a stable item identifier between
/// File Provider containers. Keeping this in the journal prevents a move from
/// becoming invisible to the enumerator for the item's former parent.
public struct IndexedMetadataItemRoute: Hashable, Sendable {
    public let folderID: FolderID
    public let parentID: String?
    public let isInWorkingSet: Bool

    public init(folderID: FolderID, parentID: String?, isInWorkingSet: Bool) {
        self.folderID = folderID
        self.parentID = parentID
        self.isInWorkingSet = isInWorkingSet
    }

    public init(item: IndexedItem) {
        self.init(
            folderID: item.folderID,
            parentID: item.parentID,
            isInWorkingSet: true
        )
    }

    fileprivate func isIncluded(in scope: IndexedMetadataContainerScope) -> Bool {
        switch scope {
        case .workingSet:
            true
        case .folderWorkingSet(let folderID):
            self.folderID == folderID
        case .folderRoot(let folderID):
            self.folderID == folderID && parentID == nil
        case .directory(let itemID):
            parentID == itemID
        }
    }
}

public enum IndexedMetadataContainerScope: Hashable, Sendable {
    case workingSet
    case folderWorkingSet(FolderID)
    case folderRoot(FolderID)
    case directory(itemID: String)
}

public enum IndexedMetadataChangeEffect: Hashable, Sendable {
    case none
    case update(IndexedItem)
    case delete
}

public struct IndexedMetadataChangeCursor: Codable, Hashable, Sendable {
    public let generation: UInt64
    public let sequence: Int64
    /// Number of journal rows delivered from the enumeration's lower-bound
    /// generation through this cursor. File Provider continuation anchors use
    /// this to prove that a cursor still names a complete page boundary.
    public let rowOffset: UInt64

    public init(generation: UInt64, sequence: Int64, rowOffset: UInt64 = 0) {
        self.generation = generation
        self.sequence = sequence
        self.rowOffset = rowOffset
    }
}

public struct IndexedMetadataChange: Hashable, Sendable {
    public let generation: UInt64
    public let sequence: Int64
    public let itemID: String
    public let kind: IndexedMetadataChangeKind
    public let currentItem: IndexedItem?
    /// False only for journal entries written before route-aware schema v3.
    /// Readers handle those entries conservatively so an upgraded domain cannot
    /// retain a ghost child under an unknown former parent.
    public let previousRouteWasRecorded: Bool
    public let previousRoute: IndexedMetadataItemRoute?

    public init(
        generation: UInt64,
        sequence: Int64,
        itemID: String,
        kind: IndexedMetadataChangeKind,
        currentItem: IndexedItem?,
        previousRouteWasRecorded: Bool = true,
        previousRoute: IndexedMetadataItemRoute? = nil
    ) {
        self.generation = generation
        self.sequence = sequence
        self.itemID = itemID
        self.kind = kind
        self.currentItem = currentItem
        self.previousRouteWasRecorded = previousRouteWasRecorded
        self.previousRoute = previousRoute
    }

    /// Produces the one final observer action needed for this journal row and
    /// container. Deletions intentionally remain domain-wide, matching the
    /// existing Files deletion propagation semantics for pathless tombstones.
    public func effect(in scope: IndexedMetadataContainerScope) -> IndexedMetadataChangeEffect {
        if kind == .delete {
            return .delete
        }

        if let currentItem, IndexedMetadataItemRoute(item: currentItem).isIncluded(in: scope) {
            return .update(currentItem)
        }

        if !previousRouteWasRecorded {
            // A v2 journal row has no former route. A deletion is a safe no-op in
            // unrelated containers and repairs any legacy stale membership.
            return .delete
        }
        if let previousRoute, previousRoute.isIncluded(in: scope) {
            return .delete
        }
        return .none
    }
}

public struct IndexedMetadataChangePage: Hashable, Sendable {
    public let changes: [IndexedMetadataChange]
    public let nextCursor: IndexedMetadataChangeCursor?
    public let currentGeneration: UInt64?

    public init(
        changes: [IndexedMetadataChange],
        nextCursor: IndexedMetadataChangeCursor?,
        currentGeneration: UInt64?
    ) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.currentGeneration = currentGeneration
    }
}

/// Result of a File Provider change-journal read whose generation, retention
/// coverage, and continuation boundary were validated in one SQLite snapshot.
public enum IndexedMetadataValidatedChangeResult: Hashable, Sendable {
    case page(IndexedMetadataChangePage)
    case expired
}

public struct IndexedMetadataTombstoneCursor: Codable, Hashable, Sendable {
    public let generation: UInt64
    public let itemID: String

    public init(generation: UInt64, itemID: String) {
        self.generation = generation
        self.itemID = itemID
    }
}

public struct IndexedMetadataTombstonePage: Hashable, Sendable {
    public let tombstones: [IndexTombstone]
    public let nextCursor: IndexedMetadataTombstoneCursor?

    public init(tombstones: [IndexTombstone], nextCursor: IndexedMetadataTombstoneCursor?) {
        self.tombstones = tombstones
        self.nextCursor = nextCursor
    }
}

public struct IndexedMetadataImportResult: Hashable, Sendable {
    public let generation: UInt64
    public let insertedOrUpdatedItems: Int
    public let deletedItems: Int
    public let recordedTombstones: Int

    public init(
        generation: UInt64,
        insertedOrUpdatedItems: Int,
        deletedItems: Int,
        recordedTombstones: Int
    ) {
        self.generation = generation
        self.insertedOrUpdatedItems = insertedOrUpdatedItems
        self.deletedItems = deletedItems
        self.recordedTombstones = recordedTombstones
    }
}

public actor IndexedMetadataStore {
    public static let currentSchemaVersion = 4
    public static let maximumPageSize = 1_000

    /// Mirrors SQLite's default BINARY ordering for the UTF-8 TEXT columns
    /// used by every keyset page. Snapshot fallback must use this exact order
    /// so switching backends cannot skip or duplicate non-ASCII filenames.
    public static func binaryItemOrderPrecedes(_ lhs: IndexedItem, _ rhs: IndexedItem) -> Bool {
        let leftPath = lhs.relativePath.utf8
        let rightPath = rhs.relativePath.utf8
        if !leftPath.elementsEqual(rightPath) {
            return leftPath.lexicographicallyPrecedes(rightPath)
        }
        return lhs.id.utf8.lexicographicallyPrecedes(rhs.id.utf8)
    }

    public let databaseURL: URL
    public let accessMode: IndexedMetadataAccessMode
    public let recoveryPolicy: IndexedMetadataRecoveryPolicy
    public private(set) var recoveryBackupURL: URL?

    private var database: SQLiteDatabase
    private var usesFullTextSearch: Bool

    private static let itemColumns = """
        i.item_id, i.folder_id, i.parent_id, i.relative_path, i.is_directory,
        i.size, i.modified_at, i.content_version, i.metadata_version,
        i.availability, i.is_pinned, i.has_unuploaded_changes,
        i.remote_replica_count, i.generation
        """

    public init(
        databaseURL: URL,
        accessMode: IndexedMetadataAccessMode = .readWrite,
        recoveryPolicy: IndexedMetadataRecoveryPolicy = .backupAndRecreate
    ) throws {
        self.databaseURL = databaseURL
        self.accessMode = accessMode
        self.recoveryPolicy = recoveryPolicy

        var backupURL: URL?
        let opened: OpenedDatabase
        do {
            opened = try Self.openDatabase(at: databaseURL, accessMode: accessMode)
        } catch let error as IndexedMetadataStoreError {
            guard accessMode == .readWrite,
                recoveryPolicy == .backupAndRecreate,
                Self.isRecoverable(error)
            else {
                throw error
            }
            backupURL = try Self.backUpDatabase(at: databaseURL)
            opened = try Self.openDatabase(at: databaseURL, accessMode: accessMode)
        }

        database = opened.database
        usesFullTextSearch = opened.usesFullTextSearch
        recoveryBackupURL = backupURL
        if let backupURL {
            try? Self.pruneRecoveryBackups(at: databaseURL, keeping: backupURL)
        }
        Self.applyFileProtectionIfAvailable(to: databaseURL)
    }

    public var searchBackend: IndexedMetadataSearchBackend {
        usesFullTextSearch ? .fullText : .likeFallback
    }

    public func schemaVersion() throws -> Int {
        Int(try database.scalarInt64("PRAGMA user_version") ?? 0)
    }

    public func currentGeneration() throws -> UInt64? {
        let statement = try database.prepare("SELECT current_generation FROM store_state WHERE singleton = 1")
        guard try statement.step() == SQLITE_ROW, !statement.isNull(at: 0) else { return nil }
        return try Self.decodeGeneration(statement.int64(at: 0))
    }

    public func itemCount(inFolder folderID: FolderID? = nil) throws -> Int {
        if let folderID {
            let statement = try database.prepare("SELECT COUNT(*) FROM items WHERE folder_id = ?")
            try statement.bind(folderID.rawValue, at: 1)
            _ = try statement.step()
            return Int(statement.int64(at: 0))
        }
        return Int(try database.scalarInt64("SELECT COUNT(*) FROM items") ?? 0)
    }

    public func item(identifier: String) throws -> IndexedItem? {
        let statement = try database.prepare(
            "SELECT \(Self.itemColumns) FROM items i WHERE i.item_id = ? LIMIT 1"
        )
        try statement.bind(identifier, at: 1)
        guard try statement.step() == SQLITE_ROW else { return nil }
        return try Self.decodeItem(from: statement, offset: 0)
    }

    public func item(identifier: String, expectedGeneration: UInt64) throws -> IndexedItem? {
        try database.transaction(mode: "DEFERRED") {
            guard try currentGeneration() == expectedGeneration else {
                throw IndexedMetadataStoreError.generationCollision(expectedGeneration)
            }
            return try item(identifier: identifier)
        }
    }

    public func item(inFolder folderID: FolderID, relativePath: String, expectedGeneration: UInt64) throws
        -> IndexedItem?
    {
        try database.transaction(mode: "DEFERRED") {
            guard try currentGeneration() == expectedGeneration else {
                throw IndexedMetadataStoreError.generationCollision(expectedGeneration)
            }
            return try item(inFolder: folderID, relativePath: relativePath)
        }
    }

    /// Resolves the authoritative item at a Syncthing folder-relative path without
    /// scanning an entire folder page. More than one ID at the same path is treated
    /// as corrupt metadata instead of choosing an arbitrary target for a mutation.
    public func item(inFolder folderID: FolderID, relativePath: String) throws -> IndexedItem? {
        let statement = try database.prepare(
            "SELECT \(Self.itemColumns) FROM items i "
                + "WHERE i.folder_id = ? AND i.relative_path = ? ORDER BY i.item_id LIMIT 2"
        )
        try statement.bind(folderID.rawValue, at: 1)
        try statement.bind(relativePath, at: 2)
        guard try statement.step() == SQLITE_ROW else { return nil }
        let item = try Self.decodeItem(from: statement, offset: 0)
        guard try statement.step() != SQLITE_ROW else {
            throw IndexedMetadataStoreError.invalidStoredValue("duplicate folder-relative path")
        }
        return item
    }

    @discardableResult
    public func importSnapshot(_ snapshot: CoreSnapshot) throws -> IndexedMetadataImportResult {
        guard accessMode == .readWrite else { throw IndexedMetadataStoreError.readOnly }
        guard snapshot.schemaVersion == 1 else {
            throw IndexedMetadataStoreError.unsupportedSnapshotSchema(snapshot.schemaVersion)
        }
        let snapshotGeneration = try Self.encodeGeneration(snapshot.generation)

        let result = try database.transaction {
            // Re-read after BEGIN IMMEDIATE acquires the writer lock. A value read
            // before the transaction could become stale when the app and its
            // extension open independent connections to the App Group database.
            let priorGeneration = try currentGeneration()
            if let priorGeneration, snapshot.generation < priorGeneration {
                throw IndexedMetadataStoreError.generationRegression(
                    current: priorGeneration,
                    proposed: snapshot.generation
                )
            }

            let clearOldTombstone = try database.prepare(
                "DELETE FROM tombstones WHERE item_id = ? AND generation < ?"
            )
            let upsertItem = try database.prepare(Self.upsertItemSQL)
            let insertJournal = try database.prepare(
                """
                INSERT OR IGNORE INTO change_journal(
                    generation, item_id, kind, previous_route_known,
                    previous_folder_id, previous_parent_id, previous_in_working_set
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            let selectPreviousRoute = try database.prepare(
                """
                SELECT folder_id, parent_id,
                       1
                FROM items WHERE item_id = ? LIMIT 1
                """
            )
            let deleteItem = try database.prepare(
                "DELETE FROM items WHERE item_id = ? AND generation <= ?"
            )
            let upsertTombstone = try database.prepare(Self.upsertTombstoneSQL)

            var updatedItems = 0
            var deletedItems = 0
            var recordedTombstones = 0
            var semanticMutations = 0

            for item in snapshot.items {
                guard item.generation <= snapshot.generation else {
                    throw IndexedMetadataStoreError.generationRegression(
                        current: snapshot.generation,
                        proposed: item.generation
                    )
                }
                let itemGeneration = try Self.encodeGeneration(item.generation)
                let previousRoute = try Self.previousRoute(
                    for: item.id,
                    using: selectPreviousRoute
                )

                try clearOldTombstone.reset()
                try clearOldTombstone.bind(item.id, at: 1)
                try clearOldTombstone.bind(itemGeneration, at: 2)
                try clearOldTombstone.stepToCompletion()
                let clearedTombstone = database.changes > 0

                try upsertItem.reset()
                try Self.bind(item: item, to: upsertItem)
                try upsertItem.bind(Self.normalizedSearchText(item.relativePath), at: 15)
                try upsertItem.bind(item.id, at: 16)
                try upsertItem.stepToCompletion()
                let itemChanged = database.changes > 0

                if itemChanged || clearedTombstone {
                    updatedItems += itemChanged ? 1 : 0
                    semanticMutations += 1
                    try Self.recordJournal(
                        generation: snapshotGeneration,
                        itemID: item.id,
                        kind: .upsert,
                        previousRouteWasRecorded: true,
                        previousRoute: previousRoute,
                        using: insertJournal
                    )
                }
            }

            for tombstone in snapshot.tombstones {
                guard tombstone.generation <= snapshot.generation else {
                    throw IndexedMetadataStoreError.generationRegression(
                        current: snapshot.generation,
                        proposed: tombstone.generation
                    )
                }
                let tombstoneGeneration = try Self.encodeGeneration(tombstone.generation)

                try deleteItem.reset()
                try deleteItem.bind(tombstone.itemID, at: 1)
                try deleteItem.bind(tombstoneGeneration, at: 2)
                try deleteItem.stepToCompletion()
                let itemWasDeleted = database.changes > 0

                try upsertTombstone.reset()
                try upsertTombstone.bind(tombstone.itemID, at: 1)
                try upsertTombstone.bind(tombstoneGeneration, at: 2)
                try upsertTombstone.bind(tombstone.itemID, at: 3)
                try upsertTombstone.bind(tombstoneGeneration, at: 4)
                try upsertTombstone.stepToCompletion()
                let tombstoneChanged = database.changes > 0

                if itemWasDeleted || tombstoneChanged {
                    deletedItems += itemWasDeleted ? 1 : 0
                    recordedTombstones += tombstoneChanged ? 1 : 0
                    semanticMutations += 1
                    try Self.recordJournal(
                        generation: snapshotGeneration,
                        itemID: tombstone.itemID,
                        kind: .delete,
                        previousRouteWasRecorded: false,
                        previousRoute: nil,
                        using: insertJournal
                    )
                }
            }

            if priorGeneration == snapshot.generation, semanticMutations > 0 {
                throw IndexedMetadataStoreError.generationCollision(snapshot.generation)
            }

            let updateState = try database.prepare(Self.updateStateSQL)
            try updateState.bind(snapshotGeneration, at: 1)
            try updateState.bind(snapshot.generatedAt.timeIntervalSince1970, at: 2)
            try updateState.stepToCompletion()

            return IndexedMetadataImportResult(
                generation: snapshot.generation,
                insertedOrUpdatedItems: updatedItems,
                deletedItems: deletedItems,
                recordedTombstones: recordedTombstones
            )
        }

        Self.applyFileProtectionIfAvailable(to: databaseURL)
        return result
    }

    public func items(
        inFolder folderID: FolderID,
        after cursor: IndexedItemPageCursor? = nil,
        limit: Int = 200
    ) throws -> IndexedItemPage {
        let limit = try Self.validatedPageSize(limit)
        var sql = "SELECT \(Self.itemColumns) FROM items i WHERE i.folder_id = ?"
        if cursor != nil {
            sql += " AND (i.relative_path > ? OR (i.relative_path = ? AND i.item_id > ?))"
        }
        sql += " ORDER BY i.relative_path, i.item_id LIMIT ?"

        let statement = try database.prepare(sql)
        var binding: Int32 = 1
        try statement.bind(folderID.rawValue, at: binding)
        binding += 1
        if let cursor {
            try statement.bind(cursor.relativePath, at: binding)
            try statement.bind(cursor.relativePath, at: binding + 1)
            try statement.bind(cursor.itemID, at: binding + 2)
            binding += 3
        }
        try statement.bind(Int64(limit + 1), at: binding)
        return try Self.readItemPage(from: statement, limit: limit)
    }

    public func allItems(
        after cursor: IndexedItemPageCursor? = nil,
        limit: Int = 200
    ) throws -> IndexedItemPage {
        let limit = try Self.validatedPageSize(limit)
        var sql = "SELECT \(Self.itemColumns) FROM items i"
        if cursor != nil {
            sql += " WHERE (i.relative_path > ? OR (i.relative_path = ? AND i.item_id > ?))"
        }
        sql += " ORDER BY i.relative_path, i.item_id LIMIT ?"

        let statement = try database.prepare(sql)
        var binding: Int32 = 1
        if let cursor {
            try statement.bind(cursor.relativePath, at: binding)
            try statement.bind(cursor.relativePath, at: binding + 1)
            try statement.bind(cursor.itemID, at: binding + 2)
            binding += 3
        }
        try statement.bind(Int64(limit + 1), at: binding)
        return try Self.readItemPage(from: statement, limit: limit)
    }

    public func workingSet(
        inFolder folderID: FolderID? = nil,
        after cursor: IndexedItemPageCursor? = nil,
        limit: Int = 200
    ) throws -> IndexedItemPage {
        let limit = try Self.validatedPageSize(limit)
        var sql = """
            SELECT \(Self.itemColumns) FROM items i
            WHERE 1 = 1
            """
        if folderID != nil { sql += " AND i.folder_id = ?" }
        if cursor != nil {
            sql += " AND (i.relative_path > ? OR (i.relative_path = ? AND i.item_id > ?))"
        }
        sql += " ORDER BY i.relative_path, i.item_id LIMIT ?"

        let statement = try database.prepare(sql)
        var binding: Int32 = 1
        if let folderID {
            try statement.bind(folderID.rawValue, at: binding)
            binding += 1
        }
        if let cursor {
            try statement.bind(cursor.relativePath, at: binding)
            try statement.bind(cursor.relativePath, at: binding + 1)
            try statement.bind(cursor.itemID, at: binding + 2)
            binding += 3
        }
        try statement.bind(Int64(limit + 1), at: binding)
        return try Self.readItemPage(from: statement, limit: limit)
    }

    public func children(
        inFolder folderID: FolderID,
        parentID: String?,
        after cursor: IndexedItemPageCursor? = nil,
        limit: Int = 200
    ) throws -> IndexedItemPage {
        let limit = try Self.validatedPageSize(limit)
        var sql = "SELECT \(Self.itemColumns) FROM items i WHERE i.folder_id = ?"
        sql += parentID == nil ? " AND i.parent_id IS NULL" : " AND i.parent_id = ?"
        if cursor != nil {
            sql += " AND (i.relative_path > ? OR (i.relative_path = ? AND i.item_id > ?))"
        }
        sql += " ORDER BY i.relative_path, i.item_id LIMIT ?"

        let statement = try database.prepare(sql)
        var binding: Int32 = 1
        try statement.bind(folderID.rawValue, at: binding)
        binding += 1
        if let parentID {
            try statement.bind(parentID, at: binding)
            binding += 1
        }
        if let cursor {
            try statement.bind(cursor.relativePath, at: binding)
            try statement.bind(cursor.relativePath, at: binding + 1)
            try statement.bind(cursor.itemID, at: binding + 2)
            binding += 3
        }
        try statement.bind(Int64(limit + 1), at: binding)
        return try Self.readItemPage(from: statement, limit: limit)
    }

    public func search(
        _ query: String,
        inFolder folderID: FolderID? = nil,
        after cursor: IndexedItemPageCursor? = nil,
        limit: Int = 200
    ) throws -> IndexedItemPage {
        let limit = try Self.validatedPageSize(limit)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IndexedMetadataStoreError.emptySearchQuery }

        if usesFullTextSearch, let fullTextQuery = Self.fullTextQuery(trimmed) {
            return try searchFullText(
                fullTextQuery,
                folderID: folderID,
                cursor: cursor,
                limit: limit
            )
        }
        return try searchLike(trimmed, folderID: folderID, cursor: cursor, limit: limit)
    }

    public func changes(
        sinceGeneration generation: UInt64,
        after cursor: IndexedMetadataChangeCursor? = nil,
        limit: Int = 500
    ) throws -> IndexedMetadataChangePage {
        let limit = try Self.validatedPageSize(limit)
        return try readChanges(
            sinceGeneration: generation,
            after: cursor,
            limit: limit
        )
    }

    /// Reads a File Provider continuation page from one stable SQLite snapshot.
    ///
    /// The pruning watermark prevents an old lower-bound anchor from silently
    /// advancing across discarded rows. Continuations additionally have to name
    /// both a real journal row and the exact cumulative row boundary emitted by
    /// an earlier page for the same lower bound and page size. A read transaction
    /// keeps those checks, the page query, and the observed generation atomic
    /// with respect to projection imports and journal pruning on other connections.
    public func validatedChanges(
        sinceGeneration generation: UInt64,
        after cursor: IndexedMetadataChangeCursor? = nil,
        expectedCurrentGeneration: UInt64,
        limit: Int = 500
    ) throws -> IndexedMetadataValidatedChangeResult {
        let limit = try Self.validatedPageSize(limit)
        return try database.transaction(mode: "DEFERRED") {
            guard try currentGeneration() == expectedCurrentGeneration,
                generation >= (try journalPrunedThrough())
            else {
                return .expired
            }

            if let cursor {
                guard cursor.generation > generation,
                    cursor.generation <= expectedCurrentGeneration,
                    cursor.sequence > 0,
                    cursor.rowOffset > 0,
                    cursor.rowOffset.isMultiple(of: UInt64(limit)),
                    try changeBoundaryRowCount(
                        sinceGeneration: generation,
                        through: cursor
                    ) == cursor.rowOffset
                else {
                    return .expired
                }
            }

            let page = try readChanges(
                sinceGeneration: generation,
                after: cursor,
                limit: limit
            )
            guard page.currentGeneration == expectedCurrentGeneration,
                page.changes.allSatisfy({ $0.generation <= expectedCurrentGeneration })
            else {
                return .expired
            }
            return .page(page)
        }
    }

    private func readChanges(
        sinceGeneration generation: UInt64,
        after cursor: IndexedMetadataChangeCursor?,
        limit: Int
    ) throws -> IndexedMetadataChangePage {
        let encodedGeneration = try Self.encodeGeneration(generation)
        var sql = """
            SELECT j.sequence, j.generation, j.item_id, j.kind,
                   j.previous_route_known, j.previous_folder_id,
                   j.previous_parent_id, j.previous_in_working_set,
                   \(Self.itemColumns)
            FROM change_journal j
            LEFT JOIN items i ON i.item_id = j.item_id
            WHERE j.generation > ?
            """
        if cursor != nil {
            sql += " AND (j.generation > ? OR (j.generation = ? AND j.sequence > ?))"
        }
        sql += " ORDER BY j.generation, j.sequence LIMIT ?"

        let statement = try database.prepare(sql)
        var binding: Int32 = 1
        try statement.bind(encodedGeneration, at: binding)
        binding += 1
        if let cursor {
            let cursorGeneration = try Self.encodeGeneration(cursor.generation)
            try statement.bind(cursorGeneration, at: binding)
            try statement.bind(cursorGeneration, at: binding + 1)
            try statement.bind(cursor.sequence, at: binding + 2)
            binding += 3
        }
        try statement.bind(Int64(limit + 1), at: binding)

        var values: [IndexedMetadataChange] = []
        values.reserveCapacity(limit + 1)
        while try statement.step() == SQLITE_ROW {
            let kindRaw = Int(statement.int64(at: 3))
            guard let kind = IndexedMetadataChangeKind(rawValue: kindRaw) else {
                throw IndexedMetadataStoreError.invalidStoredValue("unknown change kind \(kindRaw)")
            }
            let previousRouteWasRecorded = try Self.decodeBoolean(
                statement.int64(at: 4),
                field: "previous route marker"
            )
            let previousRoute = try Self.decodePreviousRoute(
                from: statement,
                routeWasRecorded: previousRouteWasRecorded,
                offset: 5
            )
            let item = statement.isNull(at: 8) ? nil : try Self.decodeItem(from: statement, offset: 8)
            values.append(
                IndexedMetadataChange(
                    generation: try Self.decodeGeneration(statement.int64(at: 1)),
                    sequence: statement.int64(at: 0),
                    itemID: try statement.text(at: 2),
                    kind: kind,
                    currentItem: item,
                    previousRouteWasRecorded: previousRouteWasRecorded,
                    previousRoute: previousRoute
                )
            )
        }
        let hasMore = values.count > limit
        if hasMore { values.removeLast(values.count - limit) }
        let priorRowOffset = cursor?.rowOffset ?? 0
        let deliveredRowCount = UInt64(values.count)
        guard priorRowOffset <= UInt64.max - deliveredRowCount else {
            throw IndexedMetadataStoreError.invalidStoredValue(
                "change-journal cursor row offset overflow"
            )
        }
        let nextCursor =
            hasMore
            ? values.last.map {
                IndexedMetadataChangeCursor(
                    generation: $0.generation,
                    sequence: $0.sequence,
                    rowOffset: priorRowOffset + deliveredRowCount
                )
            } : nil
        return IndexedMetadataChangePage(
            changes: values,
            nextCursor: nextCursor,
            currentGeneration: try currentGeneration()
        )
    }

    private func journalPrunedThrough() throws -> UInt64 {
        let statement = try database.prepare(
            "SELECT journal_pruned_through FROM store_state WHERE singleton = 1"
        )
        guard try statement.step() == SQLITE_ROW else { return 0 }
        return try Self.decodeGeneration(statement.int64(at: 0))
    }

    private func changeBoundaryRowCount(
        sinceGeneration generation: UInt64,
        through cursor: IndexedMetadataChangeCursor
    ) throws -> UInt64 {
        let statement = try database.prepare(
            """
            SELECT COUNT(*) FROM change_journal
            WHERE generation > ?
              AND (generation < ? OR (generation = ? AND sequence <= ?))
            """
        )
        try statement.bind(Self.encodeGeneration(generation), at: 1)
        let cursorGeneration = try Self.encodeGeneration(cursor.generation)
        try statement.bind(cursorGeneration, at: 2)
        try statement.bind(cursorGeneration, at: 3)
        try statement.bind(cursor.sequence, at: 4)
        guard try statement.step() == SQLITE_ROW else { return 0 }
        let count = statement.int64(at: 0)
        guard count >= 0 else {
            throw IndexedMetadataStoreError.invalidStoredValue(
                "negative change-journal boundary count"
            )
        }
        return UInt64(count)
    }

    /// Confirms that an opaque File Provider continuation cursor names a real
    /// journal row. Generation bounds alone are insufficient: a forged or
    /// corrupt sequence could otherwise skip changes within that generation.
    public func containsChange(at cursor: IndexedMetadataChangeCursor) throws -> Bool {
        guard cursor.sequence > 0 else { return false }
        let statement = try database.prepare(
            "SELECT 1 FROM change_journal WHERE generation = ? AND sequence = ? LIMIT 1"
        )
        try statement.bind(Self.encodeGeneration(cursor.generation), at: 1)
        try statement.bind(cursor.sequence, at: 2)
        return try statement.step() == SQLITE_ROW
    }

    public func tombstones(
        after cursor: IndexedMetadataTombstoneCursor? = nil,
        limit: Int = 500
    ) throws -> IndexedMetadataTombstonePage {
        let limit = try Self.validatedPageSize(limit)
        var sql = "SELECT item_id, generation FROM tombstones"
        if cursor != nil {
            sql += " WHERE generation > ? OR (generation = ? AND item_id > ?)"
        }
        sql += " ORDER BY generation, item_id LIMIT ?"

        let statement = try database.prepare(sql)
        var binding: Int32 = 1
        if let cursor {
            let encoded = try Self.encodeGeneration(cursor.generation)
            try statement.bind(encoded, at: binding)
            try statement.bind(encoded, at: binding + 1)
            try statement.bind(cursor.itemID, at: binding + 2)
            binding += 3
        }
        try statement.bind(Int64(limit + 1), at: binding)

        var values: [IndexTombstone] = []
        values.reserveCapacity(limit + 1)
        while try statement.step() == SQLITE_ROW {
            values.append(
                IndexTombstone(
                    itemID: try statement.text(at: 0),
                    generation: try Self.decodeGeneration(statement.int64(at: 1))
                )
            )
        }
        let hasMore = values.count > limit
        if hasMore { values.removeLast(values.count - limit) }
        let nextCursor =
            hasMore
            ? values.last.map {
                IndexedMetadataTombstoneCursor(generation: $0.generation, itemID: $0.itemID)
            } : nil
        return IndexedMetadataTombstonePage(tombstones: values, nextCursor: nextCursor)
    }

    public func pruneChangeJournal(throughGeneration generation: UInt64) throws -> Int {
        guard accessMode == .readWrite else { throw IndexedMetadataStoreError.readOnly }
        return try database.transaction {
            guard let currentGeneration = try currentGeneration() else { return 0 }
            let effectiveGeneration = min(generation, currentGeneration)
            let encodedGeneration = try Self.encodeGeneration(effectiveGeneration)

            let delete = try database.prepare(
                "DELETE FROM change_journal WHERE generation <= ?"
            )
            try delete.bind(encodedGeneration, at: 1)
            try delete.stepToCompletion()
            let deletedCount = database.changes

            let updateWatermark = try database.prepare(
                """
                UPDATE store_state
                SET journal_pruned_through = MAX(journal_pruned_through, ?)
                WHERE singleton = 1
                """
            )
            try updateWatermark.bind(encodedGeneration, at: 1)
            try updateWatermark.stepToCompletion()
            return deletedCount
        }
    }

    @discardableResult
    public func recoverIfNeeded() throws -> Bool {
        guard accessMode == .readWrite else { throw IndexedMetadataStoreError.readOnly }
        do {
            try Self.verifyIntegrity(of: database)
            return false
        } catch let error as IndexedMetadataStoreError {
            guard recoveryPolicy == .backupAndRecreate, Self.isRecoverable(error) else { throw error }
            database.close()
            let backup = try Self.backUpDatabase(at: databaseURL)
            let opened = try Self.openDatabase(at: databaseURL, accessMode: .readWrite)
            database = opened.database
            usesFullTextSearch = opened.usesFullTextSearch
            recoveryBackupURL = backup
            if let backup {
                try? Self.pruneRecoveryBackups(at: databaseURL, keeping: backup)
            }
            Self.applyFileProtectionIfAvailable(to: databaseURL)
            return true
        }
    }

    private func searchFullText(
        _ query: String,
        folderID: FolderID?,
        cursor: IndexedItemPageCursor?,
        limit: Int
    ) throws -> IndexedItemPage {
        var sql = """
            SELECT \(Self.itemColumns)
            FROM item_search
            JOIN items i ON i.rowid = item_search.rowid
            WHERE item_search MATCH ?
            """
        if folderID != nil { sql += " AND i.folder_id = ?" }
        if cursor != nil {
            sql += " AND (i.relative_path > ? OR (i.relative_path = ? AND i.item_id > ?))"
        }
        sql += " ORDER BY i.relative_path, i.item_id LIMIT ?"

        let statement = try database.prepare(sql)
        var binding: Int32 = 1
        try statement.bind(query, at: binding)
        binding += 1
        if let folderID {
            try statement.bind(folderID.rawValue, at: binding)
            binding += 1
        }
        if let cursor {
            try statement.bind(cursor.relativePath, at: binding)
            try statement.bind(cursor.relativePath, at: binding + 1)
            try statement.bind(cursor.itemID, at: binding + 2)
            binding += 3
        }
        try statement.bind(Int64(limit + 1), at: binding)
        return try Self.readItemPage(from: statement, limit: limit)
    }

    private func searchLike(
        _ query: String,
        folderID: FolderID?,
        cursor: IndexedItemPageCursor?,
        limit: Int
    ) throws -> IndexedItemPage {
        var sql = "SELECT \(Self.itemColumns) FROM items i WHERE i.search_text LIKE ? ESCAPE '\\'"
        if folderID != nil { sql += " AND i.folder_id = ?" }
        if cursor != nil {
            sql += " AND (i.relative_path > ? OR (i.relative_path = ? AND i.item_id > ?))"
        }
        sql += " ORDER BY i.relative_path, i.item_id LIMIT ?"

        let statement = try database.prepare(sql)
        var binding: Int32 = 1
        try statement.bind("%\(Self.escapedLikePattern(Self.normalizedSearchText(query)))%", at: binding)
        binding += 1
        if let folderID {
            try statement.bind(folderID.rawValue, at: binding)
            binding += 1
        }
        if let cursor {
            try statement.bind(cursor.relativePath, at: binding)
            try statement.bind(cursor.relativePath, at: binding + 1)
            try statement.bind(cursor.itemID, at: binding + 2)
            binding += 3
        }
        try statement.bind(Int64(limit + 1), at: binding)
        return try Self.readItemPage(from: statement, limit: limit)
    }
}

extension IndexedMetadataStore {
    fileprivate struct OpenedDatabase {
        let database: SQLiteDatabase
        let usesFullTextSearch: Bool
    }

    fileprivate static let updateStateSQL = """
        INSERT INTO store_state(singleton, current_generation, generated_at)
        VALUES (1, ?, ?)
        ON CONFLICT(singleton) DO UPDATE SET
            current_generation = excluded.current_generation,
            generated_at = excluded.generated_at
        """

    fileprivate static let upsertTombstoneSQL = """
        INSERT INTO tombstones(item_id, generation)
        SELECT ?, ?
        WHERE NOT EXISTS (
            SELECT 1 FROM items WHERE item_id = ? AND generation > ?
        )
        ON CONFLICT(item_id) DO UPDATE SET generation = excluded.generation
        WHERE excluded.generation > tombstones.generation
        """

    fileprivate static let upsertItemSQL = """
        INSERT INTO items(
            item_id, folder_id, parent_id, relative_path, is_directory,
            size, modified_at, content_version, metadata_version,
            availability, is_pinned, has_unuploaded_changes,
            remote_replica_count, generation, search_text
        )
        SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        WHERE NOT EXISTS (SELECT 1 FROM tombstones WHERE item_id = ?)
        ON CONFLICT(item_id) DO UPDATE SET
            folder_id = excluded.folder_id,
            parent_id = excluded.parent_id,
            relative_path = excluded.relative_path,
            is_directory = excluded.is_directory,
            size = excluded.size,
            modified_at = excluded.modified_at,
            content_version = excluded.content_version,
            metadata_version = excluded.metadata_version,
            availability = excluded.availability,
            is_pinned = excluded.is_pinned,
            has_unuploaded_changes = excluded.has_unuploaded_changes,
            remote_replica_count = excluded.remote_replica_count,
            generation = excluded.generation,
            search_text = excluded.search_text
        WHERE
            excluded.generation >= items.generation AND (
                items.folder_id IS NOT excluded.folder_id OR
                items.parent_id IS NOT excluded.parent_id OR
                items.relative_path IS NOT excluded.relative_path OR
                items.is_directory IS NOT excluded.is_directory OR
                items.size IS NOT excluded.size OR
                items.modified_at IS NOT excluded.modified_at OR
                items.content_version IS NOT excluded.content_version OR
                items.metadata_version IS NOT excluded.metadata_version OR
                items.availability IS NOT excluded.availability OR
                items.is_pinned IS NOT excluded.is_pinned OR
                items.has_unuploaded_changes IS NOT excluded.has_unuploaded_changes OR
                items.remote_replica_count IS NOT excluded.remote_replica_count OR
                items.generation IS NOT excluded.generation OR
                items.search_text IS NOT excluded.search_text
            )
        """

    fileprivate static func openDatabase(
        at url: URL,
        accessMode: IndexedMetadataAccessMode
    ) throws -> OpenedDatabase {
        if accessMode == .readWrite {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let flags: Int32 =
            accessMode == .readWrite
            ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let database = try SQLiteDatabase(path: url.path, flags: flags)
        try database.setBusyTimeout(milliseconds: 5_000)
        try database.execute("PRAGMA cache_size = -8192")
        // File Provider may open the read projection repeatedly while Files is
        // browsing. Keep query temporaries out of file-backed storage so those
        // reads cannot consume the extension's daily disk-write budget.
        try database.execute("PRAGMA temp_store = MEMORY")

        switch accessMode {
        case .readWrite:
            let journalMode = try database.scalarText("PRAGMA journal_mode = WAL")?.lowercased()
            guard journalMode == "wal" else {
                throw IndexedMetadataStoreError.sqlite(
                    code: SQLITE_ERROR,
                    message: "unable to enable WAL journal mode"
                )
            }
            try database.execute("PRAGMA synchronous = NORMAL")
            try database.execute("PRAGMA wal_autocheckpoint = 1000")
            try database.execute("PRAGMA foreign_keys = ON")
            try migrate(database)
        case .readOnly:
            try database.execute("PRAGMA query_only = ON")
            let version = Int(try database.scalarInt64("PRAGMA user_version") ?? 0)
            guard version == currentSchemaVersion else {
                throw IndexedMetadataStoreError.unsupportedDatabaseSchema(version)
            }
        }

        try verifyIntegrity(of: database)
        let usesFullTextSearch = try configureFullTextSearch(
            database,
            mayCreate: accessMode == .readWrite
        )
        return OpenedDatabase(database: database, usesFullTextSearch: usesFullTextSearch)
    }

    fileprivate static func migrate(_ database: SQLiteDatabase) throws {
        let version = Int(try database.scalarInt64("PRAGMA user_version") ?? 0)
        guard version <= currentSchemaVersion else {
            throw IndexedMetadataStoreError.unsupportedDatabaseSchema(version)
        }
        guard version < currentSchemaVersion else { return }

        try database.transaction(mode: "EXCLUSIVE") {
            var workingVersion = version
            if workingVersion == 0 {
                try createVersionOneSchema(in: database)
                try database.execute("PRAGMA user_version = 1")
                workingVersion = 1
            }
            if workingVersion == 1 {
                try migrateVersionOneToVersionTwo(in: database)
                try database.execute("PRAGMA user_version = 2")
                workingVersion = 2
            }
            if workingVersion == 2 {
                try migrateVersionTwoToVersionThree(in: database)
                try database.execute("PRAGMA user_version = 3")
                workingVersion = 3
            }
            if workingVersion == 3 {
                try migrateVersionThreeToVersionFour(in: database)
                try database.execute("PRAGMA user_version = 4")
                workingVersion = 4
            }
            guard workingVersion == currentSchemaVersion else {
                throw IndexedMetadataStoreError.unsupportedDatabaseSchema(workingVersion)
            }
        }
    }

    fileprivate static func createVersionOneSchema(in database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE store_state(
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                current_generation INTEGER,
                generated_at REAL NOT NULL
            );

            CREATE TABLE items(
                item_id TEXT PRIMARY KEY NOT NULL,
                folder_id TEXT NOT NULL,
                parent_id TEXT,
                relative_path TEXT NOT NULL,
                is_directory INTEGER NOT NULL CHECK(is_directory IN (0, 1)),
                size INTEGER NOT NULL,
                modified_at REAL NOT NULL,
                content_version BLOB NOT NULL,
                metadata_version BLOB NOT NULL,
                availability TEXT NOT NULL,
                is_pinned INTEGER NOT NULL CHECK(is_pinned IN (0, 1)),
                has_unuploaded_changes INTEGER NOT NULL CHECK(has_unuploaded_changes IN (0, 1)),
                remote_replica_count INTEGER NOT NULL,
                generation INTEGER NOT NULL CHECK(generation >= 0)
            );

            CREATE TABLE tombstones(
                item_id TEXT PRIMARY KEY NOT NULL,
                generation INTEGER NOT NULL CHECK(generation >= 0)
            );
            """)
    }

    fileprivate static func migrateVersionOneToVersionTwo(in database: SQLiteDatabase) throws {
        try database.execute("ALTER TABLE items ADD COLUMN search_text TEXT NOT NULL DEFAULT ''")
        try database.execute("UPDATE items SET search_text = lower(relative_path)")
        try database.execute(
            """
            CREATE TABLE change_journal(
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                generation INTEGER NOT NULL CHECK(generation >= 0),
                item_id TEXT NOT NULL,
                kind INTEGER NOT NULL CHECK(kind IN (1, 2)),
                UNIQUE(generation, item_id, kind)
            );

            CREATE INDEX items_by_folder_path
                ON items(folder_id, relative_path, item_id);
            CREATE INDEX items_by_parent_path
                ON items(folder_id, parent_id, relative_path, item_id);
            CREATE INDEX items_by_path
                ON items(relative_path, item_id);
            CREATE INDEX tombstones_by_generation
                ON tombstones(generation, item_id);
            CREATE INDEX journal_by_generation_sequence
                ON change_journal(generation, sequence);
            """)
    }

    fileprivate static func migrateVersionTwoToVersionThree(in database: SQLiteDatabase) throws {
        // Existing rows deliberately retain previous_route_known = 0. Their
        // original parent cannot be reconstructed from the current items table,
        // so route-aware readers conservatively remove them from non-current
        // containers during the first post-upgrade change enumeration.
        try database.execute(
            """
            ALTER TABLE change_journal
                ADD COLUMN previous_route_known INTEGER NOT NULL DEFAULT 0
                CHECK(previous_route_known IN (0, 1));
            ALTER TABLE change_journal
                ADD COLUMN previous_folder_id TEXT;
            ALTER TABLE change_journal
                ADD COLUMN previous_parent_id TEXT;
            ALTER TABLE change_journal
                ADD COLUMN previous_in_working_set INTEGER
                CHECK(previous_in_working_set IS NULL OR previous_in_working_set IN (0, 1));
            """)
    }

    fileprivate static func migrateVersionThreeToVersionFour(in database: SQLiteDatabase) throws {
        try database.execute(
            """
            ALTER TABLE store_state
                ADD COLUMN journal_pruned_through INTEGER NOT NULL DEFAULT 0
                CHECK(journal_pruned_through >= 0);

            -- Earlier schemas did not record whether change rows had ever been
            -- pruned. Conservatively expire pre-upgrade anchors rather than
            -- claiming unprovable journal coverage.
            UPDATE store_state
            SET journal_pruned_through = COALESCE(current_generation, 0)
            WHERE singleton = 1;
            """)
    }

    fileprivate static func configureFullTextSearch(
        _ database: SQLiteDatabase,
        mayCreate: Bool
    ) throws -> Bool {
        let exists =
            try database.scalarInt64(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'item_search'"
            ) == 1
        if exists {
            do {
                // sqlite_master can describe an FTS5 virtual table even when
                // this process's SQLite build cannot load the module. Probe the
                // table before retaining its write triggers; otherwise every
                // ordinary items upsert fails later with `no such module: fts5`.
                _ = try database.scalarInt64("SELECT COUNT(*) FROM item_search")
                return true
            } catch let error as IndexedMetadataStoreError {
                guard case .sqlite(_, let message) = error,
                    message.localizedCaseInsensitiveContains("no such module")
                else {
                    throw error
                }
                if mayCreate {
                    // The read-write initializer treats SQLite errors as
                    // recoverable and rebuilds this derived cache. A fresh DB
                    // then reaches the capability-aware create path below and
                    // cleanly selects LIKE fallback when FTS5 is unavailable.
                    throw error
                }
                return false
            }
        }
        guard mayCreate else { return false }

        do {
            try database.transaction {
                try database.execute(
                    """
                    CREATE VIRTUAL TABLE item_search USING fts5(
                        relative_path,
                        content = 'items',
                        content_rowid = 'rowid',
                        tokenize = 'unicode61 remove_diacritics 2'
                    );

                    CREATE TRIGGER item_search_after_insert AFTER INSERT ON items BEGIN
                        INSERT INTO item_search(rowid, relative_path)
                        VALUES (new.rowid, new.relative_path);
                    END;

                    CREATE TRIGGER item_search_after_delete AFTER DELETE ON items BEGIN
                        INSERT INTO item_search(item_search, rowid, relative_path)
                        VALUES ('delete', old.rowid, old.relative_path);
                    END;

                    CREATE TRIGGER item_search_after_path_update
                    AFTER UPDATE OF relative_path ON items BEGIN
                        INSERT INTO item_search(item_search, rowid, relative_path)
                        VALUES ('delete', old.rowid, old.relative_path);
                        INSERT INTO item_search(rowid, relative_path)
                        VALUES (new.rowid, new.relative_path);
                    END;

                    INSERT INTO item_search(item_search) VALUES ('rebuild');
                    """)
            }
            return true
        } catch let error as IndexedMetadataStoreError {
            if case .sqlite(_, let message) = error,
                message.localizedCaseInsensitiveContains("no such module")
            {
                return false
            }
            throw error
        }
    }

    fileprivate static func verifyIntegrity(of database: SQLiteDatabase) throws {
        let result = try database.scalarText("PRAGMA quick_check(1)") ?? "no result"
        guard result == "ok" else { throw IndexedMetadataStoreError.integrityCheckFailed(result) }
    }

    fileprivate static func backUpDatabase(at url: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let backupURL = URL(fileURLWithPath: url.path + ".recovered-" + UUID().uuidString)
        var movedSidecars: [(source: URL, destination: URL)] = []
        do {
            // Move sidecars before the main database. A crash before the final
            // rename can at worst leave the rebuildable base database without
            // its journal; it cannot expose stale WAL/SHM files to a newly
            // created database at the original path.
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                guard fileManager.fileExists(atPath: sidecar.path) else { continue }
                let destination = URL(fileURLWithPath: backupURL.path + suffix)
                try fileManager.moveItem(at: sidecar, to: destination)
                movedSidecars.append((sidecar, destination))
            }
            try fileManager.moveItem(at: url, to: backupURL)
        } catch {
            for moved in movedSidecars.reversed()
            where fileManager.fileExists(atPath: moved.destination.path)
                && !fileManager.fileExists(atPath: moved.source.path)
            {
                try? fileManager.moveItem(at: moved.destination, to: moved.source)
            }
            throw error
        }
        return backupURL
    }

    /// A recovered index is diagnostic-only derived data, not user content.
    /// Keep the newest exact backup and remove older validated siblings so a
    /// recurring cache failure cannot consume unbounded App Group storage.
    fileprivate static func pruneRecoveryBackups(at databaseURL: URL, keeping: URL) throws {
        let manager = FileManager.default
        let parent = databaseURL.deletingLastPathComponent().standardizedFileURL
        let prefix = databaseURL.lastPathComponent + ".recovered-"
        let keepName = keeping.lastPathComponent
        let names = try manager.contentsOfDirectory(atPath: parent.path)
        var backupBaseNames = Set<String>()
        for name in names where name.hasPrefix(prefix) {
            let baseName: String
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") {
                baseName = String(name.dropLast(4))
            } else {
                baseName = name
            }
            let suffix = String(baseName.dropFirst(prefix.count))
            guard let uuid = UUID(uuidString: suffix), uuid.uuidString == suffix else { continue }
            backupBaseNames.insert(baseName)
        }
        for baseName in backupBaseNames where baseName != keepName {
            for suffix in ["", "-wal", "-shm"] {
                let candidate = parent.appendingPathComponent(baseName + suffix).standardizedFileURL
                guard candidate.deletingLastPathComponent() == parent,
                    let attributes = try? manager.attributesOfItem(atPath: candidate.path),
                    attributes[.type] as? FileAttributeType == .typeRegular
                else { continue }
                try manager.removeItem(at: candidate)
            }
        }
    }

    fileprivate static func isRecoverable(_ error: IndexedMetadataStoreError) -> Bool {
        switch error {
        case .sqlite, .integrityCheckFailed, .databaseClosed:
            true
        case .readOnly,
            .unsupportedSnapshotSchema,
            .unsupportedDatabaseSchema,
            .generationRegression,
            .generationCollision,
            .generationOutOfRange,
            .invalidPageSize,
            .emptySearchQuery,
            .invalidStoredValue:
            false
        }
    }

    fileprivate static func bind(item: IndexedItem, to statement: SQLiteStatement) throws {
        try statement.bind(item.id, at: 1)
        try statement.bind(item.folderID.rawValue, at: 2)
        try statement.bind(item.parentID, at: 3)
        try statement.bind(item.relativePath, at: 4)
        try statement.bind(item.isDirectory, at: 5)
        try statement.bind(item.size, at: 6)
        try statement.bind(item.modifiedAt.timeIntervalSince1970, at: 7)
        try statement.bind(item.contentVersion, at: 8)
        try statement.bind(item.metadataVersion, at: 9)
        try statement.bind(item.availability.rawValue, at: 10)
        try statement.bind(item.isPinned, at: 11)
        try statement.bind(item.hasUnuploadedChanges, at: 12)
        try statement.bind(Int64(item.remoteReplicaCount), at: 13)
        try statement.bind(encodeGeneration(item.generation), at: 14)
    }

    fileprivate static func recordJournal(
        generation: Int64,
        itemID: String,
        kind: IndexedMetadataChangeKind,
        previousRouteWasRecorded: Bool,
        previousRoute: IndexedMetadataItemRoute?,
        using statement: SQLiteStatement
    ) throws {
        try statement.reset()
        try statement.bind(generation, at: 1)
        try statement.bind(itemID, at: 2)
        try statement.bind(Int64(kind.rawValue), at: 3)
        try statement.bind(previousRouteWasRecorded, at: 4)
        try statement.bind(previousRoute?.folderID.rawValue, at: 5)
        try statement.bind(previousRoute?.parentID, at: 6)
        if let previousRoute {
            try statement.bind(previousRoute.isInWorkingSet, at: 7)
        } else {
            try statement.bindNull(at: 7)
        }
        try statement.stepToCompletion()
    }

    fileprivate static func previousRoute(
        for itemID: String,
        using statement: SQLiteStatement
    ) throws -> IndexedMetadataItemRoute? {
        try statement.reset()
        try statement.bind(itemID, at: 1)
        guard try statement.step() == SQLITE_ROW else { return nil }
        let folderValue = try statement.text(at: 0)
        guard let folderID = FolderID(rawValue: folderValue) else {
            throw IndexedMetadataStoreError.invalidStoredValue("invalid previous folder identifier")
        }
        return IndexedMetadataItemRoute(
            folderID: folderID,
            parentID: statement.optionalText(at: 1),
            isInWorkingSet: try decodeBoolean(
                statement.int64(at: 2),
                field: "previous working-set membership"
            )
        )
    }

    fileprivate static func decodePreviousRoute(
        from statement: SQLiteStatement,
        routeWasRecorded: Bool,
        offset: Int32
    ) throws -> IndexedMetadataItemRoute? {
        guard routeWasRecorded else {
            guard statement.isNull(at: offset),
                statement.isNull(at: offset + 1),
                statement.isNull(at: offset + 2)
            else {
                throw IndexedMetadataStoreError.invalidStoredValue(
                    "unrecorded previous route contains metadata"
                )
            }
            return nil
        }

        guard !statement.isNull(at: offset) else {
            guard statement.isNull(at: offset + 1), statement.isNull(at: offset + 2) else {
                throw IndexedMetadataStoreError.invalidStoredValue(
                    "partial previous route metadata"
                )
            }
            return nil
        }
        let folderValue = try statement.text(at: offset)
        guard let folderID = FolderID(rawValue: folderValue),
            !statement.isNull(at: offset + 2)
        else {
            throw IndexedMetadataStoreError.invalidStoredValue("invalid previous item route")
        }
        return IndexedMetadataItemRoute(
            folderID: folderID,
            parentID: statement.optionalText(at: offset + 1),
            isInWorkingSet: try decodeBoolean(
                statement.int64(at: offset + 2),
                field: "previous working-set membership"
            )
        )
    }

    fileprivate static func decodeBoolean(_ value: Int64, field: String) throws -> Bool {
        switch value {
        case 0: false
        case 1: true
        default:
            throw IndexedMetadataStoreError.invalidStoredValue("invalid \(field)")
        }
    }

    fileprivate static func decodeItem(from statement: SQLiteStatement, offset: Int32) throws -> IndexedItem {
        let folderValue = try statement.text(at: offset + 1)
        guard let folderID = FolderID(rawValue: folderValue) else {
            throw IndexedMetadataStoreError.invalidStoredValue("invalid folder identifier")
        }
        let availabilityValue = try statement.text(at: offset + 9)
        guard let availability = FileAvailability(rawValue: availabilityValue) else {
            throw IndexedMetadataStoreError.invalidStoredValue("invalid availability value")
        }
        let replicaCount = statement.int64(at: offset + 12)
        guard let decodedReplicaCount = Int(exactly: replicaCount) else {
            throw IndexedMetadataStoreError.invalidStoredValue("remote replica count is out of range")
        }
        return IndexedItem(
            id: try statement.text(at: offset),
            folderID: folderID,
            parentID: statement.optionalText(at: offset + 2),
            relativePath: try statement.text(at: offset + 3),
            isDirectory: statement.bool(at: offset + 4),
            size: statement.int64(at: offset + 5),
            modifiedAt: Date(timeIntervalSince1970: statement.double(at: offset + 6)),
            contentVersion: statement.data(at: offset + 7),
            metadataVersion: statement.data(at: offset + 8),
            availability: availability,
            isPinned: statement.bool(at: offset + 10),
            hasUnuploadedChanges: statement.bool(at: offset + 11),
            remoteReplicaCount: decodedReplicaCount,
            generation: try decodeGeneration(statement.int64(at: offset + 13))
        )
    }

    fileprivate static func readItemPage(
        from statement: SQLiteStatement,
        limit: Int
    ) throws -> IndexedItemPage {
        var values: [IndexedItem] = []
        values.reserveCapacity(limit + 1)
        while try statement.step() == SQLITE_ROW {
            values.append(try decodeItem(from: statement, offset: 0))
        }
        let hasMore = values.count > limit
        if hasMore { values.removeLast(values.count - limit) }
        let nextCursor =
            hasMore
            ? values.last.map {
                IndexedItemPageCursor(relativePath: $0.relativePath, itemID: $0.id)
            } : nil
        return IndexedItemPage(items: values, nextCursor: nextCursor)
    }

    fileprivate static func validatedPageSize(_ value: Int) throws -> Int {
        guard (1...maximumPageSize).contains(value) else {
            throw IndexedMetadataStoreError.invalidPageSize(value)
        }
        return value
    }

    fileprivate static func encodeGeneration(_ value: UInt64) throws -> Int64 {
        guard let result = Int64(exactly: value) else {
            throw IndexedMetadataStoreError.generationOutOfRange(value)
        }
        return result
    }

    fileprivate static func decodeGeneration(_ value: Int64) throws -> UInt64 {
        guard value >= 0 else {
            throw IndexedMetadataStoreError.invalidStoredValue("negative generation")
        }
        return UInt64(value)
    }

    fileprivate static func normalizedSearchText(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    fileprivate static func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    fileprivate static func fullTextQuery(_ value: String) -> String? {
        let terms = value.split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty else { return nil }
        return terms.map { term in
            let escaped = String(term).replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " AND ")
    }

    fileprivate static func applyFileProtectionIfAvailable(to databaseURL: URL) {
        #if os(iOS)
            let fileManager = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                let path = databaseURL.path + suffix
                guard fileManager.fileExists(atPath: path) else { continue }
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path
                )
            }
        #endif
    }
}
