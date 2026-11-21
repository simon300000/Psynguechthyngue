import Darwin
import Foundation

public enum SharedContainerError: Error, Sendable, LocalizedError, Equatable {
    case missingAppGroupIdentifier
    case appGroupUnavailable(String)
    case invalidManagedRootToken
    case invalidManagedFolderIdentifier
    case managedFolderEscapesContainer
    case unsafeManagedFolderRoot

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupIdentifier: "PsyAppGroupIdentifier is missing from Info.plist."
        case .appGroupUnavailable(let identifier): "The App Group container is unavailable: \(identifier)"
        case .invalidManagedRootToken: "The managed-root token is invalid."
        case .invalidManagedFolderIdentifier: "The managed folder identifier is invalid."
        case .managedFolderEscapesContainer: "The managed folder is outside the App Group managed root."
        case .unsafeManagedFolderRoot:
            "The managed folder root is unavailable, is not a directory, or uses a symbolic link."
        }
    }
}

public struct SharedContainerPaths: Hashable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var coordinationDirectory: URL { root.appendingPathComponent("Coordination", isDirectory: true) }
    public var coreLock: URL { coordinationDirectory.appendingPathComponent("syncthing-core.lock") }
    public var commandQueue: URL { coordinationDirectory.appendingPathComponent("Commands", isDirectory: true) }
    public var snapshot: URL { root.appendingPathComponent("Metadata/core-snapshot.json") }
    public var metadataIndex: URL { root.appendingPathComponent("Metadata/global-index.sqlite") }
    public var metadataIndexStatus: URL { root.appendingPathComponent("Metadata/global-index-status.json") }
    /// Cross-process retention intent, upload evidence, pending eviction, and
    /// crash-recovery transactions. It is deliberately independent of the
    /// derived global-index SQLite projection.
    public var fileProviderReplicaState: URL { root.appendingPathComponent("Metadata/file-provider-replicas-v1.json") }

    public var contentRetention: URL {
        root.appendingPathComponent("Metadata/content-retention-v1.json")
    }
    public var workingSetSignalState: URL {
        root.appendingPathComponent("Metadata/file-provider-working-set-signal.json")
    }
    public var externalDirectoryRecords: URL { root.appendingPathComponent("Metadata/external-directories.json") }
    /// User data belongs outside the embedded core's configuration and database
    /// homes. Go bridge validation rejects folder roots nested under either one.
    public var managedFoldersRoot: URL { root.appendingPathComponent("ManagedFolders", isDirectory: true) }
    public var externalManagedFoldersRoot: URL {
        managedFoldersRoot.appendingPathComponent("External", isDirectory: true)
    }
    public var synchronizedManagedFoldersRoot: URL {
        managedFoldersRoot.appendingPathComponent("Folders", isDirectory: true)
    }
    public var policy: URL { root.appendingPathComponent("Metadata/sync-policy.json") }
    /// Durable reservations and settlement receipts for protocol-byte budgets.
    /// This remains separate from human-facing run history so a crash cannot
    /// make an incomplete transfer disappear from the hard daily ceiling.
    public var transferAccounting: URL {
        root.appendingPathComponent("Metadata/transfer-accounting.json")
    }
    /// App-owned durable identities for configured folder incarnations. This
    /// is deliberately independent of the embedded core's configuration so a
    /// remove-and-readd cannot inherit policy or accounting authority.
    public var folderIncarnations: URL {
        root.appendingPathComponent("Metadata/folder-incarnations.json")
    }
    public var coreConfiguration: URL { root.appendingPathComponent("Core/Config", isDirectory: true) }
    public var coreData: URL { root.appendingPathComponent("Core/Data", isDirectory: true) }
    public var coreMutationRecoveryExports: URL {
        root.appendingPathComponent(
            "Core/Bridge/MutationRecoveryExports",
            isDirectory: true
        )
    }
    public var fileProviderStaging: URL { root.appendingPathComponent("FileProvider/Staging", isDirectory: true) }
    public var history: URL { root.appendingPathComponent("Metadata/run-history.jsonl") }
    public var backgroundTaskScheduleStatus: URL {
        root.appendingPathComponent("Metadata/background-task-schedule-status.json")
    }

    public func externalManagedRoot(for token: String) throws -> URL {
        guard let uuid = UUID(uuidString: token),
            uuid.uuidString.caseInsensitiveCompare(token) == .orderedSame
        else {
            throw SharedContainerError.invalidManagedRootToken
        }
        return try containedChild(
            component: uuid.uuidString.lowercased(),
            of: externalManagedFoldersRoot
        )
    }

    public func createExternalManagedRoot(for token: String) throws -> URL {
        let url = try externalManagedRoot(for: token)
        try createManagedDirectoryHierarchy(parent: externalManagedFoldersRoot, child: url)
        return try validatedExternalManagedRoot(for: token)
    }

    /// Resolves the opaque external-root token without following a caller-
    /// controlled symbolic link. Every App-owned component must be a real
    /// directory and the resolved child must remain exactly one level below the
    /// resolved External root.
    public func validatedExternalManagedRoot(for token: String) throws -> URL {
        let candidate = try externalManagedRoot(for: token)
        let manager = FileManager.default
        for component in [managedFoldersRoot, externalManagedFoldersRoot, candidate] {
            guard let attributes = try? manager.attributesOfItem(atPath: component.path),
                attributes[.type] as? FileAttributeType == .typeDirectory,
                (try? manager.destinationOfSymbolicLink(atPath: component.path)) == nil
            else {
                throw SharedContainerError.unsafeManagedFolderRoot
            }
        }
        let resolvedParent = externalManagedFoldersRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let parentComponents = resolvedParent.pathComponents
        guard resolvedCandidate.pathComponents.count == parentComponents.count + 1,
            Array(resolvedCandidate.pathComponents.prefix(parentComponents.count)) == parentComponents
        else {
            throw SharedContainerError.managedFolderEscapesContainer
        }
        return candidate.standardizedFileURL
    }

    public func managedFolder(for folderID: FolderID) throws -> URL {
        let encoded = Data(folderID.rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard !encoded.isEmpty else { throw SharedContainerError.invalidManagedFolderIdentifier }
        return try containedChild(component: "folder-" + encoded, of: synchronizedManagedFoldersRoot)
    }

    public func createManagedFolder(for folderID: FolderID) throws -> URL {
        let url = try managedFolder(for: folderID)
        try createManagedDirectoryHierarchy(parent: synchronizedManagedFoldersRoot, child: url)
        return try validatedManagedFolder(for: folderID)
    }

    /// Validates every App-owned path component without following a symbolic
    /// link. The leaf must remain exactly one level below the resolved
    /// ManagedFolders/Folders root.
    public func validatedManagedFolder(for folderID: FolderID) throws -> URL {
        let candidate = try managedFolder(for: folderID)
        try validateRealDirectory(root)
        try validateRealDirectory(managedFoldersRoot)
        try validateRealDirectory(synchronizedManagedFoldersRoot)
        try validateRealDirectory(candidate)
        try validateDirectChild(candidate, of: synchronizedManagedFoldersRoot)
        return candidate.standardizedFileURL
    }

    private func createManagedDirectoryHierarchy(parent: URL, child: URL) throws {
        let manager = FileManager.default
        try validateRealDirectory(root)
        try createOrValidateRealDirectory(managedFoldersRoot, using: manager)
        try validateDirectChild(managedFoldersRoot, of: root)
        try createOrValidateRealDirectory(parent, using: manager)
        try validateDirectChild(parent, of: managedFoldersRoot)
        // Only create the leaf after every parent has been proven to be a real
        // directory. This prevents createDirectory from traversing a replaced
        // parent symlink before validation.
        try createOrValidateRealDirectory(child, using: manager)
        try validateDirectChild(child, of: parent)
    }

    private func createOrValidateRealDirectory(
        _ url: URL,
        using manager: FileManager
    ) throws {
        if !manager.fileExists(atPath: url.path) {
            do {
                try manager.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                // Another process may have created the same component. The
                // postcondition below is authoritative and rejects every other
                // object type, including symlinks.
                guard manager.fileExists(atPath: url.path) else { throw error }
            }
        }
        try validateRealDirectory(url)
    }

    private func validateRealDirectory(_ url: URL) throws {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeDirectory,
            (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil
        else {
            throw SharedContainerError.unsafeManagedFolderRoot
        }
    }

    private func validateDirectChild(_ child: URL, of parent: URL) throws {
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
        let parentComponents = resolvedParent.pathComponents
        guard resolvedChild.pathComponents.count == parentComponents.count + 1,
            Array(resolvedChild.pathComponents.prefix(parentComponents.count)) == parentComponents
        else {
            throw SharedContainerError.managedFolderEscapesContainer
        }
    }

    private func containedChild(component: String, of parent: URL) throws -> URL {
        guard !component.isEmpty,
            component != ".",
            component != "..",
            !component.contains("/"),
            !component.contains("\\"),
            !component.contains("\0")
        else {
            throw SharedContainerError.managedFolderEscapesContainer
        }
        let normalizedParent = parent.standardizedFileURL
        let candidate = normalizedParent.appendingPathComponent(component, isDirectory: true).standardizedFileURL
        let parentComponents = normalizedParent.pathComponents
        guard candidate.pathComponents.count == parentComponents.count + 1,
            Array(candidate.pathComponents.prefix(parentComponents.count)) == parentComponents
        else {
            throw SharedContainerError.managedFolderEscapesContainer
        }
        return candidate
    }

    public static func resolve(bundle: Bundle = .main) throws -> SharedContainerPaths {
        guard let identifier = bundle.object(forInfoDictionaryKey: "PsyAppGroupIdentifier") as? String,
            !identifier.isEmpty
        else {
            throw SharedContainerError.missingAppGroupIdentifier
        }
        guard
            let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: identifier
            )
        else {
            throw SharedContainerError.appGroupUnavailable(identifier)
        }
        return SharedContainerPaths(root: root)
    }
}

/// Exact-incarnation folder policy state used by trusted editors. `nil`
/// `policyOverride` means every policy field inherits the global document;
/// priority remains independently configurable and incarnation-bound.
public struct FolderPolicyConfiguration: Hashable, Sendable {
    public var context: FolderPolicyContext
    public var policyOverride: SyncPolicyOverride?
    public var queuePriority: FolderQueuePriority
    public var globalPolicy: SyncPolicy
    public var effectivePolicy: SyncPolicy

    public init(
        context: FolderPolicyContext,
        policyOverride: SyncPolicyOverride?,
        queuePriority: FolderQueuePriority,
        globalPolicy: SyncPolicy,
        effectivePolicy: SyncPolicy
    ) {
        self.context = context
        self.policyOverride = policyOverride
        self.queuePriority = queuePriority
        self.globalPolicy = globalPolicy
        self.effectivePolicy = effectivePolicy
    }
}

public struct SyncPolicyStore: Sendable {
    private let documentStore: SyncPolicyDocumentStore

    public init(
        url: URL,
        legacyBudgetTimeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    ) {
        documentStore = SyncPolicyDocumentStore(
            url: url,
            legacyBudgetTimeZoneIdentifier: legacyBudgetTimeZoneIdentifier
        )
    }

    public func load() throws -> SyncPolicy {
        try loadDocument().global
    }

    public func save(_ policy: SyncPolicy) throws {
        _ = try documentStore.saveGlobalPreservingOverrides(policy)
    }

    /// Loads the authoritative policy document, migrating a legacy bare
    /// `SyncPolicy` under the document store's inter-process lock when needed.
    public func loadDocument() throws -> SyncPolicyDocumentV2 {
        try documentStore.load()
    }

    /// Replaces the complete policy document. Global-only editors should use
    /// `save(_:)` so they cannot discard folder-bound policy and priority.
    public func saveDocument(_ document: SyncPolicyDocumentV2) throws {
        try documentStore.save(document)
    }

    /// Atomically replaces named one-task profiles while preserving global
    /// policy, exact-incarnation folder policy, priorities, and budget zone.
    @discardableResult
    public func saveTemporaryProfiles(
        _ profiles: [TemporarySyncPolicyProfile]
    ) throws -> SyncPolicyDocumentV2 {
        try documentStore.update { document in
            document.temporaryProfiles = profiles
        }
    }

    /// Atomically saves the global editor and the profile editor at one
    /// persistence linearization point.
    @discardableResult
    public func saveGlobalAndTemporaryProfiles(
        global: SyncPolicy,
        profiles: [TemporarySyncPolicyProfile]
    ) throws -> SyncPolicyDocumentV2 {
        try documentStore.update { document in
            document.global = global
            document.temporaryProfiles = profiles
        }
    }

    /// Resolves policy only when a folder override still belongs to the exact
    /// folder incarnation. A stale binding is an error rather than silently
    /// inheriting global policy.
    public func resolvedPolicy(for context: FolderPolicyContext) throws -> SyncPolicy {
        let document = try loadDocument()
        return try document.resolvedPolicy(
            for: context.folderID,
            folderIncarnationDigest: context.folderIncarnationDigest
        )
    }

    public func conservativePolicy(for contexts: [FolderPolicyContext]) throws -> SyncPolicy {
        try loadDocument().conservativePolicy(for: contexts)
    }

    /// Loads the editable state for one exact folder lifetime. A policy record
    /// for the same folder ID but another incarnation is never inherited.
    public func folderPolicyConfiguration(
        for context: FolderPolicyContext
    ) throws -> FolderPolicyConfiguration {
        try Self.folderPolicyConfiguration(in: loadDocument(), for: context)
    }

    /// Atomically replaces one exact-incarnation folder policy and priority.
    /// An all-inherit override at normal priority is canonicalized by removing
    /// the entry. Existing state for another incarnation is rejected rather
    /// than reassigned to a remove-and-readd folder with the same ID.
    @discardableResult
    public func saveFolderPolicy(
        _ policyOverride: SyncPolicyOverride?,
        queuePriority: FolderQueuePriority,
        for context: FolderPolicyContext
    ) throws -> FolderPolicyConfiguration {
        let normalizedOverride = policyOverride.flatMap {
            $0 == SyncPolicyOverride() ? nil : $0
        }
        let document = try documentStore.update { document in
            let existingIndex = document.folderOverrides.firstIndex(where: {
                $0.folderID == context.folderID
            })
            if let existingIndex {
                guard
                    document.folderOverrides[existingIndex].folderIncarnationDigest
                        == context.folderIncarnationDigest
                else {
                    throw SyncPolicyDocumentError.staleFolderOverride(
                        folderID: context.folderID.rawValue
                    )
                }
                if normalizedOverride == nil, queuePriority == .normal {
                    document.folderOverrides.remove(at: existingIndex)
                } else {
                    document.folderOverrides[existingIndex] = FolderSyncPolicyOverride(
                        folderID: context.folderID,
                        folderIncarnationDigest: context.folderIncarnationDigest,
                        queuePriority: queuePriority,
                        policy: normalizedOverride ?? SyncPolicyOverride()
                    )
                }
            } else if normalizedOverride != nil || queuePriority != .normal {
                document.folderOverrides.append(
                    FolderSyncPolicyOverride(
                        folderID: context.folderID,
                        folderIncarnationDigest: context.folderIncarnationDigest,
                        queuePriority: queuePriority,
                        policy: normalizedOverride ?? SyncPolicyOverride()
                    )
                )
            }
        }
        return try Self.folderPolicyConfiguration(in: document, for: context)
    }

    /// Discards settings for one previously trusted incarnation without ever
    /// deleting a replacement incarnation's policy by folder ID alone.
    @discardableResult
    public func discardFolderPolicy(for expectedContext: FolderPolicyContext) throws -> Bool {
        try documentStore.discardFolderOverride(expectedContext: expectedContext)
    }

    /// Returns the scheduling priority bound to this exact folder incarnation.
    /// Missing overrides use the stable normal default; stale overrides fail
    /// closed so a remove-and-readd cannot inherit old scheduling authority.
    public func queuePriority(for context: FolderPolicyContext) throws -> FolderQueuePriority {
        let document = try loadDocument()
        guard
            let entry = document.folderOverrides.first(where: {
                $0.folderID == context.folderID
            })
        else {
            return .normal
        }
        guard entry.folderIncarnationDigest == context.folderIncarnationDigest else {
            throw SyncPolicyDocumentError.staleFolderOverride(
                folderID: context.folderID.rawValue
            )
        }
        return entry.queuePriority
    }

    private static func folderPolicyConfiguration(
        in document: SyncPolicyDocumentV2,
        for context: FolderPolicyContext
    ) throws -> FolderPolicyConfiguration {
        let document = try document.validated()
        let entry = document.folderOverrides.first(where: {
            $0.folderID == context.folderID
        })
        if let entry,
            entry.folderIncarnationDigest != context.folderIncarnationDigest
        {
            throw SyncPolicyDocumentError.staleFolderOverride(
                folderID: context.folderID.rawValue
            )
        }
        let storedOverride = entry?.policy
        return FolderPolicyConfiguration(
            context: context,
            policyOverride: storedOverride == SyncPolicyOverride() ? nil : storedOverride,
            queuePriority: entry?.queuePriority ?? .normal,
            globalPolicy: document.global,
            effectivePolicy: try document.resolvedPolicy(
                for: context.folderID,
                folderIncarnationDigest: context.folderIncarnationDigest
            )
        )
    }
}

public enum SyncRunEndReason: String, Codable, Sendable {
    case completed
    case noWork
    case policyDenied
    case cancelled
    case expired
    case coreBusy
    case failed
}

public struct SyncRunRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var trigger: SyncTrigger
    public var startedAt: Date
    public var endedAt: Date
    public var transferredBytes: Int64
    /// Exact Syncthing protocol traffic measured for this run. Both fields are
    /// present together when measurement succeeded. `nil` is deliberately
    /// distinct from zero for legacy records and bridge failures.
    public var networkReceivedBytes: Int64?
    public var networkSentBytes: Int64?
    public var endReason: SyncRunEndReason
    public var failureCode: String?

    public init(
        id: UUID = UUID(),
        trigger: SyncTrigger,
        startedAt: Date,
        endedAt: Date,
        transferredBytes: Int64,
        networkReceivedBytes: Int64? = nil,
        networkSentBytes: Int64? = nil,
        endReason: SyncRunEndReason,
        failureCode: String? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transferredBytes = transferredBytes
        self.networkReceivedBytes = networkReceivedBytes
        self.networkSentBytes = networkSentBytes
        self.endReason = endReason
        self.failureCode = failureCode
    }

    public var measuredNetworkBytes: Int64? {
        guard let networkReceivedBytes,
            let networkSentBytes,
            networkReceivedBytes >= 0,
            networkSentBytes >= 0
        else {
            return nil
        }
        let (total, overflowed) = networkReceivedBytes.addingReportingOverflow(networkSentBytes)
        return overflowed ? nil : total
    }
}

public struct SyncRunHistory: Sendable {
    private enum HistoryStreamError: Error {
        case lineTooLong
    }

    private struct HistoryFileState: Equatable {
        var device: UInt64
        var inode: UInt64
        var byteCount: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64

        init(_ status: stat) {
            // Darwin's `dev_t` is a signed Int32 carrying an unsigned device
            // bit pattern. A checked signed-to-unsigned conversion can trap
            // for a valid high-bit device identifier.
            device = UInt64(UInt32(bitPattern: status.st_dev))
            inode = UInt64(status.st_ino)
            byteCount = status.st_size
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    private struct HistoryFingerprint: Codable, Equatable {
        var device: UInt64
        var inode: UInt64
        var byteCount: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
        var edgeDigest: UInt64

        init(state: HistoryFileState, edgeDigest: UInt64) {
            device = state.device
            inode = state.inode
            byteCount = state.byteCount
            modifiedSeconds = state.modifiedSeconds
            modifiedNanoseconds = state.modifiedNanoseconds
            changedSeconds = state.changedSeconds
            changedNanoseconds = state.changedNanoseconds
            self.edgeDigest = edgeDigest
        }
    }

    private struct NetworkMeasurementSummary: Codable {
        static let schemaVersion = 1

        var schemaVersion: Int
        var sinceTimeInterval: TimeInterval
        var historyFingerprint: HistoryFingerprint
        /// `nil` is a durable unknown result, not a missing summary. This
        /// preserves fail-closed behavior for legacy or unmeasured records.
        var measuredNetworkBytes: Int64?

        init(
            since: Date,
            historyFingerprint: HistoryFingerprint,
            measuredNetworkBytes: Int64?
        ) {
            schemaVersion = Self.schemaVersion
            sinceTimeInterval = since.timeIntervalSince1970
            self.historyFingerprint = historyFingerprint
            self.measuredNetworkBytes = measuredNetworkBytes
        }

        var isValid: Bool {
            schemaVersion == Self.schemaVersion
                && sinceTimeInterval.isFinite
                && measuredNetworkBytes.map { $0 >= 0 } != false
        }
    }

    private static let maximumMeasurementSummaryBytes: Int64 = 16 * 1_024
    private static let maximumHistoryRecordBytes = 64 * 1_024
    private static let historyReadChunkBytes = 64 * 1_024
    private static let fingerprintWindowBytes = 4 * 1_024

    private let url: URL
    private let lockURL: URL

    private var measurementSummaryURL: URL {
        url.appendingPathExtension("network-measurement-v1.json")
    }

    public init(url: URL) {
        self.url = url
        lockURL = url.appendingPathExtension("lock")
    }

    public func append(_ record: SyncRunRecord) throws {
        try FileLock.withExclusiveLock(at: lockURL) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(record)
            guard data.count <= Self.maximumHistoryRecordBytes else {
                throw CocoaError(.fileWriteUnknown)
            }
            data.append(0x0A)

            let descriptor = url.path.withCString {
                open(
                    $0,
                    O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(descriptor) }

            let before = try Self.regularFileState(descriptor: descriptor)
            guard Self.historyFileState(at: url) == before else {
                throw CocoaError(.fileWriteUnknown)
            }
            let (minimumFinalByteCount, overflowed) = before.byteCount.addingReportingOverflow(
                Int64(data.count)
            )
            guard !overflowed else { throw CocoaError(.fileWriteOutOfSpace) }

            try Self.writeExactly(data, descriptor: descriptor)
            try Self.synchronize(descriptor: descriptor)

            let after = try Self.regularFileState(descriptor: descriptor)
            guard after.device == before.device,
                after.inode == before.inode,
                after.byteCount >= minimumFinalByteCount,
                Self.historyFileState(at: url) == after
            else {
                throw CocoaError(.fileWriteUnknown)
            }

            // Deliberately leave any prior summary fingerprint stale. Even a
            // non-cooperating writer can append or rewrite the JSONL between a
            // preflight fingerprint and this append, so incrementally blessing
            // the resulting fingerprint could omit those records. The next
            // measurement rebuilds once from the authoritative JSONL; repeated
            // 100 ms policy captures then return to bounded summary reads.
        }
    }

    public func recent(limit: Int = 100) throws -> [SyncRunRecord] {
        try FileLock.withExclusiveLock(at: lockURL) {
            let retainedLimit = max(0, limit)
            let candidate = try Self.withStableHistoryFile(
                at: url,
                expectedFingerprint: nil,
                {
                    descriptor, fingerprint in
                    var retained: [Data] = []
                    var firstRetainedIndex = 0
                    try Self.streamHistoryLines(
                        descriptor: descriptor,
                        byteCount: fingerprint.byteCount
                    ) { line in
                        guard retainedLimit > 0 else { return true }
                        retained.append(line)
                        if retained.count - firstRetainedIndex > retainedLimit {
                            firstRetainedIndex += 1
                        }
                        // Keep storage proportional to the requested result,
                        // rather than allowing discarded prefixes to grow with
                        // the append-only history.
                        let activeCount = retained.count - firstRetainedIndex
                        if firstRetainedIndex >= 128,
                            firstRetainedIndex >= activeCount
                        {
                            retained.removeFirst(firstRetainedIndex)
                            firstRetainedIndex = 0
                        }
                        return true
                    }
                    return Array(retained.dropFirst(firstRetainedIndex))
                }
            )
            guard let snapshot = candidate else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try snapshot.value.reversed().map {
                try decoder.decode(SyncRunRecord.self, from: $0)
            }
        }
    }

    /// Returns the conservative all-network protocol total since `date`.
    /// A single legacy, malformed, or unmeasured run makes the result unknown,
    /// so a configured daily cap can fail closed instead of treating missing
    /// accounting as zero.
    public func measuredNetworkBytes(since date: Date) throws -> Int64? {
        try measuredNetworkBytes(
            since: date,
            didOpenHistoryForScan: nil,
            didFinishReadingHistoryForScan: nil
        )
    }

    func measuredNetworkBytesForTesting(
        since date: Date,
        didOpenHistoryForScan: @escaping () throws -> Void,
        didFinishReadingHistoryForScan: @escaping (Int64?) throws -> Void
    ) throws -> Int64? {
        try measuredNetworkBytes(
            since: date,
            didOpenHistoryForScan: didOpenHistoryForScan,
            didFinishReadingHistoryForScan: didFinishReadingHistoryForScan
        )
    }

    private func measuredNetworkBytes(
        since date: Date,
        didOpenHistoryForScan: (() throws -> Void)?,
        didFinishReadingHistoryForScan: ((Int64?) throws -> Void)?
    ) throws -> Int64? {
        try FileLock.withExclusiveLock(at: lockURL) {
            guard date.timeIntervalSince1970.isFinite else {
                guard
                    let snapshot = try scanMeasuredNetworkBytesUnlocked(
                        since: date,
                        expectedFingerprint: nil,
                        didOpenHistory: didOpenHistoryForScan,
                        didFinishReadingHistory: didFinishReadingHistoryForScan
                    )
                else {
                    return 0
                }
                return snapshot.value
            }

            // A cooperating App or extension process holds the same file
            // lock. Fingerprinting also detects an older binary or external
            // writer that appends to or replaces the JSONL without updating
            // the sidecar. Repeated policy captures therefore read only a
            // bounded summary plus two bounded fingerprints, rather than
            // decoding an ever-growing history every 100 ms.
            var observedHistory = false
            for _ in 0..<2 {
                guard let before = try historyFingerprintUnlocked() else {
                    guard !observedHistory else { throw CocoaError(.fileReadUnknown) }
                    return 0
                }
                observedHistory = true
                if let summary = readMeasurementSummaryUnlocked(),
                    summary.isValid,
                    summary.sinceTimeInterval == date.timeIntervalSince1970,
                    summary.historyFingerprint == before,
                    try historyFingerprintUnlocked() == before
                {
                    return summary.measuredNetworkBytes
                }

                guard
                    let scanned = try scanMeasuredNetworkBytesUnlocked(
                        since: date,
                        expectedFingerprint: before,
                        didOpenHistory: didOpenHistoryForScan,
                        didFinishReadingHistory: didFinishReadingHistoryForScan
                    )
                else {
                    continue
                }
                let summary = NetworkMeasurementSummary(
                    since: date,
                    historyFingerprint: scanned.fingerprint,
                    measuredNetworkBytes: scanned.value
                )
                try? writeMeasurementSummaryUnlocked(summary)
                return scanned.value
            }
            throw CocoaError(.fileReadUnknown)
        }
    }

    private func readMeasurementSummaryUnlocked() -> NetworkMeasurementSummary? {
        guard
            let data = try? Self.readBoundedRegularFile(
                at: measurementSummaryURL,
                maximumByteCount: Self.maximumMeasurementSummaryBytes
            ),
            let summary = try? JSONDecoder().decode(NetworkMeasurementSummary.self, from: data)
        else {
            return nil
        }
        return summary
    }

    private func writeMeasurementSummaryUnlocked(_ summary: NetworkMeasurementSummary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(summary)
        guard data.count <= Self.maximumMeasurementSummaryBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: measurementSummaryURL, options: .atomic)
    }

    private func scanMeasuredNetworkBytesUnlocked(
        since date: Date,
        expectedFingerprint: HistoryFingerprint?,
        didOpenHistory: (() throws -> Void)?,
        didFinishReadingHistory: ((Int64?) throws -> Void)?
    ) throws -> (value: Int64?, fingerprint: HistoryFingerprint)? {
        try Self.withStableHistoryFile(
            at: url,
            expectedFingerprint: expectedFingerprint
        ) { descriptor, fingerprint in
            try didOpenHistory?()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var total: Int64? = 0
            do {
                try Self.streamHistoryLines(
                    descriptor: descriptor,
                    byteCount: fingerprint.byteCount
                ) { line in
                    let record = try decoder.decode(SyncRunRecord.self, from: line)
                    guard record.endedAt >= date else { return true }
                    guard let bytes = record.measuredNetworkBytes,
                        let current = total
                    else {
                        total = nil
                        return false
                    }
                    let (next, overflowed) = current.addingReportingOverflow(bytes)
                    guard !overflowed else {
                        total = nil
                        return false
                    }
                    total = next
                    return true
                }
            } catch is DecodingError {
                // A stable malformed JSONL is an unknown accounting result,
                // not a transient I/O failure. The descriptor/path checks
                // around this closure must still pass before it is cached.
                total = nil
            } catch HistoryStreamError.lineTooLong {
                // An overlong record is malformed rather than a truncated
                // record. Cache the same fail-closed unknown result only after
                // the stable-file postcondition below succeeds.
                total = nil
            }
            try didFinishReadingHistory?(total)
            return total
        }
    }

    private func historyFingerprintUnlocked() throws -> HistoryFingerprint? {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(descriptor) }

        return try Self.stableFingerprint(descriptor: descriptor, path: url)
    }

    private static func withStableHistoryFile<T>(
        at url: URL,
        expectedFingerprint: HistoryFingerprint? = nil,
        _ body: (Int32, HistoryFingerprint) throws -> T
    ) throws -> (value: T, fingerprint: HistoryFingerprint)? {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(descriptor) }

        let before = try stableFingerprint(descriptor: descriptor, path: url)
        if let expectedFingerprint, before != expectedFingerprint {
            throw CocoaError(.fileReadUnknown)
        }
        let value = try body(descriptor, before)
        let after = try stableFingerprint(descriptor: descriptor, path: url)
        guard after == before else { throw CocoaError(.fileReadUnknown) }
        return (value, after)
    }

    private static func stableFingerprint(
        descriptor: Int32,
        path: URL
    ) throws -> HistoryFingerprint {
        let before = try regularFileState(descriptor: descriptor)
        let edgeDigest = try boundedEdgeDigest(
            descriptor: descriptor,
            byteCount: before.byteCount
        )
        let after = try regularFileState(descriptor: descriptor)
        guard after == before, historyFileState(at: path) == before else {
            throw CocoaError(.fileReadUnknown)
        }
        return HistoryFingerprint(state: before, edgeDigest: edgeDigest)
    }

    private static func boundedEdgeDigest(descriptor: Int32, byteCount: Int64) throws -> UInt64 {
        let window = min(Int64(fingerprintWindowBytes), byteCount)
        var digest: UInt64 = 14_695_981_039_346_656_037
        func absorb(_ data: Data) {
            for byte in data {
                digest ^= UInt64(byte)
                digest &*= 1_099_511_628_211
            }
        }
        if window > 0 {
            absorb(
                try readExactly(
                    descriptor: descriptor,
                    offset: 0,
                    byteCount: Int(window)
                )
            )
        }
        if byteCount > window {
            absorb(
                try readExactly(
                    descriptor: descriptor,
                    offset: byteCount - window,
                    byteCount: Int(window)
                )
            )
        }
        return digest
    }

    private static func readBoundedRegularFile(
        at url: URL,
        maximumByteCount: Int64
    ) throws -> Data {
        guard maximumByteCount >= 0, maximumByteCount <= Int64(Int.max) else {
            throw CocoaError(.fileReadTooLarge)
        }
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_size >= 0,
            before.st_size <= maximumByteCount
        else {
            throw CocoaError(.fileReadTooLarge)
        }
        let state = HistoryFileState(before)
        let data = try readExactly(
            descriptor: descriptor,
            offset: 0,
            byteCount: Int(state.byteCount)
        )
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            HistoryFileState(after) == state,
            Int64(data.count) == state.byteCount,
            historyFileState(at: url) == state
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    private static func streamHistoryLines(
        descriptor: Int32,
        byteCount: Int64,
        _ visit: (Data) throws -> Bool
    ) throws {
        guard byteCount >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        var offset: Int64 = 0
        var pending = Data()
        pending.reserveCapacity(min(maximumHistoryRecordBytes, historyReadChunkBytes))
        while offset < byteCount {
            let count = Int(min(Int64(historyReadChunkBytes), byteCount - offset))
            let chunk = try readExactly(
                descriptor: descriptor,
                offset: offset,
                byteCount: count
            )
            offset += Int64(count)
            for byte in chunk {
                if byte == 0x0A {
                    if !pending.isEmpty, try !visit(pending) { return }
                    pending.removeAll(keepingCapacity: true)
                } else {
                    guard pending.count < maximumHistoryRecordBytes else {
                        throw HistoryStreamError.lineTooLong
                    }
                    pending.append(byte)
                }
            }
        }
        if !pending.isEmpty {
            _ = try visit(pending)
        }
    }

    private static func readExactly(
        descriptor: Int32,
        offset: Int64,
        byteCount: Int
    ) throws -> Data {
        guard offset >= 0, byteCount >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (endOffset, overflowed) = offset.addingReportingOverflow(Int64(byteCount))
        guard !overflowed, endOffset >= offset else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard byteCount > 0 else { return Data() }

        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var total = 0
            while total < byteCount {
                let result = pread(
                    descriptor,
                    baseAddress.advanced(by: total),
                    byteCount - total,
                    off_t(offset + Int64(total))
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw CocoaError(.fileReadCorruptFile) }
                total += result
            }
        }
        return data
    }

    private static func writeExactly(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var total = 0
            while total < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: total),
                    buffer.count - total
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw CocoaError(.fileWriteUnknown) }
                total += result
            }
        }
    }

    private static func synchronize(descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func regularFileState(descriptor: Int32) throws -> HistoryFileState {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            status.st_size >= 0
        else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return HistoryFileState(status)
    }

    private static func historyFileState(at url: URL) -> HistoryFileState? {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            status.st_size >= 0
        else {
            return nil
        }
        return HistoryFileState(status)
    }
}
