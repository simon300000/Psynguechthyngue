import Foundation

public struct SyncPolicyDocumentStore: Sendable {
    public static let maximumDocumentBytes: Int64 = 1_048_576

    private let url: URL
    private let lockURL: URL
    private let legacyBudgetTimeZoneIdentifier: String

    public init(
        url: URL,
        legacyBudgetTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) {
        self.url = url
        lockURL = url.appendingPathExtension("lock")
        self.legacyBudgetTimeZoneIdentifier = legacyBudgetTimeZoneIdentifier
    }

    /// Loads V2 or migrates a legacy bare `SyncPolicy` while holding the same
    /// secure inter-process lock used for the read and atomic replacement.
    public func load() throws -> SyncPolicyDocumentV2 {
        try FileLock.withExclusiveLock(at: lockURL) {
            try loadUnlocked(persistLegacyMigration: true)
        }
    }

    public func save(_ document: SyncPolicyDocumentV2) throws {
        try FileLock.withExclusiveLock(at: lockURL) {
            try writeUnlocked(document.validatedForPersistence())
        }
    }

    /// Atomically reads, mutates, validates, and replaces the document under a
    /// single secure inter-process lock. Callers must not re-enter this store
    /// from `mutation`.
    @discardableResult
    public func update(
        _ mutation: (inout SyncPolicyDocumentV2) throws -> Void
    ) throws -> SyncPolicyDocumentV2 {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try loadUnlocked(persistLegacyMigration: false)
            try mutation(&document)
            document = try document.validatedForPersistence()
            try writeUnlocked(document)
            return document
        }
    }

    /// Compatibility facade for existing global-policy editors. Folder
    /// overrides, their incarnation bindings, queue priorities, and the fixed
    /// budget timezone are preserved at the same linearization point as the
    /// global policy replacement.
    @discardableResult
    public func saveGlobalPreservingOverrides(
        _ policy: SyncPolicy
    ) throws -> SyncPolicyDocumentV2 {
        try update { document in
            document.global = policy
        }
    }

    /// Removes policy authority only when it is still bound to the caller's
    /// exact, previously trusted folder incarnation. A record for a re-added
    /// folder with the same ID is preserved and reported as stale.
    @discardableResult
    public func discardFolderOverride(
        expectedContext: FolderPolicyContext
    ) throws -> Bool {
        try FileLock.withExclusiveLock(at: lockURL) {
            var document = try loadUnlocked(persistLegacyMigration: false)
            guard
                let index = document.folderOverrides.firstIndex(where: {
                    $0.folderID == expectedContext.folderID
                })
            else {
                return false
            }
            guard
                document.folderOverrides[index].folderIncarnationDigest
                    == expectedContext.folderIncarnationDigest
            else {
                throw SyncPolicyDocumentError.staleFolderOverride(
                    folderID: expectedContext.folderID.rawValue
                )
            }
            document.folderOverrides.remove(at: index)
            try writeUnlocked(document.validatedForPersistence())
            return true
        }
    }

    private func loadUnlocked(
        persistLegacyMigration: Bool
    ) throws -> SyncPolicyDocumentV2 {
        try SyncPolicyDocumentV2.validateTimeZoneIdentifier(
            legacyBudgetTimeZoneIdentifier
        )
        guard
            let data = try SecureLockFile.readRegularFileIfPresent(
                at: url,
                maximumSize: Self.maximumDocumentBytes
            )
        else {
            return try SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: legacyBudgetTimeZoneIdentifier
            ).validated()
        }
        guard !data.isEmpty else { throw SyncPolicyDocumentError.invalidDocument }

        let shape = try StrictJSONDocument.parse(data)
        switch try StrictPolicySchema.classifyAndValidate(shape) {
        case .v2:
            return try decodeV2(data).validated()
        case .legacy:
            let policy = try decodeLegacy(data)
            try SyncPolicyDocumentV2.validate(policy)
            let migrated = try SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: legacyBudgetTimeZoneIdentifier,
                global: policy
            ).validated()
            if persistLegacyMigration { try writeUnlocked(migrated) }
            return migrated
        }
    }

    private func writeUnlocked(_ document: SyncPolicyDocumentV2) throws {
        let document = try document.validatedForPersistence()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard Int64(data.count) <= Self.maximumDocumentBytes else {
            throw SyncPolicyDocumentError.invalidPolicy("documentTooLarge")
        }
        // Validate the exact bytes before publishing them. This also keeps the
        // writer and reader schema allowlists from drifting apart.
        _ = try StrictPolicySchema.classifyAndValidate(
            StrictJSONDocument.parse(data)
        )
        try SecureLockFile.writeAtomically(data, to: url)
    }

    private func decodeV2(_ data: Data) throws -> SyncPolicyDocumentV2 {
        do {
            return try JSONDecoder().decode(SyncPolicyDocumentV2.self, from: data)
        } catch let error as SyncPolicyDocumentError {
            throw error
        } catch {
            throw SyncPolicyDocumentError.invalidDocument
        }
    }

    private func decodeLegacy(_ data: Data) throws -> SyncPolicy {
        do {
            return try JSONDecoder().decode(SyncPolicy.self, from: data)
        } catch let error as SyncPolicyDocumentError {
            throw error
        } catch {
            throw SyncPolicyDocumentError.invalidDocument
        }
    }
}

indirect enum StrictJSONValue {
    case object([(String, StrictJSONValue)])
    case array([StrictJSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null

    var objectEntries: [(String, StrictJSONValue)]? {
        guard case .object(let entries) = self else { return nil }
        return entries
    }

    func value(for key: String) -> StrictJSONValue? {
        objectEntries?.first(where: { $0.0 == key })?.1
    }
}

enum StrictJSONDocument {
    static func parse(_ data: Data) throws -> StrictJSONValue {
        guard data.count <= Int(SyncPolicyDocumentStore.maximumDocumentBytes) else {
            throw SyncPolicyDocumentError.invalidDocument
        }
        var parser = StrictJSONParser(bytes: Array(data))
        return try parser.parse()
    }
}

private struct StrictJSONParser {
    let bytes: [UInt8]
    var index = 0

    mutating func parse() throws -> StrictJSONValue {
        skipWhitespace()
        let result = try parseValue(path: "$", depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw SyncPolicyDocumentError.invalidDocument
        }
        return result
    }

    private mutating func parseValue(path: String, depth: Int) throws -> StrictJSONValue {
        guard depth <= 64, index < bytes.count else {
            throw SyncPolicyDocumentError.invalidDocument
        }
        switch bytes[index] {
        case 0x7B:
            return try parseObject(path: path, depth: depth)
        case 0x5B:
            return try parseArray(path: path, depth: depth)
        case 0x22:
            return .string(try parseString())
        case 0x74:
            try consume("true")
            return .boolean(true)
        case 0x66:
            try consume("false")
            return .boolean(false)
        case 0x6E:
            try consume("null")
            return .null
        case 0x2D, 0x30...0x39:
            return .number(try parseNumber())
        default:
            throw SyncPolicyDocumentError.invalidDocument
        }
    }

    private mutating func parseObject(path: String, depth: Int) throws -> StrictJSONValue {
        index += 1
        skipWhitespace()
        if consumeIf(0x7D) { return .object([]) }
        var entries: [(String, StrictJSONValue)] = []
        var keys = Set<String>()
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw SyncPolicyDocumentError.invalidDocument
            }
            let key = try parseString()
            let childPath = path + "." + key
            guard keys.insert(key).inserted else {
                throw SyncPolicyDocumentError.duplicateField(childPath)
            }
            skipWhitespace()
            guard consumeIf(0x3A) else { throw SyncPolicyDocumentError.invalidDocument }
            skipWhitespace()
            entries.append((key, try parseValue(path: childPath, depth: depth + 1)))
            skipWhitespace()
            if consumeIf(0x7D) { return .object(entries) }
            guard consumeIf(0x2C) else { throw SyncPolicyDocumentError.invalidDocument }
            skipWhitespace()
        }
    }

    private mutating func parseArray(path: String, depth: Int) throws -> StrictJSONValue {
        index += 1
        skipWhitespace()
        if consumeIf(0x5D) { return .array([]) }
        var values: [StrictJSONValue] = []
        while true {
            guard values.count < 16_384 else {
                throw SyncPolicyDocumentError.invalidDocument
            }
            values.append(
                try parseValue(
                    path: path + "[\(values.count)]",
                    depth: depth + 1
                )
            )
            skipWhitespace()
            if consumeIf(0x5D) { return .array(values) }
            guard consumeIf(0x2C) else { throw SyncPolicyDocumentError.invalidDocument }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        guard consumeIf(0x22) else { throw SyncPolicyDocumentError.invalidDocument }
        let tokenStart = index - 1
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                index += 1
                let token = Data(bytes[tokenStart..<index])
                do {
                    return try JSONDecoder().decode(String.self, from: token)
                } catch {
                    throw SyncPolicyDocumentError.invalidDocument
                }
            case 0x5C:
                index += 1
                guard index < bytes.count else {
                    throw SyncPolicyDocumentError.invalidDocument
                }
                index += 1
            case 0x00...0x1F:
                throw SyncPolicyDocumentError.invalidDocument
            default:
                index += 1
            }
        }
        throw SyncPolicyDocumentError.invalidDocument
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        _ = consumeIf(0x2D)
        guard index < bytes.count else { throw SyncPolicyDocumentError.invalidDocument }
        if consumeIf(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw SyncPolicyDocumentError.invalidDocument
            }
        } else {
            guard consumeDigit(in: 0x31...0x39) else {
                throw SyncPolicyDocumentError.invalidDocument
            }
            while consumeDigit(in: 0x30...0x39) {}
        }
        if consumeIf(0x2E) {
            guard consumeDigit(in: 0x30...0x39) else {
                throw SyncPolicyDocumentError.invalidDocument
            }
            while consumeDigit(in: 0x30...0x39) {}
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            guard consumeDigit(in: 0x30...0x39) else {
                throw SyncPolicyDocumentError.invalidDocument
            }
            while consumeDigit(in: 0x30...0x39) {}
        }
        guard let value = String(bytes: bytes[start..<index], encoding: .utf8) else {
            throw SyncPolicyDocumentError.invalidDocument
        }
        return value
    }

    private mutating func consume(_ literal: StaticString) throws {
        let expected = Array("\(literal)".utf8)
        guard index + expected.count <= bytes.count,
            Array(bytes[index..<(index + expected.count)]) == expected
        else {
            throw SyncPolicyDocumentError.invalidDocument
        }
        index += expected.count
    }

    private mutating func consumeDigit(in range: ClosedRange<UInt8>) -> Bool {
        guard index < bytes.count, range.contains(bytes[index]) else { return false }
        index += 1
        return true
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
            bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D
        {
            index += 1
        }
    }
}

private enum StrictPolicyShape {
    case legacy
    case v2
}

private enum StrictPolicySchema {
    private static let policyKeys: Set<String> = [
        "automaticallyAllowedNetworks",
        "cellularAccess",
        "allowExpensive",
        "allowConstrained",
        "maxCellularFileBytes",
        "maxExpensiveRunBytes",
        "dailyExpensiveBytes",
        "requirePowerForAllAutomaticWork",
        "requirePowerForLargeTransferBytes",
        "requirePowerForMaintenance",
        "minimumBatteryLevel",
        "lowPowerBehavior",
        "pauseTransfersAtThermalLevel",
        "minimumFreeDiskBytes",
        "automaticTimeWindows",
        "automaticBackgroundMode",
        "allowBackgroundUpload",
        "allowBackgroundDownload",
        "allowBackgroundScan",
        "allowTemporaryUserOverride",
    ]

    static func classifyAndValidate(_ value: StrictJSONValue) throws -> StrictPolicyShape {
        guard let entries = value.objectEntries else {
            throw SyncPolicyDocumentError.invalidDocument
        }
        if entries.contains(where: { $0.0 == "schemaVersion" }) {
            try validateObject(
                value,
                allowed: [
                    "schemaVersion",
                    "budgetTimeZoneIdentifier",
                    "global",
                    "folderOverrides",
                    "temporaryProfiles",
                ],
                path: "$"
            )
            guard case .number(let rawVersion)? = value.value(for: "schemaVersion"),
                let version = Int(rawVersion)
            else {
                throw SyncPolicyDocumentError.invalidDocument
            }
            guard version == SyncPolicyDocumentV2.currentSchemaVersion else {
                throw SyncPolicyDocumentError.unsupportedSchemaVersion(version)
            }
            guard let global = value.value(for: "global"),
                let overrides = value.value(for: "folderOverrides")
            else {
                throw SyncPolicyDocumentError.invalidDocument
            }
            try validatePolicy(global, path: "$.global")
            guard case .array(let entries) = overrides else {
                throw SyncPolicyDocumentError.invalidDocument
            }
            for (index, entry) in entries.enumerated() {
                let path = "$.folderOverrides[\(index)]"
                try validateObject(
                    entry,
                    allowed: ["folderID", "folderIncarnationDigest", "queuePriority", "policy"],
                    path: path
                )
                guard let policy = entry.value(for: "policy") else {
                    throw SyncPolicyDocumentError.invalidDocument
                }
                try validateOverride(policy, path: path + ".policy")
            }
            if let profiles = value.value(for: "temporaryProfiles") {
                guard case .array(let entries) = profiles else {
                    throw SyncPolicyDocumentError.invalidDocument
                }
                for (index, entry) in entries.enumerated() {
                    try validateObject(
                        entry,
                        allowed: [
                            "id", "name", "maximumNetworkBytes", "validitySeconds",
                            "requestsTemporaryOverride",
                        ],
                        path: "$.temporaryProfiles[\(index)]"
                    )
                }
            }
            return .v2
        }

        try validatePolicy(value, path: "$")
        return .legacy
    }

    private static func validatePolicy(_ value: StrictJSONValue, path: String) throws {
        try validateObject(value, allowed: policyKeys, path: path)
        if let windows = value.value(for: "automaticTimeWindows") {
            try validateWindows(windows, path: path + ".automaticTimeWindows")
        }
    }

    private static func validateOverride(_ value: StrictJSONValue, path: String) throws {
        try validateObject(value, allowed: policyKeys, path: path)
        for key in [
            "maxCellularFileBytes",
            "maxExpensiveRunBytes",
            "dailyExpensiveBytes",
            "requirePowerForLargeTransferBytes",
        ] {
            if let limit = value.value(for: key) {
                try validateObject(limit, allowed: ["mode", "bytes"], path: path + "." + key)
            }
        }
        if let windows = value.value(for: "automaticTimeWindows") {
            try validateWindows(windows, path: path + ".automaticTimeWindows")
        }
    }

    private static func validateWindows(_ value: StrictJSONValue, path: String) throws {
        guard case .array(let windows) = value else {
            throw SyncPolicyDocumentError.invalidDocument
        }
        for (index, window) in windows.enumerated() {
            try validateObject(
                window,
                allowed: ["weekdays", "startMinute", "endMinute"],
                path: path + "[\(index)]"
            )
        }
    }

    static func validateObject(
        _ value: StrictJSONValue,
        allowed: Set<String>,
        path: String
    ) throws {
        guard let entries = value.objectEntries else {
            throw SyncPolicyDocumentError.invalidDocument
        }
        for (key, _) in entries where !allowed.contains(key) {
            throw SyncPolicyDocumentError.unknownField(path + "." + key)
        }
    }
}
