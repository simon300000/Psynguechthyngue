import Foundation
import Testing
@testable import PsySync

private let f1 = FolderID(rawValue: "f1")

final class FakeFetchBridge: RestrictedFetchBridge, @unchecked Sendable {
    let payload: Data
    let error: Error?
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(payload: Data = Data("fetched".utf8), error: Error? = nil) {
        self.payload = payload
        self.error = error
    }

    func fetch(
        homeDirectory: URL, identity: DeviceIdentity, folder: FolderID, path: RelativePath, expectedVersion: String?,
        destination: URL, budget: RestrictedFetchBudget, progress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> RestrictedFetchResult {
        lock.withLock { _calls += 1 }
        #expect(Thread.isMainThread == false)
        if let error { throw error }
        try payload.write(to: destination)
        progress(Int64(payload.count), Int64(payload.count))
        return RestrictedFetchResult(stagedFile: destination, size: Int64(payload.count), version: "v", servedBy: [])
    }
}

struct ContentHarness {
    let root: URL
    let layout: AppGroupLayout
    let store: FilesStore
    let lock: FlockEngineLock

    init(mode: ContentMode = .onDemand) throws {
        root = FilesFixtures.tempDir()
        layout = AppGroupLayout(root: root)
        store = try FilesStore(url: layout.filesDatabase)
        try store.upsertFolder(FilesFolderInfo(folderID: f1, label: "F", isReadOnly: false, contentMode: mode))
        try FileManager.default.createDirectory(at: layout.managedFolder(f1), withIntermediateDirectories: true)
        lock = FlockEngineLock(layout: layout)
    }

    func provider(bridge: (any RestrictedFetchBridge)?, accept: Duration = .seconds(2)) -> LiveContentProvider {
        var config = LiveContentProvider.Configuration()
        config.acceptTimeout = accept
        config.lockTimeout = .seconds(2)
        config.pollInterval = .milliseconds(50)
        return LiveContentProvider(
            layout: layout, store: store, folder: f1, engineLock: FlockEngineLock(layout: layout), fetchBridge: bridge,
            identity: { DeviceIdentity(certificatePEM: Data(), privateKeyPEM: Data(), deviceID: DeviceID(rawValue: "X")) },
            temporaryDirectory: root.appending(path: "tmp"), configuration: config)
    }

    func project(_ entries: [GlobalIndexEntry]) throws { _ = try store.applyIndexBatch(f1, entries: entries) }

    func id(_ path: String) throws -> ItemIdentifier {
        try #require(try store.record(folder: f1, path: RelativePath(rawValue: path))).itemID
    }

    func write(_ path: String, _ text: String) throws {
        let url = layout.managedFolder(f1).appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

@Suite(.serialized) struct LiveContentProviderTests {
    @Test func localCloneWhenFileIsLocal() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("docs/a.txt", size: 5, local: true)])
        try h.write("docs/a.txt", "hello")
        let bridge = FakeFetchBridge()
        let result = try await h.provider(bridge: bridge).provideContents(for: h.id("docs/a.txt"), requestedVersion: nil, progress: Progress())
        #expect(result.source == .localClone)
        #expect(try String(contentsOf: result.url, encoding: .utf8) == "hello")
        #expect(bridge.calls == 0)
    }

    @Test func restrictedFetchWhenAppNotRunning() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("b.bin", size: 7, local: false)])
        let bridge = FakeFetchBridge()
        let result = try await h.provider(bridge: bridge).provideContents(for: h.id("b.bin"), requestedVersion: Data([9]), progress: Progress())
        #expect(result.source == .restrictedFetch)
        #expect(try String(contentsOf: result.url, encoding: .utf8) == "fetched")
        #expect(try String(contentsOf: h.layout.managedFolder(f1).appending(path: "b.bin"), encoding: .utf8) == "fetched")
        #expect(try h.store.record(folder: f1, path: RelativePath(rawValue: "b.bin"))?.isLocal == true)
        #expect(try h.store.pending(limit: 10).map(\.kind) == [.modified])
        let attrs = try FileManager.default.attributesOfItem(atPath: h.layout.managedFolder(f1).appending(path: "b.bin").path)
        #expect((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 == 1_700_000_000)  // global mtime kept
        #expect(h.lock.currentHolder() == nil)  // lock released
        // Second open is a local clone.
        let again = try await h.provider(bridge: bridge).provideContents(for: h.id("b.bin"), requestedVersion: nil, progress: Progress())
        #expect(again.source == .localClone)
        #expect(bridge.calls == 1)
    }

    @Test func restrictedFetchErrorsMapToOpenApp() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("c", local: false)])
        let noPeer = FakeFetchBridge(error: EngineError.bridge(code: "no_peer", detail: "x"))
        await #expect(throws: FilesContentError.openAppRequired(.noPeer)) {
            _ = try await h.provider(bridge: noPeer).provideContents(for: h.id("c"), requestedVersion: nil, progress: Progress())
        }
        await #expect(throws: FilesContentError.openAppRequired(.unavailable)) {
            _ = try await h.provider(bridge: nil).provideContents(for: h.id("c"), requestedVersion: nil, progress: Progress())
        }
        #expect(h.lock.currentHolder() == nil)
    }

    @Test func delegatedToAppWhenEngineRunning() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("d/remote.txt", size: 6, local: false)])
        let appLease = try #require(await h.lock.acquire(owner: .app, timeout: .seconds(1)))
        defer { appLease.release() }
        let engine = FilesFakeEngine()
        let folderURL = h.layout.managedFolder(f1)
        engine.onPrioritize = { [weak engine] folder, path in
            // Simulate Syncthing pulling the file, then ItemFinished.
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                let url = folderURL.appending(path: path.rawValue)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("pulled".utf8).write(to: url)
                engine?.emit(.itemFinished(folderID: folder, path: path, error: nil))
            }
        }
        let server = ContentRequestServer(engine: engine, store: h.store, layout: h.layout, pollInterval: .milliseconds(200)) { _ in }
        await server.start()
        defer { Task { await server.stop() } }
        let bridge = FakeFetchBridge()
        let result = try await h.provider(bridge: bridge).provideContents(for: h.id("d/remote.txt"), requestedVersion: nil, progress: Progress())
        #expect(result.source == .delegatedToApp)
        #expect(try String(contentsOf: result.url, encoding: .utf8) == "pulled")
        #expect(bridge.calls == 0)
        #expect(engine.recordedCalls.contains("presence true d/remote.txt"))
        #expect(engine.recordedCalls.contains("prio f1 d/remote.txt"))
    }

    @Test func delegationNotAcceptedFallsBackToRestrictedFetchAfterAppReleasesLock() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("e", size: 7, local: false)])
        let appLease = try #require(await h.lock.acquire(owner: .app, timeout: .seconds(1)))
        // App "suspends" shortly after: no server, lock released after 400 ms.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            appLease.release()
        }
        let bridge = FakeFetchBridge()
        let result = try await h.provider(bridge: bridge, accept: .milliseconds(200))
            .provideContents(for: h.id("e"), requestedVersion: nil, progress: Progress())
        #expect(result.source == .restrictedFetch)
        #expect(bridge.calls == 1)
    }
}

@Suite(.serialized) struct ContentRequestServerTests {
    @Test func journalDrivesTargetedScanAndUnignoreOrder() async throws {
        let h = try ContentHarness(mode: .onDemand)
        try h.project([FilesFixtures.file("old.txt"), FilesFixtures.file("gone.txt")])
        _ = try h.store.recordLocalWrite(f1, path: RelativePath(rawValue: "new/n.txt"), isDirectory: false, size: 1, modified: Date())
        try h.store.append(f1, kind: .created, path: RelativePath(rawValue: "new/n.txt"), previousPath: nil)
        try h.store.recordLocalDelete(try h.id("gone.txt"))
        try h.store.append(f1, kind: .deleted, path: RelativePath(rawValue: "gone.txt"), previousPath: nil)
        try h.store.append(f1, kind: .moved, path: RelativePath(rawValue: "renamed.txt"), previousPath: RelativePath(rawValue: "old.txt"))

        let engine = FilesFakeEngine()
        let projected = LockedBox<[FolderID]>([])
        let server = ContentRequestServer(engine: engine, store: h.store, layout: h.layout) { folder in projected.mutate { $0.append(folder) } }
        await server.drain()
        #expect(engine.recordedCalls == [
            "presence true new/n.txt,renamed.txt",
            "scan f1 gone.txt,new/n.txt,old.txt,renamed.txt",
        ])  // no re-ignore of deleted paths (deletion must propagate first)
        #expect(try h.store.pending(limit: 10).isEmpty)
        #expect(try h.store.record(folder: f1, path: RelativePath(rawValue: "new/n.txt"))?.pendingUpload == false)
        #expect(!projected.value.isEmpty)
    }

    @Test func journalKeptWhenEngineFails() async throws {
        let h = try ContentHarness(mode: .everything)
        try h.store.append(f1, kind: .created, path: RelativePath(rawValue: "x"), previousPath: nil)
        let engine = FilesFakeEngine()
        engine.failScan = true
        let server = ContentRequestServer(engine: engine, store: h.store, layout: h.layout) { _ in }
        await server.drain()
        #expect(try h.store.pending(limit: 10).count == 1)
        #expect(!engine.recordedCalls.contains { $0.hasPrefix("presence") })  // everything mode: no ignore edits
    }

    @Test func minimalScanSetDropsCoveredDescendants() {
        let paths = ["a", "a/b", "a/b/c", "d/e", "d"].map(RelativePath.init(rawValue:))
        #expect(ContentRequestServer.minimalScanSet(paths).map(\.rawValue) == ["a", "d"])
    }
}

@Suite(.serialized) struct FilesProjectorTests {
    @Test func projectsAndReactsToIndexChanges() async throws {
        let h = try ContentHarness(mode: .everything)
        let engine = FilesFakeEngine()
        engine.setIndex(f1, [FilesFixtures.dir("a"), FilesFixtures.file("a/1"), FilesFixtures.file("a/2")])
        let signals = LockedBox<Int>(0)
        let projector = FilesProjector(engine: engine, store: h.store, debounce: .milliseconds(50), pageSize: 2) { _ in
            signals.mutate { $0 += 1 }
        }
        await projector.setFolders([f1])
        await projector.start()
        #expect(await eventually { (try? h.store.itemCount(f1)) == 4 })
        let firstID = try h.id("a/1")
        engine.setIndex(f1, [FilesFixtures.dir("a"), FilesFixtures.file("a/1", version: "v2"), FilesFixtures.file("b")])
        engine.emit(.indexChanged(folderID: f1, paths: nil))
        #expect(await eventually { (try? h.store.record(folder: f1, path: RelativePath(rawValue: "b"))) != nil })
        #expect(try h.id("a/1") == firstID)
        #expect(try h.store.record(folder: f1, path: RelativePath(rawValue: "a/2")) == nil)
        #expect(signals.value >= 2)
        // A pass over an unchanged index does not signal.
        let before = signals.value
        await projector.projectNow(f1)
        #expect(signals.value == before)
        await projector.stop()
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&_value) } }
}
