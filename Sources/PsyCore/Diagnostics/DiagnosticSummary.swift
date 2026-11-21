import Darwin
import Foundation

public struct DiagnosticBuildMetadata: Codable, Hashable, Sendable {
    public var appVersion: String
    public var appBuild: String
    public var coreRevision: String

    public init(appVersion: String, appBuild: String, coreRevision: String) {
        self.appVersion = Self.safeBuildValue(appVersion)
        self.appBuild = Self.safeBuildValue(appBuild)
        self.coreRevision = Self.safeBuildValue(coreRevision)
    }

    private static func safeBuildValue(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+@-")
        guard !value.isEmpty,
            value.utf8.count <= 160,
            value.unicodeScalars.allSatisfy(allowed.contains)
        else {
            return "unavailable"
        }
        return value
    }
}

public enum DiagnosticInputHealth: String, Codable, Hashable, Sendable {
    case ok
    case missing
    case symbolicLink
    case wrongType
    case oversize
    case unreadable
    case corrupt
    case truncated
    case changedDuringRead
    case entryLimitReached
}

/// Builds a versioned, path-free diagnostic summary from the App Group's
/// durable projections. Sensitive records are decoded only into narrow local
/// types and are immediately reduced to counts or closed enums. Command and
/// result payloads are never opened; their directories are counted by type.
public struct DiagnosticSummaryBuilder: Sendable {
    public static let maximumHistoryBytes = 4 * 1_024 * 1_024
    public static let maximumEncodedBytes = 1 * 1_024 * 1_024

    private static let maximumSnapshotBytes = 64 * 1_024 * 1_024
    private static let maximumPolicyBytes = 128 * 1_024
    private static let maximumBackgroundBytes = 128 * 1_024
    private static let maximumExternalDirectoryBytes = 4 * 1_024 * 1_024
    private static let maximumOwnerBytes = 64 * 1_024
    private static let maximumWorkingSetBytes = 64 * 1_024
    private static let maximumIndexStatusBytes = 128 * 1_024
    private static let maximumQueueEntries = 16_384
    private static let maximumStagingEntries = 4_096

    private let paths: SharedContainerPaths
    private let build: DiagnosticBuildMetadata
    private let generatedAtOverride: Date?
    private let saltOverride: Data?

    public init(
        paths: SharedContainerPaths,
        build: DiagnosticBuildMetadata,
        generatedAt: Date? = nil,
        salt: Data? = nil
    ) {
        self.paths = paths
        self.build = build
        generatedAtOverride = generatedAt
        saltOverride = salt
    }

    public func makeJSON() throws -> Data {
        let generatedAt = generatedAtOverride ?? .now
        let salt = saltOverride ?? Self.randomSalt()
        guard salt.count == 16 else { throw DiagnosticExportError.invalidSalt }

        let summary = DiagnosticSummary(
            schemaVersion: 1,
            generatedAt: generatedAt,
            exportSalt: Self.base64URL(salt),
            build: build,
            system: .current,
            snapshot: snapshotSummary(now: generatedAt),
            policy: policySummary(),
            runHistory: runHistorySummary(),
            backgroundScheduler: backgroundSummary(),
            queue: queueSummary(),
            staging: stagingSummary(),
            workingSet: workingSetSummary(),
            fileProviderIndex: indexStatusSummary(),
            owner: ownerSummary(now: generatedAt),
            externalDirectories: externalDirectorySummary()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(summary)
        guard !data.isEmpty, data.count <= Self.maximumEncodedBytes else {
            throw DiagnosticExportError.summaryTooLarge
        }
        return data
    }

    private func snapshotSummary(now: Date) -> SnapshotSummary {
        let result = StrictDiagnosticFileReader.read(
            paths.snapshot,
            maximumBytes: Self.maximumSnapshotBytes
        )
        guard let data = result.data else { return .empty(health: result.health) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(CoreSnapshot.self, from: data),
            snapshot.schemaVersion == 1
        else {
            return .empty(health: .corrupt)
        }

        var deviceStates: [String: Int] = [:]
        for device in snapshot.devices {
            deviceStates.increment(device.state.rawValue)
        }
        var folderTypes: [String: Int] = [:]
        var selectionModes: [String: Int] = [:]
        for folder in snapshot.folders {
            folderTypes.increment(folder.type.rawValue)
            selectionModes.increment(folder.selectionMode.rawValue)
        }
        var availability: [String: Int] = [:]
        for item in snapshot.items {
            availability.increment(item.availability.rawValue)
        }

        return SnapshotSummary(
            health: .ok,
            schemaVersion: snapshot.schemaVersion,
            generation: snapshot.generation,
            ageSeconds: Self.age(from: snapshot.generatedAt, to: now),
            localIdentityPresent: snapshot.localDeviceID != nil,
            deviceCount: snapshot.devices.count,
            deviceStates: deviceStates,
            pausedDeviceCount: snapshot.devices.count(where: { $0.isPaused }),
            deviceBlockingCount: snapshot.devices.count(where: { $0.blockingReason != nil }),
            folderCount: snapshot.folders.count,
            folderTypes: folderTypes,
            selectionModes: selectionModes,
            pausedFolderCount: snapshot.folders.count(where: { $0.isPaused }),
            folderErrorCount: snapshot.folders.count(where: { $0.error != nil }),
            pendingUploadBytes: Self.saturatingSum(snapshot.folders.map(\.pendingUploadBytes)),
            pendingDownloadBytes: Self.saturatingSum(snapshot.folders.map(\.pendingDownloadBytes)),
            itemCount: snapshot.items.count,
            directoryItemCount: snapshot.items.count(where: \.isDirectory),
            itemAvailability: availability,
            pinnedItemCount: snapshot.items.count(where: \.isPinned),
            unuploadedItemCount: snapshot.items.count(where: \.hasUnuploadedChanges),
            indexedRegularFileBytes: Self.saturatingSum(
                snapshot.items.lazy.filter { !$0.isDirectory }.map(\.size)
            ),
            tombstoneCount: snapshot.tombstones.count,
            pendingDeviceCount: snapshot.pendingDevices.count,
            pendingFolderCount: snapshot.pendingFolders.count,
            suppressedPendingDeviceCount: snapshot.suppressedPendingDevices.count,
            suppressedPendingFolderCount: snapshot.suppressedPendingFolders.count,
            pendingFoldersTruncated: snapshot.pendingFoldersTruncated,
            suppressedPendingDevicesTruncated: snapshot.suppressedPendingDevicesTruncated,
            suppressedPendingFoldersTruncated: snapshot.suppressedPendingFoldersTruncated
        )
    }

    private func policySummary() -> PolicySummary {
        let result = StrictDiagnosticFileReader.read(
            paths.policy,
            maximumBytes: Self.maximumPolicyBytes
        )
        if result.health == .missing {
            return PolicySummary(policy: SyncPolicy(), health: .missing)
        }
        guard let data = result.data,
            let policy = try? JSONDecoder().decode(SyncPolicy.self, from: data)
        else {
            return .empty(health: result.data == nil ? result.health : .corrupt)
        }
        return PolicySummary(policy: policy, health: .ok)
    }

    private func runHistorySummary() -> RunHistorySummary {
        let result = StrictDiagnosticFileReader.read(
            paths.history,
            maximumBytes: Self.maximumHistoryBytes
        )
        guard let data = result.data else { return .empty(health: result.health) }
        guard data.isEmpty || data.last == 0x0A else { return .empty(health: .truncated) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var decoded: [SyncRunRecord] = []
        decoded.reserveCapacity(min(lines.count, 100))
        for line in lines {
            guard line.count <= 128 * 1_024,
                let record = try? decoder.decode(SyncRunRecord.self, from: Data(line))
            else {
                return .empty(health: line.count > 128 * 1_024 ? .oversize : .corrupt)
            }
            decoded.append(record)
        }
        let records = decoded.suffix(100).reversed().map { record in
            DiagnosticRunRecord(
                trigger: record.trigger.rawValue,
                durationMilliseconds: Self.durationMilliseconds(
                    from: record.startedAt,
                    to: record.endedAt
                ),
                transferredBytes: max(0, record.transferredBytes),
                endReason: record.endReason.rawValue,
                failureCode: Self.safeStableCode(record.failureCode)
            )
        }
        return RunHistorySummary(
            health: .ok,
            retainedRecordCount: records.count,
            sourceRecordCount: decoded.count,
            records: records
        )
    }

    private func backgroundSummary() -> BackgroundSchedulerSummary {
        let result = StrictDiagnosticFileReader.read(
            paths.backgroundTaskScheduleStatus,
            maximumBytes: Self.maximumBackgroundBytes
        )
        guard let data = result.data else { return .empty(health: result.health) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(BackgroundTaskScheduleStatus.self, from: data),
            status.schemaVersion == BackgroundTaskScheduleStatus.currentSchemaVersion
        else {
            return .empty(health: .corrupt)
        }
        let attempts = [status.refresh, status.processing]
            .compactMap { $0 }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
            .map {
                BackgroundAttemptSummary(
                    kind: $0.kind.rawValue,
                    result: $0.result.rawValue,
                    failureCode: $0.failureCode?.rawValue,
                    requiresNetwork: $0.requiresNetworkConnectivity,
                    requiresExternalPower: $0.requiresExternalPower
                )
            }
        return BackgroundSchedulerSummary(health: .ok, attempts: attempts)
    }

    private func queueSummary() -> QueueSummary {
        let pending = DiagnosticDirectoryCounter.countJSONFiles(
            at: paths.commandQueue.appendingPathComponent("pending", isDirectory: true),
            limit: Self.maximumQueueEntries
        )
        let completed = DiagnosticDirectoryCounter.countJSONFiles(
            at: paths.commandQueue.appendingPathComponent("completed", isDirectory: true),
            limit: Self.maximumQueueEntries
        )
        let results = DiagnosticDirectoryCounter.countJSONFiles(
            at: paths.commandQueue.appendingPathComponent("results", isDirectory: true),
            limit: Self.maximumQueueEntries
        )
        return QueueSummary(
            pendingHealth: pending.health,
            completedHealth: completed.health,
            resultHealth: results.health,
            pendingCount: pending.count,
            completedCount: completed.count,
            resultCount: results.count,
            unsafeEntryCount: Self.saturatingAdd(
                pending.unsafeEntryCount,
                Self.saturatingAdd(completed.unsafeEntryCount, results.unsafeEntryCount)
            )
        )
    }

    private func stagingSummary() -> StagingSummary {
        var summary = DiagnosticDirectoryCounter.stagingSummary(
            at: paths.fileProviderStaging,
            limit: Self.maximumStagingEntries
        )
        let reservationURL = paths.fileProviderStaging.appendingPathComponent(
            ".reservations-v1.json",
            isDirectory: false
        )
        let result = StrictDiagnosticFileReader.read(
            reservationURL,
            maximumBytes: 1_048_576
        )
        summary.reservationHealth = result.health
        guard let data = result.data,
            let document = try? JSONDecoder().decode(DiagnosticReservationDocument.self, from: data),
            document.schemaVersion == 1,
            document.entries.count <= Self.maximumStagingEntries
        else {
            if result.data != nil { summary.reservationHealth = .corrupt }
            return summary
        }
        var identifiers = Set<UUID>()
        var bytes: Int64 = 0
        for entry in document.entries {
            guard entry.destinationBytes >= 0,
                identifiers.insert(entry.commandID).inserted
            else {
                summary.reservationHealth = .corrupt
                summary.reservationCount = 0
                summary.reservedDestinationBytes = 0
                return summary
            }
            let (sum, overflow) = bytes.addingReportingOverflow(entry.destinationBytes)
            guard !overflow else {
                summary.reservationHealth = .corrupt
                summary.reservationCount = 0
                summary.reservedDestinationBytes = 0
                return summary
            }
            bytes = sum
        }
        summary.reservationCount = identifiers.count
        summary.reservedDestinationBytes = bytes
        return summary
    }

    private func workingSetSummary() -> WorkingSetSummary {
        let result = StrictDiagnosticFileReader.read(
            paths.workingSetSignalState,
            maximumBytes: Self.maximumWorkingSetBytes
        )
        guard let data = result.data else { return .empty(health: result.health) }
        guard let state = try? JSONDecoder().decode(WorkingSetState.self, from: data),
            state.schemaVersion == 1
        else {
            return .empty(health: .corrupt)
        }
        return WorkingSetSummary(
            health: .ok,
            requestPending: state.pendingGeneration != nil,
            pendingGeneration: state.pendingGeneration
        )
    }

    private func indexStatusSummary() -> IndexStatusSummary {
        let result = StrictDiagnosticFileReader.read(
            paths.metadataIndexStatus,
            maximumBytes: Self.maximumIndexStatusBytes
        )
        guard let data = result.data else { return .empty(health: result.health) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let status = try? decoder.decode(MetadataIndexProjectionStatus.self, from: data),
            status.schemaVersion == 1
        else {
            return .empty(health: .corrupt)
        }
        return IndexStatusSummary(
            health: .ok,
            state: status.state.rawValue,
            snapshotGeneration: status.snapshotGeneration,
            indexedItemCount: status.indexedItemCount.map { max(0, $0) },
            errorCode: Self.safeStableCode(status.errorCode)
        )
    }

    private func ownerSummary(now: Date) -> OwnerSummary {
        let ownerURL = CoreProcessCoordinator.ownerMetadataURL(for: paths.coreLock)
        let result = StrictDiagnosticFileReader.read(
            ownerURL,
            maximumBytes: Self.maximumOwnerBytes
        )
        guard let data = result.data else { return .empty(health: result.health) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let lease = try? decoder.decode(CoreOwnerLease.self, from: data),
            lease.schemaVersion == CoreOwnerLease.schemaVersion,
            lease.epoch > 0
        else {
            return .empty(health: .corrupt)
        }
        return OwnerSummary(
            health: .ok,
            schemaVersion: lease.schemaVersion,
            epoch: lease.epoch,
            role: lease.role.rawValue,
            leaseAgeSeconds: Self.age(from: lease.acquiredAt, to: now)
        )
    }

    private func externalDirectorySummary() -> ExternalDirectorySummary {
        let result = StrictDiagnosticFileReader.read(
            paths.externalDirectoryRecords,
            maximumBytes: Self.maximumExternalDirectoryBytes
        )
        guard let data = result.data else { return .empty(health: result.health) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([ExternalDirectoryRecord].self, from: data),
            records.count <= Self.maximumStagingEntries,
            records.allSatisfy({
                (1...ExternalDirectoryRecord.currentSchemaVersion).contains($0.schemaVersion)
                    && $0.authorizationEpoch > 0
                    && $0.revision > 0
            })
        else {
            return .empty(health: .corrupt)
        }

        var modes: [String: Int] = [:]
        var authorizations: [String: Int] = [:]
        var mirrorPhases: [String: Int] = [:]
        var mirrorFailures: [String: Int] = [:]
        var bindingPhases: [String: Int] = [:]
        var capabilities: [String: Int] = [:]
        var pendingDeletionCount = 0
        for record in records {
            modes.increment(record.mode.rawValue)
            authorizations.increment(record.authorizationState.rawValue)
            mirrorPhases.increment(record.lastMirrorStatus.phase.rawValue)
            if let code = record.lastMirrorStatus.failureCode {
                mirrorFailures.increment(code.rawValue)
            }
            bindingPhases.increment(record.syncBinding.phase.rawValue)
            pendingDeletionCount = Self.saturatingAdd(
                pendingDeletionCount,
                record.pendingDeletionConfirmations.count
            )
            let value = record.capabilities
            capabilities.increment("canEnumerate", by: value.canEnumerate ? 1 : 0)
            capabilities.increment("canRead", by: value.canRead ? 1 : 0)
            capabilities.increment("canCreate", by: value.canCreate ? 1 : 0)
            capabilities.increment("canWrite", by: value.canWrite ? 1 : 0)
            capabilities.increment("canAtomicallyReplace", by: value.canAtomicallyReplace ? 1 : 0)
            capabilities.increment("canRename", by: value.canRename ? 1 : 0)
            capabilities.increment("canDelete", by: value.canDelete ? 1 : 0)
            capabilities.increment("canAccessRecursively", by: value.canAccessRecursively ? 1 : 0)
            capabilities.increment("cleanupSucceeded", by: value.cleanupSucceeded ? 1 : 0)
        }
        return ExternalDirectorySummary(
            health: .ok,
            recordCount: records.count,
            modes: modes,
            authorizationStates: authorizations,
            mirrorPhases: mirrorPhases,
            mirrorFailureCodes: mirrorFailures,
            bindingPhases: bindingPhases,
            capabilitySuccessCounts: capabilities,
            pendingDeletionConfirmationCount: pendingDeletionCount
        )
    }

    private static func randomSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func age(from date: Date, to now: Date) -> Int64 {
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds >= Double(Int64.max) ? .max : Int64(seconds.rounded(.down))
    }

    private static func durationMilliseconds(from start: Date, to end: Date) -> Int64 {
        let milliseconds = end.timeIntervalSince(start) * 1_000
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        return milliseconds >= Double(Int64.max) ? .max : Int64(milliseconds.rounded())
    }

    private static func saturatingSum<S: Sequence>(_ values: S) -> Int64 where S.Element == Int64 {
        values.reduce(0) { partial, value in
            let nonnegative = max(0, value)
            let (sum, overflow) = partial.addingReportingOverflow(nonnegative)
            return overflow ? .max : sum
        }
    }

    fileprivate static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }

    private static func safeStableCode(_ code: String?) -> String? {
        guard let code else { return nil }
        return stableCodes.contains(code) ? code : "unrecognized"
    }

    private static let stableCodes: Set<String> = {
        var values: Set<String> = [
            "bridgeUnavailable", "cancelled", "configurationUnavailable",
            "coreBusy", "coreExecutionFailed", "coreInvalidResponse",
            "coreOwnershipFailed", "coreStopFailed", "expired",
            "identityUnavailable", "indeterminate_prior_attempt",
            "internal_error", "invalid_base_version", "invalid_request",
            "metadataIndexClosed", "metadataIndexDatabaseSchema",
            "metadataIndexEmptyQuery", "metadataIndexGenerationCollision",
            "metadataIndexGenerationRange", "metadataIndexGenerationRegression",
            "metadataIndexIntegrityFailure", "metadataIndexInvalidValue",
            "metadataIndexPageSize", "metadataIndexReadOnly",
            "metadataIndexSQLiteBusy", "metadataIndexSQLiteCantOpen",
            "metadataIndexSQLiteCorrupt", "metadataIndexSQLiteFailure",
            "metadataIndexSQLiteFull", "metadataIndexSQLiteIO",
            "metadataIndexSQLiteLocked", "metadataIndexSQLitePermission",
            "metadataIndexSQLiteReadOnly", "metadataIndexSnapshotSchema",
            "metadataIndexUnavailable", "ownerMetadataCorrupt",
            "ownerMetadataMissing", "ownerMetadataSchemaUnsupported",
            "ownerMetadataUnreadable", "ownerMetadataWriteFailed",
            "policyConfigurationUnavailable", "policyDenied",
            "peer_index_proof_unavailable",
            "propagation_not_indexed", "rescan_failed", "snapshotUnavailable",
            "staleLease", "start_failed", "stop_failed", "version_conflict",
        ]
        values.formUnion(BackgroundTaskScheduleFailureCode.allCases.map(\.rawValue))
        values.formUnion([
            BackgroundSnapshotRefreshFailureCode.snapshotUnreadable.rawValue,
            BackgroundSnapshotRefreshFailureCode.historyWriteFailed.rawValue,
        ])
        values.formUnion(PolicyBlockReason.allCases.map(\.rawValue))
        return values
    }()
}

public enum DiagnosticExportError: Error, Hashable, Sendable {
    case invalidSalt
    case summaryTooLarge
    case unsafeOutputDirectory
    case invalidOutputName
    case outputAlreadyExists
    case outputWriteFailed
    case outputCommitFailed
    case unsafeCleanupTarget
}

public struct DiagnosticSummaryExporter: Sendable {
    private let builder: DiagnosticSummaryBuilder

    public init(builder: DiagnosticSummaryBuilder) {
        self.builder = builder
    }

    public func export(to directory: URL) throws -> URL {
        let data = try builder.makeJSON()
        var generator = SystemRandomNumberGenerator()
        let suffix = (0..<12).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        return try DiagnosticAtomicFileWriter.write(
            data,
            to: directory,
            finalName: "diagnostic-summary-\(suffix).json"
        )
    }

    public func removeExport(at url: URL, from directory: URL) throws {
        try Self.removeExport(at: url, from: directory)
    }

    public func removeTemporaryExports(from directory: URL) throws {
        try Self.removeTemporaryExports(from: directory)
    }

    public static func removeExport(at url: URL, from directory: URL) throws {
        try DiagnosticAtomicFileWriter.removeExport(at: url, from: directory)
    }

    public static func removeTemporaryExports(from directory: URL) throws {
        try DiagnosticAtomicFileWriter.removeTemporaryExports(from: directory)
    }
}

enum DiagnosticAtomicFileWriter {
    static func write(
        _ data: Data,
        to directory: URL,
        finalName: String,
        beforeCommit: () throws -> Void = {}
    ) throws -> URL {
        guard !data.isEmpty, data.count <= DiagnosticSummaryBuilder.maximumEncodedBytes,
            isSafeOutputName(finalName)
        else {
            throw DiagnosticExportError.invalidOutputName
        }
        try createOrValidateDirectory(directory)
        let directoryDescriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { throw DiagnosticExportError.unsafeOutputDirectory }
        defer { close(directoryDescriptor) }

        let temporaryName = ".partial-" + randomHex(byteCount: 12)
        let descriptor = temporaryName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw DiagnosticExportError.outputWriteFailed }
        var committed = false
        defer {
            close(descriptor)
            if !committed {
                _ = temporaryName.withCString { unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        #if os(iOS)
            let temporaryURL = directory.appendingPathComponent(temporaryName)
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: temporaryURL.path
                )
            } catch {
                throw DiagnosticExportError.outputWriteFailed
            }
        #endif

        do {
            try writeAll(data, descriptor: descriptor)
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                fsync(descriptor) == 0
            else {
                throw DiagnosticExportError.outputWriteFailed
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                status.st_size == data.count
            else {
                throw DiagnosticExportError.outputWriteFailed
            }
            try beforeCommit()
        } catch let error as DiagnosticExportError {
            throw error
        } catch {
            throw error
        }

        let renameResult = temporaryName.withCString { temporaryPointer in
            finalName.withCString { finalPointer in
                renameatx_np(
                    directoryDescriptor,
                    temporaryPointer,
                    directoryDescriptor,
                    finalPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            if errno == EEXIST { throw DiagnosticExportError.outputAlreadyExists }
            throw DiagnosticExportError.outputCommitFailed
        }
        committed = true
        #if os(iOS)
            do {
                var finalURL = directory.appendingPathComponent(finalName, isDirectory: false)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try finalURL.setResourceValues(resourceValues)
            } catch {
                _ = finalName.withCString { unlinkat(directoryDescriptor, $0, 0) }
                _ = fsync(directoryDescriptor)
                throw DiagnosticExportError.outputCommitFailed
            }
        #endif
        guard fsync(descriptor) == 0, fsync(directoryDescriptor) == 0 else {
            // The file is complete and visible, but durability is not proven.
            // Remove it rather than returning a possibly non-durable export.
            _ = finalName.withCString { unlinkat(directoryDescriptor, $0, 0) }
            _ = fsync(directoryDescriptor)
            throw DiagnosticExportError.outputCommitFailed
        }
        return directory.appendingPathComponent(finalName, isDirectory: false)
    }

    static func removeExport(at url: URL, from directory: URL) throws {
        let normalizedDirectory = directory.standardizedFileURL
        let normalizedURL = url.standardizedFileURL
        guard normalizedURL.deletingLastPathComponent() == normalizedDirectory,
            isSafeOutputName(normalizedURL.lastPathComponent)
        else {
            throw DiagnosticExportError.unsafeCleanupTarget
        }
        let directoryDescriptor = open(
            normalizedDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { throw DiagnosticExportError.unsafeOutputDirectory }
        defer { close(directoryDescriptor) }
        var status = stat()
        let name = normalizedURL.lastPathComponent
        let statusResult = name.withCString {
            fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0, errno == ENOENT { return }
        guard statusResult == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0,
            fsync(directoryDescriptor) == 0
        else {
            throw DiagnosticExportError.unsafeCleanupTarget
        }
    }

    static func removeTemporaryExports(from directory: URL) throws {
        var initial = stat()
        let pathResult = lstat(directory.path, &initial)
        if pathResult != 0, errno == ENOENT { return }
        guard pathResult == 0,
            initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw DiagnosticExportError.unsafeOutputDirectory
        }
        let directoryDescriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { throw DiagnosticExportError.unsafeOutputDirectory }
        defer { close(directoryDescriptor) }
        var opened = stat()
        guard fstat(directoryDescriptor, &opened) == 0,
            opened.st_dev == initial.st_dev,
            opened.st_ino == initial.st_ino,
            opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw DiagnosticExportError.unsafeOutputDirectory
        }
        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw DiagnosticExportError.unsafeOutputDirectory
        }
        defer { closedir(stream) }
        var removedAny = false
        while let entry = readdir(stream) {
            let name = directoryEntryName(entry)
            guard isSafeOutputName(name) || isSafePartialName(name) else { continue }
            var status = stat()
            let statusResult = name.withCString {
                fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0,
                status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0
            else {
                throw DiagnosticExportError.unsafeCleanupTarget
            }
            removedAny = true
        }
        var final = stat()
        guard fstat(directoryDescriptor, &final) == 0,
            final.st_dev == opened.st_dev,
            final.st_ino == opened.st_ino,
            final.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            !removedAny || fsync(directoryDescriptor) == 0
        else {
            throw DiagnosticExportError.unsafeCleanupTarget
        }
    }

    private static func createOrValidateDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            let parent = directory.deletingLastPathComponent()
            var parentStatus = stat()
            guard lstat(parent.path, &parentStatus) == 0,
                parentStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                !isSymbolicLink(parentStatus)
            else {
                throw DiagnosticExportError.unsafeOutputDirectory
            }
            do {
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                guard manager.fileExists(atPath: directory.path) else {
                    throw DiagnosticExportError.unsafeOutputDirectory
                }
            }
        }
        var status = stat()
        guard lstat(directory.path, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            !isSymbolicLink(status),
            chmod(directory.path, mode_t(0o700)) == 0
        else {
            throw DiagnosticExportError.unsafeOutputDirectory
        }
        #if os(iOS)
            do {
                var protectedDirectory = directory
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try protectedDirectory.setResourceValues(resourceValues)
            } catch {
                throw DiagnosticExportError.unsafeOutputDirectory
            }
        #endif
    }

    private static func isSafeOutputName(_ value: String) -> Bool {
        value.hasPrefix("diagnostic-summary")
            && value.hasSuffix(".json")
            && value.utf8.count <= 96
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
            }
    }

    private static func isSafePartialName(_ value: String) -> Bool {
        let prefix = ".partial-"
        guard value.hasPrefix(prefix), value.utf8.count == prefix.utf8.count + 24 else {
            return false
        }
        return value.dropFirst(prefix.count).utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    private static func isSymbolicLink(_ status: stat) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }

    private static func randomHex(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DiagnosticExportError.outputWriteFailed }
                offset += count
            }
        }
    }
}

struct StrictDiagnosticReadResult {
    var health: DiagnosticInputHealth
    var data: Data?
}

enum StrictDiagnosticFileReader {
    static func read(
        _ url: URL,
        maximumBytes: Int,
        beforeFinalValidation: () throws -> Void = {}
    ) -> StrictDiagnosticReadResult {
        var initial = stat()
        guard lstat(url.path, &initial) == 0 else {
            return .init(health: errno == ENOENT ? .missing : .unreadable, data: nil)
        }
        let type = initial.st_mode & mode_t(S_IFMT)
        guard type != mode_t(S_IFLNK) else { return .init(health: .symbolicLink, data: nil) }
        guard type == mode_t(S_IFREG) else { return .init(health: .wrongType, data: nil) }
        guard initial.st_size >= 0, initial.st_size <= maximumBytes else {
            return .init(health: .oversize, data: nil)
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return .init(health: .unreadable, data: nil) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
            opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            opened.st_dev == initial.st_dev,
            opened.st_ino == initial.st_ino
        else {
            return .init(health: .changedDuringRead, data: nil)
        }
        guard opened.st_size >= 0, opened.st_size <= maximumBytes else {
            return .init(health: .oversize, data: nil)
        }

        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .init(health: .unreadable, data: nil) }
            guard count > 0 else { break }
            guard data.count <= maximumBytes - count else {
                return .init(health: .oversize, data: nil)
            }
            data.append(buffer, count: count)
        }

        do {
            try beforeFinalValidation()
        } catch {
            return .init(health: .unreadable, data: nil)
        }

        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        guard fstat(descriptor, &finalDescriptorStatus) == 0,
            lstat(url.path, &finalPathStatus) == 0,
            finalDescriptorStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            finalDescriptorStatus.st_dev == opened.st_dev,
            finalDescriptorStatus.st_ino == opened.st_ino,
            finalDescriptorStatus.st_size == data.count,
            sameFileState(opened, finalDescriptorStatus),
            finalPathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            finalPathStatus.st_dev == opened.st_dev,
            finalPathStatus.st_ino == opened.st_ino,
            sameFileState(opened, finalPathStatus)
        else {
            return .init(health: .changedDuringRead, data: nil)
        }
        return .init(health: .ok, data: data)
    }

    private static func sameFileState(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

private struct DirectoryCount {
    var health: DiagnosticInputHealth
    var count: Int
    var unsafeEntryCount: Int
}

private enum DiagnosticDirectoryCounter {
    static func countJSONFiles(at url: URL, limit: Int) -> DirectoryCount {
        scan(at: url, limit: limit) { name, status, count, unsafe in
            let type = status.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFREG), name.hasSuffix(".json") {
                count = DiagnosticSummaryBuilder.saturatingAdd(count, 1)
            } else {
                unsafe = DiagnosticSummaryBuilder.saturatingAdd(unsafe, 1)
            }
        }
    }

    static func stagingSummary(at url: URL, limit: Int) -> StagingSummary {
        var directoryCount = 0
        var contentCount = 0
        var contentBytes: Int64 = 0
        var unsafeCount = 0
        let base = scan(at: url, limit: limit) { name, status, _, unsafe in
            if name == ".reservations-v1.json",
                status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            {
                return
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                UUID(uuidString: name) != nil
            else {
                unsafe = DiagnosticSummaryBuilder.saturatingAdd(unsafe, 1)
                return
            }
            directoryCount = DiagnosticSummaryBuilder.saturatingAdd(directoryCount, 1)
            let child = url.appendingPathComponent(name, isDirectory: true)
            let nested = scan(at: child, limit: 16) { childName, childStatus, _, childUnsafe in
                guard childName == "contents",
                    childStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                    childStatus.st_size >= 0
                else {
                    childUnsafe = DiagnosticSummaryBuilder.saturatingAdd(childUnsafe, 1)
                    return
                }
                contentCount = DiagnosticSummaryBuilder.saturatingAdd(contentCount, 1)
                let (sum, overflow) = contentBytes.addingReportingOverflow(childStatus.st_size)
                contentBytes = overflow ? .max : sum
            }
            unsafeCount = DiagnosticSummaryBuilder.saturatingAdd(
                unsafeCount,
                nested.unsafeEntryCount
            )
            if nested.health != .ok, nested.health != .missing {
                unsafeCount = DiagnosticSummaryBuilder.saturatingAdd(unsafeCount, 1)
            }
        }
        unsafeCount = DiagnosticSummaryBuilder.saturatingAdd(
            unsafeCount,
            base.unsafeEntryCount
        )
        return StagingSummary(
            health: base.health,
            commandDirectoryCount: directoryCount,
            regularContentCount: contentCount,
            regularContentBytes: contentBytes,
            unsafeEntryCount: unsafeCount
        )
    }

    private static func scan(
        at url: URL,
        limit: Int,
        visit: (_ name: String, _ status: stat, _ count: inout Int, _ unsafe: inout Int) -> Void
    ) -> DirectoryCount {
        var initial = stat()
        guard lstat(url.path, &initial) == 0 else {
            return .init(health: errno == ENOENT ? .missing : .unreadable, count: 0, unsafeEntryCount: 0)
        }
        let type = initial.st_mode & mode_t(S_IFMT)
        guard type != mode_t(S_IFLNK) else {
            return .init(health: .symbolicLink, count: 0, unsafeEntryCount: 0)
        }
        guard type == mode_t(S_IFDIR) else {
            return .init(health: .wrongType, count: 0, unsafeEntryCount: 0)
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return .init(health: .unreadable, count: 0, unsafeEntryCount: 0)
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
            opened.st_dev == initial.st_dev,
            opened.st_ino == initial.st_ino,
            opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            return .init(health: .changedDuringRead, count: 0, unsafeEntryCount: 0)
        }
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            return .init(health: .unreadable, count: 0, unsafeEntryCount: 0)
        }
        defer { closedir(stream) }

        var seen = 0
        var count = 0
        var unsafe = 0
        var limited = false
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            seen = DiagnosticSummaryBuilder.saturatingAdd(seen, 1)
            guard seen <= max(0, limit) else {
                limited = true
                break
            }
            var status = stat()
            let statusResult = name.withCString {
                fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0 else {
                unsafe = DiagnosticSummaryBuilder.saturatingAdd(unsafe, 1)
                continue
            }
            if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                unsafe = DiagnosticSummaryBuilder.saturatingAdd(unsafe, 1)
                continue
            }
            visit(name, status, &count, &unsafe)
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
            final.st_dev == opened.st_dev,
            final.st_ino == opened.st_ino,
            final.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec
        else {
            return .init(health: .changedDuringRead, count: 0, unsafeEntryCount: unsafe)
        }
        return .init(
            health: limited ? .entryLimitReached : .ok,
            count: count,
            unsafeEntryCount: unsafe
        )
    }
}

private struct DiagnosticSummary: Encodable {
    var schemaVersion: Int
    var generatedAt: Date
    var exportSalt: String
    var build: DiagnosticBuildMetadata
    var system: DiagnosticSystemSummary
    var snapshot: SnapshotSummary
    var policy: PolicySummary
    var runHistory: RunHistorySummary
    var backgroundScheduler: BackgroundSchedulerSummary
    var queue: QueueSummary
    var staging: StagingSummary
    var workingSet: WorkingSetSummary
    var fileProviderIndex: IndexStatusSummary
    var owner: OwnerSummary
    var externalDirectories: ExternalDirectorySummary
}

private struct DiagnosticSystemSummary: Encodable {
    var platform: String
    var osVersion: String

    static var current: Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
            let platform = "iOS"
        #elseif os(macOS)
            let platform = "macOS"
        #else
            let platform = "Apple"
        #endif
        return Self(
            platform: platform,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        )
    }
}

private struct SnapshotSummary: Encodable {
    var health: DiagnosticInputHealth
    var schemaVersion: Int?
    var generation: UInt64?
    var ageSeconds: Int64?
    var localIdentityPresent: Bool
    var deviceCount: Int
    var deviceStates: [String: Int]
    var pausedDeviceCount: Int
    var deviceBlockingCount: Int
    var folderCount: Int
    var folderTypes: [String: Int]
    var selectionModes: [String: Int]
    var pausedFolderCount: Int
    var folderErrorCount: Int
    var pendingUploadBytes: Int64
    var pendingDownloadBytes: Int64
    var itemCount: Int
    var directoryItemCount: Int
    var itemAvailability: [String: Int]
    var pinnedItemCount: Int
    var unuploadedItemCount: Int
    var indexedRegularFileBytes: Int64
    var tombstoneCount: Int
    var pendingDeviceCount: Int
    var pendingFolderCount: Int
    var suppressedPendingDeviceCount: Int
    var suppressedPendingFolderCount: Int
    var pendingFoldersTruncated: Bool
    var suppressedPendingDevicesTruncated: Bool
    var suppressedPendingFoldersTruncated: Bool

    static func empty(health: DiagnosticInputHealth) -> Self {
        Self(
            health: health,
            schemaVersion: nil,
            generation: nil,
            ageSeconds: nil,
            localIdentityPresent: false,
            deviceCount: 0,
            deviceStates: [:],
            pausedDeviceCount: 0,
            deviceBlockingCount: 0,
            folderCount: 0,
            folderTypes: [:],
            selectionModes: [:],
            pausedFolderCount: 0,
            folderErrorCount: 0,
            pendingUploadBytes: 0,
            pendingDownloadBytes: 0,
            itemCount: 0,
            directoryItemCount: 0,
            itemAvailability: [:],
            pinnedItemCount: 0,
            unuploadedItemCount: 0,
            indexedRegularFileBytes: 0,
            tombstoneCount: 0,
            pendingDeviceCount: 0,
            pendingFolderCount: 0,
            suppressedPendingDeviceCount: 0,
            suppressedPendingFolderCount: 0,
            pendingFoldersTruncated: false,
            suppressedPendingDevicesTruncated: false,
            suppressedPendingFoldersTruncated: false
        )
    }
}

private struct PolicySummary: Encodable {
    var health: DiagnosticInputHealth
    var automaticallyAllowedNetworks: [String]
    var cellularAccess: String?
    var allowExpensive: Bool
    var allowConstrained: Bool
    var cellularFileLimitConfigured: Bool
    var expensiveRunLimitConfigured: Bool
    var dailyExpensiveLimitConfigured: Bool
    var requirePowerForAllAutomaticWork: Bool
    var largeTransferPowerThresholdConfigured: Bool
    var requirePowerForMaintenance: Bool
    var minimumBatteryConfigured: Bool
    var lowPowerBehavior: String?
    var thermalPauseLevel: String?
    var automaticWindowCount: Int
    var automaticBackgroundMode: String?
    var allowBackgroundUpload: Bool
    var allowBackgroundDownload: Bool
    var allowBackgroundScan: Bool
    var allowTemporaryUserOverride: Bool

    init(policy: SyncPolicy, health: DiagnosticInputHealth) {
        self.health = health
        automaticallyAllowedNetworks = policy.automaticallyAllowedNetworks.map(\.rawValue).sorted()
        cellularAccess = policy.cellularAccess.rawValue
        allowExpensive = policy.allowExpensive
        allowConstrained = policy.allowConstrained
        cellularFileLimitConfigured = policy.maxCellularFileBytes != nil
        expensiveRunLimitConfigured = policy.maxExpensiveRunBytes != nil
        dailyExpensiveLimitConfigured = policy.dailyExpensiveBytes != nil
        requirePowerForAllAutomaticWork = policy.requirePowerForAllAutomaticWork
        largeTransferPowerThresholdConfigured = policy.requirePowerForLargeTransferBytes != nil
        requirePowerForMaintenance = policy.requirePowerForMaintenance
        minimumBatteryConfigured = policy.minimumBatteryLevel != nil
        lowPowerBehavior = policy.lowPowerBehavior.rawValue
        thermalPauseLevel = policy.pauseTransfersAtThermalLevel.rawValue
        automaticWindowCount = policy.automaticTimeWindows.count
        automaticBackgroundMode = policy.automaticBackgroundMode.rawValue
        allowBackgroundUpload = policy.allowBackgroundUpload
        allowBackgroundDownload = policy.allowBackgroundDownload
        allowBackgroundScan = policy.allowBackgroundScan
        allowTemporaryUserOverride = policy.allowTemporaryUserOverride
    }

    static func empty(health: DiagnosticInputHealth) -> Self {
        var value = Self(policy: SyncPolicy(), health: health)
        value.automaticallyAllowedNetworks = []
        value.cellularAccess = nil
        value.lowPowerBehavior = nil
        value.thermalPauseLevel = nil
        value.automaticBackgroundMode = nil
        return value
    }
}

private struct DiagnosticRunRecord: Encodable {
    var trigger: String
    var durationMilliseconds: Int64
    var transferredBytes: Int64
    var endReason: String
    var failureCode: String?
}

private struct RunHistorySummary: Encodable {
    var health: DiagnosticInputHealth
    var retainedRecordCount: Int
    var sourceRecordCount: Int
    var records: [DiagnosticRunRecord]

    static func empty(health: DiagnosticInputHealth) -> Self {
        Self(health: health, retainedRecordCount: 0, sourceRecordCount: 0, records: [])
    }
}

private struct BackgroundAttemptSummary: Encodable {
    var kind: String
    var result: String
    var failureCode: String?
    var requiresNetwork: Bool
    var requiresExternalPower: Bool
}

private struct BackgroundSchedulerSummary: Encodable {
    var health: DiagnosticInputHealth
    var attempts: [BackgroundAttemptSummary]

    static func empty(health: DiagnosticInputHealth) -> Self {
        Self(health: health, attempts: [])
    }
}

private struct QueueSummary: Encodable {
    var pendingHealth: DiagnosticInputHealth
    var completedHealth: DiagnosticInputHealth
    var resultHealth: DiagnosticInputHealth
    var pendingCount: Int
    var completedCount: Int
    var resultCount: Int
    var unsafeEntryCount: Int
}

private struct StagingSummary: Encodable {
    var health: DiagnosticInputHealth
    var commandDirectoryCount: Int
    var regularContentCount: Int
    var regularContentBytes: Int64
    var unsafeEntryCount: Int
    var reservationHealth: DiagnosticInputHealth = .missing
    var reservationCount: Int = 0
    var reservedDestinationBytes: Int64 = 0
}

private struct DiagnosticReservationDocument: Decodable {
    var schemaVersion: Int
    var entries: [DiagnosticReservationEntry]
}

private struct DiagnosticReservationEntry: Decodable {
    var commandID: UUID
    var destinationBytes: Int64
}

private struct WorkingSetState: Decodable {
    var schemaVersion: Int
    var pendingGeneration: UInt64?
}

private struct WorkingSetSummary: Encodable {
    var health: DiagnosticInputHealth
    var requestPending: Bool
    var pendingGeneration: UInt64?

    static func empty(health: DiagnosticInputHealth) -> Self {
        Self(health: health, requestPending: false, pendingGeneration: nil)
    }
}

private struct IndexStatusSummary: Encodable {
    var health: DiagnosticInputHealth
    var state: String?
    var snapshotGeneration: UInt64?
    var indexedItemCount: Int?
    var errorCode: String?

    static func empty(health: DiagnosticInputHealth) -> Self {
        Self(
            health: health,
            state: nil,
            snapshotGeneration: nil,
            indexedItemCount: nil,
            errorCode: nil
        )
    }
}

private struct OwnerSummary: Encodable {
    var health: DiagnosticInputHealth
    var schemaVersion: Int?
    var epoch: UInt64?
    var role: String?
    var leaseAgeSeconds: Int64?

    static func empty(health: DiagnosticInputHealth) -> Self {
        Self(health: health, schemaVersion: nil, epoch: nil, role: nil, leaseAgeSeconds: nil)
    }
}

private struct ExternalDirectorySummary: Encodable {
    var health: DiagnosticInputHealth
    var recordCount: Int
    var modes: [String: Int]
    var authorizationStates: [String: Int]
    var mirrorPhases: [String: Int]
    var mirrorFailureCodes: [String: Int]
    var bindingPhases: [String: Int]
    var capabilitySuccessCounts: [String: Int]
    var pendingDeletionConfirmationCount: Int

    static func empty(health: DiagnosticInputHealth) -> Self {
        Self(
            health: health,
            recordCount: 0,
            modes: [:],
            authorizationStates: [:],
            mirrorPhases: [:],
            mirrorFailureCodes: [:],
            bindingPhases: [:],
            capabilitySuccessCounts: [:],
            pendingDeletionConfirmationCount: 0
        )
    }
}

extension Dictionary where Key == String, Value == Int {
    fileprivate mutating func increment(_ key: String, by amount: Int = 1) {
        let current = self[key, default: 0]
        self[key] = DiagnosticSummaryBuilder.saturatingAdd(current, Swift.max(0, amount))
    }
}

extension Collection {
    fileprivate func count(where predicate: (Element) throws -> Bool) rethrows -> Int {
        try reduce(into: 0) { count, element in
            if try predicate(element) {
                count = DiagnosticSummaryBuilder.saturatingAdd(count, 1)
            }
        }
    }
}
