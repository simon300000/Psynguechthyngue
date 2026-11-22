import Foundation
import Testing
@testable import PsySync

private let f1 = FolderID(rawValue: "f1")

final class FakeFetchBridge: RestrictedFetchBridge, @unchecked Sendable {
    let payload: Data
    let error: Error?
    /// Called inside recordFetchedFile (to observe the commit order).
    var onRecord: (@Sendable (FolderID, RelativePath, String) -> Void)?
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    private var _lastMemoryMiB: Int64?
    var lastMemoryMiB: Int64? { lock.withLock { _lastMemoryMiB } }

    init(payload: Data = Data("fetched".utf8), error: Error? = nil) {
        self.payload = payload
        self.error = error
    }

    func fetch(
        homeDirectory: URL, identity: DeviceIdentity, folder: FolderID, path: RelativePath, expectedVersion: String?,
        destination: URL, budget: RestrictedFetchBudget, progress: @escaping @Sendable (Int64, Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> RestrictedFetchResult {
        lock.withLock { _calls += 1; _lastMemoryMiB = budget.memory.limitMiB }
        #expect(Thread.isMainThread == false)
        if let error { throw error }
        try payload.write(to: destination)
        progress(Int64(payload.count), Int64(payload.count))
        return RestrictedFetchResult(stagedFile: destination, size: Int64(payload.count), version: "v", servedBy: [])
    }

    private var _recorded: [(FolderID, RelativePath, String)] = []
    var recorded: [(FolderID, RelativePath, String)] { lock.withLock { _recorded } }

    func recordFetchedFile(
        homeDirectory: URL, identity: DeviceIdentity, folder: FolderID, path: RelativePath, version: String
    ) throws {
        onRecord?(folder, path, version)
        lock.withLock { _recorded.append((folder, path, version)) }
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

    func provider(
        bridge: (any RestrictedFetchBridge)?, accept: Duration = .seconds(2), availableMemory: UInt64? = nil,
        memory: (@Sendable () -> UInt64)? = nil, release: (@Sendable () -> Void)? = nil
    ) -> LiveContentProvider {
        var config = LiveContentProvider.Configuration()
        if let availableMemory { config.availableMemory = { availableMemory } }
        if let memory { config.availableMemory = memory }
        config.afterFetch = release
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
        #expect(h.lock.currentHolder() == nil)  // lock released
        // Second open is a local clone.
        let again = try await h.provider(bridge: bridge).provideContents(for: h.id("b.bin"), requestedVersion: nil, progress: Progress())
        #expect(again.source == .localClone)
        #expect(bridge.calls == 1)
    }

    /// Contract change WP-A record-fetched-file: fetch → rename → recordFetchedFile
    /// → `.stignore` `!/path` → journal → unlock.
    @Test func restrictedFetchCommitOrder() async throws {
        let h = try ContentHarness(mode: .onDemand)
        let folder = h.layout.managedFolder(f1)
        try IgnoreRulesGenerator.fileContents(present: [RelativePath(rawValue: "keep.txt")])
            .write(to: folder.appending(path: ".stignore"), atomically: true, encoding: .utf8)
        try h.project([FilesFixtures.file("sub/c.bin", size: 7, local: false)])
        let observed = LockedBox<[String]>([])
        let bridge = FakeFetchBridge()
        let store = h.store
        let lock = h.lock
        bridge.onRecord = { _, path, version in
            let fileThere = FileManager.default.fileExists(atPath: folder.appending(path: path.rawValue).path)
            let ignores = (try? String(contentsOf: folder.appending(path: ".stignore"), encoding: .utf8)) ?? ""
            let journal = (try? store.pending(limit: 10).count) ?? -1
            observed.mutate {
                $0 = ["renamed=\(fileThere)", "ruleBefore=\(ignores.contains("!/sub/c.bin"))", "journal=\(journal)",
                      "locked=\(lock.currentHolder() == .fileProviderExtension)", "version=\(version)"]
            }
        }
        let result = try await h.provider(bridge: bridge).provideContents(for: h.id("sub/c.bin"), requestedVersion: nil, progress: Progress())
        #expect(result.source == .restrictedFetch)
        #expect(observed.value == ["renamed=true", "ruleBefore=false", "journal=0", "locked=true", "version=v"])
        let ignores = try String(contentsOf: folder.appending(path: ".stignore"), encoding: .utf8)
        #expect(IgnoreRulesGenerator.presentPaths(from: ignores.split(separator: "\n").map(String.init))
            == [RelativePath(rawValue: "keep.txt"), RelativePath(rawValue: "sub/c.bin")])
        #expect(try h.store.pending(limit: 10).map(\.kind) == [.modified])
        #expect(h.lock.currentHolder() == nil)
        #expect(bridge.recorded.count == 1)
    }

    @Test func fittedBudgetFollowsJetsamHeadroom() {
        let base = RestrictedFetchBudget.default
        #expect(base.memory.limitMiB == 40)
        #expect(base.fitted(availableBytes: 0) == base)  // unknown → static ceiling
        #expect(base.fitted(availableBytes: 200 << 20)?.memory.limitMiB == 40)  // capped
        #expect(base.fitted(availableBytes: 14 << 20)?.memory.limitMiB == 10)  // device: ≈14 MiB left
        #expect(base.fitted(availableBytes: 9 << 20)?.memory.limitMiB == 5)  // was refused (needed 10 MiB)
        #expect(base.fitted(availableBytes: (7 << 20) + 123)?.memory.limitMiB == 4)  // threshold, floor
        #expect(base.fitted(availableBytes: (7 << 20) - 1) == nil)
        #expect(base.fitted(availableBytes: 1 << 20) == nil)
        #expect(base.fitted(availableBytes: 14 << 20)?.memory.gcPercent == base.memory.gcPercent)
    }

    @Test func restrictedFetchUsesFittedMemoryLimit() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("m.bin", size: 7, local: false)])
        let bridge = FakeFetchBridge()
        let result = try await h.provider(bridge: bridge, availableMemory: 13 << 20)
            .provideContents(for: h.id("m.bin"), requestedVersion: nil, progress: Progress())
        #expect(result.source == .restrictedFetch)
        #expect(bridge.lastMemoryMiB == 9)
    }

    @Test func restrictedFetchRefusedWhenHeadroomTooSmall() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("m.bin", size: 7, local: false)])
        let bridge = FakeFetchBridge()
        await #expect(throws: FilesContentError.openAppRequired(.lowMemory)) {
            _ = try await h.provider(bridge: bridge, availableMemory: 6 << 20)
                .provideContents(for: h.id("m.bin"), requestedVersion: nil, progress: Progress())
        }
        #expect(bridge.calls == 0)
        #expect(h.lock.currentHolder() == nil)
    }

    /// Regression (iPhone 17 Pro, iOS 27.3): a 231-byte file was refused with
    /// "too large" because ~8–9 MiB of headroom counted as too little.
    @Test func smallHeadroomStillFetches() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("package.json", size: 231, local: false)])
        let bridge = FakeFetchBridge()
        let result = try await h.provider(bridge: bridge, availableMemory: 8 << 20)
            .provideContents(for: h.id("package.json"), requestedVersion: nil, progress: Progress())
        #expect(result.source == .restrictedFetch)
        #expect(bridge.lastMemoryMiB == 4)
    }

    /// Go memory of the previous fetch is released asynchronously; release it
    /// and measure again before refusing.
    @Test func lowHeadroomReleasesMemoryAndRemeasures() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("m.bin", size: 7, local: false)])
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool { lock.withLock { value } }
            func set() { lock.withLock { value = true } }
        }
        let released = Flag()
        let bridge = FakeFetchBridge()
        let provider = h.provider(
            bridge: bridge, memory: { released.isSet ? 12 << 20 : 5 << 20 }, release: { released.set() })
        let result = try await provider.provideContents(for: h.id("m.bin"), requestedVersion: nil, progress: Progress())
        #expect(result.source == .restrictedFetch)
        #expect(bridge.lastMemoryMiB == 8)
    }

    @Test func bridgeErrorDescriptionsMap() {
        struct Described: Error, CustomStringConvertible { let description: String }
        #expect(LiveContentProvider.mapBridgeError(Described(description: "psy:too_large: 3 GiB"), cancelled: false)
            == .openAppRequired(.tooLarge))
        #expect(LiveContentProvider.mapBridgeError(Described(description: "psy:version_mismatch: x"), cancelled: false)
            == .openAppRequired(.staleIndex))
        #expect(LiveContentProvider.mapBridgeError(Described(description: "psy:cancelled"), cancelled: false) == .cancelled)
    }

    @Test func restrictedFetchErrorsMapToOpenApp() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("c", local: false)])
        let noPeer = FakeFetchBridge(error: EngineError.bridge(code: "no_peer", detail: "x"))
        // On-demand: the user's request is kept for later (presence intent).
        await #expect(throws: FilesContentError.openAppRequired(.queuedNoPeer)) {
            _ = try await h.provider(bridge: noPeer).provideContents(for: h.id("c"), requestedVersion: nil, progress: Progress())
        }
        #expect(try h.store.pendingPresence() == [PresenceRequest(folderID: f1, path: RelativePath(rawValue: "c"), present: true)])
        // "Everything" downloads anyway: plain no-peer, nothing queued.
        let all = try ContentHarness(mode: .everything)
        try all.project([FilesFixtures.file("c", local: false)])
        await #expect(throws: FilesContentError.openAppRequired(.noPeer)) {
            _ = try await all.provider(bridge: noPeer).provideContents(for: all.id("c"), requestedVersion: nil, progress: Progress())
        }
        #expect(try all.store.pendingPresence().isEmpty)
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

    /// User request: an open while no device is reachable must not leave
    /// Files spinning for the 10-minute delegation timeout, and must not be
    /// lost — the presence rule stays so the engine downloads it later.
    @Test func delegatedOpenWithNoPeerIsQueuedAndFailsFast() async throws {
        let h = try ContentHarness()
        try h.project([FilesFixtures.file("q.txt", size: 6, local: false)])
        let appLease = try #require(await h.lock.acquire(owner: .app, timeout: .seconds(1)))
        defer { appLease.release() }
        let engine = FilesFakeEngine()
        let peer = DeviceID(rawValue: "PEER")
        engine.folderList = [Folder(id: f1, label: "F", contentMode: .onDemand, devices: [peer])]
        engine.connectionList = [DeviceConnection(deviceID: peer, state: .disconnected)]
        let server = ContentRequestServer(engine: engine, store: h.store, layout: h.layout, pollInterval: .milliseconds(200)) { _ in }
        await server.start()
        defer { Task { await server.stop() } }
        let started = ContinuousClock.now
        await #expect(throws: FilesContentError.openAppRequired(.queuedNoPeer)) {
            _ = try await h.provider(bridge: FakeFetchBridge()).provideContents(for: h.id("q.txt"), requestedVersion: nil, progress: Progress())
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(engine.recordedCalls.contains("presence true q.txt"))
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

    /// Regression (device, big-folder folder): the App went to background while a
    /// pass was streaming a large index; `stop()` cancelled the pass, the
    /// cancelled stream *ended* instead of throwing, and the sweep deleted
    /// every row not yet reached. Files then showed only a few root items.
    @Test func stopMidPassDoesNotSweepUnreadRows() async throws {
        let h = try ContentHarness(mode: .onDemand)
        let engine = FilesFakeEngine()
        let entries = [FilesFixtures.dir("d")] + (0..<20).map { FilesFixtures.file("f\($0)") }
        engine.setIndex(f1, entries)
        let traces = LockedBox<[String]>([])
        let projector = FilesProjector(engine: engine, store: h.store, debounce: .milliseconds(50), pageSize: 3,
                                       trace: { line in traces.mutate { $0.append(line) } }) { _ in }
        await projector.setFolders([f1])
        await projector.projectNow(f1)
        #expect(try h.store.itemCount(f1) == 22)
        let anchor = try h.store.currentAnchor()

        engine.pageDelay = .milliseconds(200)
        let pass = Task { await projector.projectNow(f1) }
        #expect(await eventually { engine.pagesServed >= 1 })
        await projector.stop()
        await pass.value

        #expect(try h.store.itemCount(f1) == 22)
        #expect(try h.store.currentAnchor() == anchor)
        #expect(traces.value.last?.contains("cancelled") == true, "\(traces.value)")
        #expect(!traces.value.contains { $0.contains("swept=") && !$0.contains("swept=0") }, "\(traces.value)")
    }

    /// Regression: two requests waiting on the same running pass both started
    /// together afterwards; the second reset the shared mark set and the first
    /// then swept everything it had not marked since.
    @Test func overlappingRequestsRunOneAtATime() async throws {
        let h = try ContentHarness(mode: .onDemand)
        let engine = FilesFakeEngine()
        engine.setIndex(f1, [FilesFixtures.dir("d")] + (0..<12).map { FilesFixtures.file("f\($0)") })
        let traces = LockedBox<[String]>([])
        let projector = FilesProjector(engine: engine, store: h.store, debounce: .milliseconds(50), pageSize: 3,
                                       trace: { line in traces.mutate { $0.append(line) } }) { _ in }
        await projector.setFolders([f1])
        await projector.projectNow(f1)
        engine.pageDelay = .milliseconds(20)
        async let a: Void = projector.projectNow(f1)
        async let b: Void = projector.projectNow(f1)
        async let c: Void = projector.projectNow(f1)
        _ = await (a, b, c)
        #expect(try h.store.itemCount(f1) == 14)
        #expect(!traces.value.contains { !$0.contains("swept=0") }, "\(traces.value)")
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
