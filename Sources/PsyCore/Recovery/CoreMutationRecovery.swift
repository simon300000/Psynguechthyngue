import Foundation

public enum CoreMutationRecoveryPayloadKind: String, Codable, CaseIterable, Hashable, Sendable {
    case file
    case directory
}

public enum CoreMutationRecoveryStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case prepared
    case retainedRequiresUserConfirmation
    case conflictRequiresManualCleanup
    case disposalApprovedPendingCleanup
}

public enum CoreMutationRecoveryValidationError: Error, Hashable, Sendable {
    case invalidRecoveryID
    case invalidFolderID
    case invalidCommandKind
    case invalidRelativePath
    case invalidDigest
    case invalidByteCount
    case invalidTimestamp
    case invalidQueryRequest
    case invalidPage
    case disposalRequiresOrdinaryConfirmation
    case disposalRequiresDangerousReview
    case invalidExport
}

/// Redacted metadata for one App-owned Go bridge mutation recovery payload.
/// It intentionally carries only a folder-relative path and content proof;
/// native storage locators and the original command UUID never cross the API.
public struct CoreMutationRecoverySummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String { recoveryID }
    public let recoveryID: String
    public let folderID: FolderID
    public let commandKind: CoreCommandKind
    public let relativePath: String
    public let payloadKind: CoreMutationRecoveryPayloadKind
    public let digest: String
    public let bytes: Int64
    public let createdAt: Date
    public let status: CoreMutationRecoveryStatus

    public init(
        recoveryID: String,
        folderID: FolderID,
        commandKind: CoreCommandKind,
        relativePath: String,
        payloadKind: CoreMutationRecoveryPayloadKind,
        digest: String,
        bytes: Int64,
        createdAt: Date,
        status: CoreMutationRecoveryStatus
    ) throws {
        guard Self.isLowercaseSHA256(recoveryID) else {
            throw CoreMutationRecoveryValidationError.invalidRecoveryID
        }
        guard !folderID.rawValue.isEmpty else {
            throw CoreMutationRecoveryValidationError.invalidFolderID
        }
        guard [.create, .modify, .move, .delete].contains(commandKind) else {
            throw CoreMutationRecoveryValidationError.invalidCommandKind
        }
        guard Self.isSafeRelativePath(relativePath) else {
            throw CoreMutationRecoveryValidationError.invalidRelativePath
        }
        guard Self.isLowercaseSHA256(digest) else {
            throw CoreMutationRecoveryValidationError.invalidDigest
        }
        guard bytes >= 0 else {
            throw CoreMutationRecoveryValidationError.invalidByteCount
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CoreMutationRecoveryValidationError.invalidTimestamp
        }
        self.recoveryID = recoveryID
        self.folderID = folderID
        self.commandKind = commandKind
        self.relativePath = relativePath
        self.payloadKind = payloadKind
        self.digest = digest
        self.bytes = bytes
        self.createdAt = createdAt
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case recoveryID
        case folderID
        case commandKind
        case relativePath
        case payloadKind
        case digest
        case bytes
        case createdAt
        case status
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let folderID = FolderID(
                rawValue: try values.decode(String.self, forKey: .folderID)
            )
        else {
            throw CoreMutationRecoveryValidationError.invalidFolderID
        }
        guard
            let commandKind = CoreCommandKind(
                rawValue: try values.decode(String.self, forKey: .commandKind)
            )
        else {
            throw CoreMutationRecoveryValidationError.invalidCommandKind
        }
        try self.init(
            recoveryID: try values.decode(String.self, forKey: .recoveryID),
            folderID: folderID,
            commandKind: commandKind,
            relativePath: try values.decode(String.self, forKey: .relativePath),
            payloadKind: try values.decode(CoreMutationRecoveryPayloadKind.self, forKey: .payloadKind),
            digest: try values.decode(String.self, forKey: .digest),
            bytes: try values.decode(Int64.self, forKey: .bytes),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            status: try values.decode(CoreMutationRecoveryStatus.self, forKey: .status)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(recoveryID, forKey: .recoveryID)
        try values.encode(folderID.rawValue, forKey: .folderID)
        try values.encode(commandKind.rawValue, forKey: .commandKind)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(payloadKind, forKey: .payloadKind)
        try values.encode(digest, forKey: .digest)
        try values.encode(bytes, forKey: .bytes)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(status, forKey: .status)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard (1...4096).contains(value.utf8.count),
            !value.hasPrefix("/"),
            !value.contains("\\"),
            !value.contains(":"),
            !value.contains("\0")
        else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && component.utf8.count <= 255
                && component.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
        }
    }
}

/// Exact wire request accepted by `QueryJSON(query: recoveries)`.
public struct CoreMutationRecoveryQueryRequest: Encodable, Hashable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let query: String
    public let cursor: String?
    public let limit: Int

    public init(requestID: String, cursor: String? = nil, limit: Int = 100) throws {
        guard (1...128).contains(requestID.utf8.count),
            requestID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            (1...200).contains(limit),
            cursor.map({ (1...512).contains($0.utf8.count) }) ?? true
        else {
            throw CoreMutationRecoveryValidationError.invalidQueryRequest
        }
        schemaVersion = 1
        self.requestID = requestID
        query = "recoveries"
        self.cursor = cursor
        self.limit = limit
    }
}

public struct CoreMutationRecoveryPage: Hashable, Sendable {
    public let recoveries: [CoreMutationRecoverySummary]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(
        recoveries: [CoreMutationRecoverySummary],
        nextCursor: String?,
        hasMore: Bool
    ) throws {
        let identifiers = Set(recoveries.map(\.recoveryID))
        guard recoveries.count <= 200,
            identifiers.count == recoveries.count,
            hasMore == (nextCursor != nil),
            !hasMore || !recoveries.isEmpty,
            nextCursor.map({ (1...512).contains($0.utf8.count) }) ?? true
        else {
            throw CoreMutationRecoveryValidationError.invalidPage
        }
        self.recoveries = recoveries
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public enum CoreMutationRecoveryCommandBuilder {
    public static func dispose(
        _ summary: CoreMutationRecoverySummary,
        id: UUID = UUID(),
        trigger: SyncTrigger = .user
    ) throws -> CoreCommand {
        guard
            summary.status == .retainedRequiresUserConfirmation
                || summary.status == .disposalApprovedPendingCleanup
        else {
            throw CoreMutationRecoveryValidationError.disposalRequiresDangerousReview
        }
        return CoreCommand(
            id: id,
            kind: .disposeRecovery,
            arguments: commonArguments(summary),
            trigger: trigger
        )
    }

    public static func disposeAfterDangerousReview(
        _ summary: CoreMutationRecoverySummary,
        id: UUID = UUID(),
        trigger: SyncTrigger = .user
    ) throws -> CoreCommand {
        guard
            summary.status == .prepared
                || summary.status == .conflictRequiresManualCleanup
        else {
            throw CoreMutationRecoveryValidationError.disposalRequiresOrdinaryConfirmation
        }
        var arguments = commonArguments(summary)
        arguments["payloadKind"] = summary.payloadKind.rawValue
        return CoreCommand(
            id: id,
            kind: .disposeRecoveryReviewed,
            arguments: arguments,
            trigger: trigger
        )
    }

    private static func commonArguments(
        _ summary: CoreMutationRecoverySummary
    ) -> [String: String] {
        [
            "recoveryID": summary.recoveryID,
            "digest": summary.digest,
            "byteCount": String(summary.bytes),
            "status": summary.status.rawValue,
            "confirmed": "true",
        ]
    }
}

/// App-owned, verified snapshot created by the native bridge for an explicit
/// system share. Its URL is derived from an opaque export ID and never reveals
/// the retained recovery payload's native locator.
public struct CoreMutationRecoveryExport: Hashable, Sendable, Identifiable {
    public var id: UUID { exportID }
    public let exportID: UUID
    public let url: URL
    public let payloadKind: CoreMutationRecoveryPayloadKind

    init(
        exportID: UUID,
        url: URL,
        payloadKind: CoreMutationRecoveryPayloadKind
    ) {
        self.exportID = exportID
        self.url = url
        self.payloadKind = payloadKind
    }
}

public enum CoreMutationRecoveryExportOutcome: Sendable {
    case completed(CoreMutationRecoveryExport)
    case coreBusy
    case configurationUnavailable
    case failed(code: String)
}

public enum CoreMutationRecoveryExportCleanupOutcome: Sendable, Equatable {
    case completed
    case coreBusy
    case configurationUnavailable
    case failed(code: String)
}

public enum CoreMutationRecoveryExportBuilder {
    public static func outputName(
        for summary: CoreMutationRecoverySummary,
        exportID: UUID
    ) -> String {
        let leaf = summary.relativePath.split(separator: "/").last.map(String.init) ?? "Recovery"
        let suffix = " Recovery " + String(exportID.uuidString.prefix(8))
        let candidate: String
        if summary.payloadKind == .file {
            let pathExtension = (leaf as NSString).pathExtension
            if pathExtension.isEmpty {
                candidate = leaf + suffix
            } else {
                candidate =
                    (leaf as NSString).deletingPathExtension + suffix + "." + pathExtension
            }
        } else {
            candidate = leaf + suffix
        }
        guard candidate.utf8.count <= 180 else {
            let fallback = "Recovery" + suffix
            guard summary.payloadKind == .file else { return fallback }
            let pathExtension = (leaf as NSString).pathExtension
            let withExtension =
                pathExtension.isEmpty ? fallback : fallback + "." + pathExtension
            return withExtension.utf8.count <= 180 ? withExtension : fallback
        }
        return candidate
    }

    public static func arguments(
        for summary: CoreMutationRecoverySummary,
        exportID: UUID,
        outputName: String
    ) throws -> [String: String] {
        guard isSafeOutputName(outputName) else {
            throw CoreMutationRecoveryValidationError.invalidExport
        }
        return [
            "recoveryID": summary.recoveryID,
            "folderID": summary.folderID.rawValue,
            "commandKind": summary.commandKind.rawValue,
            "relativePath": summary.relativePath,
            "payloadKind": summary.payloadKind.rawValue,
            "digest": summary.digest,
            "byteCount": String(summary.bytes),
            "status": summary.status.rawValue,
            "exportID": exportID.uuidString.lowercased(),
            "outputName": outputName,
        ]
    }

    public static func export(
        for summary: CoreMutationRecoverySummary,
        exportID: UUID,
        paths: SharedContainerPaths
    ) throws -> CoreMutationRecoveryExport {
        let outputName = outputName(for: summary, exportID: exportID)
        guard isSafeOutputName(outputName) else {
            throw CoreMutationRecoveryValidationError.invalidExport
        }
        let container = paths.coreMutationRecoveryExports.appendingPathComponent(
            ".psy-core-recovery-export-" + exportID.uuidString.lowercased(),
            isDirectory: true
        )
        return CoreMutationRecoveryExport(
            exportID: exportID,
            url: container.appendingPathComponent(
                outputName,
                isDirectory: summary.payloadKind == .directory
            ),
            payloadKind: summary.payloadKind
        )
    }

    private static func isSafeOutputName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.utf8.count <= 180
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

public enum CoreMutationRecoveryStableCode: String, CaseIterable, Hashable, Sendable {
    case invalidRecoveryID = "invalid_recovery_id"
    case invalidRecoverySummary = "invalid_recovery_summary"
    case recoveryNotDisposable = "recovery_not_disposable"
    case recoveryReviewRequired = "recovery_review_required"
    case recoveryConfirmationRequired = "recovery_confirmation_required"
    case recoveryNotFound = "recovery_not_found"
    case recoverySummaryMismatch = "recovery_summary_mismatch"
    case recoveryLocationUnavailable = "recovery_location_unavailable"
    case recoveryStoreCorrupt = "recovery_store_corrupt"
    case recoveryChanged = "recovery_changed"
    case recoveryDisposalFailed = "recovery_disposal_failed"
    case recoveryDisposalInterrupted = "recovery_disposal_interrupted"
    case invalidRecoveryExport = "invalid_recovery_export"
    case recoveryExportFailed = "recovery_export_failed"
    case recoveryExportCleanupFailed = "recovery_export_cleanup_failed"
    case invalidQuery = "invalid_query"
    case invalidCursor = "invalid_cursor"
    case queryFailed = "query_failed"
    case invalidRequest = "invalid_request"
    case unsupportedSchema = "unsupported_schema"
    case invalidRequestID = "invalid_request_id"
    case coreNotRunning = "core_not_running"
    case requestCacheFull = "request_cache_full"
    case requestIDConflict = "request_id_conflict"
    case internalError = "internal_error"
    case cancelled

    public static func validated(_ value: String) -> String? {
        Self(rawValue: value)?.rawValue
    }
}
