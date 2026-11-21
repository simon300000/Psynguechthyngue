import Darwin
import Foundation

/// `EngineLock` over flock(2) on `AppGroupLayout.engineLock` (DESIGN.md §1.1 I1, §6.6).
///
/// After acquiring, the holder writes "<owner> <pid>\n" into the lock file so
/// other processes can tell *who* holds it (`currentHolder`). The file itself
/// is never deleted; only the advisory lock matters. flock locks belong to the
/// open file description, so two opens in one process also exclude each other.
public final class FlockEngineLock: EngineLock, @unchecked Sendable {
    public let url: URL
    private let pollInterval: Duration

    public init(url: URL, pollInterval: Duration = .milliseconds(50)) {
        self.url = url
        self.pollInterval = pollInterval
    }

    public convenience init(layout: AppGroupLayout) {
        self.init(url: layout.engineLock)
    }

    public func acquire(owner: EngineLockOwner, timeout: Duration) async -> (any EngineLockLease)? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var delay = pollInterval
        while true {
            if let lease = tryAcquire(owner: owner) { return lease }
            if clock.now >= deadline || Task.isCancelled { return nil }
            let remaining = clock.now.duration(to: deadline)
            try? await Task.sleep(for: min(delay, remaining))
            delay = min(delay * 2, .milliseconds(500))
        }
    }

    /// Non-blocking single attempt.
    public func tryAcquire(owner: EngineLockOwner) -> FlockLease? {
        guard let fd = openLockFile() else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }
        let line = "\(owner.rawValue) \(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = line.withCString { pwrite(fd, $0, strlen($0), 0) }
        _ = fsync(fd)
        return FlockLease(fd: fd, owner: owner)
    }

    public func currentHolder() -> EngineLockOwner? {
        guard let fd = openLockFile() else { return nil }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            // Free: we just took it; release immediately.
            flock(fd, LOCK_UN)
            return nil
        }
        return Self.parseOwner(fd: fd)?.owner
    }

    /// Owner and pid recorded by the current holder (diagnostics).
    public func holderInfo() -> (owner: EngineLockOwner, pid: Int32)? {
        guard let fd = openLockFile() else { return nil }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        return Self.parseOwner(fd: fd)
    }

    private static func parseOwner(fd: Int32) -> (owner: EngineLockOwner, pid: Int32)? {
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let first = parts.first, let owner = EngineLockOwner(rawValue: String(first)) else { return nil }
        let pid = parts.count > 1 ? Int32(parts[1]) ?? 0 : 0
        return (owner, pid)
    }

    private func openLockFile() -> Int32? {
        let path = url.path(percentEncoded: false)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        return fd >= 0 ? fd : nil
    }
}

public final class FlockLease: EngineLockLease, @unchecked Sendable {
    public let owner: EngineLockOwner
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32, owner: EngineLockOwner) {
        self.fd = fd
        self.owner = owner
    }

    deinit { release() }

    public var isHeld: Bool { lock.withLock { fd >= 0 } }

    public func release() {
        let closing: Int32 = lock.withLock {
            let value = fd
            fd = -1
            return value
        }
        guard closing >= 0 else { return }
        _ = ftruncate(closing, 0)
        flock(closing, LOCK_UN)
        Darwin.close(closing)
        DarwinNotifier.post(DarwinNotification.engineLockReleased)
    }
}
