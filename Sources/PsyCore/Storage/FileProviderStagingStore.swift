import CryptoKit
import Darwin
import Foundation

public enum FileProviderStagingError: Error, Hashable, Sendable {
    case unsafeRoot
    case unsafeCommandDirectory
    case sourceNotRegularFile
    case sourceChangedDuringCopy
    case existingContentMismatch
    case availableCapacityUnknown
    case insufficientCapacity(required: Int64, available: Int64)
    case sizeOverflow
    case invalidStagedContentToken
    case targetNotRegularFile
    case contentChangedDuringValidation
    case reservationStateCorrupt
    case durabilitySyncFailed
}

public struct FileProviderStagingResult: Hashable, Sendable {
    public var token: String
    public var createdByThisInvocation: Bool

    public init(token: String, createdByThisInvocation: Bool) {
        self.token = token
        self.createdByThisInvocation = createdByThisInvocation
    }
}

/// Owns the App Group upload staging area used by the replicated File Provider.
///
/// Staged bytes remain durable while their command is pending or requires
/// manual reconciliation. Cleanup is deliberately age-gated and receives the
/// complete set of command IDs that must be retained, so extension recreation
/// cannot delete an in-flight upload.
public struct FileProviderStagingStore: Sendable {
    public typealias AvailableCapacity = @Sendable (URL) throws -> Int64?
    public typealias CancellationCheck = @Sendable () throws -> Void
    public typealias ProgressHandler = @Sendable (_ completedBytes: Int64, _ totalBytes: Int64) -> Void

    typealias BeforeSourceRead = @Sendable (URL) throws -> Void

    public static let defaultMinimumFreeSpaceBytes: Int64 = 256 * 1_024 * 1_024
    public static let defaultStaleAge: TimeInterval = 24 * 60 * 60

    private let root: URL
    private let minimumFreeSpaceBytes: Int64
    private let staleAge: TimeInterval
    private let availableCapacity: AvailableCapacity
    private let beforeSourceRead: BeforeSourceRead
    private let beforeCommit: CancellationCheck
    private let beforeComparison: CancellationCheck
    private let beforePathIdentityRecheck: BeforeSourceRead

    public init(
        root: URL,
        minimumFreeSpaceBytes: Int64 = Self.defaultMinimumFreeSpaceBytes,
        staleAge: TimeInterval = Self.defaultStaleAge,
        availableCapacity: @escaping AvailableCapacity = { url in
            try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
    ) {
        self.init(
            root: root,
            minimumFreeSpaceBytes: minimumFreeSpaceBytes,
            staleAge: staleAge,
            availableCapacity: availableCapacity,
            beforeSourceRead: { _ in },
            beforeCommit: {},
            beforeComparison: {},
            beforePathIdentityRecheck: { _ in }
        )
    }

    init(
        root: URL,
        minimumFreeSpaceBytes: Int64 = Self.defaultMinimumFreeSpaceBytes,
        staleAge: TimeInterval = Self.defaultStaleAge,
        availableCapacity: @escaping AvailableCapacity,
        beforeSourceRead: @escaping BeforeSourceRead,
        beforeCommit: @escaping CancellationCheck = {},
        beforeComparison: @escaping CancellationCheck = {},
        beforePathIdentityRecheck: @escaping BeforeSourceRead = { _ in }
    ) {
        self.root = root.standardizedFileURL
        self.minimumFreeSpaceBytes = max(0, minimumFreeSpaceBytes)
        self.staleAge = max(0, staleAge)
        self.availableCapacity = availableCapacity
        self.beforeSourceRead = beforeSourceRead
        self.beforeCommit = beforeCommit
        self.beforeComparison = beforeComparison
        self.beforePathIdentityRecheck = beforePathIdentityRecheck
    }

    /// Copies a coordinated, immutable source into `<UUID>/contents` and
    /// returns the only token shape accepted by the Go bridge.
    public func stage(
        _ source: URL,
        id: UUID,
        cancellationCheck: @escaping CancellationCheck = {},
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> String {
        try stageWithDisposition(
            source,
            id: id,
            cancellationCheck: cancellationCheck,
            progress: progress
        ).token
    }

    /// Stages bytes and reports, while holding the cross-process operation
    /// lock, whether this exact invocation installed the durable token.
    public func stageWithDisposition(
        _ source: URL,
        id: UUID,
        cancellationCheck: @escaping CancellationCheck = {},
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> FileProviderStagingResult {
        try cancellationCheck()
        try ensureSafeRoot()
        return try FileLock.withExclusiveLock(at: operationLockURL) {
            // Recheck after acquiring the cross-process reservation lock. Both
            // the capacity observation and the durable copy must be serialized
            // so concurrent uploads cannot all spend the same free bytes.
            try cancellationCheck()
            try ensureSafeRoot()
            return try stageLocked(
                source,
                id: id,
                cancellationCheck: cancellationCheck,
                progress: progress
            )
        }
    }

    /// Holds the staging operation lock until the caller's durable commit
    /// completes. A replay cannot borrow an idempotent token between staging
    /// and enqueue, and a failed commit removes only bytes installed by this
    /// invocation.
    public func stageAndCommit(
        _ source: URL,
        id: UUID,
        cancellationCheck: @escaping CancellationCheck = {},
        progress: @escaping ProgressHandler = { _, _ in },
        expectedDigest: Data? = nil,
        commit: () throws -> Void
    ) throws -> FileProviderStagingResult {
        try cancellationCheck()
        try ensureSafeRoot()
        return try FileLock.withExclusiveLock(at: operationLockURL) {
            try cancellationCheck()
            try ensureSafeRoot()
            let result = try stageLocked(
                source,
                id: id,
                cancellationCheck: cancellationCheck,
                progress: progress
            )
            do {
                try cancellationCheck()
                if let expectedDigest {
                    let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
                    guard
                        try secureDigest(
                            root: directory, relativePath: "contents", invalidFileError: .existingContentMismatch,
                            cancellationCheck: cancellationCheck) == expectedDigest
                    else { throw FileProviderStagingError.contentChangedDuringValidation }
                }
                try commit()
                return result
            } catch {
                if result.createdByThisInvocation {
                    try releaseLocked(id: id)
                }
                throw error
            }
        }
    }

    /// Content identities for retry/conflict naming. The descriptor, file type
    /// and inode/time/size fence are checked before and after hashing.
    public func sourceContentDigest(_ source: URL, cancellationCheck: CancellationCheck = {}) throws -> Data {
        let opened = try openRegularSource(source)
        defer { close(opened.descriptor) }
        return try secureDigest(
            descriptor: opened.descriptor, invalidFileError: .sourceNotRegularFile, cancellationCheck: cancellationCheck
        )
    }

    public func managedContentDigest(root: URL, relativePath: String, cancellationCheck: CancellationCheck = {}) throws
        -> Data
    {
        try secureDigest(
            root: root, relativePath: relativePath, invalidFileError: .targetNotRegularFile,
            cancellationCheck: cancellationCheck)
    }

    /// Releases both the staged bytes and their durable destination-space
    /// reservation after a command reaches a terminal, reconciled state.
    /// Removing bytes first is conservative: if persisting the reservation
    /// update fails, later requests continue to reserve too much rather than
    /// overcommitting disk space.
    public func release(id: UUID) throws {
        try ensureSafeRoot()
        try FileLock.withExclusiveLock(at: operationLockURL) {
            try ensureSafeRoot()
            try releaseLocked(id: id)
        }
    }

    private func releaseLocked(id: UUID) throws {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try validateExistingCommandDirectory(directory)
            try FileManager.default.removeItem(at: directory)
            try synchronizeDirectory(root)
        }
        var reservations = try loadReservationsLocked()
        if reservations.removeValue(forKey: id) != nil {
            try persistReservationsLocked(reservations)
        }
    }

    /// Compares a mutation's retained upload with the installed target while
    /// holding the same cross-process lock used by staging and cleanup. Tokens
    /// are deliberately not general paths: the command UUID and `contents`
    /// leaf must match byte-for-byte.
    public func contentMatches(
        token: String,
        commandID: UUID,
        targetRoot: URL,
        targetRelativePath: String
    ) throws -> Bool {
        guard token == commandID.uuidString + "/contents" else {
            throw FileProviderStagingError.invalidStagedContentToken
        }
        try ensureSafeRoot()
        return try FileLock.withExclusiveLock(at: operationLockURL) {
            try ensureSafeRoot()
            return try contentMatchesLocked(
                commandID: commandID,
                targetRoot: targetRoot,
                targetRelativePath: targetRelativePath
            )
        }
    }

    /// Stages a reimport probe, compares it with an authoritative managed
    /// target, and conditionally releases newly created probe bytes while one
    /// cross-process operation lock is held. Concurrent callbacks therefore
    /// cannot borrow or delete another invocation's token between these steps.
    public func stageAndCompareContent(
        _ source: URL,
        id: UUID,
        targetRoot: URL,
        targetRelativePath: String,
        cancellationCheck: @escaping CancellationCheck = {},
        progress: @escaping ProgressHandler = { _, _ in }
    ) throws -> Bool {
        try cancellationCheck()
        try ensureSafeRoot()
        return try FileLock.withExclusiveLock(at: operationLockURL) {
            try cancellationCheck()
            try ensureSafeRoot()
            let result = try stageLocked(
                source,
                id: id,
                cancellationCheck: cancellationCheck,
                progress: progress
            )
            do {
                try cancellationCheck()
                try beforeComparison()
                try cancellationCheck()
                guard result.token == id.uuidString + "/contents" else {
                    throw FileProviderStagingError.invalidStagedContentToken
                }
                let matches = try contentMatchesLocked(
                    commandID: id,
                    targetRoot: targetRoot,
                    targetRelativePath: targetRelativePath,
                    cancellationCheck: cancellationCheck
                )
                try cancellationCheck()
                if result.createdByThisInvocation {
                    try releaseLocked(id: id)
                }
                return matches
            } catch {
                if result.createdByThisInvocation {
                    try? releaseLocked(id: id)
                }
                throw error
            }
        }
    }

    private func contentMatchesLocked(
        commandID: UUID,
        targetRoot: URL,
        targetRelativePath: String,
        cancellationCheck: CancellationCheck = {}
    ) throws -> Bool {
        let directory = root.appendingPathComponent(commandID.uuidString, isDirectory: true)
        try validateExistingCommandDirectory(directory)
        let stagedDigest = try secureDigest(
            root: directory,
            relativePath: "contents",
            invalidFileError: .existingContentMismatch,
            cancellationCheck: cancellationCheck
        )
        let targetDigest = try secureDigest(
            root: targetRoot,
            relativePath: targetRelativePath,
            invalidFileError: .targetNotRegularFile,
            cancellationCheck: cancellationCheck
        )
        return stagedDigest == targetDigest
    }

    private func stageLocked(
        _ source: URL,
        id: UUID,
        cancellationCheck: CancellationCheck,
        progress: ProgressHandler
    ) throws -> FileProviderStagingResult {
        try cancellationCheck()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try ensureSafeCommandDirectory(directory)
        let destination = directory.appendingPathComponent("contents", isDirectory: false)

        let openedSource = try openRegularSource(source)
        defer { close(openedSource.descriptor) }
        let byteCount = openedSource.state.size
        let (reportedTotalBytes, totalOverflow) = byteCount.multipliedReportingOverflow(by: 2)
        let progressTotal = totalOverflow || reportedTotalBytes <= 0 ? 1 : reportedTotalBytes
        progress(0, progressTotal)
        if FileManager.default.fileExists(atPath: destination.path) {
            try beforeSourceRead(source)
            let sourceDigest = try digest(
                descriptor: openedSource.descriptor,
                cancellationCheck: cancellationCheck,
                progress: { completedBytes in
                    progress(min(completedBytes, progressTotal), progressTotal)
                }
            )
            try validateSourceAfterRead(
                source,
                descriptor: openedSource.descriptor,
                initialState: openedSource.state,
                bytesRead: sourceDigest.bytesRead
            )
            let destinationDigest = try secureDigest(
                root: directory,
                relativePath: destination.lastPathComponent,
                invalidFileError: .existingContentMismatch,
                cancellationCheck: cancellationCheck,
                progress: { completedBytes in
                    let (combined, overflow) = byteCount.addingReportingOverflow(completedBytes)
                    progress(
                        min(overflow ? progressTotal : combined, progressTotal),
                        progressTotal
                    )
                }
            )
            guard destinationDigest == sourceDigest.digest else {
                throw FileProviderStagingError.existingContentMismatch
            }
            try reserveDestinationLocked(
                id: id,
                byteCount: openedSource.state.size,
                stagingBytesAlreadyPresent: true
            )
            try cancellationCheck()
            progress(progressTotal, progressTotal)
            return FileProviderStagingResult(
                token: id.uuidString + "/contents",
                createdByThisInvocation: false
            )
        }

        try cancellationCheck()
        try reserveDestinationLocked(
            id: id,
            byteCount: openedSource.state.size,
            stagingBytesAlreadyPresent: false
        )
        var keepReservation = false
        var installedByThisInvocation = false
        defer {
            if !keepReservation {
                if installedByThisInvocation {
                    try? FileManager.default.removeItem(at: destination)
                    try? synchronizeDirectory(directory)
                }
                try? removeReservationLocked(id: id)
            }
        }

        let temporary = directory.appendingPathComponent(
            ".contents-" + UUID().uuidString,
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try beforeSourceRead(source)
        let copied = try copyAndDigest(
            from: openedSource.descriptor,
            to: temporary,
            cancellationCheck: cancellationCheck,
            progress: { completedBytes in
                progress(min(completedBytes, progressTotal), progressTotal)
            }
        )
        try cancellationCheck()
        try validateSourceAfterRead(
            source,
            descriptor: openedSource.descriptor,
            initialState: openedSource.state,
            bytesRead: copied.bytesRead
        )

        do {
            try cancellationCheck()
            try FileManager.default.moveItem(at: temporary, to: destination)
            installedByThisInvocation = true
        } catch {
            guard FileManager.default.fileExists(atPath: destination.path),
                try secureDigest(
                    root: directory,
                    relativePath: destination.lastPathComponent,
                    invalidFileError: .existingContentMismatch
                ) == copied.digest
            else {
                throw error
            }
        }
        try beforeCommit()
        try cancellationCheck()
        let installedDigest = try secureDigest(
            root: directory,
            relativePath: destination.lastPathComponent,
            invalidFileError: .existingContentMismatch,
            cancellationCheck: cancellationCheck,
            progress: { completedBytes in
                let (combined, overflow) = byteCount.addingReportingOverflow(completedBytes)
                progress(
                    min(overflow ? progressTotal : combined, progressTotal),
                    progressTotal
                )
            }
        )
        guard installedDigest == copied.digest else {
            throw FileProviderStagingError.existingContentMismatch
        }
        try cancellationCheck()
        try synchronizeDirectory(directory)
        keepReservation = true
        progress(progressTotal, progressTotal)
        return FileProviderStagingResult(
            token: id.uuidString + "/contents",
            createdByThisInvocation: installedByThisInvocation
        )
    }

    /// Removes only expired, real UUID directories that are not referenced by
    /// a pending command. Suspicious entries are left untouched for diagnosis.
    @discardableResult
    public func reclaimStaleDirectories(
        retaining retainedIDs: Set<UUID>,
        now: Date = .now
    ) throws -> Int {
        try ensureSafeRoot()
        return try FileLock.withExclusiveLock(at: operationLockURL) {
            try ensureSafeRoot()
            return try reclaimStaleDirectoriesLocked(retaining: retainedIDs, now: now)
        }
    }

    private func reclaimStaleDirectoriesLocked(
        retaining retainedIDs: Set<UUID>,
        now: Date
    ) throws -> Int {
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        var removed = 0
        var reservations = try loadReservationsLocked()
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                !retainedIDs.contains(id),
                isDirectChild(entry, of: root),
                isRealDirectory(entry),
                let attributes = try? manager.attributesOfItem(atPath: entry.path),
                let modifiedAt = attributes[.modificationDate] as? Date,
                now.timeIntervalSince(modifiedAt) >= staleAge
            else {
                continue
            }
            try manager.removeItem(at: entry)
            reservations.removeValue(forKey: id)
            removed += 1
        }
        let existingIDs = Set(
            (try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            ))?.compactMap { UUID(uuidString: $0.lastPathComponent) } ?? []
        )
        reservations = reservations.filter { existingIDs.contains($0.key) }
        try persistReservationsLocked(reservations)
        return removed
    }

    private var operationLockURL: URL {
        root.appendingPathExtension("operations.lock")
    }

    private func ensureSafeRoot() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard isRealDirectory(root) else {
            throw FileProviderStagingError.unsafeRoot
        }
    }

    private func ensureSafeCommandDirectory(_ directory: URL) throws {
        guard isDirectChild(directory, of: root) else {
            throw FileProviderStagingError.unsafeCommandDirectory
        }
        var status = stat()
        let initialResult = directory.path.withCString { lstat($0, &status) }
        if initialResult != 0 {
            guard errno == ENOENT else {
                throw FileProviderStagingError.unsafeCommandDirectory
            }
            let createResult = directory.path.withCString { mkdir($0, mode_t(0o700)) }
            guard createResult == 0 || errno == EEXIST else {
                throw FileProviderStagingError.unsafeCommandDirectory
            }
        }
        guard isRealDirectory(directory) else {
            throw FileProviderStagingError.unsafeCommandDirectory
        }
    }

    private func validateExistingCommandDirectory(_ directory: URL) throws {
        guard isDirectChild(directory, of: root), isRealDirectory(directory) else {
            throw FileProviderStagingError.unsafeCommandDirectory
        }
    }

    private var reservationsURL: URL {
        root.appendingPathComponent(".reservations-v1.json", isDirectory: false)
    }

    private func reserveDestinationLocked(
        id: UUID,
        byteCount: Int64,
        stagingBytesAlreadyPresent: Bool
    ) throws {
        guard byteCount >= 0 else { throw FileProviderStagingError.sizeOverflow }
        var reservations = try loadReservationsLocked()
        if let existing = reservations[id] {
            guard existing == byteCount else {
                throw FileProviderStagingError.reservationStateCorrupt
            }
            // An installed staged file already consumes its bytes in the live
            // capacity observation, and its durable entry reserves only the
            // future atomic destination copy. If a process crashed after the
            // ledger commit but before installing `contents`, the ledger must
            // continue to reserve both copies until the retry finishes.
            guard !stagingBytesAlreadyPresent else { return }
            let outstanding = try outstandingReservationBytesLocked(reservations)
            let (required, overflow) = outstanding.addingReportingOverflow(minimumFreeSpaceBytes)
            guard !overflow else { throw FileProviderStagingError.sizeOverflow }
            try requireAvailableCapacity(required)
            return
        }
        guard reservations.count < ReservationDocument.maximumEntries else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        let outstanding = try outstandingReservationBytesLocked(reservations)
        let newStagingBytes = stagingBytesAlreadyPresent ? 0 : byteCount
        let (withStaging, firstOverflow) = outstanding.addingReportingOverflow(newStagingBytes)
        let (withDestination, secondOverflow) = withStaging.addingReportingOverflow(byteCount)
        let (required, thirdOverflow) = withDestination.addingReportingOverflow(minimumFreeSpaceBytes)
        guard !firstOverflow, !secondOverflow, !thirdOverflow else {
            throw FileProviderStagingError.sizeOverflow
        }
        try requireAvailableCapacity(required)
        reservations[id] = byteCount
        try persistReservationsLocked(reservations)
    }

    private func outstandingReservationBytesLocked(
        _ reservations: [UUID: Int64]
    ) throws -> Int64 {
        try reservations.reduce(into: Int64(0)) { total, entry in
            let copiesStillRequired =
                try hasInstalledStagedContent(
                    id: entry.key,
                    expectedSize: entry.value
                ) ? 1 : 2
            for _ in 0..<copiesStillRequired {
                let (next, overflow) = total.addingReportingOverflow(entry.value)
                guard !overflow else { throw FileProviderStagingError.sizeOverflow }
                total = next
            }
        }
    }

    private func hasInstalledStagedContent(id: UUID, expectedSize: Int64) throws -> Bool {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        var pathStatus = stat()
        let pathResult = directory.path.withCString { lstat($0, &pathStatus) }
        if pathResult != 0, errno == ENOENT { return false }
        guard pathResult == 0,
            pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        let directoryDescriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        defer { close(directoryDescriptor) }
        var openedDirectoryStatus = stat()
        guard fstat(directoryDescriptor, &openedDirectoryStatus) == 0,
            openedDirectoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            openedDirectoryStatus.st_dev == pathStatus.st_dev,
            openedDirectoryStatus.st_ino == pathStatus.st_ino
        else {
            throw FileProviderStagingError.reservationStateCorrupt
        }

        let descriptor = "contents".withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0, errno == ENOENT { return false }
        guard descriptor >= 0 else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        defer { close(descriptor) }
        var contentStatus = stat()
        var contentPathStatus = stat()
        let contentPathResult = "contents".withCString {
            fstatat(directoryDescriptor, $0, &contentPathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard fstat(descriptor, &contentStatus) == 0,
            contentPathResult == 0,
            contentStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            contentPathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            contentStatus.st_size == expectedSize,
            contentStatus.st_dev == contentPathStatus.st_dev,
            contentStatus.st_ino == contentPathStatus.st_ino
        else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        return true
    }

    private func requireAvailableCapacity(_ required: Int64) throws {
        guard let available = try availableCapacity(root) else {
            throw FileProviderStagingError.availableCapacityUnknown
        }
        guard available >= required else {
            throw FileProviderStagingError.insufficientCapacity(
                required: required,
                available: available
            )
        }
    }

    private func removeReservationLocked(id: UUID) throws {
        var reservations = try loadReservationsLocked()
        guard reservations.removeValue(forKey: id) != nil else { return }
        try persistReservationsLocked(reservations)
    }

    private func loadReservationsLocked() throws -> [UUID: Int64] {
        var status = stat()
        let result = reservationsURL.path.withCString { lstat($0, &status) }
        if result != 0 {
            if errno == ENOENT { return [:] }
            throw FileProviderStagingError.reservationStateCorrupt
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            status.st_size >= 0,
            status.st_size <= 1_048_576
        else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        let descriptor = reservationsURL.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw FileProviderStagingError.reservationStateCorrupt }
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            openedStatus.st_dev == status.st_dev,
            openedStatus.st_ino == status.st_ino,
            openedStatus.st_size == status.st_size
        else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        let document: ReservationDocument
        do {
            document = try JSONDecoder().decode(ReservationDocument.self, from: data)
        } catch {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        guard document.schemaVersion == ReservationDocument.schemaVersion,
            document.entries.count <= ReservationDocument.maximumEntries
        else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        var reservations: [UUID: Int64] = [:]
        for entry in document.entries {
            guard entry.destinationBytes >= 0,
                reservations.updateValue(entry.destinationBytes, forKey: entry.commandID) == nil
            else {
                throw FileProviderStagingError.reservationStateCorrupt
            }
        }
        return reservations
    }

    private func persistReservationsLocked(_ reservations: [UUID: Int64]) throws {
        guard reservations.count <= ReservationDocument.maximumEntries,
            reservations.values.allSatisfy({ $0 >= 0 })
        else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        let entries = reservations.map {
            ReservationEntry(commandID: $0.key, destinationBytes: $0.value)
        }.sorted { $0.commandID.uuidString < $1.commandID.uuidString }
        let document = ReservationDocument(entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= 1_048_576 else {
            throw FileProviderStagingError.reservationStateCorrupt
        }
        #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
        #else
            let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: reservationsURL, options: options)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: reservationsURL.path
        )
        try synchronizeRegularFile(reservationsURL)
        try synchronizeDirectory(root)
    }

    private func synchronizeRegularFile(_ url: URL) throws {
        var pathStatus = stat()
        guard url.path.withCString({ lstat($0, &pathStatus) }) == 0,
            pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw FileProviderStagingError.durabilitySyncFailed
        }
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw FileProviderStagingError.durabilitySyncFailed }
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            openedStatus.st_dev == pathStatus.st_dev,
            openedStatus.st_ino == pathStatus.st_ino,
            fsync(descriptor) == 0
        else {
            throw FileProviderStagingError.durabilitySyncFailed
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        var pathStatus = stat()
        guard url.path.withCString({ lstat($0, &pathStatus) }) == 0,
            pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw FileProviderStagingError.durabilitySyncFailed
        }
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw FileProviderStagingError.durabilitySyncFailed }
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            openedStatus.st_dev == pathStatus.st_dev,
            openedStatus.st_ino == pathStatus.st_ino,
            fsync(descriptor) == 0
        else {
            throw FileProviderStagingError.durabilitySyncFailed
        }
    }

    private func openRegularSource(_ source: URL) throws -> OpenedRegularFile {
        let descriptor = source.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw FileProviderStagingError.sourceNotRegularFile
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            close(descriptor)
            throw FileProviderStagingError.sourceNotRegularFile
        }
        let state = DescriptorFileState(status)
        guard pathState(of: source) == state else {
            close(descriptor)
            throw FileProviderStagingError.sourceNotRegularFile
        }
        return OpenedRegularFile(descriptor: descriptor, state: state)
    }

    private func validateSourceAfterRead(
        _ source: URL,
        descriptor: Int32,
        initialState: DescriptorFileState,
        bytesRead: Int64
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            DescriptorFileState(status) == initialState,
            bytesRead == initialState.size,
            pathState(of: source) == initialState
        else {
            throw FileProviderStagingError.sourceChangedDuringCopy
        }
    }

    private func pathState(of url: URL) -> DescriptorFileState? {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            return nil
        }
        return DescriptorFileState(status)
    }

    private func copyAndDigest(
        from sourceDescriptor: Int32,
        to destination: URL,
        cancellationCheck: CancellationCheck,
        progress: @Sendable (Int64) -> Void
    ) throws
        -> DigestedBytes
    {
        let manager = FileManager.default
        let outputDescriptor = destination.path.withCString {
            open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard outputDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { close(outputDescriptor) }
        #if os(iOS)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
        #endif
        guard lseek(sourceDescriptor, 0, SEEK_SET) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false)
        var hasher = SHA256()
        var bytesRead: Int64 = 0
        while true {
            try cancellationCheck()
            let chunk = try input.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            hasher.update(data: chunk)
            bytesRead += Int64(chunk.count)
            progress(bytesRead)
        }
        try cancellationCheck()
        try output.synchronize()
        return DigestedBytes(digest: Data(hasher.finalize()), bytesRead: bytesRead)
    }

    private func digest(
        descriptor: Int32,
        cancellationCheck: CancellationCheck = {},
        progress: @Sendable (Int64) -> Void = { _ in }
    ) throws -> DigestedBytes {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        var bytesRead: Int64 = 0
        while true {
            try cancellationCheck()
            let chunk = try input.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            bytesRead += Int64(chunk.count)
            progress(bytesRead)
        }
        try cancellationCheck()
        return DigestedBytes(digest: Data(hasher.finalize()), bytesRead: bytesRead)
    }

    private func secureDigest(
        root digestRoot: URL,
        relativePath: String,
        invalidFileError: FileProviderStagingError,
        cancellationCheck: CancellationCheck = {},
        progress: @Sendable (Int64) -> Void = { _ in }
    ) throws -> Data {
        try cancellationCheck()
        guard let components = safeRelativePathComponents(relativePath) else {
            throw invalidFileError
        }
        let rootDescriptor = digestRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else { throw invalidFileError }
        defer { close(rootDescriptor) }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
            rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw invalidFileError
        }
        let rootDevice = UInt64(UInt32(bitPattern: rootStatus.st_dev))
        let rootInode = UInt64(rootStatus.st_ino)

        var directoryDescriptor = rootDescriptor
        var ownedDirectoryDescriptor: Int32?
        defer {
            if let ownedDirectoryDescriptor {
                close(ownedDirectoryDescriptor)
            }
        }
        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else { throw invalidFileError }
            if let ownedDirectoryDescriptor {
                close(ownedDirectoryDescriptor)
            }
            ownedDirectoryDescriptor = nextDescriptor
            directoryDescriptor = nextDescriptor
        }
        let descriptor = components[components.count - 1].withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else { throw invalidFileError }
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
            openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw invalidFileError
        }
        let openedState = DescriptorFileState(openedStatus)
        let digest = try secureDigest(
            descriptor: descriptor,
            invalidFileError: invalidFileError,
            cancellationCheck: cancellationCheck,
            progress: progress
        )
        try beforePathIdentityRecheck(
            digestRoot.appendingPathComponent(relativePath, isDirectory: false)
        )
        try cancellationCheck()
        var descriptorAfter = stat()
        guard fstat(descriptor, &descriptorAfter) == 0,
            DescriptorFileState(descriptorAfter) == openedState,
            currentRegularFileState(
                root: digestRoot,
                expectedDevice: rootDevice,
                expectedInode: rootInode,
                components: components
            ) == openedState
        else {
            throw FileProviderStagingError.contentChangedDuringValidation
        }
        return digest
    }

    /// Reopens the complete no-follow path after hashing. Checking only the
    /// already-open file descriptor would accept the old inode if the managed
    /// target or one of its parent directories were replaced during the read.
    private func currentRegularFileState(
        root pathRoot: URL,
        expectedDevice: UInt64,
        expectedInode: UInt64,
        components: [String]
    ) -> DescriptorFileState? {
        let rootDescriptor = pathRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else { return nil }
        defer { close(rootDescriptor) }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
            rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            UInt64(UInt32(bitPattern: rootStatus.st_dev)) == expectedDevice,
            UInt64(rootStatus.st_ino) == expectedInode
        else {
            return nil
        }

        var directoryDescriptor = rootDescriptor
        var ownedDirectoryDescriptor: Int32?
        defer {
            if let ownedDirectoryDescriptor {
                close(ownedDirectoryDescriptor)
            }
        }
        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else { return nil }
            if let ownedDirectoryDescriptor {
                close(ownedDirectoryDescriptor)
            }
            ownedDirectoryDescriptor = nextDescriptor
            directoryDescriptor = nextDescriptor
        }
        let descriptor = components[components.count - 1].withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            return nil
        }
        return DescriptorFileState(status)
    }

    private func secureDigest(
        descriptor: Int32,
        invalidFileError: FileProviderStagingError,
        cancellationCheck: CancellationCheck = {},
        progress: @Sendable (Int64) -> Void = { _ in }
    ) throws -> Data {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw invalidFileError
        }
        let beforeState = DescriptorFileState(before)
        let digested = try digest(
            descriptor: descriptor,
            cancellationCheck: cancellationCheck,
            progress: progress
        )
        try cancellationCheck()
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw FileProviderStagingError.contentChangedDuringValidation
        }
        guard beforeState == DescriptorFileState(after), digested.bytesRead == after.st_size else {
            throw FileProviderStagingError.contentChangedDuringValidation
        }
        return digested.digest
    }

    private func safeRelativePathComponents(_ relativePath: String) -> [String]? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\0"),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            return nil
        }
        return components.map(String.init)
    }

    private func isDirectChild(_ child: URL, of parent: URL) -> Bool {
        // Every caller supplies exactly one UUID child. Normalize only
        // Darwin's fixed root aliases; filesystem standardization after the
        // root appears can otherwise change `/var` to `/private/var` between
        // an internally constructed URL and a FileManager enumeration result.
        return !child.lastPathComponent.isEmpty
            && normalizedDarwinPath(child.deletingLastPathComponent())
                == normalizedDarwinPath(parent)
    }

    private func normalizedDarwinPath(_ url: URL) -> String {
        let path = url.path
        if path == "/var" || path.hasPrefix("/var/") { return "/private" + path }
        if path == "/tmp" || path.hasPrefix("/tmp/") { return "/private" + path }
        if path == "/etc" || path.hasPrefix("/etc/") { return "/private" + path }
        return path
    }

    /// Uses the same no-follow filesystem primitive on every Apple platform.
    /// Foundation's symbolic-link query can transiently report a just-created
    /// directory as unavailable in a physical iOS app container.
    private func isRealDirectory(_ url: URL) -> Bool {
        var status = stat()
        return url.path.withCString { lstat($0, &status) } == 0
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }
}

private struct OpenedRegularFile {
    var descriptor: Int32
    var state: DescriptorFileState
}

private struct DigestedBytes {
    var digest: Data
    var bytesRead: Int64
}

private struct ReservationDocument: Codable {
    static let schemaVersion = 1
    static let maximumEntries = 4_096

    var schemaVersion: Int = Self.schemaVersion
    var entries: [ReservationEntry]
}

private struct ReservationEntry: Codable {
    var commandID: UUID
    var destinationBytes: Int64
}

private struct DescriptorFileState: Equatable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
    var changedSeconds: Int64
    var changedNanoseconds: Int64

    init(_ value: stat) {
        device = UInt64(UInt32(bitPattern: value.st_dev))
        inode = UInt64(value.st_ino)
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}
