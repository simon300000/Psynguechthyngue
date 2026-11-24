import Foundation
import Testing
@testable import PsySync

@Suite struct RESTModelTests {
    @Test func decodesRecordedFixtures() throws {
        let d = RESTCoding.decoder()
        let status = try d.decode(SystemStatusDTO.self, from: Fixtures.data("system_status.json"))
        #expect(DeviceIDCodec.isValid(status.myID))
        let devices = try d.decode([DeviceConfigDTO].self, from: Fixtures.data("config_devices.json"))
        #expect(devices.count == 2)
        let folders = try d.decode([FolderConfigDTO].self, from: Fixtures.data("config_folders.json"))
        #expect(folders.first?.id == "f1" && folders.first?.devices.count == 2)
        let conns = try d.decode(ConnectionsDTO.self, from: Fixtures.data("connections.json"))
        #expect(conns.connections.values.first?.connected == true)
        // Upstream `type` names the protocol only ("tcp-client"); LAN is `isLocal`
        // (device acceptance: a LAN peer was shown as "over the internet").
        #expect(conns.connections.values.first?.type == "tcp-client")
        #expect(conns.connections.values.first?.isLocal == true)
        let pd = try d.decode([String: PendingDeviceDTO].self, from: Fixtures.data("pending_devices.json"))
        #expect(pd.count == 1)
        let pf = try d.decode([String: PendingFolderDTO].self, from: Fixtures.data("pending_folders.json"))
        #expect(pf["f1"]?.offeredBy.values.first?.label == "F One")
        let db = try d.decode(DBStatusDTO.self, from: Fixtures.data("db_status.json"))
        #expect(db.state == "idle" && db.globalBytes == 6)
        let c = try d.decode(CompletionDTO.self, from: Fixtures.data("db_completion_device.json"))
        #expect(c.completion == 100 && c.remoteState == "valid")
        let errs = try d.decode(FolderErrorsDTO.self, from: Fixtures.data("folder_errors.json"))
        #expect(errs.errors == nil)
        let ign = try d.decode(IgnoresDTO.self, from: Fixtures.data("db_ignores.json"))
        #expect(ign.ignore == nil)
        let opts = try d.decode(OptionsDTO.self, from: Fixtures.data("config_options.json"))
        #expect(opts.maxSendKbps == 0)
    }

    @Test func parsesUpstreamDates() {
        #expect(SyncthingDate.parse("2026-11-21T15:29:39.651636+08:00") != nil)
        #expect(SyncthingDate.parse("2026-11-21T07:29:27Z") != nil)
        #expect(SyncthingDate.parse("2026-11-21T15:29:40.597518123+08:00") != nil)
        #expect(SyncthingDate.parseNonZero("0001-01-01T00:00:00Z") == nil)
        let a = SyncthingDate.parse("2026-11-21T07:29:27Z")!
        let b = SyncthingDate.parse("2026-11-21T15:29:27.000+08:00")!
        #expect(a == b)
    }

    @Test func clientSendsKeyHeaderAndMapsErrors() async throws {
        let (url, authority) = StubURLProtocol.uniqueAuthority()
        StubURLProtocol.register(authority: authority) { req in
            req.path.hasSuffix("/rest/db/status") ? .json("no such folder", status: 404) : .json(#"{"ping":"pong"}"#)
        }
        let client = SyncthingRESTClient(endpoint: RESTEndpoint(baseURL: url, apiKey: "secret-key", deviceID: DeviceID(rawValue: "X")),
                                         configuration: StubURLProtocol.configuration())
        try await client.ping()
        await #expect(throws: EngineError.rest(status: 404, body: "no such folder")) { try await client.dbStatus("nope") }
        let reqs = StubURLProtocol.requests(authority: authority)
        #expect(reqs.allSatisfy { $0.apiKey == "secret-key" })
        #expect(reqs.allSatisfy { !$0.path.contains("secret") && !$0.query.values.contains("secret-key") })
    }

    @Test func plusIsEncodedInQuery() async throws {
        let (url, authority) = StubURLProtocol.uniqueAuthority()
        StubURLProtocol.register(authority: authority) { _ in .json("{}") }
        let client = SyncthingRESTClient(endpoint: RESTEndpoint(baseURL: url, apiKey: "k", deviceID: DeviceID(rawValue: "X")),
                                         configuration: StubURLProtocol.configuration())
        try await client.send("POST", "rest/db/scan", query: [.init(name: "sub", value: "a+b c.txt")])
        #expect(StubURLProtocol.requests(authority: authority).last?.query["sub"] == "a+b c.txt")
    }
}

@Suite struct EventTranslatorTests {
    @Test func translatesRecordedStream() throws {
        let events = try RESTCoding.decoder().decode([RawEventDTO].self, from: Fixtures.data("events.json"))
        let actions = events.flatMap(EventTranslator.translate)
        #expect(actions.contains(.refreshPendingDevices))
        #expect(actions.contains(.refreshPendingFolders))
        #expect(actions.contains(.refreshFolder(FolderID(rawValue: "f1"))))
        #expect(actions.contains(.emit(.itemStarted(folderID: FolderID(rawValue: "f1"), path: RelativePath(rawValue: "one.txt")))))
        #expect(actions.contains(.emit(.itemFinished(folderID: FolderID(rawValue: "f1"), path: RelativePath(rawValue: "one.txt"), error: nil))))
        #expect(actions.contains(.emit(.indexChanged(folderID: FolderID(rawValue: "f1"), paths: [RelativePath(rawValue: "one.txt")]))))
        #expect(actions.contains(.emit(.indexChanged(folderID: FolderID(rawValue: "f1"), paths: nil))))
        #expect(actions.contains { if case .emit(.deviceConnectionChanged(let c)) = $0 { return c.state == .connected && c.transport == "tcp-client" }; return false })
    }

    @Test func translatesSyntheticEvents() throws {
        func ev(_ json: String) throws -> [EventAction] {
            EventTranslator.translate(try RESTCoding.decoder().decode(RawEventDTO.self, from: Data(json.utf8)))
        }
        #expect(try ev(#"{"id":1,"type":"DeviceDisconnected","data":{"id":"D","error":"x"}}"#).first
                == .emit(.deviceConnectionChanged(DeviceConnection(deviceID: DeviceID(rawValue: "D"), state: .disconnected))))
        #expect(try ev(#"{"id":1,"type":"DevicePaused","data":{"device":"D"}}"#).first
                == .emit(.deviceConnectionChanged(DeviceConnection(deviceID: DeviceID(rawValue: "D"), state: .paused))))
        #expect(try ev(#"{"id":1,"type":"ItemFinished","data":{"folder":"f","item":"a","error":"boom"}}"#)
                == [.emit(.itemFinished(folderID: FolderID(rawValue: "f"), path: RelativePath(rawValue: "a"), error: "boom"))])
        #expect(try ev(#"{"id":1,"type":"DownloadProgress","data":{"f":{"a.bin":{"bytesDone":10,"bytesTotal":100}}}}"#)
                == [.emit(.downloadProgress(folderID: FolderID(rawValue: "f"), path: RelativePath(rawValue: "a.bin"), bytesDone: 10, bytesTotal: 100))])
        #expect(try ev(#"{"id":1,"type":"ConfigSaved","data":{}}"#).first == .emit(.configurationChanged))
        #expect(try ev(#"{"id":1,"type":"Unknown","data":null}"#).isEmpty)
        #expect(EventTranslator.mask.count == 18)
    }

    @Test func broadcasterFansOutAndCleansUp() async {
        let b = EventBroadcaster()
        var s1: AsyncStream<EngineEvent>? = b.stream()
        let s2 = b.stream()
        #expect(b.subscriberCount == 2)
        b.yield(.configurationChanged)
        var it1 = s1!.makeAsyncIterator()
        var it2 = s2.makeAsyncIterator()
        #expect(await it1.next() == .configurationChanged)
        #expect(await it2.next() == .configurationChanged)
        _ = it1
        s1 = nil
        _ = s1
    }
}

/// Minimal in-memory Syncthing REST surface for engine unit tests.
final class FakeSyncthing: @unchecked Sendable {
    let myID = DeviceIDCodec.random()
    private let lock = NSLock()
    var devices: [DeviceConfigDTO] = []
    var folders: [FolderConfigDTO] = []
    var options = OptionsDTO(maxSendKbps: 0, maxRecvKbps: 0, listenAddresses: ["default"], globalAnnounceEnabled: true, relaysEnabled: true)
    var ignores: [String: [String]] = [:]

    init() {
        devices = [DeviceConfigDTO(deviceID: myID.rawValue, name: "me", addresses: ["dynamic"], paused: false, introducer: false, autoAcceptFolders: false)]
    }

    /// Answer to GET /rest/config/folders is computed, then delayed this long.
    var configFoldersDelay: TimeInterval = 0
    var dbStatus = #"{"state":"idle","globalBytes":0,"localBytes":0,"needBytes":0,"needTotalItems":0}"#
    /// Bodies served by GET /rest/events, one per poll ("[]" when empty).
    var eventBatches: [String] = []

    func handle(_ r: StubURLProtocol.Recorded) -> StubURLProtocol.Response {
        let response = lock.withLock { route(r) }
        if r.method == "GET", r.path == "/rest/config/folders" {
            let delay = lock.withLock { configFoldersDelay }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        return response
    }

    func addFolderConfig(_ f: FolderConfigDTO) { lock.withLock { folders.append(f) } }
    func pushEvents(_ json: String) { lock.withLock { eventBatches.append(json) } }
    func ignoreLines(_ folder: String) -> [String]? { lock.withLock { ignores[folder] } }
    func setIgnoreLines(_ folder: String, _ lines: [String]) { lock.withLock { ignores[folder] = lines } }

    private func json(_ v: some Encodable) -> StubURLProtocol.Response {
        StubURLProtocol.Response(200, try! JSONEncoder().encode(v))
    }

    private func route(_ r: StubURLProtocol.Recorded) -> StubURLProtocol.Response {
        let d = JSONDecoder()
        switch (r.method, r.path) {
        case ("GET", "/rest/system/ping"): return .json(#"{"ping":"pong"}"#)
        case ("GET", "/rest/events"):
            if !eventBatches.isEmpty { return .json(eventBatches.removeFirst()) }
            return .json("[]")
        case ("GET", "/rest/config/devices"): return json(devices)
        case ("POST", "/rest/config/devices"):
            devices.append(try! d.decode(DeviceConfigDTO.self, from: r.body!)); return .json("")
        case ("POST", "/rest/system/pause"), ("POST", "/rest/system/resume"):
            let paused = r.path.hasSuffix("pause")
            for i in devices.indices where r.query["device"] == nil || devices[i].deviceID == r.query["device"] {
                devices[i].paused = paused
            }
            return .json("")
        case ("GET", "/rest/config/options"): return json(options)
        case ("PATCH", "/rest/config/options"):
            // Merge like upstream's PATCH: only the fields present change.
            let obj = (try? JSONSerialization.jsonObject(with: r.body!)) as? [String: Any] ?? [:]
            if let v = obj["maxSendKbps"] as? Int { options.maxSendKbps = v }
            if let v = obj["maxRecvKbps"] as? Int { options.maxRecvKbps = v }
            if let v = obj["listenAddresses"] as? [String] { options.listenAddresses = v }
            if let v = obj["globalAnnounceEnabled"] as? Bool { options.globalAnnounceEnabled = v }
            if let v = obj["relaysEnabled"] as? Bool { options.relaysEnabled = v }
            if let v = obj["maxFolderConcurrency"] as? Int { options.maxFolderConcurrency = v }
            if let v = obj["limitBandwidthInLan"] as? Bool { options.limitBandwidthInLan = v }
            return .json("")
        case ("GET", "/rest/system/version"): return .json(#"{"version":"v2.1.6","longVersion":"syncthing v2.1.6"}"#)
        case ("GET", "/rest/config/folders"): return json(folders)
        case ("POST", "/rest/config/folders"):
            folders.append(try! d.decode(FolderConfigDTO.self, from: r.body!)); return .json("")
        case ("GET", "/rest/system/connections"): return .json(#"{"connections":{}}"#)
        case ("GET", "/rest/stats/device"), ("GET", "/rest/stats/folder"): return .json("{}")
        case ("GET", "/rest/db/ignores"):
            // Like upstream: .stignore on disk is the truth (in-memory only
            // for folders whose directory does not exist).
            let id = r.query["folder"] ?? ""
            if let f = folders.first(where: { $0.id == id }),
               let text = try? String(contentsOf: URL(filePath: f.path).appending(path: ".stignore"), encoding: .utf8) {
                return json(IgnoresDTO(ignore: LiveSyncEngine.splitLines(text)))
            }
            return json(IgnoresDTO(ignore: ignores[id]))
        case ("POST", "/rest/db/ignores"):
            let id = r.query["folder"] ?? ""
            let lines = try! d.decode(IgnoresDTO.self, from: r.body!).ignore
            ignores[id] = lines
            if let f = folders.first(where: { $0.id == id }), FileManager.default.fileExists(atPath: f.path) {
                try? Data(LiveSyncEngine.joinLines(lines ?? []).utf8).write(to: URL(filePath: f.path).appending(path: ".stignore"))
            }
            return .json("{}")
        case ("POST", "/rest/db/scan"), ("POST", "/rest/db/prio"): return .json("{}")
        case ("GET", "/rest/db/status"):
            return .json(dbStatus)
        case ("GET", "/rest/folder/errors"): return .json(#"{"errors":null}"#)
        case ("GET", "/rest/db/completion"): return .json(#"{"completion":100,"needBytes":0,"needItems":0,"needDeletes":0,"remoteState":"unknown"}"#)
        default:
            if r.method == "PATCH", r.path.hasPrefix("/rest/config/devices/") {
                let id = String(r.path.dropFirst("/rest/config/devices/".count))
                let patch = try! JSONSerialization.jsonObject(with: r.body!) as! [String: Any]
                if let i = devices.firstIndex(where: { $0.deviceID == id }), let p = patch["paused"] as? Bool { devices[i].paused = p }
                if let i = devices.firstIndex(where: { $0.deviceID == id }), let n = patch["name"] as? String { devices[i].name = n }
                return .json("")
            }
            if r.method == "PATCH", r.path.hasPrefix("/rest/config/folders/") {
                let id = String(r.path.dropFirst("/rest/config/folders/".count))
                let patch = try! JSONSerialization.jsonObject(with: r.body!) as! [String: Any]
                if let i = folders.firstIndex(where: { $0.id == id }) {
                    if let v = patch["label"] as? String { folders[i].label = v }
                    if let v = patch["type"] as? String { folders[i].type = v }
                    if let v = patch["paused"] as? Bool { folders[i].paused = v }
                }
                return .json("")
            }
            if r.method == "GET", r.path.hasPrefix("/rest/config/folders/") {
                let id = String(r.path.dropFirst("/rest/config/folders/".count))
                if let f = folders.first(where: { $0.id == id }) { return json(f) }
                return .json("not found", status: 404)
            }
            return .json("unhandled \(r.method) \(r.path)", status: 500)
        }
    }

    func device(_ id: DeviceID) -> DeviceConfigDTO? { lock.withLock { devices.first { $0.deviceID == id.rawValue } } }
    var currentOptions: OptionsDTO { lock.withLock { options } }
    func setListenAddresses(_ addresses: [String]?) { lock.withLock { options.listenAddresses = addresses } }
    func setLoadOptions(maxFolderConcurrency: Int, limitBandwidthInLan: Bool) {
        lock.withLock { options.maxFolderConcurrency = maxFolderConcurrency; options.limitBandwidthInLan = limitBandwidthInLan }
    }
}

@Suite struct LiveSyncEngineTests {
    struct Harness {
        let engine: LiveSyncEngine
        let bridge: FakeBridge
        let lock: FakeEngineLock
        let fake: FakeSyncthing
        let authority: String
        let root: URL
    }

    func makeHarness(root existing: URL? = nil, baseURL: URL? = nil,
                     configure: (inout LiveSyncEngineConfiguration) -> Void = { _ in }) throws -> Harness {
        var (url, authority) = StubURLProtocol.uniqueAuthority()
        if let baseURL { url = baseURL }
        let fake = FakeSyncthing()
        StubURLProtocol.register(authority: authority) { fake.handle($0) }
        let bridge = FakeBridge(endpoint: RESTEndpoint(baseURL: url, apiKey: "k", deviceID: fake.myID))
        let lock = FakeEngineLock()
        let root = existing ?? FileManager.default.temporaryDirectory.appending(path: "psy-live-\(UUID().uuidString)")
        var cfg = LiveSyncEngineConfiguration(layout: AppGroupLayout(root: root), deviceName: "test")
        cfg.sessionConfiguration = { StubURLProtocol.configuration() }
        cfg.folderRefreshDebounce = .milliseconds(10)
        cfg.eventPollTimeoutSeconds = 1
        // Deterministic: never probe this host's real ports in engine tests.
        cfg.preferAlternateListenPort = false
        cfg.portProbe = { _ in true }
        configure(&cfg)
        let engine = LiveSyncEngine(bridge: bridge, lock: lock, identityStore: KeychainIdentityStore(backend: InMemoryKeychainBackend()), configuration: cfg)
        return Harness(engine: engine, bridge: bridge, lock: lock, fake: fake, authority: authority, root: root)
    }

    @Test func startStopHoldsAndReleasesLockOffThePool() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let events = h.engine.events()
        try await h.engine.start(context: .foreground)
        guard case .running = await h.engine.state else { Issue.record("not running"); return }
        #expect(h.lock.currentHolder() == .app)
        #expect(await h.engine.localDeviceID == h.fake.myID)
        try await h.engine.start(context: .background)   // idempotent, switches profile
        try await h.engine.stop(deadline: .seconds(1))
        #expect(await h.engine.state == .stopped)
        #expect(h.lock.currentHolder() == nil)
        try await h.engine.stop(deadline: .seconds(1))  // idempotent
        #expect(h.bridge.callList.filter { $0 == "start" }.count == 1)
        #expect(h.bridge.callList.contains("applyMemoryProfile:160"))
        // Every blocking bridge call ran on the dedicated queue, never the cooperative pool.
        #expect(!h.bridge.labels.isEmpty)
        #expect(h.bridge.labels.allSatisfy { $0 == "app.psynguechthyngue.bridge" }, "\(h.bridge.labels)")
        var states: [EngineState] = []
        for await e in events {
            if case .engineStateChanged(let s) = e { states.append(s) }
            if states.last == .stopped { break }
        }
        #expect(states.first == .starting)
        #expect(states.contains(.stopping))
    }

    @Test func lockUnavailable() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.lock.available = false
        await #expect(throws: EngineError.lockUnavailable) { try await h.engine.start(context: .foreground) }
        #expect(h.bridge.callList.isEmpty)
    }

    @Test func startFailureReleasesLock() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.bridge.startError = TestBridgeError(message: "psy:listen: address in use")
        await #expect(throws: EngineError.bridge(code: "listen", detail: "address in use")) { try await h.engine.start(context: .foreground) }
        #expect(h.lock.currentHolder() == nil)
        #expect(await h.engine.state == .failed(code: "listen", detail: "address in use"))
    }

    @Test func stopTimeoutReleasesLockAndAllowsRestart() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        h.bridge.stopError = TestBridgeError(message: "psy:stop_timeout: keeps stopping in the background")
        await #expect(throws: EngineError.bridge(code: "stop_timeout", detail: "keeps stopping in the background")) {
            try await h.engine.stop(deadline: .milliseconds(10))
        }
        #expect(h.lock.currentHolder() == nil)   // never held across suspension (0xdead10cc)
        #expect(await h.engine.state == .failed(code: "stop_timeout", detail: "bridge(code: \"stop_timeout\", detail: \"keeps stopping in the background\")"))

        // The bridge finishes the shutdown in the background and its next
        // Start waits for it: the engine must not stay unusable.
        h.bridge.stopError = nil
        try await h.engine.start(context: .foreground)
        guard case .running = await h.engine.state else { Issue.record("not running after restart"); return }
        #expect(h.lock.currentHolder() == .app)
        #expect(h.bridge.callList.filter { $0 == "start" }.count == 2)
        try await h.engine.stop(deadline: .seconds(1))
        #expect(await h.engine.state == .stopped)
        #expect(h.lock.currentHolder() == nil)
    }

    @Test func stopAfterStopTimeoutIsANoOpThatClearsFailure() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        h.bridge.stopError = TestBridgeError(message: "psy:stop_timeout: slow")
        await #expect(throws: EngineError.self) { try await h.engine.stop(deadline: .milliseconds(10)) }
        h.bridge.stopError = nil
        try await h.engine.stop(deadline: .seconds(1))   // nothing left to stop
        #expect(await h.engine.state == .stopped)
        #expect(h.bridge.callList.filter { $0 == "stop" }.count == 1)
    }

    @Test func concurrentStartsAreSerialised() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<5 { g.addTask { try await h.engine.start(context: .foreground) } }
            try await g.waitForAll()
        }
        #expect(h.bridge.callList.filter { $0 == "start" }.count == 1)
        try await h.engine.stop(deadline: .seconds(1))
    }

    @Test func policyHoldNeverResumesUserPausedDevices() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let a = Device(id: DeviceIDCodec.random(), name: "a")
        let b = Device(id: DeviceIDCodec.random(), name: "b", paused: true)
        try await h.engine.addDevice(a)
        try await h.engine.addDevice(b)

        try await h.engine.apply(PolicyDecision(hold: .lowPowerMode))
        #expect(h.fake.device(a.id)?.paused == true)
        #expect(h.fake.device(h.fake.myID)?.paused == false)
        // UI still shows the user's intent.
        let shown = try await h.engine.devices()
        #expect(shown.first { $0.id == a.id }?.paused == false)
        #expect(shown.first { $0.id == b.id }?.paused == true)
        #expect(!shown.contains { $0.id == h.fake.myID })
        // A device added during the hold is held too.
        let c = Device(id: DeviceIDCodec.random(), name: "c")
        try await h.engine.addDevice(c)
        #expect(h.fake.device(c.id)?.paused == true)

        try await h.engine.apply(PolicyDecision(sendLimitKiBps: 64, receiveLimitKiBps: 256))
        #expect(h.fake.device(a.id)?.paused == false)
        #expect(h.fake.device(b.id)?.paused == true)
        #expect(h.fake.device(c.id)?.paused == false)
        #expect(h.fake.currentOptions == OptionsDTO(maxSendKbps: 64, maxRecvKbps: 256, listenAddresses: ["default"], globalAnnounceEnabled: true, relaysEnabled: true))

        // Hold persists across restart: decision stored, re-applied at start.
        try await h.engine.apply(PolicyDecision(hold: .thermal))
        try await h.engine.stop(deadline: .seconds(1))
        try await h.engine.apply(.run)   // stored while stopped
        try await h.engine.start(context: .foreground)
        #expect(h.fake.device(a.id)?.paused == false)
        #expect(h.fake.device(b.id)?.paused == true)
        #expect(h.fake.currentOptions == OptionsDTO(maxSendKbps: 0, maxRecvKbps: 0, listenAddresses: ["default"], globalAnnounceEnabled: true, relaysEnabled: true))
        try await h.engine.stop(deadline: .seconds(1))
    }

    @Test func onDemandFolderRules() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let id = FolderID(rawValue: "od")
        try await h.engine.addFolder(Folder(id: id, label: "OD", contentMode: .onDemand))
        let dir = AppGroupLayout(root: h.root).managedFolder(id)
        let stignore = try String(contentsOf: dir.appending(path: ".stignore"), encoding: .utf8)
        #expect(stignore.hasPrefix(IgnoreRulesGenerator.header))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: ".stignore-user").path(percentEncoded: false)))
        #expect(try await h.engine.folders().first?.contentMode == .onDemand)
        #expect(try await h.engine.folders().first?.location == .managed)

        // The fake serves ignores from its own store; seed it like upstream would after reading .stignore.
        let file = dir.appending(path: "docs/a.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        try await h.engine.setLocalPresence(id, paths: [RelativePath(rawValue: "docs/a.txt")], present: true)
        let reqs = StubURLProtocol.requests(authority: h.authority)
        #expect(reqs.contains { $0.path == "/rest/db/prio" && $0.query["file"] == "docs/a.txt" })
        // Already kept (Files asks for a file the engine is pulling): only
        // prioritized, no rule rewrite and no rescan.
        let writes = { StubURLProtocol.requests(authority: h.authority).filter { ($0.method == "POST" && $0.path == "/rest/db/ignores") || $0.path == "/rest/db/scan" }.count }
        let writesBefore = writes()
        try await h.engine.setLocalPresence(id, paths: [RelativePath(rawValue: "docs/a.txt")], present: true)
        #expect(writes() == writesBefore)
        try await h.engine.setLocalPresence(id, paths: [RelativePath(rawValue: "docs/a.txt")], present: false)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        await #expect(throws: EngineError.self) {
            try await h.engine.setLocalPresence(id, paths: [RelativePath(rawValue: "../escape")], present: false)
        }
        try await h.engine.stop(deadline: .seconds(1))
    }

    /// Regression (dynamic E2E): switching "Everything" → "On demand" kept
    /// whole top-level directories un-ignored, so their remote-only files
    /// (and everything added later) still downloaded. Directories holding a
    /// remote-only file are kept file by file; fully local ones get one rule
    /// (review: per-file rules made scans quadratic). The user's rules still
    /// round-trip through .stignore-user.
    @Test func switchingToOnDemandKeepsPresentFilesOnly() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let id = FolderID(rawValue: "sw")
        try await h.engine.addFolder(Folder(id: id, label: "SW", contentMode: .everything))
        let dir = AppGroupLayout(root: h.root).managedFolder(id)
        for rel in ["报告 1/子目录/a b.txt", "top.md", ".stfolder/x", "d/.syncthing.c.txt.tmp", "d/[x].txt"] {
            let f = dir.appending(path: rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: f)
        }
        try await h.engine.setUserIgnoreRules(id, ["*.tmp"])
        // "报告 1/子目录" also has a file that is not on this device.
        h.bridge.indexEntries = [GlobalIndexEntry(
            name: RelativePath(rawValue: "报告 1/子目录/remote.txt"), type: .file, size: 1, modified: Date(),
            deleted: false, invalid: false, sequence: 1, version: "v", blocksHash: "", localPresent: false)]
        var folder = try #require(try await h.engine.folders().first { $0.id == id })
        folder.contentMode = .onDemand
        try await h.engine.updateFolder(folder)

        let lines = h.fake.ignores["sw"] ?? []
        #expect(IgnoreRulesGenerator.isManaged(lines))
        #expect(IgnoreRulesGenerator.presentPaths(from: lines) == Set(["报告 1/子目录/a b.txt", "top.md", "d"].map(RelativePath.init(rawValue:))))
        #expect(!lines.contains("!/报告 1"))
        #expect(lines.last == "*")
        #expect(try await h.engine.userIgnoreRules(id) == ["*.tmp"])

        folder.contentMode = .everything
        try await h.engine.updateFolder(folder)
        #expect(try await h.engine.userIgnoreRules(id) == ["*.tmp"])
        try await h.engine.stop(deadline: .seconds(1))
    }

    /// Dynamic E2E: "Stop Syncing, Keep Files" then accepting the same folder
    /// again left the old on-demand `.stignore` in force: as "Everything" it
    /// downloaded nothing new yet looked up to date; as "On demand" the kept
    /// files became ignored.
    @Test func reAddingAKeptFolderMatchesTheChosenMode() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let id = FolderID(rawValue: "re")
        let dir = AppGroupLayout(root: h.root).managedFolder(id)
        try FileManager.default.createDirectory(at: dir.appending(path: "d"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appending(path: "d/kept.txt"))
        try Data((IgnoreRulesGenerator.fileContents(present: [RelativePath(rawValue: "old.txt")])).utf8)
            .write(to: dir.appending(path: ".stignore"))
        try Data("*.psd\n".utf8).write(to: dir.appending(path: IgnoreRulesGenerator.userFile))

        try await h.engine.addFolder(Folder(id: id, label: "RE", contentMode: .everything))
        let everything = try String(contentsOf: dir.appending(path: ".stignore"), encoding: .utf8)
        #expect(!IgnoreRulesGenerator.isManaged(LiveSyncEngine.splitLines(everything)))
        #expect(everything.contains("*.psd") && !everything.contains("\n*\n"))

        try await h.engine.addFolder(Folder(id: id, label: "RE", contentMode: .onDemand))
        let onDemand = LiveSyncEngine.splitLines(try String(contentsOf: dir.appending(path: ".stignore"), encoding: .utf8))
        #expect(IgnoreRulesGenerator.presentPaths(from: onDemand) == [RelativePath(rawValue: "d/kept.txt")])
        try await h.engine.stop(deadline: .seconds(1))
    }

    /// Report risk #1: paths excluded by the user's own rules were listed in
    /// Files. The index stream marks them — using the user's rules only, not
    /// the on-demand `*` (remote-only items must stay listed).
    @Test func indexMarksPathsExcludedByTheUsersOwnRules() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let id = FolderID(rawValue: "ui")
        try await h.engine.addFolder(Folder(id: id, label: "UI", contentMode: .onDemand))
        let dir = AppGroupLayout(root: h.root).managedFolder(id)
        try Data("*.skip\n".utf8).write(to: dir.appending(path: IgnoreRulesGenerator.userFile))
        func entry(_ p: String) -> GlobalIndexEntry {
            GlobalIndexEntry(name: RelativePath(rawValue: p), type: .file, size: 1, modified: Date(), deleted: false,
                             invalid: false, sequence: 1, version: "v", blocksHash: "", localPresent: false)
        }
        h.bridge.indexEntries = [entry("a.skip"), entry("b.txt")]
        var marked: [String: Bool] = [:]
        for try await page in h.engine.globalIndex(id, pageSize: 10) {
            for e in page { marked[e.name.rawValue] = e.userIgnored }
        }
        #expect(marked == ["a.skip": true, "b.txt": false])
        #expect(h.bridge.ignoreLinesSeen == ["*.skip"])   // never the managed `*`
        try await h.engine.stop(deadline: .seconds(1))
    }

    @Test func rejectsInvalidRequests() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        await #expect(throws: EngineError.notRunning) { try await h.engine.devices() }
        try await h.engine.start(context: .foreground)
        await #expect(throws: EngineError.self) { try await h.engine.addFolder(Folder(id: FolderID(rawValue: "../x"), label: "x")) }
        await #expect(throws: EngineError.self) {
            try await h.engine.addFolder(Folder(id: FolderID(rawValue: "e"), label: "e",
                                                location: .external(bookmark: Data(), displayPath: "/"), contentMode: .onDemand))
        }
        let pending = PendingFolder(folderID: FolderID(rawValue: "p"), label: "p", offeredBy: DeviceIDCodec.random(), receivedAt: Date())
        await #expect(throws: EngineError.self) { try await h.engine.acceptPendingFolder(pending, as: Folder(id: FolderID(rawValue: "q"), label: "q")) }
        await #expect(throws: EngineError.self) { try await h.engine.setLocalPresence(FolderID(rawValue: "none"), paths: [], present: true) }
        try await h.engine.stop(deadline: .seconds(1))
    }

    /// Real-device report: a paused folder showed "Size 0 KB, on this
    /// device 0 KB" with 435 MB on the device (upstream's summary is all zero
    /// for a paused folder); the DB counters still know.
    @Test func pausedFolderKeepsItsSizes() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        var state = FolderIndexState()
        state.globalFiles = 1059
        state.globalBytes = 553_100_000
        state.localBytes = 435_100_000
        h.bridge.indexState = state
        try await h.engine.start(context: .foreground)
        try await h.engine.addFolder(Folder(id: FolderID(rawValue: "f"), label: "f", paused: true))
        let paused = try await h.engine.folderStatus(FolderID(rawValue: "f"))
        #expect(paused.state == .paused)
        #expect(paused.progress.globalBytes == 553_100_000)
        #expect(paused.progress.localBytes == 435_100_000)
        #expect(paused.progress.globalItems == 1059)
        try await h.engine.stop(deadline: .seconds(1))
    }

    /// Part 8 (real device): "On this device" stood still while an on-demand
    /// folder downloaded, because upstream's counters move only when a file
    /// completes. Between refreshes the engine re-maps its last status with
    /// the bytes DownloadProgress reports, at most once per interval.
    @Test func liveStatusFollowsDownloadProgress() async throws {
        let h = try makeHarness { $0.liveProgressInterval = .milliseconds(300) }
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.fake.dbStatus = #"{"state":"syncing","globalBytes":1000,"localBytes":100,"needBytes":900,"needTotalItems":2}"#
        let id = FolderID(rawValue: "f")
        try await h.engine.start(context: .foreground)
        try await h.engine.addFolder(Folder(id: id, label: "f"))
        _ = try await h.engine.folderStatus(id)
        let collected = StatusLog()
        let events = h.engine.events()
        let reader = Task {
            for await e in events { if case .folderStatusChanged(let s) = e, s.folderID == id { collected.add(s) } }
        }
        defer { reader.cancel() }
        func progress(_ p: String, _ done: Int64, _ total: Int64) -> EventAction {
            .emit(.downloadProgress(folderID: id, path: RelativePath(rawValue: p), bytesDone: done, bytesTotal: total))
        }
        await h.engine.handle([progress("a", 50, 400)])
        try await waitUntil { collected.last?.progress.inProgressBytes == 50 }
        #expect(collected.last?.progress.bytesOnDevice == 150)
        let before = collected.count
        await h.engine.handle([progress("a", 150, 400)])
        await h.engine.handle([progress("a", 250, 400)])
        try await waitUntil { collected.last?.progress.inProgressBytes == 250 }
        #expect(collected.count == before + 1, "throttled to one status per interval")
        // The file completes; until the next REST read it counts as local.
        await h.engine.handle([.emit(.itemFinished(folderID: id, path: RelativePath(rawValue: "a"), error: nil)), progress("b", 10, 100)])
        try await waitUntil { collected.last?.progress.inProgressBytes == 10 }
        #expect(collected.last?.progress.localBytes == 500)
        #expect(collected.last?.progress.bytesOnDevice == 510)
        try await h.engine.stop(deadline: .seconds(1))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// Simulator acceptance found that conflict copies never reached the UI with
    /// the live engine: the engine now lists them from the global index.
    @Test func folderStatusListsConflictCopiesFromGlobalIndex() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        func entry(_ name: String, deleted: Bool = false) -> GlobalIndexEntry {
            GlobalIndexEntry(name: RelativePath(rawValue: name), type: .file, size: 1, modified: Date(timeIntervalSince1970: 7),
                             deleted: deleted, invalid: false, sequence: 1, version: "v", blocksHash: "h", localPresent: true)
        }
        h.bridge.indexEntries = [entry("notes.txt"), entry("notes.sync-conflict-20261122-001844-ABCDEFG.txt"),
                                 entry("gone.sync-conflict-20261122-001845-ABCDEFG.txt", deleted: true)]
        try await h.engine.start(context: .foreground)
        try await h.engine.addFolder(Folder(id: FolderID(rawValue: "f"), label: "f"))
        try await h.engine.stop(deadline: .seconds(1))
        try await h.engine.start(context: .foreground)   // conflict scan runs at start
        var issues: [SyncIssue] = []
        for _ in 0..<100 {
            issues = try await h.engine.folderStatus(FolderID(rawValue: "f")).issues
            if !issues.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(issues.map(\.kind) == [.conflict])
        #expect(issues.first?.path == RelativePath(rawValue: "notes.sync-conflict-20261122-001844-ABCDEFG.txt"))
        #expect(try await h.engine.folderStatus(FolderID(rawValue: "f")).conflictsChecked)
        try await h.engine.stop(deadline: .seconds(1))
    }

    /// A folder without conflict copies says so once its index was walked
    /// (the App drops records of deleted copies only from such a status).
    @Test func folderStatusMarksConflictsCheckedWithoutConflicts() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.bridge.indexEntries = [GlobalIndexEntry(name: RelativePath(rawValue: "notes.txt"), type: .file, size: 1,
                                                  modified: Date(timeIntervalSince1970: 7), deleted: false, invalid: false,
                                                  sequence: 1, version: "v", blocksHash: "h", localPresent: true)]
        try await h.engine.start(context: .foreground)
        try await h.engine.addFolder(Folder(id: FolderID(rawValue: "f"), label: "f"))
        try await h.engine.stop(deadline: .seconds(1))
        try await h.engine.start(context: .foreground)
        var status = try await h.engine.folderStatus(FolderID(rawValue: "f"))
        for _ in 0..<100 where !status.conflictsChecked {
            try await Task.sleep(for: .milliseconds(20))
            status = try await h.engine.folderStatus(FolderID(rawValue: "f"))
        }
        #expect(status.conflictsChecked)
        #expect(status.issues.isEmpty)
        try await h.engine.stop(deadline: .seconds(1))
    }

    @Test func globalIndexStreamsPages() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        do {
            var it = h.engine.globalIndex(FolderID(rawValue: "f"), pageSize: 10).makeAsyncIterator()
            await #expect(throws: EngineError.notRunning) { _ = try await it.next() }
        }
        try await h.engine.start(context: .foreground)
        var pages = 0
        for try await page in h.engine.globalIndex(FolderID(rawValue: "f"), pageSize: 10) {
            #expect(page.count == 1)
            pages += 1
        }
        #expect(pages == 3)
        try await h.engine.stop(deadline: .seconds(1))
    }
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [FolderStatus] = []
    func add(_ s: FolderStatus) { lock.withLock { list.append(s) } }
    var last: FolderStatus? { lock.withLock { list.last } }
    var count: Int { lock.withLock { list.count } }
}
