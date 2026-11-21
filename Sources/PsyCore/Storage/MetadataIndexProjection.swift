import Foundation
import SQLite3

public enum MetadataIndexProjectionState: String, Codable, Sendable {
    case ready
    case degraded
}

public struct MetadataIndexProjectionStatus: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var state: MetadataIndexProjectionState
    public var snapshotGeneration: UInt64
    public var indexedItemCount: Int?
    public var errorCode: String?
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        state: MetadataIndexProjectionState,
        snapshotGeneration: UInt64,
        indexedItemCount: Int? = nil,
        errorCode: String? = nil,
        updatedAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.snapshotGeneration = snapshotGeneration
        self.indexedItemCount = indexedItemCount
        self.errorCode = errorCode
        self.updatedAt = updatedAt
    }
}

/// Builds the query-oriented SQLite projection without making command completion depend on
/// a derived cache. The canonical core snapshot remains durable even if an index migration or
/// disk-pressure failure occurs; a later run can safely rebuild the projection from it.
public struct MetadataIndexProjector: Sendable {
    private let databaseURL: URL
    private let statusURL: URL
    private let retentionResolver: ContentRetentionIntentResolver

    public init(
        databaseURL: URL,
        statusURL: URL,
        retentionResolver: ContentRetentionIntentResolver? = nil
    ) {
        self.databaseURL = databaseURL
        self.statusURL = statusURL
        self.retentionResolver =
            retentionResolver
            ?? ContentRetentionIntentResolver(metadataDatabaseURL: databaseURL)
    }

    @discardableResult
    public func project(_ snapshot: CoreSnapshot) async -> MetadataIndexProjectionStatus {
        let status: MetadataIndexProjectionStatus
        do {
            let store = try IndexedMetadataStore(databaseURL: databaseURL)
            var projected = snapshot
            projected.items = try retentionResolver.applying(to: snapshot.items)
            _ = try await store.importSnapshot(projected)
            status = MetadataIndexProjectionStatus(
                state: .ready,
                snapshotGeneration: snapshot.generation,
                indexedItemCount: try await store.itemCount()
            )
        } catch {
            status = MetadataIndexProjectionStatus(
                state: .degraded,
                snapshotGeneration: snapshot.generation,
                errorCode: Self.stableErrorCode(error)
            )
        }
        try? persist(status)
        return status
    }

    public func readStatus() throws -> MetadataIndexProjectionStatus? {
        guard FileManager.default.fileExists(atPath: statusURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(MetadataIndexProjectionStatus.self, from: Data(contentsOf: statusURL))
        guard status.schemaVersion == 1 else { return nil }
        return status
    }

    private func persist(_ status: MetadataIndexProjectionStatus) throws {
        try FileManager.default.createDirectory(
            at: statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
        #else
            let options: Data.WritingOptions = [.atomic]
        #endif
        try encoder.encode(status).write(to: statusURL, options: options)
    }

    static func stableErrorCode(_ error: Error) -> String {
        if error is ContentRetentionStoreError || error is FolderIncarnationStoreError {
            return "metadataIndexRetentionStateFailure"
        }
        guard let error = error as? IndexedMetadataStoreError else {
            return "metadataIndexUnavailable"
        }
        switch error {
        case .sqlite(let code, _):
            switch code & 0xFF {
            case SQLITE_BUSY: return "metadataIndexSQLiteBusy"
            case SQLITE_LOCKED: return "metadataIndexSQLiteLocked"
            case SQLITE_READONLY: return "metadataIndexSQLiteReadOnly"
            case SQLITE_CANTOPEN: return "metadataIndexSQLiteCantOpen"
            case SQLITE_CORRUPT, SQLITE_NOTADB: return "metadataIndexSQLiteCorrupt"
            case SQLITE_FULL: return "metadataIndexSQLiteFull"
            case SQLITE_IOERR: return "metadataIndexSQLiteIO"
            case SQLITE_PERM, SQLITE_AUTH: return "metadataIndexSQLitePermission"
            default: return "metadataIndexSQLiteFailure"
            }
        case .databaseClosed:
            return "metadataIndexClosed"
        case .readOnly:
            return "metadataIndexReadOnly"
        case .unsupportedSnapshotSchema:
            return "metadataIndexSnapshotSchema"
        case .unsupportedDatabaseSchema:
            return "metadataIndexDatabaseSchema"
        case .generationRegression:
            return "metadataIndexGenerationRegression"
        case .generationCollision:
            return "metadataIndexGenerationCollision"
        case .generationOutOfRange:
            return "metadataIndexGenerationRange"
        case .invalidPageSize:
            return "metadataIndexPageSize"
        case .emptySearchQuery:
            return "metadataIndexEmptyQuery"
        case .invalidStoredValue:
            return "metadataIndexInvalidValue"
        case .integrityCheckFailed:
            return "metadataIndexIntegrityFailure"
        }
    }
}
