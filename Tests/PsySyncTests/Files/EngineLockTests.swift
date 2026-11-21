import Foundation
import Testing
@testable import PsySync

/// Cross-process EngineLock tests. The "other process" is a perl one-liner
/// speaking the same protocol (flock(LOCK_EX) + "<owner> <pid>" in the file),
/// so these exercise real inter-process flock semantics on the lock file.
@Suite(.serialized) struct EngineLockTests {
    /// Spawns a child that takes the lock (blocking up to `wait` s), writes
    /// `owner`, prints "LOCKED", holds for `hold` seconds, exits 0; exits 3 if
    /// it could not lock within `wait`.
    static func child(_ url: URL, owner: String, hold: Double, wait: Double = 0) throws -> (Process, Pipe) {
        let script = """
            use Fcntl qw(:flock); use Time::HiRes qw(sleep time);
            $| = 1;
            open(my $f, '+>>', $ARGV[0]) or die;
            my $deadline = time + $ARGV[3];
            while (!flock($f, LOCK_EX | LOCK_NB)) { if (time > $deadline) { exit 3 } sleep 0.02 }
            truncate($f, 0); seek($f, 0, 0); print $f "$ARGV[1] $$\\n"; $f->flush();
            print "LOCKED\\n";
            sleep $ARGV[2];
            exit 0;
            """
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = ["-e", script, url.path(percentEncoded: false), owner, String(hold), String(wait)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        return (process, pipe)
    }

    static func waitForLine(_ pipe: Pipe) -> String {
        var data = Data()
        while !data.contains(UInt8(ascii: "\n")) {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data += chunk
        }
        return String(decoding: data, as: UTF8.self)
    }

    @Test func otherProcessHoldingBlocksAcquireAndReportsOwner() async throws {
        let url = Fixtures.tempDir().appending(path: "Engine/engine.lock")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = FlockEngineLock(url: url)
        #expect(lock.currentHolder() == nil)

        let (process, pipe) = try Self.child(url, owner: "fileProviderExtension", hold: 1.5)
        #expect(Self.waitForLine(pipe).contains("LOCKED"))
        #expect(lock.currentHolder() == .fileProviderExtension)
        #expect(lock.holderInfo()?.pid == process.processIdentifier)
        let start = ContinuousClock.now
        #expect(await lock.acquire(owner: .app, timeout: .milliseconds(300)) == nil)
        #expect(ContinuousClock.now - start >= .milliseconds(300))

        // Blocking acquire succeeds once the child exits (lock released by the kernel).
        let lease = try #require(await lock.acquire(owner: .app, timeout: .seconds(5)))
        process.waitUntilExit()
        #expect(lease.owner == .app)
        #expect(lock.currentHolder() == .app)
        lease.release()
        #expect(lock.currentHolder() == nil)
    }

    @Test func ourLeaseExcludesOtherProcessUntilReleased() async throws {
        let url = Fixtures.tempDir().appending(path: "engine.lock")
        let lock = FlockEngineLock(url: url)
        let lease = try #require(await lock.acquire(owner: .app, timeout: .seconds(1)))
        let (blocked, _) = try Self.child(url, owner: "fileProviderExtension", hold: 0, wait: 0.3)
        blocked.waitUntilExit()
        #expect(blocked.terminationStatus == 3)  // could not lock while we hold it

        let (waiter, pipe) = try Self.child(url, owner: "fileProviderExtension", hold: 0.5, wait: 5)
        try await Task.sleep(for: .milliseconds(200))
        lease.release()
        #expect(Self.waitForLine(pipe).contains("LOCKED"))
        #expect(lock.currentHolder() == .fileProviderExtension)
        waiter.waitUntilExit()
        #expect(waiter.terminationStatus == 0)
    }

    @Test func crashedHolderReleasesLock() async throws {
        let url = Fixtures.tempDir().appending(path: "engine.lock")
        let lock = FlockEngineLock(url: url)
        let (process, pipe) = try Self.child(url, owner: "app", hold: 30)
        #expect(Self.waitForLine(pipe).contains("LOCKED"))
        #expect(lock.currentHolder() == .app)
        process.terminate()  // SIGTERM: no cleanup code runs
        process.waitUntilExit()
        #expect(await lock.acquire(owner: .fileProviderExtension, timeout: .seconds(2)) != nil)
    }

    @Test func twoOpensInOneProcessExcludeEachOther() async throws {
        let url = Fixtures.tempDir().appending(path: "engine.lock")
        let a = FlockEngineLock(url: url)
        let b = FlockEngineLock(url: url)
        let lease = try #require(a.tryAcquire(owner: .app))
        #expect(b.tryAcquire(owner: .fileProviderExtension) == nil)
        lease.release()
        #expect(b.tryAcquire(owner: .fileProviderExtension) != nil)
    }
}

@Suite struct PathContainmentTests {
    @Test func rejectsEscapes() throws {
        let root = Fixtures.tempDir()
        let outside = Fixtures.tempDir()
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: outside)
        let c = PathContainment(root: root)
        #expect(throws: PathContainmentError.self) { try c.url(for: RelativePath(rawValue: "../x")) }
        #expect(throws: PathContainmentError.self) { try c.url(for: RelativePath(rawValue: "/etc/passwd")) }
        #expect(throws: PathContainmentError.self) { try c.url(for: RelativePath(rawValue: "a//b")) }
        #expect(throws: PathContainmentError.symlinkEscapesRoot) { try c.url(for: RelativePath(rawValue: "link/file")) }
        #expect(try c.url(for: RelativePath(rawValue: "a/b.txt")).lastPathComponent == "b.txt")
        #expect(PathContainment.isValidFilename("ok.txt"))
        #expect(!PathContainment.isValidFilename("a/b"))
        #expect(!PathContainment.isValidFilename(".."))
    }

    @Test func allowsSymlinkedRootItself() throws {
        // The folder root may itself be a symlink (e.g. /var → /private/var).
        let real = Fixtures.tempDir()
        let linkParent = Fixtures.tempDir()
        let link = linkParent.appending(path: "root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(try PathContainment(root: link).url(for: RelativePath(rawValue: "x/y")).lastPathComponent == "y")
    }
}
