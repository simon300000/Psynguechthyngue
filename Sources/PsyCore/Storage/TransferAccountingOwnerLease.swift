import Darwin
import Foundation

public enum TransferAccountingOwnerLeaseError: Error, Hashable, Sendable {
    case invalidOwnerIdentifier
    case unsafeLeaseDirectory
    case leaseAlreadyHeld
    case leaseUnavailable
}

/// A process-liveness fence for transfer reservations. The lock file is never
/// removed: unlinking advisory-lock files permits two processes to lock two
/// different inodes under the same path.
public final class TransferAccountingOwnerLease: @unchecked Sendable {
    public let ownerID: UUID
    public let url: URL

    private let stateLock = NSLock()
    private var opened: SecureLockFile.Opened?

    private init(ownerID: UUID, url: URL, opened: SecureLockFile.Opened) {
        self.ownerID = ownerID
        self.url = url
        self.opened = opened
    }

    public static func acquire(
        directoryURL: URL,
        ownerID: UUID = UUID()
    ) throws -> TransferAccountingOwnerLease {
        let url = try leaseURL(directoryURL: directoryURL, ownerID: ownerID)
        let opened = try openLease(at: url)
        guard flock(opened.descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(opened)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw TransferAccountingOwnerLeaseError.leaseAlreadyHeld
            }
            throw TransferAccountingOwnerLeaseError.leaseUnavailable
        }
        guard SecureLockFile.validate(opened) else {
            flock(opened.descriptor, LOCK_UN)
            close(opened)
            throw TransferAccountingOwnerLeaseError.leaseUnavailable
        }
        return TransferAccountingOwnerLease(
            ownerID: ownerID,
            url: url,
            opened: opened
        )
    }

    public static func isLive(ownerID: UUID, directoryURL: URL) throws -> Bool {
        let url = try leaseURL(directoryURL: directoryURL, ownerID: ownerID)
        let opened = try openLease(at: url)
        defer { close(opened) }
        if flock(opened.descriptor, LOCK_EX | LOCK_NB) == 0 {
            let valid = SecureLockFile.validate(opened)
            flock(opened.descriptor, LOCK_UN)
            guard valid else {
                throw TransferAccountingOwnerLeaseError.leaseUnavailable
            }
            return false
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            return true
        }
        throw TransferAccountingOwnerLeaseError.leaseUnavailable
    }

    public func release() {
        stateLock.lock()
        let current = opened
        opened = nil
        stateLock.unlock()
        guard let current else { return }
        flock(current.descriptor, LOCK_UN)
        Self.close(current)
    }

    deinit {
        release()
    }

    private static func leaseURL(directoryURL: URL, ownerID: UUID) throws -> URL {
        let canonical = ownerID.uuidString.lowercased()
        guard UUID(uuidString: canonical)?.uuidString.lowercased() == canonical else {
            throw TransferAccountingOwnerLeaseError.invalidOwnerIdentifier
        }
        return directoryURL.appendingPathComponent(canonical + ".lock")
    }

    private static func openLease(at url: URL) throws -> SecureLockFile.Opened {
        let opened: SecureLockFile.Opened
        do {
            opened = try SecureLockFile.open(at: url)
        } catch let error as SecureLockFile.OpenError {
            if error.code == ELOOP || error.code == ENOTDIR {
                throw TransferAccountingOwnerLeaseError.unsafeLeaseDirectory
            }
            throw TransferAccountingOwnerLeaseError.leaseUnavailable
        } catch {
            throw TransferAccountingOwnerLeaseError.leaseUnavailable
        }
        guard fchmod(opened.traversal.parentDescriptor, mode_t(0o700)) == 0,
            fchmod(opened.descriptor, mode_t(0o600)) == 0,
            SecureLockFile.validate(opened)
        else {
            close(opened)
            throw TransferAccountingOwnerLeaseError.leaseUnavailable
        }
        return opened
    }

    private static func close(_ opened: SecureLockFile.Opened) {
        Darwin.close(opened.descriptor)
        SecureLockFile.closeTraversal(opened.traversal)
    }
}
