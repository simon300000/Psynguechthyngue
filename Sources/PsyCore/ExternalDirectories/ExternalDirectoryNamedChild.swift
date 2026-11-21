import Darwin
import Foundation

/// Opaque device/inode identity used only for equality fences. Its fields are
/// intentionally not public so diagnostics and UI cannot stringify a path or
/// filesystem identifier by accident.
public struct ExternalDirectoryRootIdentity: Hashable, Sendable {
    fileprivate let device: dev_t
    fileprivate let inode: ino_t

    fileprivate init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
    }
}

public enum ExternalDirectoryRootIdentityError: Error, Hashable, Sendable {
    case unsafePath
}

public enum ExternalDirectoryRootIdentityFence {
    public static func capture(at url: URL) throws -> ExternalDirectoryRootIdentity {
        let traversal = try directoryTraversal(at: url)
        defer { SecureLockFile.closeTraversal(traversal) }
        var finalStatus = stat()
        guard SecureLockFile.validate(traversal),
            fstat(traversal.parentDescriptor, &finalStatus) == 0,
            finalStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw ExternalDirectoryRootIdentityError.unsafePath
        }
        return ExternalDirectoryRootIdentity(finalStatus)
    }

    static func validatedPathComponents(at url: URL) throws -> [String] {
        let traversal = try directoryTraversal(at: url)
        defer { SecureLockFile.closeTraversal(traversal) }
        guard SecureLockFile.validate(traversal) else {
            throw ExternalDirectoryRootIdentityError.unsafePath
        }
        return URL(fileURLWithPath: traversal.anchorPath, isDirectory: true).pathComponents
            + traversal.directoryComponents
    }

    private static func directoryTraversal(
        at url: URL
    ) throws -> SecureLockFile.Traversal {
        guard url.isFileURL else {
            throw ExternalDirectoryRootIdentityError.unsafePath
        }
        do {
            // `openTraversal` anchors app-container and App Group paths at the
            // system-provided container URL on physical iOS, where opening
            // `/` is forbidden. The synthetic leaf keeps the selected URL as
            // the final validated directory descriptor and is never created.
            return try SecureLockFile.openTraversal(
                to: url.appendingPathComponent(".psy-identity-fence", isDirectory: false),
                createMissingDirectories: false
            )
        } catch {
            throw ExternalDirectoryRootIdentityError.unsafePath
        }
    }
}

/// Runtime gate for the iOS binary running through Apple's Designed-for-iPad
/// compatibility environment. A native macOS SwiftPM process and Mac Catalyst
/// are deliberately not treated as this environment.
public struct IOSAppOnMacEnvironment: Hashable, Sendable {
    public let isIOSAppOnMac: Bool

    public init(isIOSAppOnMac: Bool) {
        self.isIOSAppOnMac = isIOSAppOnMac
    }

    public var allowsNamedChildCreation: Bool { isIOSAppOnMac }

    public static var current: Self {
        #if os(iOS) && !targetEnvironment(macCatalyst)
            Self(isIOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
        #else
            Self(isIOSAppOnMac: false)
        #endif
    }
}

public enum ExternalDirectoryChildNameValidationError: Error, Hashable, Sendable, LocalizedError {
    case empty
    case dotComponent
    case pathSeparator
    case controlCharacter
    case tooLong

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a folder name."
        case .dotComponent:
            "The folder name cannot be . or ..."
        case .pathSeparator:
            "Enter one folder name without a path separator."
        case .controlCharacter:
            "The folder name contains an unsupported control character."
        case .tooLong:
            "The folder name is too long."
        }
    }
}

/// A single portable file-system component. The byte limit matches NAME_MAX on
/// the Apple platforms while still leaving provider-specific limits to the
/// coordinated creation attempt.
public struct ExternalDirectoryChildName: Hashable, Sendable {
    public static let maximumUTF8ByteCount = 255

    public let rawValue: String

    public init(validating rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw ExternalDirectoryChildNameValidationError.empty
        }
        guard rawValue != ".", rawValue != ".." else {
            throw ExternalDirectoryChildNameValidationError.dotComponent
        }
        guard !rawValue.contains("/"), !rawValue.contains("\\") else {
            throw ExternalDirectoryChildNameValidationError.pathSeparator
        }
        guard !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ExternalDirectoryChildNameValidationError.controlCharacter
        }
        guard rawValue.utf8.count <= Self.maximumUTF8ByteCount else {
            throw ExternalDirectoryChildNameValidationError.tooLong
        }
        self.rawValue = rawValue
    }
}

public enum ExternalDirectoryNamedChildError: Error, Hashable, Sendable, LocalizedError {
    case parentAuthorizationDenied
    case unsafeParent
    case unsafeExistingItem
    case creationFailed
    case authorizationFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .parentAuthorizationDenied:
            "Access to the selected parent directory was denied or revoked."
        case .unsafeParent:
            "The selected parent directory is unsafe or unavailable."
        case .unsafeExistingItem:
            "An item with that name already exists and is not a safe directory."
        case .creationFailed:
            "The folder could not be created safely in the selected parent directory."
        case .authorizationFailed:
            "The new folder could not be authorized. No external path details were retained."
        case .rollbackFailed:
            "Authorization failed, and the new folder could not be removed because it changed or is no longer empty."
        }
    }
}

/// Creates or reuses one named child while the picker-authorized parent scope is
/// active, then hands that URL to the existing external-directory broker. The
/// broker remains responsible for capability probing, bookmark creation,
/// managed-root binding, and persistence.
public struct ExternalDirectoryNamedChildAuthorizer: Sendable {
    private let scopeAccess: ExternalDirectoryBookmarkAccess
    private let beforeAuthorize: @Sendable (URL) throws -> Void

    public init(
        scopeAccess: ExternalDirectoryBookmarkAccess = .system,
        beforeAuthorize: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.scopeAccess = scopeAccess
        self.beforeAuthorize = beforeAuthorize
    }

    public func createAndAuthorize<Authorized: Sendable>(
        parentURL: URL,
        name rawName: String,
        authorize: @escaping @Sendable (URL) async throws -> Authorized
    ) async throws -> Authorized {
        try await createAndAuthorizeBound(
            parentURL: parentURL,
            name: rawName
        ) { childURL, _ in
            try await authorize(childURL)
        }
    }

    public func createAndAuthorizeBound<Authorized: Sendable>(
        parentURL: URL,
        name rawName: String,
        authorize: @escaping @Sendable (URL, ExternalDirectoryRootIdentity) async throws -> Authorized
    ) async throws -> Authorized {
        let name = try ExternalDirectoryChildName(validating: rawName)
        let leaseKey = ExternalDirectoryNamedChildGate.Key(
            parentPath: parentURL.path,
            childName: name.rawValue
        )
        await ExternalDirectoryNamedChildGate.shared.acquire(leaseKey)
        do {
            let result = try await createAndAuthorizeWithLease(
                parentURL: parentURL,
                name: name,
                authorize: authorize
            )
            await ExternalDirectoryNamedChildGate.shared.release(leaseKey)
            return result
        } catch {
            await ExternalDirectoryNamedChildGate.shared.release(leaseKey)
            throw error
        }
    }

    private func createAndAuthorizeWithLease<Authorized: Sendable>(
        parentURL: URL,
        name: ExternalDirectoryChildName,
        authorize: @escaping @Sendable (URL, ExternalDirectoryRootIdentity) async throws -> Authorized
    ) async throws -> Authorized {
        guard scopeAccess.beginAccess(to: parentURL) else {
            throw ExternalDirectoryNamedChildError.parentAuthorizationDenied
        }
        defer { scopeAccess.endAccess(to: parentURL) }

        let createdChild = try Self.createOrOpenChild(in: parentURL, name: name)
        do {
            try beforeAuthorize(createdChild.url)
            try Self.revalidate(createdChild)
        } catch {
            // Rebinding is a security failure, not an authorization failure.
            // Attempt a conservative cleanup of our new empty directory, but
            // never chase a path that no longer has the captured identity.
            if createdChild.wasCreated { _ = Self.rollback(createdChild) }
            if let error = error as? ExternalDirectoryNamedChildError {
                throw error
            }
            throw ExternalDirectoryNamedChildError.unsafeParent
        }
        do {
            return try await authorize(createdChild.url, createdChild.identity)
        } catch {
            if createdChild.wasCreated, !Self.rollback(createdChild) {
                throw ExternalDirectoryNamedChildError.rollbackFailed
            }
            if let error = error as? ExternalDirectoryError { throw error }
            if let error = error as? ExternalDirectoryNamedChildError { throw error }
            if let error = error as? ExternalDirectoryChildNameValidationError { throw error }
            throw ExternalDirectoryNamedChildError.authorizationFailed
        }
    }

    private struct CreatedChild: Sendable {
        let parentURL: URL
        let parentIdentity: ExternalDirectoryRootIdentity
        let name: ExternalDirectoryChildName
        let url: URL
        let identity: ExternalDirectoryRootIdentity
        let wasCreated: Bool
    }

    private static func createOrOpenChild(
        in parentURL: URL,
        name: ExternalDirectoryChildName
    ) throws -> CreatedChild {
        do {
            return try coordinatedWrite(at: parentURL) { coordinatedParent in
                try withOpenDirectoryNoFollow(at: coordinatedParent) { parentDescriptor, parentIdentity in
                    var wasCreated = false
                    let mkdirResult = name.rawValue.withCString {
                        mkdirat(parentDescriptor, $0, mode_t(0o700))
                    }
                    if mkdirResult == 0 {
                        wasCreated = true
                    } else if errno != EEXIST {
                        throw ExternalDirectoryNamedChildError.creationFailed
                    }

                    var entryStatus = stat()
                    let statusResult = name.rawValue.withCString {
                        fstatat(parentDescriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
                    }
                    guard statusResult == 0 else {
                        throw ExternalDirectoryNamedChildError.creationFailed
                    }
                    guard entryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                        throw ExternalDirectoryNamedChildError.unsafeExistingItem
                    }
                    let expectedIdentity = ExternalDirectoryRootIdentity(entryStatus)

                    let childDescriptor = name.rawValue.withCString {
                        openat(
                            parentDescriptor,
                            $0,
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                        )
                    }
                    guard childDescriptor >= 0 else {
                        throw ExternalDirectoryNamedChildError.unsafeExistingItem
                    }
                    defer { close(childDescriptor) }

                    var openedStatus = stat()
                    guard fstat(childDescriptor, &openedStatus) == 0,
                        openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                        ExternalDirectoryRootIdentity(openedStatus) == expectedIdentity
                    else {
                        throw ExternalDirectoryNamedChildError.unsafeExistingItem
                    }

                    let childURL = coordinatedParent.appendingPathComponent(
                        name.rawValue,
                        isDirectory: true
                    )
                    guard isDirectChild(childURL, of: coordinatedParent, named: name.rawValue) else {
                        throw ExternalDirectoryNamedChildError.unsafeExistingItem
                    }
                    return CreatedChild(
                        parentURL: coordinatedParent,
                        parentIdentity: parentIdentity,
                        name: name,
                        url: childURL,
                        identity: expectedIdentity,
                        wasCreated: wasCreated
                    )
                }
            }
        } catch let error as ExternalDirectoryNamedChildError {
            throw error
        } catch {
            throw ExternalDirectoryNamedChildError.creationFailed
        }
    }

    private static func rollback(_ child: CreatedChild) -> Bool {
        do {
            return try coordinatedWrite(at: child.parentURL) { coordinatedParent in
                try withOpenDirectoryNoFollow(at: coordinatedParent) { parentDescriptor, parentIdentity in
                    guard parentIdentity == child.parentIdentity else { return false }
                    var entryStatus = stat()
                    let statusResult = child.name.rawValue.withCString {
                        fstatat(parentDescriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
                    }
                    guard statusResult == 0,
                        entryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                        ExternalDirectoryRootIdentity(entryStatus) == child.identity
                    else {
                        return false
                    }
                    let removeResult = child.name.rawValue.withCString {
                        unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
                    }
                    guard removeResult == 0 else { return false }
                    var removedStatus = stat()
                    let recheck = child.name.rawValue.withCString {
                        fstatat(parentDescriptor, $0, &removedStatus, AT_SYMLINK_NOFOLLOW)
                    }
                    return recheck != 0 && errno == ENOENT
                }
            }
        } catch {
            return false
        }
    }

    private static func revalidate(_ child: CreatedChild) throws {
        do {
            let isStillBound = try coordinatedWrite(at: child.parentURL) { coordinatedParent in
                try withOpenDirectoryNoFollow(at: coordinatedParent) { parentDescriptor, parentIdentity in
                    guard parentIdentity == child.parentIdentity,
                        isDirectChild(child.url, of: coordinatedParent, named: child.name.rawValue)
                    else {
                        return false
                    }
                    var entryStatus = stat()
                    let statusResult = child.name.rawValue.withCString {
                        fstatat(parentDescriptor, $0, &entryStatus, AT_SYMLINK_NOFOLLOW)
                    }
                    guard statusResult == 0,
                        entryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                        ExternalDirectoryRootIdentity(entryStatus) == child.identity
                    else {
                        return false
                    }
                    let childDescriptor = child.name.rawValue.withCString {
                        openat(
                            parentDescriptor,
                            $0,
                            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                        )
                    }
                    guard childDescriptor >= 0 else { return false }
                    defer { close(childDescriptor) }
                    var openedStatus = stat()
                    return fstat(childDescriptor, &openedStatus) == 0
                        && openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                        && ExternalDirectoryRootIdentity(openedStatus) == child.identity
                }
            }
            guard isStillBound else { throw ExternalDirectoryNamedChildError.unsafeParent }
        } catch let error as ExternalDirectoryNamedChildError {
            throw error
        } catch {
            throw ExternalDirectoryNamedChildError.unsafeParent
        }
    }

    private static func withOpenDirectoryNoFollow<T>(
        at url: URL,
        operation: (Int32, ExternalDirectoryRootIdentity) throws -> T
    ) throws -> T {
        guard url.isFileURL else { throw ExternalDirectoryNamedChildError.unsafeParent }
        let traversal: SecureLockFile.Traversal
        do {
            // Keep the parent as the final opened directory. This shares the
            // physical-iOS App Group/app-container anchor logic with durable
            // file traversal while preserving descriptor-by-descriptor
            // O_NOFOLLOW and inode validation below the trusted anchor.
            traversal = try SecureLockFile.openTraversal(
                to: url.appendingPathComponent(".psy-named-child-fence", isDirectory: false),
                createMissingDirectories: false
            )
        } catch {
            throw ExternalDirectoryNamedChildError.unsafeParent
        }
        defer { SecureLockFile.closeTraversal(traversal) }
        var finalStatus = stat()
        guard SecureLockFile.validate(traversal),
            fstat(traversal.parentDescriptor, &finalStatus) == 0,
            finalStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw ExternalDirectoryNamedChildError.unsafeParent
        }
        return try operation(
            traversal.parentDescriptor,
            ExternalDirectoryRootIdentity(finalStatus)
        )
    }

    private static func isDirectChild(_ child: URL, of parent: URL, named name: String) -> Bool {
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        guard childComponents.count == parentComponents.count + 1,
            childComponents.last == name
        else {
            return false
        }
        return Array(childComponents.dropLast()) == parentComponents
    }

    private static func coordinatedWrite<T>(
        at url: URL,
        operation: (URL) throws -> T
    ) throws -> T {
        try CoordinatedFileAccess().write(at: url, operation: operation)
    }
}

private actor ExternalDirectoryNamedChildGate {
    struct Key: Hashable, Sendable {
        let parentPath: String
        let childName: String
    }

    static let shared = ExternalDirectoryNamedChildGate()

    private var active: Set<Key> = []
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: Key) async {
        if active.insert(key).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: Key) {
        if var queued = waiters[key], !queued.isEmpty {
            let next = queued.removeFirst()
            if queued.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = queued
            }
            next.resume()
            return
        }
        active.remove(key)
    }
}
