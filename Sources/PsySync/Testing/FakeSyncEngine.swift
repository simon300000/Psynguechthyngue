import Foundation

/// In-memory `SyncEngine` for UI development and XCUITest fixtures
/// (`-PsyUITestFixture`). Behaviour is deterministic; state is scriptable
/// through the `script*` helpers. Shipped in the PsySync target so the App can
/// link it in test builds.
public final class FakeSyncEngine: SyncEngine, @unchecked Sendable {
    public struct Scenario: Sendable {
        public var devices: [Device] = []
        public var connections: [DeviceConnection] = []
        public var folders: [Folder] = []
        public var statuses: [FolderStatus] = []
        public var pendingDevices: [PendingDevice] = []
        public var pendingFolders: [PendingFolder] = []
        /// Names devices report when they connect (upstream Hello): a device
        /// added with an empty name takes it, as upstream fills it in.
        public var reportedNames: [DeviceID: String] = [:]
        public var localDeviceID: DeviceID
        public init(localDeviceID: DeviceID) { self.localDeviceID = localDeviceID }
    }

    /// Valid (Luhn-32 checked) sample device IDs.
    public static let sampleIDs: [DeviceID] = [
        "UJZDEGX-DNCF32H-EPF3DHO-DZDOCIE-S2JHTLG-MXGEDNB-73U55XT-PLPFT7K",
        "V4SEH2K-VJ72CE5-UVW75EF-R6EDT4T-SYWB5WK-H7DNSIE-PZZ7FK4-ZRI3R2F",
        "WYOJFLJ-OOA7LQG-SAJ2XUI-D5ZZZZN-G6ZDMEN-4KHVDGL-AJGXBEN-YJQWX6F",
    ].map { DeviceID(rawValue: $0) }

    private let lock = NSLock()
    private var m: Mutable
    /// Simulated start latency (seconds) to exercise "starting" UI.
    public var startDelay: Duration = .zero
    public var stopDelay: Duration = .zero
    /// When set, the next `stop` takes the engine down but reports this error
    /// (e.g. `stop_timeout`), like a bridge whose Stop overran its deadline.
    public var nextStopFailure: EngineError?

    public init(scenario: Scenario) { self.m = Mutable(scenario: scenario) }

    public convenience init(named name: String = "empty") {
        self.init(scenario: Self.makeScenario(named: name))
    }

    // MARK: Scenarios

    public static func makeScenario(named name: String) -> Scenario {
        var s = Scenario(localDeviceID: sampleIDs[2])
        let now = Date()
        switch name {
        case "empty":
            break
        case "pending":
            s.pendingDevices = [PendingDevice(id: sampleIDs[1], name: "Anna's Laptop", address: "192.168.1.20:22000", firstSeen: now)]
            s.pendingFolders = [PendingFolder(folderID: FolderID(rawValue: "abcde-fghij"), label: "Photos", offeredBy: sampleIDs[0], receivedAt: now)]
            s.devices = [Device(id: sampleIDs[0], name: "Home Server")]
            s.connections = [DeviceConnection(deviceID: sampleIDs[0], state: .connected, transport: "tcp-lan", address: "192.168.1.5:22000", lastSeen: now)]
            // A device added by ID without a name (UI tests' new peer).
            s.reportedNames = [DeviceID(rawValue: "ZYMLOPI-FQYF7MF-2NXYNJ5-LVFF6U5-ZCRA3NX-F5M5DWO-INK4LLC-HBK62F5"): "Desk Mac"]
        case "pending-existing":
            // A second device offers a folder this device already shares with
            // another one (same folder ID), plus a repeated offer from a device
            // the folder is already shared with (not actionable).
            let shared = FolderID(rawValue: "shared-00001")
            s.devices = [Device(id: sampleIDs[0], name: "Home Server"), Device(id: sampleIDs[1], name: "Work Laptop")]
            s.connections = [
                DeviceConnection(deviceID: sampleIDs[0], state: .connected, transport: "tcp-client", address: "192.168.1.5:22000", lastSeen: now),
                DeviceConnection(deviceID: sampleIDs[1], state: .connected, transport: "tcp-client", address: "192.168.1.6:22000", lastSeen: now),
            ]
            s.folders = [Folder(id: shared, label: "Shared Notes", contentMode: .onDemand, devices: [sampleIDs[0]])]
            s.statuses = [FolderStatus(folderID: shared, state: .upToDate, progress: SyncProgress(globalBytes: 1000, localBytes: 1000, globalItems: 3), lastScan: now)]
            s.pendingFolders = [
                PendingFolder(folderID: shared, label: "Team Notes", offeredBy: sampleIDs[1], receivedAt: now),
                PendingFolder(folderID: shared, label: "Shared Notes", offeredBy: sampleIDs[0], receivedAt: now),
            ]
        default: // "populated", "errors", "conflicts"
            s.devices = [Device(id: sampleIDs[0], name: "Home Server"), Device(id: sampleIDs[1], name: "Work Laptop")]
            s.connections = [
                DeviceConnection(deviceID: sampleIDs[0], state: .connected, transport: "tcp-client", isLocalNetwork: true, address: "192.168.1.5:22000",
                                 clientVersion: "v2.1.6", lastSeen: now, inBytesTotal: 40_000_000, outBytesTotal: 10_000_000),
                DeviceConnection(deviceID: sampleIDs[1], state: .disconnected, lastSeen: now.addingTimeInterval(-3600 * 5)),
            ]
            s.folders = [
                Folder(id: FolderID(rawValue: "docum-ents1"), label: "Documents", devices: [sampleIDs[0], sampleIDs[1]]),
                Folder(id: FolderID(rawValue: "photo-s0001"), label: "Photos", contentMode: .onDemand, devices: [sampleIDs[0]]),
                Folder(id: FolderID(rawValue: "notes-00001"), label: "Notes", devices: [sampleIDs[1]]),
            ]
            s.statuses = [
                FolderStatus(folderID: s.folders[0].id, state: .upToDate, progress: SyncProgress(globalBytes: 5_000_000, localBytes: 5_000_000, remoteCompletion: [sampleIDs[0]: 100, sampleIDs[1]: 82], globalItems: 1_340), lastScan: now),
                FolderStatus(folderID: s.folders[1].id, state: .syncing, progress: SyncProgress(globalBytes: 800_000_000, localBytes: 300_000_000, needBytes: 500_000_000, needItems: 120), lastSyncedFile: RelativePath(rawValue: "2026/IMG_0042.heic")),
                FolderStatus(folderID: s.folders[2].id, state: name == "errors" ? .error : .waitingForDevices, progress: SyncProgress(globalBytes: 1000, localBytes: 900, needBytes: 100, needItems: 1),
                             issues: name == "errors" ? [SyncIssue(id: "e1", kind: .outOfSpace, folderID: s.folders[2].id, path: nil, technicalDetail: "write /x: no space left on device", occurredAt: now),
                                                         SyncIssue(id: "c1", kind: .conflict, folderID: s.folders[2].id, path: RelativePath(rawValue: "todo.sync-conflict-20261120-120000-ABCDEFG.txt"), technicalDetail: "conflict", occurredAt: now)] : []),
            ]
            if name == "conflicts" {
                // Several conflict copies in one folder, one in another (Home
                // ▸ Recent problems groups them per folder).
                s.statuses[2].state = .upToDate
                s.statuses[2].issues = Self.conflictIssues(s.folders[2].id, [
                    "todo.sync-conflict-20261120-120000-ABCDEFG.txt",
                    "plans/week.sync-conflict-20261121-090000-ABCDEFG.md",
                    "plans/week.sync-conflict-20261122-180000-HIJKLMN.md",
                ], now: now)
                s.statuses[0].issues = Self.conflictIssues(s.folders[0].id, [
                    "report.sync-conflict-20261123-100000-ABCDEFG.pdf",
                ], now: now)
            }
        }
        for i in s.statuses.indices { s.statuses[i].conflictsChecked = true }
        return s
    }

    private static func conflictIssues(_ folder: FolderID, _ paths: [String], now: Date) -> [SyncIssue] {
        paths.enumerated().map { n, path in
            SyncIssue(id: "\(folder.rawValue):conflict:\(path)", kind: .conflict, folderID: folder,
                      path: RelativePath(rawValue: path), technicalDetail: path, occurredAt: now.addingTimeInterval(-Double(n) * 60))
        }
    }

    // MARK: Scripting

    private struct Mutable {
        var scenario: Scenario
        var engineState: EngineState = .stopped
        var policy: PolicyDecision = .run
        var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
        var log: [String] = []
        var failNext: EngineError?
        var options = EngineOptions(deviceName: "iPhone")
        var userIgnores: [FolderID: [String]] = [:]
    }

    private func sync<T>(_ body: (inout Mutable) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&m) }

    public func script(_ body: (inout Scenario) -> Void) { sync { body(&$0.scenario) } }
    public func emit(_ event: EngineEvent) {
        let subs = sync { Array($0.subscribers.values) }
        for s in subs { s.yield(event) }
    }
    private func record(_ s: String) { sync { $0.log.append(s) } }
    private func setState(_ s: EngineState) { sync { $0.engineState = s }; emit(.engineStateChanged(s)) }
    public func scriptFailure(_ e: EngineError?) { sync { $0.failNext = e } }
    private func failIfScripted() throws {
        if let f = sync({ m -> EngineError? in let f = m.failNext; m.failNext = nil; return f }) { throw f }
    }
    public var recordedLog: [String] { sync { $0.log } }

    // MARK: Lifecycle

    /// Simulates a blocking bridge call on a dedicated thread (like the real
    /// `SyncthingBridge`), rather than a timer that the OS may coalesce in background.
    private static func blockOnThread(_ d: Duration) async {
        let micros = UInt32(d.components.seconds * 1_000_000 + d.components.attoseconds / 1_000_000_000_000)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread { usleep(micros); c.resume() }
        }
    }

    public func start(context: EngineRunContext) async throws {
        record("start:\(context.rawValue)")
        if case .running = sync({ $0.engineState }) { return }
        if case .failed = sync({ $0.engineState }) { record("restart-after-failure") }
        setState(.starting)
        if startDelay > .zero { await Self.blockOnThread(startDelay) }
        setState(.running(since: Date()))
    }

    public func stop(deadline: Duration) async throws {
        record("stop")
        if case .stopped = sync({ $0.engineState }) { return }
        setState(.stopping)
        if stopDelay > .zero { await Self.blockOnThread(stopDelay) }
        if let failure = nextStopFailure {
            nextStopFailure = nil
            setState(.failed(code: BridgeContract.Code.stopTimeout.rawValue, detail: "stop overran its deadline"))
            record("stop-failed")
            throw failure
        }
        setState(.stopped)
    }

    public var state: EngineState { get async { sync { $0.engineState } } }
    public var localDeviceID: DeviceID? { get async { sync { $0.scenario.localDeviceID } } }

    // MARK: Observation

    public func events() -> AsyncStream<EngineEvent> {
        let id = UUID()
        return AsyncStream { cont in
            sync { $0.subscribers[id] = cont }
            cont.onTermination = { [weak self] _ in self?.sync { $0.subscribers[id] = nil } }
        }
    }

    public func snapshot() async throws -> EngineStatus {
        sync { m in
            EngineStatus(state: m.engineState, localDeviceID: m.scenario.localDeviceID, policy: m.policy,
                         connectedDevices: m.scenario.connections.filter { $0.state == .connected }.count,
                         totalDevices: m.scenario.devices.count, folders: m.scenario.statuses)
        }
    }

    // MARK: Devices

    public func devices() async throws -> [Device] { sync { $0.scenario.devices } }
    public func connections() async throws -> [DeviceConnection] { sync { $0.scenario.connections } }

    public func addDevice(_ device: Device) async throws {
        try failIfScripted()
        record("addDevice:\(device.id.short)")
        let pend = sync { m -> [PendingDevice] in
            if !m.scenario.devices.contains(where: { $0.id == device.id }) {
                m.scenario.devices.append(device)
                m.scenario.connections.append(DeviceConnection(deviceID: device.id, state: .disconnected))
            }
            m.scenario.pendingDevices.removeAll { $0.id == device.id }
            return m.scenario.pendingDevices
        }
        emit(.pendingDevicesChanged(pend)); emit(.configurationChanged)
        if device.name.isEmpty, let reported = sync({ $0.scenario.reportedNames[device.id] }) {
            // The device "connects" and upstream stores the name it reports.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.sync { m in
                    if let i = m.scenario.devices.firstIndex(where: { $0.id == device.id }), m.scenario.devices[i].name.isEmpty {
                        m.scenario.devices[i].name = reported
                        if let c = m.scenario.connections.firstIndex(where: { $0.deviceID == device.id }) { m.scenario.connections[c].state = .connected }
                    }
                }
                self.emit(.configurationChanged)
            }
        }
    }

    public func updateDevice(_ device: Device) async throws {
        try failIfScripted()
        record("updateDevice:\(device.id.short)")
        // Like upstream's PATCH of an unknown device (404 → "rejected").
        guard sync({ m in m.scenario.devices.contains { $0.id == device.id } }) else {
            throw EngineError.rest(status: 404, body: "no such device")
        }
        sync { m in
            if let i = m.scenario.devices.firstIndex(where: { $0.id == device.id }) { m.scenario.devices[i] = device }
            if let i = m.scenario.connections.firstIndex(where: { $0.deviceID == device.id }) {
                if device.paused { m.scenario.connections[i].state = .paused }
                else if m.scenario.connections[i].state == .paused { m.scenario.connections[i].state = .disconnected }
            }
        }
        emit(.configurationChanged)
    }

    public func removeDevice(_ id: DeviceID) async throws {
        record("removeDevice:\(id.short)")
        sync { m in
            m.scenario.devices.removeAll { $0.id == id }
            m.scenario.connections.removeAll { $0.deviceID == id }
            for i in m.scenario.folders.indices { m.scenario.folders[i].devices.removeAll { $0 == id } }
        }
        emit(.configurationChanged)
    }

    public func pendingDevices() async throws -> [PendingDevice] { sync { $0.scenario.pendingDevices } }

    public func dismissPendingDevice(_ id: DeviceID) async throws {
        record("dismissPendingDevice:\(id.short)")
        let p = sync { m -> [PendingDevice] in m.scenario.pendingDevices.removeAll { $0.id == id }; return m.scenario.pendingDevices }
        emit(.pendingDevicesChanged(p))
    }

    // MARK: Folders

    public func folders() async throws -> [Folder] { sync { $0.scenario.folders } }
    public func folderStatus(_ id: FolderID) async throws -> FolderStatus {
        sync { m in m.scenario.statuses.first { $0.folderID == id } ?? FolderStatus(folderID: id, state: .upToDate, conflictsChecked: true) }
    }

    public func addFolder(_ folder: Folder) async throws {
        try failIfScripted()
        record("addFolder:\(folder.label):\(folder.contentMode.rawValue)")
        let status = FolderStatus(folderID: folder.id, state: .upToDate, conflictsChecked: true)
        sync { m in m.scenario.folders.append(folder); m.scenario.statuses.append(status) }
        emit(.configurationChanged); emit(.folderStatusChanged(status))
    }

    public func updateFolder(_ folder: Folder) async throws {
        try failIfScripted()
        record("updateFolder:\(folder.label)")
        let st: FolderStatus? = sync { m in
            if let i = m.scenario.folders.firstIndex(where: { $0.id == folder.id }) { m.scenario.folders[i] = folder }
            guard let i = m.scenario.statuses.firstIndex(where: { $0.folderID == folder.id }) else { return nil }
            if folder.paused { m.scenario.statuses[i].state = .paused }
            else if m.scenario.statuses[i].state == .paused { m.scenario.statuses[i].state = .upToDate }
            return m.scenario.statuses[i]
        }
        if let st { emit(.folderStatusChanged(st)) }
        emit(.configurationChanged)
    }

    public func removeFolder(_ id: FolderID, deleteLocalFiles: Bool) async throws {
        record("removeFolder:\(id.rawValue):\(deleteLocalFiles)")
        sync { m in m.scenario.folders.removeAll { $0.id == id }; m.scenario.statuses.removeAll { $0.folderID == id } }
        emit(.configurationChanged)
    }

    public func pendingFolders() async throws -> [PendingFolder] { sync { $0.scenario.pendingFolders } }

    public func acceptPendingFolder(_ pending: PendingFolder, as folder: Folder) async throws {
        let existing = sync { m in m.scenario.folders.first { $0.id == pending.folderID } }
        if let existing {
            // Like LiveSyncEngine: an existing folder only gains the device.
            record("joinPendingFolder:\(pending.label)")
            try await updateFolder(existing.sharing(with: pending.offeredBy))
        } else {
            record("acceptPendingFolder:\(pending.label):\(folder.contentMode.rawValue)")
            try await addFolder(folder.sharing(with: pending.offeredBy))
        }
        let p = sync { m -> [PendingFolder] in m.scenario.pendingFolders.removeAll { $0.id == pending.id }; return m.scenario.pendingFolders }
        emit(.pendingFoldersChanged(p))
    }

    public func dismissPendingFolder(_ pending: PendingFolder) async throws {
        record("dismissPendingFolder:\(pending.label)")
        let p = sync { m -> [PendingFolder] in m.scenario.pendingFolders.removeAll { $0.id == pending.id }; return m.scenario.pendingFolders }
        emit(.pendingFoldersChanged(p))
    }

    // MARK: Operations

    public func scan(_ folder: FolderID, paths: [RelativePath]?) async throws { record("scan:\(folder.rawValue)") }
    public func prioritize(_ folder: FolderID, path: RelativePath) async throws { record("prioritize:\(path.rawValue)") }
    public func setLocalPresence(_ folder: FolderID, paths: [RelativePath], present: Bool) async throws { record("presence:\(present)") }
    public func apply(_ decision: PolicyDecision) async throws {
        record("apply:\(decision.hold?.rawValue ?? "run"):\(decision.sendLimitKiBps)/\(decision.receiveLimitKiBps)"
               + (decision.reducedResourceUsage ? ":reduced" : ""))
        sync { $0.policy = decision }
    }
    public func globalIndex(_ folder: FolderID, pageSize: Int) -> AsyncThrowingStream<[GlobalIndexEntry], Error> {
        AsyncThrowingStream { $0.finish() }
    }

    // MARK: Settings

    public func options() async throws -> EngineOptions {
        try failIfScripted()
        return sync { $0.options }
    }
    public func updateOptions(_ options: EngineOptions) async throws {
        try failIfScripted()
        record("options:\(options.deviceName):\(options.globalDiscovery):\(options.relays)")
        sync { $0.options = options }
        emit(.configurationChanged)
    }
    public func userIgnoreRules(_ folder: FolderID) async throws -> [String] {
        try failIfScripted()
        return sync { $0.userIgnores[folder] ?? [] }
    }
    public func setUserIgnoreRules(_ folder: FolderID, _ lines: [String]) async throws {
        try failIfScripted()
        record("ignores:\(folder.rawValue):\(lines.count)")
        sync { $0.userIgnores[folder] = lines }
    }
    public var syncthingVersion: String { get async { "v2.1.6" } }

    // MARK: Statistics

    /// Counters grow at a fixed rate per connected device since the engine
    /// was created (Home Server: 1.5 MB/s down, 256 KB/s up), so the UI shows
    /// steady, deterministic rates.
    public static let fakeRate = TransferRate(inPerSecond: 1_500_000, outPerSecond: 256_000)
    private let createdAt = Date()

    public func traffic() async throws -> TrafficSample {
        try failIfScripted()
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(createdAt))
        let connected = sync { m in m.scenario.connections.filter { $0.state == .connected }.map(\.deviceID) }
        var devices: [DeviceID: DeviceTraffic] = [:]
        for (i, id) in connected.enumerated() {
            let base = Int64(40_000_000 * (i + 1))
            devices[id] = DeviceTraffic(inBytesTotal: base + Int64(Self.fakeRate.inPerSecond * elapsed),
                                        outBytesTotal: base / 4 + Int64(Self.fakeRate.outPerSecond * elapsed),
                                        connectionCount: 2)
        }
        return TrafficSample(at: now, inBytesTotal: devices.values.map(\.inBytesTotal).reduce(0, +),
                             outBytesTotal: devices.values.map(\.outBytesTotal).reduce(0, +), devices: devices)
    }

    public func folderDetails(_ id: FolderID) async throws -> FolderDetails {
        try failIfScripted()
        let status = try await folderStatus(id)
        let p = status.progress
        let files = max(1, p.globalItems > 0 ? p.globalItems * 9 / 10 : p.globalBytes / 400_000)
        let dirs = max(1, files / 12)
        let needFiles = min(files, p.needItems)
        return FolderDetails(
            global: .init(files: files, directories: dirs, deleted: files / 20, bytes: p.globalBytes),
            local: .init(files: files - needFiles, directories: dirs, deleted: files / 20, bytes: p.localBytes),
            needBytes: p.needBytes, needItems: p.needItems,
            lastScan: status.lastScan ?? createdAt.addingTimeInterval(-300),
            lastFile: status.lastSyncedFile ?? RelativePath(rawValue: "Notes/Shopping.txt"),
            lastFileAt: createdAt.addingTimeInterval(-120))
    }

    public func systemInfo() async throws -> EngineSystemInfo {
        try failIfScripted()
        return EngineSystemInfo(
            version: "v2.1.6", startedAt: createdAt, uptime: Date().timeIntervalSince(createdAt) + 3 * 3600 + 25 * 60,
            memoryAllocBytes: 38_000_000, memorySysBytes: 71_000_000, goroutines: 84,
            listeners: [
                .init(address: "dynamic+https://relays.syncthing.net/endpoint", wanAddresses: ["relay://203.0.113.7:22067"]),
                .init(address: "quic://0.0.0.0:22000", lanAddresses: ["quic://192.168.1.23:22000"], wanAddresses: ["quic://198.51.100.4:22000"]),
                .init(address: "tcp://0.0.0.0:22000", lanAddresses: ["tcp://192.168.1.23:22000"], wanAddresses: ["tcp://198.51.100.4:22000"]),
            ],
            discoveryEnabled: true,
            discovery: [.init(method: "IPv4 local"), .init(method: "IPv6 local"),
                        .init(method: "global@https://discovery.syncthing.net/v2/")])
    }
}
