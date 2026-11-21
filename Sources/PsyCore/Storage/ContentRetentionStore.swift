import Foundation

public enum ContentRetentionStoreError: Error, Hashable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidDocument
    case generationCollision(current: UInt64, expected: UInt64)
    case generationOverflow
    case folderIncarnationMismatch(String)
    case transactionNotFound(UUID)
    case tooManyRecords
}

public struct ContentRetentionStatus: Hashable, Sendable {
    public let isPinned: Bool
    public let pendingEvict: Bool
    public let isUploaded: Bool
    public let evictionTransactionID: UUID?

    public init(
        isPinned: Bool,
        pendingEvict: Bool,
        isUploaded: Bool,
        evictionTransactionID: UUID?
    ) {
        self.isPinned = isPinned
        self.pendingEvict = pendingEvict
        self.isUploaded = isUploaded
        self.evictionTransactionID = evictionTransactionID
    }
}

public struct ContentEvictionTransaction: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Hashable, Sendable {
        /// Intent and the pre-operation pin state are durable. No system
        /// eviction may begin before this record exists.
        case prepared
        /// File Provider has accepted the eviction request. Recovery must
        /// verify the materialization state before completing the transaction.
        case systemAccepted
        /// System eviction completed; the bridge still needs to stop
        /// advertising the local device as a source for this exact version.
        case contentRemoved
    }

    public let id: UUID
    public let itemID: String
    public let folderID: FolderID
    public let folderIncarnationDigest: String
    public let configurationRevision: String
    public let contentVersion: Data
    public let previousPinned: Bool
    public var phase: Phase
    public let createdAt: Date
}

public struct ContentDirectoryEvictionIntent: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let itemID: String
    public let folderID: FolderID
    public let relativePath: String
    public let folderIncarnationDigest: String
    public let configurationRevision: String
    public var indexGeneration: UInt64
    public var cursor: IndexedItemPageCursor?
    public let createdAt: Date
}

public enum ContentEvictionDisposition: Hashable, Sendable {
    /// A newer keep-downloaded intent won the race with a directory batch.
    /// The caller must leave the materialized content untouched.
    case retained
    case waitingForUpload
    case ready(ContentEvictionTransaction)
}

public struct ContentRetentionFolderPolicy: Codable, Hashable, Sendable {
    public let folderID: FolderID
    public let folderIncarnationDigest: String
    public let generation: UInt64
    public let plan: FolderSelectionPlan
    public let previousPlan: FolderSelectionPlan?
}

private struct ContentUploadEvidence: Codable, Hashable, Sendable {
    let contentVersion: Data
    let metadataVersion: Data
    let size: Int64
    let uploaded: Bool
    let observedAt: Date
}

private struct ContentRetentionItemRecord: Codable, Hashable, Sendable {
    let itemID: String
    let folderID: FolderID
    let folderIncarnationDigest: String
    var relativePath: String
    var isDirectoryScope: Bool
    var explicitPinned: Bool?
    var pendingEvict: Bool
    var uploadEvidence: ContentUploadEvidence?
}

private struct ContentRetentionDocument: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var generation: UInt64 = 0
    var policies: [ContentRetentionFolderPolicy] = []
    var items: [ContentRetentionItemRecord] = []
    var transactions: [ContentEvictionTransaction] = []
    var directoryEvictions: [ContentDirectoryEvictionIntent]?
    var materializedSetReconciliationPending: Bool?
    var materializedSetReconciliationDomains: [String]?
    var backgroundScanCursor: IndexedItemPageCursor?
}

/// Inter-process-linearized source of truth for mobile content retention.
///
/// The store never reads or writes `.stignore`. Folder plans are evaluated
/// against global-index metadata and affect only keep-downloaded intent.
/// Explicit item/directory intent wins over the folder plan. Every mutation is
/// serialized by a file lock and published with an atomic, no-follow writer so
/// App, File Provider, BGTask, and App Intents share one recoverable state.
public struct ContentRetentionStore: Sendable {
    public static let maximumDocumentBytes: Int64 = 4 * 1_048_576
    public static let maximumPolicies = 4_096
    public static let maximumItems = 100_000
    public static let maximumTransactions = 4_096
    public static let maximumDirectoryEvictions = 4_096

    public static func folderRootScopeItemID(_ folderID: FolderID) -> String {
        "psy-retention-folder-root:\(folderID.rawValue)"
    }

    private let url: URL
    private let lockURL: URL

    public init(url: URL) {
        self.url = url
        lockURL = url.appendingPathExtension("lock")
    }

    @discardableResult
    public func applyPlan(
        folderID: FolderID,
        folderIncarnationDigest: String,
        expectedGeneration: UInt64,
        plan: FolderSelectionPlan
    ) throws -> ContentRetentionFolderPolicy {
        guard Self.isCanonicalDigest(folderIncarnationDigest) else {
            throw ContentRetentionStoreError.invalidDocument
        }
        if let issue = plan.validate().first { throw issue }
        return try mutate { document in
            Self.reconcileIncarnation(
                folderID: folderID,
                digest: folderIncarnationDigest,
                document: &document
            )
            let current = document.policies.first(where: { $0.folderID == folderID })
            let currentGeneration = current?.generation ?? 0
            guard currentGeneration == expectedGeneration else {
                throw ContentRetentionStoreError.generationCollision(
                    current: currentGeneration,
                    expected: expectedGeneration
                )
            }
            guard currentGeneration < UInt64.max else {
                throw ContentRetentionStoreError.generationOverflow
            }
            let policy = ContentRetentionFolderPolicy(
                folderID: folderID,
                folderIncarnationDigest: folderIncarnationDigest,
                generation: currentGeneration + 1,
                plan: plan,
                previousPlan: current?.plan
            )
            document.policies.removeAll { $0.folderID == folderID }
            document.policies.append(policy)
            return policy
        }
    }

    public func status(
        for item: IndexedItem,
        folderIncarnationDigest: String
    ) throws -> ContentRetentionStatus {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try readUnlocked()
            let changed = Self.reconcileIncarnation(
                folderID: item.folderID,
                digest: folderIncarnationDigest,
                document: &document
            )
            if changed { try writeAdvancedUnlocked(&document) }
            return try Self.status(
                for: item,
                folderIncarnationDigest: folderIncarnationDigest,
                document: document
            )
        }
    }

    public func keepDownloaded(
        itemID: String,
        folderID: FolderID,
        relativePath: String,
        isDirectory: Bool,
        folderIncarnationDigest: String
    ) throws {
        return try mutate { document in
            Self.reconcileIncarnation(
                folderID: folderID,
                digest: folderIncarnationDigest,
                document: &document
            )
            var record = Self.itemRecord(
                itemID: itemID,
                folderID: folderID,
                relativePath: relativePath,
                folderIncarnationDigest: folderIncarnationDigest,
                document: document
            )
            record.relativePath = normalizedSelectionPath(relativePath)
            record.isDirectoryScope = isDirectory
            record.explicitPinned = true
            record.pendingEvict = false
            Self.upsert(record, in: &document)
            // Keep may race an already-started system eviction. Retain its
            // transaction for completion, but revoke its core-release authority.
            let activeIDs = Set(
                document.transactions.filter {
                    $0.folderID == folderID && $0.folderIncarnationDigest == folderIncarnationDigest
                }.map(\.itemID))
            for index in document.items.indices
            where activeIDs.contains(document.items[index].itemID)
                && document.items[index].folderID == folderID
                && document.items[index].folderIncarnationDigest == folderIncarnationDigest
            {
                if document.items[index].itemID == itemID
                    || (isDirectory
                        && selectionPath(document.items[index].relativePath, isDescendantOf: record.relativePath))
                {
                    document.items[index].explicitPinned = true
                }
            }
            if isDirectory {
                for index in document.items.indices
                where document.items[index].folderID == folderID
                    && document.items[index].folderIncarnationDigest == folderIncarnationDigest
                    && selectionPath(
                        document.items[index].relativePath,
                        isDescendantOf: record.relativePath
                    )
                {
                    document.items[index].pendingEvict = false
                }
                document.directoryEvictions?.removeAll {
                    $0.folderID == folderID
                        && ($0.itemID == itemID
                            || selectionPath($0.relativePath, isDescendantOf: record.relativePath))
                }
            }
        }
    }

    /// Clears retention for an item or directory scope without requesting an
    /// immediate eviction. Directory removal uses this first so future
    /// descendants inherit the unpinned intent, then handles each currently
    /// materialized regular file independently.
    public func allowAutomaticEviction(
        itemID: String,
        folderID: FolderID,
        relativePath: String,
        isDirectory: Bool,
        folderIncarnationDigest: String
    ) throws {
        return try mutate { document in
            Self.reconcileIncarnation(
                folderID: folderID,
                digest: folderIncarnationDigest,
                document: &document
            )
            let normalizedPath = normalizedSelectionPath(relativePath)
            if isDirectory {
                let descendantIDs = Set(
                    document.items.filter {
                        $0.folderID == folderID
                            && $0.folderIncarnationDigest == folderIncarnationDigest
                            && ($0.relativePath == normalizedPath
                                || selectionPath($0.relativePath, isDescendantOf: normalizedPath))
                    }.map(\.itemID)
                )
                for index in document.items.indices
                where document.items[index].folderID == folderID
                    && document.items[index].folderIncarnationDigest == folderIncarnationDigest
                    && descendantIDs.contains(document.items[index].itemID)
                {
                    document.items[index].explicitPinned = false
                    document.items[index].pendingEvict = false
                }
            }
            var record = Self.itemRecord(
                itemID: itemID,
                folderID: folderID,
                relativePath: relativePath,
                folderIncarnationDigest: folderIncarnationDigest,
                document: document
            )
            record.relativePath = normalizedPath
            record.isDirectoryScope = isDirectory
            record.explicitPinned = false
            record.pendingEvict = false
            Self.upsert(record, in: &document)
            if !isDirectory {
                document.transactions.removeAll {
                    $0.folderID == folderID && $0.itemID == itemID
                }
            }
        }
    }

    /// Starts or resumes a durable directory traversal. The directory scope is
    /// made unpinned before any child eviction begins; each regular-file
    /// eviction still owns its own exact-version transaction. If the metadata
    /// generation changed since an interrupted traversal, the cursor restarts
    /// from the beginning and idempotently rechecks every descendant.
    @discardableResult
    public func beginDirectoryEviction(
        itemID: String,
        folderID: FolderID,
        relativePath: String,
        folderIncarnationDigest: String,
        configurationRevision: String,
        indexGeneration: UInt64
    ) throws -> ContentDirectoryEvictionIntent {
        guard Self.isCanonicalDigest(folderIncarnationDigest),
            Self.isCanonicalDigest(configurationRevision),
            !itemID.isEmpty
        else {
            throw ContentRetentionStoreError.invalidDocument
        }
        return try mutate { document in
            Self.reconcileIncarnation(
                folderID: folderID,
                digest: folderIncarnationDigest,
                document: &document
            )
            let normalizedPath = normalizedSelectionPath(relativePath)
            var root = Self.itemRecord(
                itemID: itemID,
                folderID: folderID,
                relativePath: normalizedPath,
                folderIncarnationDigest: folderIncarnationDigest,
                document: document
            )
            root.relativePath = normalizedPath
            root.isDirectoryScope = true
            root.explicitPinned = false
            root.pendingEvict = false
            Self.upsert(root, in: &document)
            for index in document.items.indices
            where document.items[index].folderID == folderID
                && document.items[index].folderIncarnationDigest == folderIncarnationDigest
                && selectionPath(
                    document.items[index].relativePath,
                    isDescendantOf: normalizedPath
                )
            {
                document.items[index].explicitPinned = false
            }

            var intents = document.directoryEvictions ?? []
            if let index = intents.firstIndex(where: {
                $0.folderID == folderID && $0.itemID == itemID
            }) {
                guard intents[index].folderIncarnationDigest == folderIncarnationDigest,
                    intents[index].configurationRevision == configurationRevision,
                    intents[index].relativePath == normalizedPath
                else {
                    throw ContentRetentionStoreError.invalidDocument
                }
                if intents[index].indexGeneration != indexGeneration {
                    intents[index].indexGeneration = indexGeneration
                    intents[index].cursor = nil
                }
                document.directoryEvictions = intents
                return intents[index]
            }
            let intent = ContentDirectoryEvictionIntent(
                id: UUID(),
                itemID: itemID,
                folderID: folderID,
                relativePath: normalizedPath,
                folderIncarnationDigest: folderIncarnationDigest,
                configurationRevision: configurationRevision,
                indexGeneration: indexGeneration,
                cursor: nil,
                createdAt: .now
            )
            intents.append(intent)
            document.directoryEvictions = intents
            return intent
        }
    }

    public func directoryEvictionIntents() throws -> [ContentDirectoryEvictionIntent] {
        try FileLock.withExclusiveLock(at: lockURL) {
            try (readUnlocked().directoryEvictions ?? []).sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    /// Restarts only an already-active traversal after the derived metadata
    /// generation changed. If a newer Keep Downloaded intent cancelled the
    /// traversal, this returns nil and never recreates or unpins it.
    public func restartDirectoryEviction(
        intentID: UUID,
        indexGeneration: UInt64
    ) throws -> ContentDirectoryEvictionIntent? {
        try mutate { document in
            var intents = document.directoryEvictions ?? []
            guard let index = intents.firstIndex(where: { $0.id == intentID }) else {
                return nil
            }
            intents[index].indexGeneration = indexGeneration
            intents[index].cursor = nil
            document.directoryEvictions = intents
            return intents[index]
        }
    }

    /// Persists the next page cursor. A nil cursor means the final page was
    /// processed and removes the durable traversal intent.
    public func advanceDirectoryEviction(
        intentID: UUID,
        indexGeneration: UInt64,
        nextCursor: IndexedItemPageCursor?
    ) throws {
        try mutate { document in
            var intents = document.directoryEvictions ?? []
            guard let index = intents.firstIndex(where: { $0.id == intentID }),
                intents[index].indexGeneration == indexGeneration
            else {
                throw ContentRetentionStoreError.invalidDocument
            }
            if let nextCursor {
                intents[index].cursor = nextCursor
            } else {
                intents.remove(at: index)
            }
            document.directoryEvictions = intents
        }
    }

    @discardableResult
    public func requestEviction(
        of item: IndexedItem,
        folderIncarnationDigest: String,
        configurationRevision: String,
        preservingCurrentPin: Bool = false
    ) throws -> ContentEvictionDisposition {
        guard Self.isCanonicalDigest(configurationRevision) else {
            throw ContentRetentionStoreError.invalidDocument
        }
        return try mutate { document in
            Self.reconcileIncarnation(
                folderID: item.folderID,
                digest: folderIncarnationDigest,
                document: &document
            )
            let previous = try Self.status(
                for: item,
                folderIncarnationDigest: folderIncarnationDigest,
                document: document
            )
            if preservingCurrentPin && previous.isPinned {
                return .retained
            }
            var record = Self.itemRecord(
                itemID: item.id,
                folderID: item.folderID,
                relativePath: item.relativePath,
                folderIncarnationDigest: folderIncarnationDigest,
                document: document
            )
            record.relativePath = normalizedSelectionPath(item.relativePath)
            record.isDirectoryScope = item.isDirectory
            record.explicitPinned = false
            if item.isUploaded || Self.hasUploadInvalidation(item) {
                record.uploadEvidence = Self.evidence(for: item)
            } else if record.uploadEvidence?.contentVersion != item.contentVersion
                || record.uploadEvidence?.metadataVersion != item.metadataVersion
                || record.uploadEvidence?.size != item.size
            {
                record.uploadEvidence = nil
            }
            if !previous.isPinned,
                let existing = document.transactions.first(where: {
                    $0.folderID == item.folderID
                        && $0.itemID == item.id
                        && $0.folderIncarnationDigest == folderIncarnationDigest
                        && $0.configurationRevision == configurationRevision
                        && $0.contentVersion == item.contentVersion
                })
            {
                Self.upsert(record, in: &document)
                return .ready(existing)
            }
            document.transactions.removeAll {
                $0.folderID == item.folderID && $0.itemID == item.id
            }
            if previous.isUploaded {
                record.pendingEvict = false
                let transaction = ContentEvictionTransaction(
                    id: UUID(),
                    itemID: item.id,
                    folderID: item.folderID,
                    folderIncarnationDigest: folderIncarnationDigest,
                    configurationRevision: configurationRevision,
                    contentVersion: item.contentVersion,
                    previousPinned: previous.isPinned,
                    phase: .prepared,
                    createdAt: .now
                )
                document.transactions.append(transaction)
                Self.upsert(record, in: &document)
                return .ready(transaction)
            }
            record.pendingEvict = true
            Self.upsert(record, in: &document)
            return .waitingForUpload
        }
    }

    /// Persists upload proof for the exact indexed version and promotes a
    /// waiting eviction to a durable transaction when it becomes eligible.
    @discardableResult
    public func recordUploadEvidence(
        for item: IndexedItem,
        folderIncarnationDigest: String,
        configurationRevision: String
    ) throws -> ContentEvictionTransaction? {
        guard Self.isCanonicalDigest(configurationRevision) else {
            throw ContentRetentionStoreError.invalidDocument
        }
        return try mutate { document in
            Self.reconcileIncarnation(
                folderID: item.folderID,
                digest: folderIncarnationDigest,
                document: &document
            )
            var record = Self.itemRecord(
                itemID: item.id,
                folderID: item.folderID,
                relativePath: item.relativePath,
                folderIncarnationDigest: folderIncarnationDigest,
                document: document
            )
            record.relativePath = normalizedSelectionPath(item.relativePath)
            record.uploadEvidence = Self.evidence(for: item)
            guard record.pendingEvict, item.isUploaded else {
                Self.upsert(record, in: &document)
                return nil
            }
            if let existing = document.transactions.first(where: {
                $0.folderID == item.folderID && $0.itemID == item.id
            }) {
                Self.upsert(record, in: &document)
                return existing
            }
            record.pendingEvict = false
            let transaction = ContentEvictionTransaction(
                id: UUID(),
                itemID: item.id,
                folderID: item.folderID,
                folderIncarnationDigest: folderIncarnationDigest,
                configurationRevision: configurationRevision,
                contentVersion: item.contentVersion,
                previousPinned: false,
                phase: .prepared,
                createdAt: .now
            )
            document.transactions.append(transaction)
            Self.upsert(record, in: &document)
            return transaction
        }
    }

    public func coreEvictionIsRequested(transactionID: UUID) throws -> Bool {
        try FileLock.withExclusiveLock(at: lockURL) {
            let document = try readUnlocked()
            guard let transaction = document.transactions.first(where: { $0.id == transactionID }),
                let record = document.items.first(where: {
                    $0.itemID == transaction.itemID && $0.folderID == transaction.folderID
                        && $0.folderIncarnationDigest == transaction.folderIncarnationDigest
                })
            else { return false }
            return record.explicitPinned == false
        }
    }

    public func pendingTransactions() throws -> [ContentEvictionTransaction] {
        try FileLock.withExclusiveLock(at: lockURL) {
            try readUnlocked().transactions.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    public func markMaterializedSetReconciliationPending() throws {
        try mutate { document in
            document.materializedSetReconciliationPending = true
        }
    }

    public func completeMaterializedSetReconciliation() throws {
        try mutate { document in
            document.materializedSetReconciliationPending = false
        }
    }

    public func isMaterializedSetReconciliationPending() throws -> Bool {
        try FileLock.withExclusiveLock(at: lockURL) {
            try readUnlocked().materializedSetReconciliationPending == true
        }
    }

    public func markMaterializedSetReconciliationPending(
        domainIdentifier: String
    ) throws {
        try mutate { document in
            var domains = Set(document.materializedSetReconciliationDomains ?? [])
            domains.insert(domainIdentifier)
            document.materializedSetReconciliationDomains = domains.sorted()
        }
    }

    public func completeMaterializedSetReconciliation(
        domainIdentifier: String
    ) throws {
        try mutate { document in
            var domains = Set(document.materializedSetReconciliationDomains ?? [])
            domains.remove(domainIdentifier)
            document.materializedSetReconciliationDomains = domains.sorted()
        }
    }

    public func isMaterializedSetReconciliationPending(
        domainIdentifier: String
    ) throws -> Bool {
        try FileLock.withExclusiveLock(at: lockURL) {
            let document = try readUnlocked()
            return document.materializedSetReconciliationPending == true
                || (document.materializedSetReconciliationDomains ?? []).contains(domainIdentifier)
        }
    }

    /// Persists the metadata-index position used by bounded background work.
    /// A durable cursor prevents an offline pin near the start of the index
    /// from starving pending work later in a large folder. A nil cursor means
    /// the next opportunity starts a new pass from the beginning.
    public func backgroundScanCursor() throws -> IndexedItemPageCursor? {
        try FileLock.withExclusiveLock(at: lockURL) {
            try readUnlocked().backgroundScanCursor
        }
    }

    public func advanceBackgroundScanCursor(to cursor: IndexedItemPageCursor?) throws {
        try mutate { document in
            document.backgroundScanCursor = cursor
        }
    }

    public func folderPolicy(
        folderID: FolderID,
        folderIncarnationDigest: String
    ) throws -> ContentRetentionFolderPolicy? {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try readUnlocked()
            let changed = Self.reconcileIncarnation(
                folderID: folderID,
                digest: folderIncarnationDigest,
                document: &document
            )
            if changed { try writeAdvancedUnlocked(&document) }
            return document.policies.first {
                $0.folderID == folderID
                    && $0.folderIncarnationDigest == folderIncarnationDigest
            }
        }
    }

    public func advanceEviction(
        transactionID: UUID,
        to phase: ContentEvictionTransaction.Phase
    ) throws {
        try mutate { document in
            guard let index = document.transactions.firstIndex(where: { $0.id == transactionID }) else {
                throw ContentRetentionStoreError.transactionNotFound(transactionID)
            }
            let current = document.transactions[index].phase
            guard Self.phaseRank(phase) >= Self.phaseRank(current) else {
                throw ContentRetentionStoreError.invalidDocument
            }
            document.transactions[index].phase = phase
        }
    }

    public func completeEviction(transactionID: UUID) throws {
        try mutate { document in
            guard let transaction = document.transactions.first(where: { $0.id == transactionID }) else {
                throw ContentRetentionStoreError.transactionNotFound(transactionID)
            }
            if let index = document.items.firstIndex(where: {
                $0.folderID == transaction.folderID && $0.itemID == transaction.itemID
            }) {
                document.items[index].pendingEvict = false
            }
            document.transactions.removeAll { $0.id == transactionID }
        }
    }

    public func failEviction(transactionID: UUID) throws {
        try mutate { document in
            guard let transaction = document.transactions.first(where: { $0.id == transactionID }) else {
                throw ContentRetentionStoreError.transactionNotFound(transactionID)
            }
            if let index = document.items.firstIndex(where: {
                $0.folderID == transaction.folderID && $0.itemID == transaction.itemID
            }) {
                if document.items[index].explicitPinned != true {
                    document.items[index].explicitPinned = transaction.previousPinned
                }
                document.items[index].pendingEvict = false
            }
            document.transactions.removeAll { $0.id == transactionID }
        }
    }

    public func applying(
        to items: [IndexedItem],
        folderIncarnations: [FolderID: String]
    ) throws -> [IndexedItem] {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try readUnlocked()
            var changed = false
            for (folderID, digest) in folderIncarnations {
                changed =
                    Self.reconcileIncarnation(
                        folderID: folderID,
                        digest: digest,
                        document: &document
                    ) || changed
            }
            if changed { try writeAdvancedUnlocked(&document) }
            return try items.map { item in
                guard let digest = folderIncarnations[item.folderID] else { return item }
                let status = try Self.status(
                    for: item,
                    folderIncarnationDigest: digest,
                    document: document
                )
                var projected = item
                projected.isPinned = status.isPinned
                return projected
            }
        }
    }

    public func statuses(
        for items: [IndexedItem],
        folderIncarnations: [FolderID: String]
    ) throws -> [String: ContentRetentionStatus] {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try readUnlocked()
            var changed = false
            for (folderID, digest) in folderIncarnations {
                changed =
                    Self.reconcileIncarnation(
                        folderID: folderID,
                        digest: digest,
                        document: &document
                    ) || changed
            }
            if changed { try writeAdvancedUnlocked(&document) }
            return try Dictionary(
                uniqueKeysWithValues: items.compactMap { item in
                    guard let digest = folderIncarnations[item.folderID] else { return nil }
                    return (
                        item.id,
                        try Self.status(
                            for: item,
                            folderIncarnationDigest: digest,
                            document: document
                        )
                    )
                }
            )
        }
    }

    private func mutate<T>(_ body: (inout ContentRetentionDocument) throws -> T) throws -> T {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try readUnlocked()
            let value = try body(&document)
            try writeAdvancedUnlocked(&document)
            return value
        }
    }

    private func readUnlocked() throws -> ContentRetentionDocument {
        let data: Data?
        do {
            data = try SecureLockFile.readRegularFileIfPresent(
                at: url,
                maximumSize: Self.maximumDocumentBytes
            )
        } catch {
            throw ContentRetentionStoreError.invalidDocument
        }
        guard let data else { return ContentRetentionDocument() }
        guard !data.isEmpty else { throw ContentRetentionStoreError.invalidDocument }
        do {
            return try Self.validated(JSONDecoder().decode(ContentRetentionDocument.self, from: data))
        } catch let error as ContentRetentionStoreError {
            throw error
        } catch {
            throw ContentRetentionStoreError.invalidDocument
        }
    }

    private func writeAdvancedUnlocked(_ document: inout ContentRetentionDocument) throws {
        guard document.generation < UInt64.max else {
            throw ContentRetentionStoreError.generationOverflow
        }
        document.generation += 1
        document = try Self.validated(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard Int64(data.count) <= Self.maximumDocumentBytes else {
            throw ContentRetentionStoreError.tooManyRecords
        }
        try SecureLockFile.writeAtomically(data, to: url)
    }

    private static func status(
        for item: IndexedItem,
        folderIncarnationDigest: String,
        document: ContentRetentionDocument
    ) throws -> ContentRetentionStatus {
        let exact = document.items.first {
            $0.folderID == item.folderID && $0.itemID == item.id
                && $0.folderIncarnationDigest == folderIncarnationDigest
        }
        let inherited = document.items
            .filter {
                $0.folderID == item.folderID
                    && $0.folderIncarnationDigest == folderIncarnationDigest
                    && $0.isDirectoryScope
                    && $0.explicitPinned != nil
                    && ($0.relativePath == normalizedSelectionPath(item.relativePath)
                        || selectionPath(
                            normalizedSelectionPath(item.relativePath),
                            isDescendantOf: $0.relativePath
                        ))
            }
            .max { $0.relativePath.count < $1.relativePath.count }

        let planned: Bool
        if let plan = document.policies.first(where: {
            $0.folderID == item.folderID
                && $0.folderIncarnationDigest == folderIncarnationDigest
        })?.plan {
            planned = try plan.disposition(for: item).keepsDownloaded
        } else {
            planned = item.isPinned
        }
        let pinned = exact?.explicitPinned ?? inherited?.explicitPinned ?? planned

        let persistedUploaded: Bool
        if hasUploadInvalidation(item) {
            persistedUploaded = false
        } else if let evidence = exact?.uploadEvidence,
            evidence.contentVersion == item.contentVersion,
            evidence.metadataVersion == item.metadataVersion,
            evidence.size == item.size
        {
            persistedUploaded = evidence.uploaded
        } else {
            persistedUploaded = false
        }
        let transaction = document.transactions.first {
            $0.folderID == item.folderID && $0.itemID == item.id
                && $0.folderIncarnationDigest == folderIncarnationDigest
        }
        return ContentRetentionStatus(
            isPinned: pinned,
            pendingEvict: exact?.pendingEvict == true,
            isUploaded: item.isUploaded || persistedUploaded,
            evictionTransactionID: transaction?.id
        )
    }

    private static func evidence(for item: IndexedItem) -> ContentUploadEvidence {
        ContentUploadEvidence(
            contentVersion: item.contentVersion,
            metadataVersion: item.metadataVersion,
            size: item.size,
            uploaded: item.isUploaded,
            observedAt: .now
        )
    }

    private static func hasUploadInvalidation(_ item: IndexedItem) -> Bool {
        item.hasUnuploadedChanges
            || item.availability == .uploading
            || item.availability == .conflict
            || item.availability == .ignored
            || item.availability == .error
    }

    private static func itemRecord(
        itemID: String,
        folderID: FolderID,
        relativePath: String,
        folderIncarnationDigest: String,
        document: ContentRetentionDocument
    ) -> ContentRetentionItemRecord {
        document.items.first {
            $0.folderID == folderID && $0.itemID == itemID
                && $0.folderIncarnationDigest == folderIncarnationDigest
        }
            ?? ContentRetentionItemRecord(
                itemID: itemID,
                folderID: folderID,
                folderIncarnationDigest: folderIncarnationDigest,
                relativePath: normalizedSelectionPath(relativePath),
                isDirectoryScope: false,
                explicitPinned: nil,
                pendingEvict: false,
                uploadEvidence: nil
            )
    }

    private static func upsert(
        _ record: ContentRetentionItemRecord,
        in document: inout ContentRetentionDocument
    ) {
        document.items.removeAll {
            $0.folderID == record.folderID && $0.itemID == record.itemID
        }
        document.items.append(record)
    }

    @discardableResult
    private static func reconcileIncarnation(
        folderID: FolderID,
        digest: String,
        document: inout ContentRetentionDocument
    ) -> Bool {
        guard isCanonicalDigest(digest) else { return false }
        let knownDigests = Set(
            document.policies.filter { $0.folderID == folderID }.map(\.folderIncarnationDigest)
                + document.items.filter { $0.folderID == folderID }.map(\.folderIncarnationDigest)
                + document.transactions.filter { $0.folderID == folderID }.map(\.folderIncarnationDigest)
        )
        guard !knownDigests.isEmpty, knownDigests != [digest] else { return false }
        document.policies.removeAll { $0.folderID == folderID }
        document.items.removeAll { $0.folderID == folderID }
        document.transactions.removeAll { $0.folderID == folderID }
        document.directoryEvictions?.removeAll { $0.folderID == folderID }
        return true
    }

    private static func validated(
        _ candidate: ContentRetentionDocument
    ) throws -> ContentRetentionDocument {
        guard candidate.schemaVersion == ContentRetentionDocument.currentSchemaVersion else {
            throw ContentRetentionStoreError.unsupportedSchemaVersion(candidate.schemaVersion)
        }
        guard candidate.policies.count <= maximumPolicies,
            candidate.items.count <= maximumItems,
            candidate.transactions.count <= maximumTransactions,
            (candidate.directoryEvictions?.count ?? 0) <= maximumDirectoryEvictions
        else {
            throw ContentRetentionStoreError.tooManyRecords
        }
        var policyFolders = Set<FolderID>()
        for policy in candidate.policies {
            guard policyFolders.insert(policy.folderID).inserted,
                isCanonicalDigest(policy.folderIncarnationDigest),
                policy.generation > 0,
                policy.plan.validate().isEmpty
            else {
                throw ContentRetentionStoreError.invalidDocument
            }
        }
        var itemKeys = Set<String>()
        for item in candidate.items {
            let key = item.folderID.rawValue + "\u{0}" + item.itemID
            guard !item.itemID.isEmpty,
                itemKeys.insert(key).inserted,
                isCanonicalDigest(item.folderIncarnationDigest),
                item.relativePath == normalizedSelectionPath(item.relativePath)
            else {
                throw ContentRetentionStoreError.invalidDocument
            }
        }
        var transactionIDs = Set<UUID>()
        var transactionItems = Set<String>()
        for transaction in candidate.transactions {
            let itemKey = transaction.folderID.rawValue + "\u{0}" + transaction.itemID
            guard transactionIDs.insert(transaction.id).inserted,
                transactionItems.insert(itemKey).inserted,
                isCanonicalDigest(transaction.folderIncarnationDigest),
                !transaction.contentVersion.isEmpty
            else {
                throw ContentRetentionStoreError.invalidDocument
            }
        }
        var directoryIDs = Set<UUID>()
        var directoryItems = Set<String>()
        for intent in candidate.directoryEvictions ?? [] {
            let itemKey = intent.folderID.rawValue + "\u{0}" + intent.itemID
            guard directoryIDs.insert(intent.id).inserted,
                directoryItems.insert(itemKey).inserted,
                !intent.itemID.isEmpty,
                intent.relativePath == normalizedSelectionPath(intent.relativePath),
                isCanonicalDigest(intent.folderIncarnationDigest),
                isCanonicalDigest(intent.configurationRevision)
            else {
                throw ContentRetentionStoreError.invalidDocument
            }
        }
        if let cursor = candidate.backgroundScanCursor {
            guard !cursor.itemID.isEmpty,
                cursor.itemID.utf8.count <= 512,
                cursor.relativePath.utf8.count <= 4_096,
                cursor.relativePath == normalizedSelectionPath(cursor.relativePath)
            else {
                throw ContentRetentionStoreError.invalidDocument
            }
        }
        let reconciliationDomains = candidate.materializedSetReconciliationDomains ?? []
        guard reconciliationDomains.count <= 4_096,
            Set(reconciliationDomains).count == reconciliationDomains.count,
            reconciliationDomains.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("/") && !$0.contains(":")
            })
        else {
            throw ContentRetentionStoreError.invalidDocument
        }
        var canonical = candidate
        canonical.policies.sort { $0.folderID.rawValue < $1.folderID.rawValue }
        canonical.items.sort {
            if $0.folderID != $1.folderID {
                return $0.folderID.rawValue < $1.folderID.rawValue
            }
            return $0.itemID < $1.itemID
        }
        canonical.transactions.sort { $0.id.uuidString < $1.id.uuidString }
        canonical.directoryEvictions?.sort { $0.id.uuidString < $1.id.uuidString }
        canonical.materializedSetReconciliationDomains?.sort()
        return canonical
    }

    private static func phaseRank(_ phase: ContentEvictionTransaction.Phase) -> Int {
        switch phase {
        case .prepared: 0
        case .systemAccepted: 1
        case .contentRemoved: 2
        }
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

/// Read-side projection shared by the App and File Provider. Missing folder
/// incarnation authority leaves core metadata unchanged; a stale incarnation
/// causes the store to discard the old lifetime's intent before projection.
public struct ContentRetentionIntentResolver: Sendable {
    private let store: ContentRetentionStore
    private let incarnationStore: FolderIncarnationStore

    public init(
        store: ContentRetentionStore,
        incarnationStore: FolderIncarnationStore
    ) {
        self.store = store
        self.incarnationStore = incarnationStore
    }

    public init(metadataDatabaseURL: URL) {
        let metadata = metadataDatabaseURL.deletingLastPathComponent()
        self.init(
            store: ContentRetentionStore(
                url: metadata.appendingPathComponent("content-retention-v1.json")
            ),
            incarnationStore: FolderIncarnationStore(
                url: metadata.appendingPathComponent("folder-incarnations.json")
            )
        )
    }

    public func applying(to item: IndexedItem) throws -> IndexedItem {
        try applying(to: [item]).first ?? item
    }

    public func applying(to items: [IndexedItem]) throws -> [IndexedItem] {
        let incarnations = Dictionary(
            uniqueKeysWithValues: try incarnationStore.snapshot().records.map {
                ($0.folderID, $0.folderIncarnationDigest)
            }
        )
        return try store.applying(to: items, folderIncarnations: incarnations)
    }

    public func retainsEntireFolderOffline(_ folderID: FolderID) throws -> Bool {
        let context = try incarnationStore.policyContext(for: folderID)
        guard
            let policy = try store.folderPolicy(
                folderID: folderID,
                folderIncarnationDigest: context.folderIncarnationDigest
            )
        else {
            return false
        }
        return policy.plan.mode == .fullSync || policy.plan.mode == .pinnedOffline
    }
}
