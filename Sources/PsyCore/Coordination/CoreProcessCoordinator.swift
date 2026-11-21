import Darwin
import Foundation

public enum CoreProcessRole: String, Codable, Sendable {
    case mainApp
    case backgroundTask
    case fileProvider
    case appIntent
}

public struct CoreOwnerLease: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var epoch: UInt64
    public var instanceID: UUID
    public var role: CoreProcessRole
    public var acquiredAt: Date

    public init(
        schemaVersion: Int = Self.schemaVersion,
        epoch: UInt64,
        instanceID: UUID,
        role: CoreProcessRole,
        acquiredAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.epoch = epoch
        self.instanceID = instanceID
        self.role = role
        self.acquiredAt = acquiredAt
    }
}

public enum CoreOwnershipError: Error, Equatable, Sendable {
    case alreadyOwnedByThisInstance
    case ownedByAnotherProcess
    case cannotOpenLock(Int32)
    case cannotLock(Int32)
    case ownerMetadataMissing
    case ownerMetadataUnreadable
    case ownerMetadataCorrupt
    case unsupportedOwnerMetadataSchema(Int)
    case ownerEpochOverflow
    case ownerMetadataWriteFailed
    case notOwner
    case staleLease
}

public actor CoreProcessCoordinator {
    private let lockURL: URL
    private let metadataURL: URL
    private var descriptor: Int32 = -1
    private var openedLock: SecureLockFile.Opened?
    public private(set) var role: CoreProcessRole?
    public private(set) var lease: CoreOwnerLease?

    public init(lockURL: URL) {
        self.lockURL = lockURL
        metadataURL = Self.ownerMetadataURL(for: lockURL)
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        if let openedLock {
            SecureLockFile.closeTraversal(openedLock.traversal)
        }
    }

    public nonisolated static func ownerMetadataURL(for lockURL: URL) -> URL {
        lockURL.appendingPathExtension("owner.json")
    }

    @discardableResult
    public func acquire(
        as role: CoreProcessRole,
        instanceID: UUID = UUID(),
        acquiredAt: Date = .now
    ) throws -> CoreOwnerLease {
        guard descriptor < 0 else { throw CoreOwnershipError.alreadyOwnedByThisInstance }
        let opened: SecureLockFile.Opened
        do {
            opened = try SecureLockFile.open(at: lockURL)
        } catch let error as SecureLockFile.OpenError {
            throw CoreOwnershipError.cannotOpenLock(error.code)
        } catch {
            throw CoreOwnershipError.cannotOpenLock(EINVAL)
        }
        let fd = opened.descriptor
        var retainedTraversal = false
        defer {
            if !retainedTraversal {
                SecureLockFile.closeTraversal(opened.traversal)
            }
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw CoreOwnershipError.ownedByAnotherProcess }
            throw CoreOwnershipError.cannotLock(code)
        }
        guard SecureLockFile.validate(opened) else {
            flock(fd, LOCK_UN)
            close(fd)
            throw CoreOwnershipError.cannotOpenLock(ESTALE)
        }

        do {
            let next = try FileLock.withExclusiveLock(
                at: CoreOwnerMetadataStore.fencingLockURL(for: metadataURL)
            ) {
                let previous = try CoreOwnerMetadataStore.readIfPresent(at: metadataURL)
                let nextEpoch: UInt64
                if let previous {
                    guard previous.schemaVersion == CoreOwnerLease.schemaVersion else {
                        throw CoreOwnershipError.unsupportedOwnerMetadataSchema(previous.schemaVersion)
                    }
                    guard previous.epoch > 0 else { throw CoreOwnershipError.ownerMetadataCorrupt }
                    guard previous.epoch < UInt64.max else { throw CoreOwnershipError.ownerEpochOverflow }
                    nextEpoch = previous.epoch + 1
                } else {
                    nextEpoch = 1
                }
                let next = CoreOwnerLease(
                    epoch: nextEpoch,
                    instanceID: instanceID,
                    role: role,
                    acquiredAt: acquiredAt
                )
                try CoreOwnerMetadataStore.write(next, to: metadataURL)
                try CoreOwnerMetadataStore.validateWithoutFencingLock(next, at: metadataURL)
                return next
            }
            guard SecureLockFile.validate(opened) else {
                throw CoreOwnershipError.cannotOpenLock(ESTALE)
            }
            descriptor = fd
            openedLock = opened
            retainedTraversal = true
            self.role = role
            lease = next
            return next
        } catch {
            flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
    }

    public func validate(_ proposedLease: CoreOwnerLease) throws {
        guard descriptor >= 0, let openedLock, let lease else {
            throw CoreOwnershipError.notOwner
        }
        guard SecureLockFile.validate(openedLock) else {
            throw CoreOwnershipError.staleLease
        }
        guard lease == proposedLease else { throw CoreOwnershipError.staleLease }
        try CoreOwnerMetadataStore.validate(proposedLease, at: metadataURL)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        if let openedLock {
            SecureLockFile.closeTraversal(openedLock.traversal)
        }
        descriptor = -1
        openedLock = nil
        role = nil
        lease = nil
    }

    public var isOwner: Bool { descriptor >= 0 }
}

enum CoreOwnerMetadataStore {
    static func fencingLockURL(for metadataURL: URL) -> URL {
        metadataURL.appendingPathExtension("fence.lock")
    }

    static func readIfPresent(at url: URL) throws -> CoreOwnerLease? {
        let data: Data
        do {
            guard
                let persisted = try SecureLockFile.readRegularFileIfPresent(
                    at: url,
                    maximumSize: 64 * 1_024
                )
            else {
                return nil
            }
            data = persisted
        } catch {
            throw CoreOwnershipError.ownerMetadataUnreadable
        }
        do {
            return try decoder.decode(CoreOwnerLease.self, from: data)
        } catch {
            throw CoreOwnershipError.ownerMetadataCorrupt
        }
    }

    static func validate(_ lease: CoreOwnerLease, at url: URL) throws {
        try FileLock.withExclusiveLock(at: fencingLockURL(for: url)) {
            try validateWithoutFencingLock(lease, at: url)
        }
    }

    static func withValidatedLease<T>(
        _ lease: CoreOwnerLease,
        at url: URL,
        _ body: () throws -> T
    ) throws -> T {
        try FileLock.withExclusiveLock(at: fencingLockURL(for: url)) {
            try validateWithoutFencingLock(lease, at: url)
            return try body()
        }
    }

    static func validateWithoutFencingLock(_ lease: CoreOwnerLease, at url: URL) throws {
        guard let persisted = try readIfPresent(at: url) else {
            throw CoreOwnershipError.ownerMetadataMissing
        }
        guard persisted.schemaVersion == CoreOwnerLease.schemaVersion else {
            throw CoreOwnershipError.unsupportedOwnerMetadataSchema(persisted.schemaVersion)
        }
        guard persisted.epoch > 0 else { throw CoreOwnershipError.ownerMetadataCorrupt }
        guard persisted.epoch == lease.epoch,
            persisted.instanceID == lease.instanceID,
            persisted.role == lease.role
        else {
            throw CoreOwnershipError.staleLease
        }
    }

    static func write(_ lease: CoreOwnerLease, to url: URL) throws {
        do {
            try SecureLockFile.writeAtomically(encoder.encode(lease), to: url)
        } catch let error as CoreOwnershipError {
            throw error
        } catch {
            throw CoreOwnershipError.ownerMetadataWriteFailed
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

enum SecureLockFile {
    struct Traversal {
        var directoryDescriptors: [Int32]
        var directoryComponents: [String]
        var anchorPath: String
        var leafName: String

        var parentDescriptor: Int32 {
            directoryDescriptors[directoryDescriptors.count - 1]
        }
    }

    struct Opened {
        var descriptor: Int32
        var traversal: Traversal
    }

    struct OpenError: Error {
        var code: Int32
    }

    static func open(at url: URL) throws -> Opened {
        let traversal = try openTraversal(to: url, createMissingDirectories: true)
        let descriptor = openLockDescriptor(traversal)
        guard descriptor >= 0 else {
            let code = errno
            closeTraversal(traversal)
            throw OpenError(code: code)
        }
        let opened = Opened(descriptor: descriptor, traversal: traversal)
        guard validate(opened) else {
            close(descriptor)
            closeTraversal(traversal)
            throw OpenError(code: ESTALE)
        }
        return opened
    }

    static func openTraversal(
        to url: URL,
        createMissingDirectories: Bool
    ) throws -> Traversal {
        try openTraversal(
            to: url,
            createMissingDirectories: createMissingDirectories,
            trustedAnchorURL: trustedContainerAnchor(for: url)
        )
    }

    static func openTraversal(
        to url: URL,
        createMissingDirectories: Bool,
        trustedAnchorURL: URL?
    ) throws -> Traversal {
        let normalizedPath = normalizedAbsolutePath(url)
        let components = URL(fileURLWithPath: normalizedPath).pathComponents
        guard components.first == "/", components.count >= 2,
            let leafName = components.last,
            isSafeComponent(leafName)
        else {
            throw OpenError(code: EINVAL)
        }

        let anchorPath: String
        let directoryComponentsToOpen: ArraySlice<String>
        if let trustedAnchorURL {
            anchorPath = normalizedAbsolutePath(trustedAnchorURL)
            let anchorComponents = URL(fileURLWithPath: anchorPath).pathComponents
            guard
                anchorComponents.first == "/",
                components.count > anchorComponents.count,
                Array(components.prefix(anchorComponents.count)) == anchorComponents
            else {
                throw OpenError(code: EINVAL)
            }
            directoryComponentsToOpen = components.dropFirst(anchorComponents.count).dropLast()
        } else {
            anchorPath = "/"
            directoryComponentsToOpen = components.dropFirst().dropLast()
        }

        let rootDescriptor = Darwin.open(
            anchorPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else { throw OpenError(code: errno) }
        var directoryDescriptors = [rootDescriptor]
        var directoryComponents: [String] = []
        var succeeded = false
        defer {
            if !succeeded {
                for descriptor in directoryDescriptors.reversed() {
                    close(descriptor)
                }
            }
        }

        for component in directoryComponentsToOpen {
            guard isSafeComponent(component) else { throw OpenError(code: EINVAL) }
            let current = directoryDescriptors[directoryDescriptors.count - 1]
            var next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if next < 0, errno == ENOENT, createMissingDirectories {
                let createResult = component.withCString { mkdirat(current, $0, mode_t(0o700)) }
                if createResult != 0, errno != EEXIST {
                    throw OpenError(code: errno)
                }
                next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
            }
            guard next >= 0 else {
                throw OpenError(code: errno)
            }
            var openedStatus = stat()
            var pathStatus = stat()
            let statResult = component.withCString {
                fstatat(current, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(next, &openedStatus) == 0,
                statResult == 0,
                openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                openedStatus.st_dev == pathStatus.st_dev,
                openedStatus.st_ino == pathStatus.st_ino
            else {
                let code = errno == 0 ? ESTALE : errno
                close(next)
                throw OpenError(code: code)
            }
            directoryDescriptors.append(next)
            directoryComponents.append(component)
        }

        let traversal = Traversal(
            directoryDescriptors: directoryDescriptors,
            directoryComponents: directoryComponents,
            anchorPath: anchorPath,
            leafName: leafName
        )
        guard validate(traversal) else {
            throw OpenError(code: ESTALE)
        }
        succeeded = true
        return traversal
    }

    static func validate(_ opened: Opened) -> Bool {
        guard validate(opened.traversal) else { return false }
        var descriptorStatus = stat()
        var pathStatus = stat()
        let statResult = opened.traversal.leafName.withCString {
            fstatat(
                opened.traversal.parentDescriptor,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        return fstat(opened.descriptor, &descriptorStatus) == 0
            && statResult == 0
            && descriptorStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && descriptorStatus.st_nlink > 0
            && descriptorStatus.st_dev == pathStatus.st_dev
            && descriptorStatus.st_ino == pathStatus.st_ino
    }

    static func validate(_ traversal: Traversal) -> Bool {
        guard traversal.directoryDescriptors.count == traversal.directoryComponents.count + 1,
            let rootDescriptor = traversal.directoryDescriptors.first
        else {
            return false
        }
        var rootStatus = stat()
        var anchorStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
            lstat(traversal.anchorPath, &anchorStatus) == 0,
            rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            anchorStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            rootStatus.st_nlink > 0,
            rootStatus.st_dev == anchorStatus.st_dev,
            rootStatus.st_ino == anchorStatus.st_ino
        else {
            return false
        }
        for index in traversal.directoryComponents.indices {
            let parentDescriptor = traversal.directoryDescriptors[index]
            let childDescriptor = traversal.directoryDescriptors[index + 1]
            let component = traversal.directoryComponents[index]
            var openedStatus = stat()
            var pathStatus = stat()
            let statResult = component.withCString {
                fstatat(parentDescriptor, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard fstat(childDescriptor, &openedStatus) == 0,
                statResult == 0,
                openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                openedStatus.st_nlink > 0,
                openedStatus.st_dev == pathStatus.st_dev,
                openedStatus.st_ino == pathStatus.st_ino
            else {
                return false
            }
        }
        return true
    }

    static func closeTraversal(_ traversal: Traversal) {
        for descriptor in traversal.directoryDescriptors.reversed() {
            close(descriptor)
        }
    }

    /// Darwin may transiently return ENOENT when several processes race an
    /// O_CREAT openat against the same previously absent leaf. Retry only that
    /// creation race; every attempt retains O_NOFOLLOW and the verified parent
    /// descriptor.
    private static func openLockDescriptor(_ traversal: Traversal) -> Int32 {
        for attempt in 0..<16 {
            let descriptor = traversal.leafName.withCString {
                openat(
                    traversal.parentDescriptor,
                    $0,
                    O_CREAT | O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            guard errno == ENOENT, attempt < 15, validate(traversal) else {
                return -1
            }
            sched_yield()
        }
        return -1
    }

    static func readRegularFileIfPresent(
        at url: URL,
        maximumSize: Int64
    ) throws -> Data? {
        let traversal: Traversal
        do {
            traversal = try openTraversal(to: url, createMissingDirectories: false)
        } catch let error as OpenError where error.code == ENOENT {
            return nil
        }
        defer { closeTraversal(traversal) }

        let descriptor = traversal.leafName.withCString {
            openat(
                traversal.parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw OpenError(code: errno) }
        defer { close(descriptor) }
        guard
            validateRegularFile(
                descriptor: descriptor,
                traversal: traversal,
                leafName: traversal.leafName,
                maximumSize: maximumSize
            )
        else {
            throw OpenError(code: ESTALE)
        }
        let data =
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            .readToEnd() ?? Data()
        guard
            validateRegularFile(
                descriptor: descriptor,
                traversal: traversal,
                leafName: traversal.leafName,
                maximumSize: maximumSize
            )
        else {
            throw OpenError(code: ESTALE)
        }
        return data
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let traversal = try openTraversal(to: url, createMissingDirectories: true)
        defer { closeTraversal(traversal) }
        guard validate(traversal) else { throw OpenError(code: ESTALE) }

        var existingStatus = stat()
        let existingResult = traversal.leafName.withCString {
            fstatat(
                traversal.parentDescriptor,
                $0,
                &existingStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if existingResult == 0 {
            guard existingStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw OpenError(code: EINVAL)
            }
        } else if errno != ENOENT {
            throw OpenError(code: errno)
        }

        let temporaryName = "." + traversal.leafName + "." + UUID().uuidString + ".tmp"
        guard isSafeComponent(temporaryName) else { throw OpenError(code: EINVAL) }
        let descriptor = temporaryName.withCString {
            openat(
                traversal.parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw OpenError(code: errno) }
        var installed = false
        defer {
            close(descriptor)
            if !installed {
                _ = temporaryName.withCString {
                    unlinkat(traversal.parentDescriptor, $0, 0)
                }
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw OpenError(code: errno)
        }
        #if os(iOS)
            // Apply class B to the exact descriptor already opened and
            // validated above. The path-based Foundation API can fail with
            // NSFileWriteUnknownError on a physical-device test container and
            // would also reopen the temporary path after our no-follow check.
            guard fcntl(descriptor, F_SETPROTECTIONCLASS, 2) == 0 else {
                throw OpenError(code: errno)
            }
        #endif
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0,
            validateRegularFile(
                descriptor: descriptor,
                traversal: traversal,
                leafName: temporaryName,
                maximumSize: Int64.max
            )
        else {
            throw OpenError(code: errno == 0 ? ESTALE : errno)
        }
        let renameResult = temporaryName.withCString { temporaryPointer in
            traversal.leafName.withCString { leafPointer in
                renameat(
                    traversal.parentDescriptor,
                    temporaryPointer,
                    traversal.parentDescriptor,
                    leafPointer
                )
            }
        }
        guard renameResult == 0 else { throw OpenError(code: errno) }
        installed = true
        guard fsync(traversal.parentDescriptor) == 0,
            validateRegularFile(
                descriptor: descriptor,
                traversal: traversal,
                leafName: traversal.leafName,
                maximumSize: Int64.max
            )
        else {
            throw OpenError(code: errno == 0 ? ESTALE : errno)
        }
    }

    private static func validateRegularFile(
        descriptor: Int32,
        traversal: Traversal,
        leafName: String,
        maximumSize: Int64
    ) -> Bool {
        guard validate(traversal), maximumSize >= 0 else { return false }
        var descriptorStatus = stat()
        var pathStatus = stat()
        let statResult = leafName.withCString {
            fstatat(
                traversal.parentDescriptor,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        return fstat(descriptor, &descriptorStatus) == 0
            && statResult == 0
            && descriptorStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && descriptorStatus.st_nlink > 0
            && descriptorStatus.st_size >= 0
            && descriptorStatus.st_size <= maximumSize
            && descriptorStatus.st_dev == pathStatus.st_dev
            && descriptorStatus.st_ino == pathStatus.st_ino
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw OpenError(code: errno) }
                offset += written
            }
        }
    }

    private static func normalizedAbsolutePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == "/var" || path.hasPrefix("/var/") { return "/private" + path }
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            return "/private" + path
        }
        return path
    }

    private static func trustedContainerAnchor(for url: URL) -> URL? {
        #if os(iOS)
            let targetComponents = URL(
                fileURLWithPath: normalizedAbsolutePath(url)
            ).pathComponents
            var candidates: [URL] = []
            if let identifier = Bundle.main.object(
                forInfoDictionaryKey: "PsyAppGroupIdentifier"
            ) as? String,
                !identifier.isEmpty,
                let anchor = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: identifier
                )
            {
                candidates.append(anchor)
            }

            // A physical iOS sandbox cannot open "/" for descriptor-based
            // traversal. App-owned Documents/Library/tmp paths are instead
            // anchored at the process container home; App Group paths retain
            // their separate system-provided anchor above.
            candidates.append(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            for anchor in candidates {
                let anchorComponents = URL(
                    fileURLWithPath: normalizedAbsolutePath(anchor)
                ).pathComponents
                if targetComponents.count > anchorComponents.count,
                    Array(targetComponents.prefix(anchorComponents.count)) == anchorComponents
                {
                    return anchor
                }
            }
            return nil
        #else
            return nil
        #endif
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\0")
    }
}

enum SecureFileLeaseMode: Sendable {
    case shared
    case exclusive

    fileprivate var flockOperation: Int32 {
        switch self {
        case .shared: LOCK_SH
        case .exclusive: LOCK_EX
        }
    }
}

/// A long-lived, inode-validated advisory lease backed by the same secure
/// openat/O_NOFOLLOW traversal as the short FileLock critical sections.
/// Keeping the descriptor and every traversed directory open prevents a
/// symlink substitution from being accepted as the lifecycle lock.
final class SecureFileLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var opened: SecureLockFile.Opened?

    private init(opened: SecureLockFile.Opened) {
        self.opened = opened
    }

    static func acquire(at url: URL, mode: SecureFileLeaseMode) throws -> SecureFileLease {
        guard let lease = try acquire(at: url, mode: mode, nonBlocking: false) else {
            throw CocoaError(.fileLocking)
        }
        return lease
    }

    static func tryAcquire(at url: URL, mode: SecureFileLeaseMode) throws -> SecureFileLease? {
        try acquire(at: url, mode: mode, nonBlocking: true)
    }

    private static func acquire(
        at url: URL,
        mode: SecureFileLeaseMode,
        nonBlocking: Bool
    ) throws -> SecureFileLease? {
        let opened: SecureLockFile.Opened
        do {
            opened = try SecureLockFile.open(at: url)
        } catch {
            throw CocoaError(.fileWriteUnknown)
        }
        let operation = mode.flockOperation | (nonBlocking ? LOCK_NB : 0)
        guard flock(opened.descriptor, operation) == 0 else {
            let lockError = errno
            SecureLockFile.closeTraversal(opened.traversal)
            close(opened.descriptor)
            if nonBlocking, lockError == EWOULDBLOCK || lockError == EAGAIN { return nil }
            throw CocoaError(.fileLocking)
        }
        guard SecureLockFile.validate(opened) else {
            flock(opened.descriptor, LOCK_UN)
            SecureLockFile.closeTraversal(opened.traversal)
            close(opened.descriptor)
            throw CocoaError(.fileLocking)
        }
        return SecureFileLease(opened: opened)
    }

    func validate() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let opened, SecureLockFile.validate(opened) else {
            throw CocoaError(.fileLocking)
        }
    }

    func release() {
        stateLock.lock()
        let current = opened
        opened = nil
        stateLock.unlock()
        guard let current else { return }
        flock(current.descriptor, LOCK_UN)
        SecureLockFile.closeTraversal(current.traversal)
        close(current.descriptor)
    }

    deinit {
        release()
    }
}

enum FileLock {
    static func withExclusiveLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let opened: SecureLockFile.Opened
        do {
            opened = try SecureLockFile.open(at: url)
        } catch {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            SecureLockFile.closeTraversal(opened.traversal)
            close(opened.descriptor)
        }
        guard flock(opened.descriptor, LOCK_EX) == 0 else {
            throw CocoaError(.fileLocking)
        }
        defer { flock(opened.descriptor, LOCK_UN) }
        guard SecureLockFile.validate(opened) else {
            throw CocoaError(.fileLocking)
        }
        do {
            let value = try body()
            guard SecureLockFile.validate(opened) else {
                throw CocoaError(.fileLocking)
            }
            return value
        } catch {
            guard SecureLockFile.validate(opened) else {
                throw CocoaError(.fileLocking)
            }
            throw error
        }
    }
}
