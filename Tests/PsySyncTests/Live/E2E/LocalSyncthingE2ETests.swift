#if os(macOS)
import Foundation
import Testing
@testable import PsySync

/// E2E: LiveSyncEngine against the official Syncthing on this Mac.
///
/// Only runs from `Scripts/e2e-local-syncthing.sh` (`make e2e-local`), which
/// provides the official instance's API key in `PSY_E2E_OFFICIAL_APIKEY`
/// (process environment only — never printed or written) and checks that the
/// official configuration is unchanged apart from `psy-test-*` afterwards.
///
/// Rules: only create `psy-test-wpb-*` folders/devices on the official
/// instance, all paths under ~/SyncthingTest/wpb/, clean up at the end.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PSY_E2E_LOCAL"] == "1"))
struct LocalSyncthingE2ETests {
    @Test(.timeLimit(.minutes(10)))
    func fullScenario() async throws {
        let env = ProcessInfo.processInfo.environment
        let apiKey = try #require(env["PSY_E2E_OFFICIAL_APIKEY"], "PSY_E2E_OFFICIAL_APIKEY missing")
        let officialURL = URL(string: env["PSY_E2E_OFFICIAL_URL"] ?? "http://127.0.0.1:8384/")!
        let run = env["PSY_E2E_RUN_ID"] ?? String(UUID().uuidString.prefix(8)).lowercased()
        let testRoot = URL(filePath: NSHomeDirectory()).appending(path: "SyncthingTest/wpb/psy-test-wpb-\(run)")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

        let h = try await Harness(officialURL: officialURL, apiKey: apiKey, run: run, root: testRoot)
        do {
            try await h.runAllCases()
        } catch {
            await h.cleanup()
            throw error
        }
        await h.cleanup()
    }
}

/// Collects engine events for later assertions.
actor EventLog {
    private(set) var events: [EngineEvent] = []
    func append(_ e: EngineEvent) { events.append(e) }
    func contains(_ pred: @Sendable (EngineEvent) -> Bool) -> Bool { events.contains(where: pred) }
}

struct E2EFailure: Error, CustomStringConvertible {
    var description: String
}

final class Harness: @unchecked Sendable {
    let official: SyncthingRESTClient
    let officialID: DeviceID
    let officialPort: Int
    let run: String
    let root: URL
    let bridge = ProcessSyncthingBridge()
    let lock = FakeEngineLock()
    let engine: LiveSyncEngine
    let layout: AppGroupLayout
    let log = EventLog()
    var pump: Task<Void, Never>?
    var localID: DeviceID!
    var createdOfficialFolders: [String] = []

    var f1: FolderID { FolderID(rawValue: "psy-test-wpb-\(run)-f1") }
    var f2: FolderID { FolderID(rawValue: "psy-test-wpb-\(run)-f2") }
    var f3: FolderID { FolderID(rawValue: "psy-test-wpb-\(run)-ext") }
    var testDeviceName: String { "psy-test-wpb-\(run)" }

    init(officialURL: URL, apiKey: String, run: String, root: URL) async throws {
        self.run = run
        self.root = root
        let probe = SyncthingRESTClient(endpoint: RESTEndpoint(baseURL: officialURL, apiKey: apiKey, deviceID: DeviceID(rawValue: "")), timeout: 120)
        let status = try await probe.systemStatus()
        officialID = DeviceID(rawValue: status.myID)
        official = SyncthingRESTClient(endpoint: RESTEndpoint(baseURL: officialURL, apiKey: apiKey, deviceID: officialID), timeout: 120)
        struct Status: Decodable { var connectionServiceStatus: [String: JSONValue] }
        let st: Status = try await official.get("rest/system/status")
        officialPort = st.connectionServiceStatus.keys.compactMap { key -> Int? in
            guard key.hasPrefix("tcp://") else { return nil }
            return key.split(separator: ":").last.flatMap { Int($0) }
        }.first ?? 22000

        layout = AppGroupLayout(root: root.appending(path: "group"))
        var cfg = LiveSyncEngineConfiguration(layout: layout, deviceName: "psy-test-wpb-\(run)")
        cfg.externalAccess = .unscoped
        cfg.fsWatcherEnabled = false   // iOS behaviour: explicit scans only
        engine = LiveSyncEngine(bridge: bridge, lock: lock, identityStore: KeychainIdentityStore(backend: InMemoryKeychainBackend()), configuration: cfg)
        let stream = engine.events()
        let log = self.log
        pump = Task { for await e in stream { await log.append(e) } }
    }

    // MARK: Utilities

    func step(_ name: String) { print("[e2e] \(name)") }

    func eventually(_ what: String, timeout: TimeInterval = 90, _ cond: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do { if try await cond() { return } } catch { lastError = error }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw E2EFailure(description: "timed out: \(what)\(lastError.map { " (last error: \($0))" } ?? "")")
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
    func write(_ url: URL, _ s: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: url, options: .atomic)
    }

    func officialDir(_ f: FolderID) -> URL { root.appending(path: "official/\(f.rawValue)", directoryHint: .isDirectory) }
    func localDir(_ f: FolderID) -> URL { layout.managedFolder(f) }

    func officialScan(_ f: FolderID, _ sub: String? = nil) async throws {
        var q = [URLQueryItem(name: "folder", value: f.rawValue)]
        if let sub { q.append(.init(name: "sub", value: sub)) }
        try await official.send("POST", "rest/db/scan", query: q, timeout: 120)
    }

    func officialCreateFolder(_ f: FolderID, files: [String: String]) async throws {
        let dir = officialDir(f)
        for (path, content) in files { try write(dir.appending(path: path), content) }
        createdOfficialFolders.append(f.rawValue)
        try await official.send("POST", "rest/config/folders", json: FolderConfigDTO(
            id: f.rawValue, label: f.rawValue, path: dir.path(percentEncoded: false), type: "sendreceive",
            devices: [FolderDeviceDTO(deviceID: officialID.rawValue), FolderDeviceDTO(deviceID: localID.rawValue)],
            paused: false, fsWatcherEnabled: false, rescanIntervalS: 3600
        ))
    }

    func connected(_ id: DeviceID) async throws -> Bool {
        try await engine.connections().first { $0.deviceID == id }?.state == .connected
    }

    func folderState(_ f: FolderID) async throws -> FolderSyncState {
        try await engine.folderStatus(f).state
    }

    /// Official side has fully processed f (idle, nothing needed).
    func officialIdle(_ f: FolderID) async throws -> Bool {
        let s = try await official.dbStatus(f.rawValue)
        return s.state == "idle" && s.needTotalItems == 0
    }

    // MARK: Scenario

    func runAllCases() async throws {
        step("start engine")
        try await engine.start(context: .foreground)
        localID = await engine.localDeviceID
        guard case .running = await engine.state else { throw E2EFailure(description: "engine not running") }
        #expect(lock.currentHolder() == .app)

        try await pairing()
        try await folderInvitation()
        try await bidirectionalChanges()
        try await conflict()
        try await offlineDeviceDoesNotBlock()
        try await policyPauseResumeAndLimits()
        try await onDemand()
        try await externalFolder()
        try await restart()
    }

    func pairing() async throws {
        step("pairing: official adds us → pending device event on our side")
        try await official.send("POST", "rest/config/devices", json: DeviceConfigDTO(
            deviceID: localID.rawValue, name: testDeviceName, addresses: ["tcp://127.0.0.1:\(bridge.listenPort)"],
            paused: false, introducer: false, autoAcceptFolders: false))
        let oid = officialID
        try await eventually("pendingDevicesChanged with official") {
            await self.log.contains { if case .pendingDevicesChanged(let l) = $0 { return l.contains { $0.id == oid } }; return false }
        }
        #expect(try await engine.pendingDevices().contains { $0.id == oid })

        step("pairing: accept → connected")
        try await engine.addDevice(Device(id: oid, name: "psy-test-wpb-official", addresses: ["tcp://127.0.0.1:\(officialPort)"]))
        try await eventually("connected to official") { try await self.connected(oid) }
        #expect(await log.contains { if case .deviceConnectionChanged(let c) = $0 { return c.deviceID == oid && c.state == .connected }; return false })
        try await eventually("pending device cleared") { try await !self.engine.pendingDevices().contains { $0.id == oid } }
        #expect(try await engine.devices().contains { $0.id == oid && !$0.paused })
    }

    func folderInvitation() async throws {
        step("invitation: official shares folder → appears automatically as pending")
        try await officialCreateFolder(f1, files: ["hello.txt": "hello v1", "sub/nested.txt": "nested"])
        let f1 = self.f1
        try await eventually("pendingFoldersChanged with f1") {
            await self.log.contains { if case .pendingFoldersChanged(let l) = $0 { return l.contains { $0.folderID == f1 } }; return false }
        }
        let pending = try #require(try await engine.pendingFolders().first { $0.folderID == f1 })
        #expect(pending.offeredBy == officialID)

        step("invitation: accept as managed/everything → initial sync")
        try await engine.acceptPendingFolder(pending, as: Folder(id: f1, label: pending.label))
        let dir = localDir(f1)
        try await eventually("initial files") {
            self.read(dir.appending(path: "hello.txt")) == "hello v1" && self.read(dir.appending(path: "sub/nested.txt")) == "nested"
        }
        try await eventually("f1 upToDate") { try await self.folderState(f1) == .upToDate }
        #expect(await log.contains { if case .folderStatusChanged(let s) = $0 { return s.folderID == f1 }; return false })
        #expect(await log.contains { if case .itemFinished(let f, let p, nil) = $0 { return f == f1 && p.rawValue == "hello.txt" }; return false })
        #expect(await log.contains { if case .indexChanged(let f, _) = $0 { return f == f1 }; return false })
        #expect(try await engine.folders().first { $0.id == f1 }?.location == .managed)
        try await eventually("pending folder cleared") { try await !self.engine.pendingFolders().contains { $0.folderID == f1 } }
    }

    func bidirectionalChanges() async throws {
        let local = localDir(f1), remote = officialDir(f1), f1 = self.f1

        step("official → local: modify")
        try write(remote.appending(path: "hello.txt"), "hello v2")
        try await officialScan(f1, "hello.txt")
        try await eventually("modify propagated") { self.read(local.appending(path: "hello.txt")) == "hello v2" }

        step("local → official: add")
        try write(local.appending(path: "new.txt"), "from local")
        try await engine.scan(f1, paths: [RelativePath(rawValue: "new.txt")])
        try await eventually("add propagated") { self.read(remote.appending(path: "new.txt")) == "from local" }

        step("local → official: modify")
        try write(local.appending(path: "new.txt"), "from local v2")
        try await engine.scan(f1, paths: [RelativePath(rawValue: "new.txt")])
        try await eventually("local modify propagated") { self.read(remote.appending(path: "new.txt")) == "from local v2" }

        step("local → official: rename")
        try FileManager.default.moveItem(at: local.appending(path: "new.txt"), to: local.appending(path: "renamed.txt"))
        try await engine.scan(f1, paths: [RelativePath(rawValue: "new.txt"), RelativePath(rawValue: "renamed.txt")])
        try await eventually("local rename propagated") {
            self.read(remote.appending(path: "renamed.txt")) == "from local v2" && !self.exists(remote.appending(path: "new.txt"))
        }

        step("official → local: rename")
        try FileManager.default.moveItem(at: remote.appending(path: "sub/nested.txt"), to: remote.appending(path: "sub/moved.txt"))
        try await officialScan(f1, "sub")
        try await eventually("official rename propagated") {
            self.read(local.appending(path: "sub/moved.txt")) == "nested" && !self.exists(local.appending(path: "sub/nested.txt"))
        }

        step("local → official: delete")
        try FileManager.default.removeItem(at: local.appending(path: "renamed.txt"))
        try await engine.scan(f1, paths: [RelativePath(rawValue: "renamed.txt")])
        try await eventually("local delete propagated") { !self.exists(remote.appending(path: "renamed.txt")) }

        step("official → local: delete")
        try FileManager.default.removeItem(at: remote.appending(path: "hello.txt"))
        try await officialScan(f1, "hello.txt")
        try await eventually("official delete propagated") { !self.exists(local.appending(path: "hello.txt")) }
        try await eventually("f1 upToDate after changes") { try await self.folderState(f1) == .upToDate }
    }

    func conflict() async throws {
        let local = localDir(f1), remote = officialDir(f1), f1 = self.f1, oid = officialID
        step("conflict: concurrent edits while disconnected")
        try write(remote.appending(path: "c.txt"), "base")
        try await officialScan(f1, "c.txt")
        try await eventually("conflict base synced") { self.read(local.appending(path: "c.txt")) == "base" }
        var dev = try #require(try await engine.devices().first { $0.id == oid })
        dev.paused = true
        try await engine.updateDevice(dev)
        try await eventually("disconnected for conflict") { try await !self.connected(oid) }
        try write(local.appending(path: "c.txt"), "local edit")
        try await engine.scan(f1, paths: [RelativePath(rawValue: "c.txt")])
        try await Task.sleep(for: .seconds(1.5))   // distinct mtimes
        try write(remote.appending(path: "c.txt"), "official edit")
        try await officialScan(f1, "c.txt")
        dev.paused = false
        try await engine.updateDevice(dev)
        func hasConflict(_ dir: URL) -> Bool {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
                .contains { $0.hasPrefix("c.sync-conflict-") }
        }
        try await eventually("conflict copy appears on both sides") { hasConflict(local) && hasConflict(remote) }
        try await eventually("f1 upToDate after conflict") { try await self.folderState(f1) == .upToDate }
    }

    func offlineDeviceDoesNotBlock() async throws {
        let local = localDir(f1), remote = officialDir(f1), f1 = self.f1, oid = officialID
        step("offline device: share with a device that never comes online")
        let ghost = DeviceIDCodec.random()
        try await engine.addDevice(Device(id: ghost, name: "psy-test-wpb-\(run)-offline", addresses: ["tcp://127.0.0.1:9"]))
        var folder = try #require(try await engine.folders().first { $0.id == f1 })
        folder.devices.append(ghost)
        try await engine.updateFolder(folder)
        try write(local.appending(path: "after-ghost.txt"), "x")
        try await engine.scan(f1, paths: [RelativePath(rawValue: "after-ghost.txt")])
        try await eventually("propagated with ghost present") { self.read(remote.appending(path: "after-ghost.txt")) == "x" }
        try await eventually("upToDate despite offline device") { try await self.folderState(f1) == .upToDate }
        let snapshot = try await engine.snapshot()
        #expect(snapshot.folders.first { $0.folderID == f1 }?.state == .upToDate)
        #expect(snapshot.totalDevices == 2 && snapshot.connectedDevices == 1)

        step("offline device: no peer online with pending upload → waitingForDevices, not error")
        var dev = try #require(try await engine.devices().first { $0.id == oid })
        dev.paused = true
        try await engine.updateDevice(dev)
        try await eventually("official disconnected") { try await !self.connected(oid) }
        try write(local.appending(path: "while-alone.txt"), "alone")
        try await engine.scan(f1, paths: [RelativePath(rawValue: "while-alone.txt")])
        try await eventually("waitingForDevices") { try await self.folderState(f1) == .waitingForDevices }
        dev.paused = false
        try await engine.updateDevice(dev)
        try await eventually("delivered after reconnect") { self.read(remote.appending(path: "while-alone.txt")) == "alone" }
        try await eventually("upToDate after reconnect") { try await self.folderState(f1) == .upToDate }

        folder.devices.removeAll { $0 == ghost }
        try await engine.updateFolder(folder)
        try await engine.removeDevice(ghost)
    }

    func policyPauseResumeAndLimits() async throws {
        let f1 = self.f1, oid = officialID
        step("policy: hold pauses networking without touching user intent")
        try await engine.apply(PolicyDecision(hold: .lowPowerMode))
        try await eventually("disconnected by policy") { try await !self.connected(oid) }
        try await eventually("heldByPolicy") { try await self.folderState(f1) == .heldByPolicy }
        #expect(try await engine.devices().first { $0.id == oid }?.paused == false)
        let tClient = SyncthingRESTClient(endpoint: try #require(bridge.endpoint))
        #expect(try await tClient.configDevices().first { $0.deviceID == oid.rawValue }?.paused == true)
        #expect(try await engine.snapshot().policy.hold == .lowPowerMode)

        step("policy: resume + rate limits applied")
        try await engine.apply(PolicyDecision(sendLimitKiBps: 100, receiveLimitKiBps: 200))
        try await eventually("reconnected after hold") { try await self.connected(oid) }
        let opts = try await tClient.options()
        #expect(opts.maxSendKbps == 100 && opts.maxRecvKbps == 200)
        #expect(try await tClient.configDevices().first { $0.deviceID == oid.rawValue }?.paused == false)
        try await engine.apply(.run)
        #expect(try await tClient.options() == OptionsDTO(maxSendKbps: 0, maxRecvKbps: 0))
        try await eventually("f1 upToDate after policy") { try await self.folderState(f1) == .upToDate }
    }

    func onDemand() async throws {
        let f2 = self.f2
        step("on-demand: accept folder as on-demand → nothing downloaded")
        try await officialCreateFolder(f2, files: ["a.txt": "A", "docs/b.txt": "B", "docs/c.txt": "C", "docs/deep/d.txt": "D"])
        try await eventually("f2 pending") { try await self.engine.pendingFolders().contains { $0.folderID == f2 } }
        let pending = try #require(try await engine.pendingFolders().first { $0.folderID == f2 })
        try await engine.acceptPendingFolder(pending, as: Folder(id: f2, label: "on demand", contentMode: .onDemand))
        let local = localDir(f2), remote = officialDir(f2)
        try await eventually("f2 upToDate with everything ignored") { try await self.folderState(f2) == .upToDate }
        #expect(!exists(local.appending(path: "a.txt")))
        #expect(!exists(local.appending(path: "docs/b.txt")))
        #expect(try await engine.folders().first { $0.id == f2 }?.contentMode == .onDemand)

        step("on-demand: un-ignore one nested file → fetched")
        try await engine.setLocalPresence(f2, paths: [RelativePath(rawValue: "docs/b.txt")], present: true)
        try await eventually("b.txt fetched") { self.read(local.appending(path: "docs/b.txt")) == "B" }
        #expect(!exists(local.appending(path: "docs/c.txt")))

        step("on-demand: evict → local copy removed, remote untouched")
        try await engine.setLocalPresence(f2, paths: [RelativePath(rawValue: "docs/b.txt")], present: false)
        #expect(!exists(local.appending(path: "docs/b.txt")))
        try await Task.sleep(for: .seconds(3))
        try await officialScan(f2)
        try await eventually("official idle after evict") { try await self.officialIdle(f2) }
        #expect(read(remote.appending(path: "docs/b.txt")) == "B")

        step("on-demand: pin directory → whole subtree fetched")
        try await engine.setLocalPresence(f2, paths: [RelativePath(rawValue: "docs")], present: true)
        try await eventually("docs subtree fetched") {
            self.read(local.appending(path: "docs/b.txt")) == "B" && self.read(local.appending(path: "docs/c.txt")) == "C"
                && self.read(local.appending(path: "docs/deep/d.txt")) == "D"
        }
        #expect(!exists(local.appending(path: "a.txt")))
        try await eventually("f2 upToDate after pin") { try await self.folderState(f2) == .upToDate }

        step("on-demand: new remote file under pinned dir arrives, outside does not")
        try write(remote.appending(path: "docs/new.txt"), "N")
        try write(remote.appending(path: "other.txt"), "O")
        try await officialScan(f2)
        try await eventually("pinned dir receives new file") { self.read(local.appending(path: "docs/new.txt")) == "N" }
        #expect(!exists(local.appending(path: "other.txt")))

        step("on-demand: switch to everything → rest downloaded")
        var folder = try #require(try await engine.folders().first { $0.id == f2 })
        folder.contentMode = .everything
        try await engine.updateFolder(folder)
        try await engine.scan(f2, paths: nil)
        try await eventually("everything downloaded") {
            self.read(local.appending(path: "a.txt")) == "A" && self.read(local.appending(path: "other.txt")) == "O"
        }
    }

    func externalFolder() async throws {
        step("external location: folder synced in place at a user-picked directory")
        let f3 = self.f3
        let picked = root.appending(path: "picked-dir", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let location = try ExternalLocation.makeLocation(for: picked, access: .unscoped)
        try await officialCreateFolder(f3, files: ["ext.txt": "E"])
        try await eventually("f3 pending") { try await self.engine.pendingFolders().contains { $0.folderID == f3 } }
        let pending = try #require(try await engine.pendingFolders().first { $0.folderID == f3 })
        try await engine.acceptPendingFolder(pending, as: Folder(id: f3, label: "ext", location: location))
        try await eventually("external folder synced") { self.read(picked.appending(path: "ext.txt")) == "E" }
        let f = try #require(try await engine.folders().first { $0.id == f3 })
        if case .external = f.location {} else { Issue.record("expected external location, got \(f.location)") }
    }

    func restart() async throws {
        step("lifecycle: stop releases lock; restart reconnects")
        try await engine.stop(deadline: .seconds(10))
        #expect(await engine.state == .stopped)
        #expect(lock.currentHolder() == nil)
        await #expect(throws: EngineError.notRunning) { try await self.engine.folders() }
        try await engine.start(context: .foreground)
        let oid = officialID
        try await eventually("reconnected after restart") { try await self.connected(oid) }
        #expect(try await engine.folders().count == 3)
        try await eventually("f1 upToDate after restart") { try await self.folderState(self.f1) == .upToDate }
    }

    // MARK: Cleanup

    func cleanup() async {
        step("cleanup")
        if case .running = await engine.state {
            for f in [f1, f2, f3] {
                try? await engine.removeFolder(f, deleteLocalFiles: true)
            }
            if let devs = try? await engine.devices() {
                for d in devs { try? await engine.removeDevice(d.id) }
            }
        }
        try? await engine.stop(deadline: .seconds(10))
        pump?.cancel()
        for f in createdOfficialFolders {
            _ = try? await official.send("DELETE", "rest/config/folders/\(f)")
        }
        if let localID {
            _ = try? await official.send("DELETE", "rest/config/devices/\(localID.rawValue)")
            _ = try? await official.send("DELETE", "rest/cluster/pending/devices", query: [.init(name: "device", value: localID.rawValue)])
            for f in createdOfficialFolders {
                _ = try? await official.send("DELETE", "rest/cluster/pending/folders", query: [.init(name: "folder", value: f), .init(name: "device", value: localID.rawValue)])
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
