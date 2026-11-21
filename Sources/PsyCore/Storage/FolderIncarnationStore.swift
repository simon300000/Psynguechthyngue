import CryptoKit
import Foundation

public enum FolderIncarnationStoreError: Error, Hashable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidDocument
    case tooManyRecords
    case generationOverflow
    case missingFolderIncarnation(String)
    case incarnationConflict(String)
    case incarnationMismatch(String)
    case creationCommandReused(String)
}

/// The App-owned identity bound to policy and accounting for one exact
/// configured-folder lifetime. `creationCommandID == nil` identifies a legacy
/// folder that predates durable creation commands.
public struct FolderIncarnationRecord: Codable, Hashable, Sendable {
    public let folderID: FolderID
    public let folderIncarnationDigest: String
    public let creationCommandID: UUID?

    fileprivate init(
        folderID: FolderID,
        folderIncarnationDigest: String,
        creationCommandID: UUID?
    ) {
        self.folderID = folderID
        self.folderIncarnationDigest = folderIncarnationDigest
        self.creationCommandID = creationCommandID
    }

    private enum CodingKeys: String, CodingKey {
        case folderID
        case folderIncarnationDigest
        case creationCommandID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawFolderID = try values.decode(String.self, forKey: .folderID)
        guard let folderID = FolderID(rawValue: rawFolderID), folderID.rawValue == rawFolderID else {
            throw DecodingError.dataCorruptedError(
                forKey: .folderID,
                in: values,
                debugDescription: "The folder identifier is not canonical."
            )
        }
        self.folderID = folderID
        folderIncarnationDigest = try values.decode(
            String.self,
            forKey: .folderIncarnationDigest
        )
        if let rawCommandID = try values.decodeIfPresent(
            String.self,
            forKey: .creationCommandID
        ) {
            guard let commandID = UUID(uuidString: rawCommandID),
                rawCommandID == commandID.uuidString.lowercased()
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .creationCommandID,
                    in: values,
                    debugDescription: "The creation command identifier is not canonical."
                )
            }
            creationCommandID = commandID
        } else {
            creationCommandID = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(folderID.rawValue, forKey: .folderID)
        try values.encode(folderIncarnationDigest, forKey: .folderIncarnationDigest)
        if let creationCommandID {
            try values.encode(
                creationCommandID.uuidString.lowercased(),
                forKey: .creationCommandID
            )
        }
    }
}

public struct FolderIncarnationDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generation: UInt64
    public let records: [FolderIncarnationRecord]

    fileprivate init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generation: UInt64 = 0,
        records: [FolderIncarnationRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.records = records
    }
}

/// Secure, inter-process-linearized storage for folder incarnations.
///
/// Creation-command identities are deterministic, making a command replay
/// after a crash idempotent. Legacy configuration discovery is intentionally
/// additive unless `authoritativeReconciliation` is explicitly true.
public struct FolderIncarnationStore: Sendable {
    public static let maximumDocumentBytes: Int64 = 1_048_576
    public static let maximumRecords = 4_096

    private let url: URL
    private let lockURL: URL

    public init(url: URL) {
        self.url = url
        lockURL = url.appendingPathExtension("lock")
    }

    public func snapshot() throws -> FolderIncarnationDocument {
        try FileLock.withExclusiveLock(at: lockURL) {
            try readUnlocked()
        }
    }

    /// Returns the exact current context. A missing entry is an error rather
    /// than a global-policy fallback, so callers fail closed.
    public func policyContext(for folderID: FolderID) throws -> FolderPolicyContext {
        try FileLock.withExclusiveLock(at: lockURL) {
            let document = try readUnlocked()
            guard let record = document.records.first(where: { $0.folderID == folderID }) else {
                throw FolderIncarnationStoreError.missingFolderIncarnation(folderID.rawValue)
            }
            return Self.context(for: record)
        }
    }

    /// Records a successful folder-creation command. Replaying the same
    /// command returns the existing incarnation without rewriting the file or
    /// advancing its generation. A different command cannot replace a live
    /// incarnation: the successful deletion must remove that exact incarnation
    /// first. This prevents a delayed old add replay from rolling identity back.
    @discardableResult
    public func recordSuccessfulCreation(
        folderID: FolderID,
        commandID: UUID
    ) throws -> FolderPolicyContext {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try readUnlocked()
            if let existing = document.records.first(where: { $0.folderID == folderID }),
                existing.creationCommandID == commandID
            {
                return Self.context(for: existing)
            }
            guard !document.records.contains(where: { $0.folderID == folderID }) else {
                throw FolderIncarnationStoreError.incarnationConflict(folderID.rawValue)
            }
            guard
                !document.records.contains(where: {
                    $0.creationCommandID == commandID
                })
            else {
                throw FolderIncarnationStoreError.creationCommandReused(
                    commandID.uuidString.lowercased()
                )
            }

            let record = FolderIncarnationRecord(
                folderID: folderID,
                folderIncarnationDigest: Self.creationDigest(
                    folderID: folderID,
                    commandID: commandID
                ),
                creationCommandID: commandID
            )
            var records = document.records
            records.append(record)
            document = try Self.advancedDocument(from: document, records: records)
            try writeUnlocked(document)
            return Self.context(for: record)
        }
    }

    /// Removes the identity only after the corresponding core deletion has
    /// succeeded. Repeated removal is an idempotent no-op. A delayed deletion
    /// for an older incarnation cannot remove a newly re-added folder.
    @discardableResult
    public func removeAfterSuccessfulDeletion(
        folderID: FolderID,
        expectedFolderIncarnationDigest: String
    ) throws -> Bool {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try readUnlocked()
            guard let existing = document.records.first(where: { $0.folderID == folderID }) else {
                return false
            }
            guard Self.isCanonicalDigest(expectedFolderIncarnationDigest),
                existing.folderIncarnationDigest == expectedFolderIncarnationDigest
            else {
                throw FolderIncarnationStoreError.incarnationMismatch(folderID.rawValue)
            }
            let records = document.records.filter { $0.folderID != folderID }
            document = try Self.advancedDocument(from: document, records: records)
            try writeUnlocked(document)
            return true
        }
    }

    /// Adds identities for configured folders that predate this registry.
    /// Existing identities are preserved. Unlisted identities are retained by
    /// default and are pruned only by an explicitly authoritative caller.
    @discardableResult
    public func ensureLegacyConfiguredFolders(
        _ folderIDs: [FolderID],
        authoritativeReconciliation: Bool = false
    ) throws -> [FolderPolicyContext] {
        try FileLock.withExclusiveLock(at: lockURL) {
            let requested = Set(folderIDs)
            guard requested.count <= Self.maximumRecords else {
                throw FolderIncarnationStoreError.tooManyRecords
            }

            var document = try readUnlocked()
            var recordsByID = Dictionary(
                uniqueKeysWithValues: document.records.map { ($0.folderID, $0) }
            )
            var changed = false

            if authoritativeReconciliation {
                let previousCount = recordsByID.count
                recordsByID = recordsByID.filter { requested.contains($0.key) }
                changed = recordsByID.count != previousCount
            }

            guard
                recordsByID.count + requested.subtracting(recordsByID.keys).count
                    <= Self.maximumRecords
            else {
                throw FolderIncarnationStoreError.tooManyRecords
            }

            var usedDigests = Set(recordsByID.values.map(\.folderIncarnationDigest))
            for folderID in requested.sorted(by: Self.folderSort) where recordsByID[folderID] == nil {
                let digest = Self.uniqueRandomDigest(excluding: &usedDigests)
                recordsByID[folderID] = FolderIncarnationRecord(
                    folderID: folderID,
                    folderIncarnationDigest: digest,
                    creationCommandID: nil
                )
                changed = true
            }

            if changed {
                document = try Self.advancedDocument(
                    from: document,
                    records: Array(recordsByID.values)
                )
                try writeUnlocked(document)
            }

            return try requested.sorted(by: Self.folderSort).map { folderID in
                guard let record = recordsByID[folderID] else {
                    throw FolderIncarnationStoreError.missingFolderIncarnation(folderID.rawValue)
                }
                return Self.context(for: record)
            }
        }
    }

    private func readUnlocked() throws -> FolderIncarnationDocument {
        let data: Data?
        do {
            data = try SecureLockFile.readRegularFileIfPresent(
                at: url,
                maximumSize: Self.maximumDocumentBytes
            )
        } catch {
            throw FolderIncarnationStoreError.invalidDocument
        }
        guard let data else { return FolderIncarnationDocument() }
        guard !data.isEmpty else { throw FolderIncarnationStoreError.invalidDocument }

        let value: StrictJSONValue
        do {
            value = try StrictJSONDocument.parse(data)
        } catch {
            throw FolderIncarnationStoreError.invalidDocument
        }
        try StrictFolderIncarnationSchema.validate(value)

        do {
            return try Self.validatedCanonical(
                JSONDecoder().decode(FolderIncarnationDocument.self, from: data)
            )
        } catch let error as FolderIncarnationStoreError {
            throw error
        } catch {
            throw FolderIncarnationStoreError.invalidDocument
        }
    }

    private func writeUnlocked(_ document: FolderIncarnationDocument) throws {
        let canonical = try Self.validatedCanonical(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonical)
        guard Int64(data.count) <= Self.maximumDocumentBytes else {
            throw FolderIncarnationStoreError.invalidDocument
        }
        try StrictFolderIncarnationSchema.validate(StrictJSONDocument.parse(data))
        try SecureLockFile.writeAtomically(data, to: url)
    }

    private static func validatedCanonical(
        _ candidate: FolderIncarnationDocument
    ) throws -> FolderIncarnationDocument {
        guard candidate.schemaVersion == FolderIncarnationDocument.currentSchemaVersion else {
            throw FolderIncarnationStoreError.unsupportedSchemaVersion(candidate.schemaVersion)
        }
        guard candidate.records.count <= maximumRecords,
            candidate.records.isEmpty || candidate.generation > 0
        else {
            throw FolderIncarnationStoreError.invalidDocument
        }

        var folderIDs = Set<FolderID>()
        var digests = Set<String>()
        var creationCommandIDs = Set<UUID>()
        for record in candidate.records {
            guard folderIDs.insert(record.folderID).inserted,
                isCanonicalDigest(record.folderIncarnationDigest),
                digests.insert(record.folderIncarnationDigest).inserted
            else {
                throw FolderIncarnationStoreError.invalidDocument
            }
            if let commandID = record.creationCommandID {
                guard creationCommandIDs.insert(commandID).inserted,
                    record.folderIncarnationDigest
                        == creationDigest(folderID: record.folderID, commandID: commandID)
                else {
                    throw FolderIncarnationStoreError.invalidDocument
                }
            }
        }

        return FolderIncarnationDocument(
            generation: candidate.generation,
            records: candidate.records.sorted { folderSort($0.folderID, $1.folderID) }
        )
    }

    private static func advancedDocument(
        from document: FolderIncarnationDocument,
        records: [FolderIncarnationRecord]
    ) throws -> FolderIncarnationDocument {
        guard document.generation < UInt64.max else {
            throw FolderIncarnationStoreError.generationOverflow
        }
        return try validatedCanonical(
            FolderIncarnationDocument(
                generation: document.generation + 1,
                records: records
            )
        )
    }

    private static func context(for record: FolderIncarnationRecord) -> FolderPolicyContext {
        FolderPolicyContext(
            folderID: record.folderID,
            folderIncarnationDigest: record.folderIncarnationDigest
        )
    }

    private static func folderSort(_ lhs: FolderID, _ rhs: FolderID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func creationDigest(folderID: FolderID, commandID: UUID) -> String {
        var material = Data("psy-folder-incarnation-v1".utf8)
        material.append(0)
        material.append(contentsOf: commandID.uuidString.lowercased().utf8)
        material.append(0)
        material.append(contentsOf: folderID.rawValue.utf8)
        return hex(SHA256.hash(data: material))
    }

    private static func uniqueRandomDigest(excluding usedDigests: inout Set<String>) -> String {
        var generator = SystemRandomNumberGenerator()
        while true {
            let bytes = (0..<32).map { _ in
                UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
            }
            let digest = hex(bytes)
            if usedDigests.insert(digest).inserted { return digest }
        }
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

private enum StrictFolderIncarnationSchema {
    static func validate(_ value: StrictJSONValue) throws {
        guard case .object(let documentEntries) = value else {
            throw FolderIncarnationStoreError.invalidDocument
        }
        guard Set(documentEntries.map(\.0)) == ["schemaVersion", "generation", "records"] else {
            throw FolderIncarnationStoreError.invalidDocument
        }
        guard case .number(let rawVersion)? = value.value(for: "schemaVersion"),
            let version = Int(rawVersion)
        else {
            throw FolderIncarnationStoreError.invalidDocument
        }
        guard version == FolderIncarnationDocument.currentSchemaVersion else {
            throw FolderIncarnationStoreError.unsupportedSchemaVersion(version)
        }
        guard case .number(let rawGeneration)? = value.value(for: "generation"),
            UInt64(rawGeneration) != nil,
            case .array(let records)? = value.value(for: "records"),
            records.count <= FolderIncarnationStore.maximumRecords
        else {
            throw FolderIncarnationStoreError.invalidDocument
        }

        let requiredRecordKeys: Set<String> = ["folderID", "folderIncarnationDigest"]
        let allowedRecordKeys = requiredRecordKeys.union(["creationCommandID"])
        for record in records {
            guard case .object(let entries) = record else {
                throw FolderIncarnationStoreError.invalidDocument
            }
            let keys = Set(entries.map(\.0))
            guard requiredRecordKeys.isSubset(of: keys), keys.isSubset(of: allowedRecordKeys),
                case .string? = record.value(for: "folderID"),
                case .string? = record.value(for: "folderIncarnationDigest")
            else {
                throw FolderIncarnationStoreError.invalidDocument
            }
            if let commandID = record.value(for: "creationCommandID"),
                case .string = commandID
            {
            } else if record.value(for: "creationCommandID") != nil {
                throw FolderIncarnationStoreError.invalidDocument
            }
        }
    }
}
