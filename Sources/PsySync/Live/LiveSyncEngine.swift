import Foundation

public struct LiveSyncEngineConfiguration: Sendable {
    public var layout: AppGroupLayout
    public var deviceName: String
    /// Wait for the File Provider's restricted fetch to yield (DESIGN.md §4.1).
    public var lockTimeout: Duration = .seconds(5)
    public var startTimeout: Duration = LifecycleBudget.foregroundStartTimeout
    /// iOS has no FSEvents; the bridge disables the watcher there. New folders
    /// are created with this value (true only for Mac/E2E).
    public var fsWatcherEnabled: Bool = false
    public var externalAccess: ExternalLocationAccess = .system
    public var sessionConfiguration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    public var folderRefreshDebounce: Duration = .milliseconds(250)
    public var eventPollTimeoutSeconds: Int = 50
    /// Move the sync listener off 22000 even when it looks free (Mac: the
    /// official Syncthing may start later and would share it via SO_REUSEPORT).
    public var preferAlternateListenPort: Bool = ProcessInfo.processInfo.isiOSAppOnMac
    /// Port availability probe (tests inject a fake).
    public var portProbe: @Sendable (Int) -> Bool = ListenAddressPlanner.isPortFree

    public init(layout: AppGroupLayout, deviceName: String) {
        self.layout = layout
        self.deviceName = deviceName
    }
}

/// `SyncEngine` over the gomobile bridge (lifecycle only) + Syncthing REST
/// (everything else) + `/rest/events` long-poll (DESIGN.md §3, §5).
///
/// Concurrency: actor-isolated state; every blocking call (bridge, Keychain)
/// goes through `BridgeExecutor` (dedicated GCD queue). REST is URLSession
/// async. Lifecycle transitions (start/stop) are serialised.
public actor LiveSyncEngine: SyncEngine {
    private let bridge: any SyncthingBridge
    private let lock: any EngineLock
    private let identityStore: any IdentityStoring
    private let config: LiveSyncEngineConfiguration
    private let executor = BridgeExecutor()
    private let broadcaster = EventBroadcaster()

    private var engineState: EngineState = .stopped
    private var lease: (any EngineLockLease)?
    private var client: SyncthingRESTClient?
    private var pump: EventPump?
    private var myID: DeviceID?
    private var appState = LiveEngineAppState()
    private var externalScopes: [FolderID: ExternalLocationScope] = [:]
    private var transition: Task<Void, Error>?
    private var bridgeStarted = false

    private var pendingRefresh: Set<FolderID> = []
    private var refreshAll = false
    private var refreshTask: Task<Void, Never>?
    private var inProgress: [FolderID: [RelativePath: Int64]] = [:]

    public init(
        bridge: any SyncthingBridge,
        lock: any EngineLock,
        identityStore: any IdentityStoring,
        configuration: LiveSyncEngineConfiguration
    ) {
        self.bridge = bridge
        self.lock = lock
        self.identityStore = identityStore
        self.config = configuration
    }

    // MARK: Lifecycle

    public func start(context: EngineRunContext) async throws {
        try await serialized { try await $0.doStart(context) }
    }

    public func stop(deadline: Duration) async throws {
        try await serialized { try await $0.doStop(deadline) }
    }

    public var state: EngineState { engineState }

    public var localDeviceID: DeviceID? {
        get async {
            if let myID { return myID }
            let store = identityStore
            return try? await executor.run { try store.load()?.deviceID }
        }
    }

    private func serialized(_ body: @escaping @Sendable (isolated LiveSyncEngine) async throws -> Void) async throws {
        let previous = transition
        let task = Task<Void, Error> {
            _ = try? await previous?.value
            try await body(self)
        }
        transition = task
        try await task.value
    }

    private func setState(_ s: EngineState) {
        guard s != engineState else { return }
        engineState = s
        broadcaster.yield(.engineStateChanged(s))
    }

    private func doStart(_ context: EngineRunContext) async throws {
        let profile = context == .foreground ? MemoryProfile.foreground : MemoryProfile.background
        if case .running = engineState {
            let bridge = bridge
            try await executor.run { bridge.applyMemoryProfile(profile) }
            return
        }
        if lease != nil {
            // Previous run failed while holding the lock (engine exited); clean up first.
            try? await doStop(.seconds(5))
        }
        setState(.starting)
        guard let lease = await lock.acquire(owner: .app, timeout: config.lockTimeout) else {
            setState(.failed(code: "lock_unavailable", detail: "engine lock held by another process"))
            throw EngineError.lockUnavailable
        }
        self.lease = lease
        do {
            let home = config.layout.engineHome
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: config.layout.foldersRoot, withIntermediateDirectories: true)
            appState = LiveEngineAppState.load(from: home)
            openExternalScopes()

            let bridge = bridge, store = identityStore, name = config.deviceName, timeout = config.startTimeout
            let storedPort = appState.listenPort, preferAlternate = config.preferAlternateListenPort, probe = config.portProbe
            let (endpoint, listenPort) = try await executor.run { () throws -> (RESTEndpoint, Int?) in
                // Probe before our own engine binds 22000.
                let port = ListenAddressPlanner.alternatePort(
                    stored: storedPort,
                    defaultFree: storedPort != nil || probe(ListenAddressPlanner.defaultPort),
                    preferAlternate: preferAlternate, isFree: probe)
                bridge.applyMemoryProfile(profile)
                let identity: DeviceIdentity
                if let existing = try store.load() {
                    identity = existing
                } else {
                    identity = try bridge.generateIdentity()
                    try store.save(identity)
                }
                return (try bridge.start(homeDirectory: home, identity: identity, deviceName: name, timeout: timeout), port)
            }
            bridgeStarted = true
            guard Self.isLoopback(endpoint.baseURL) else {
                throw EngineError.bridge(code: BridgeContract.Code.listen.rawValue, detail: "REST endpoint is not on loopback")
            }
            let client = SyncthingRESTClient(endpoint: endpoint, configuration: config.sessionConfiguration())
            try await waitForREST(client)
            self.client = client
            myID = endpoint.deviceID
            setState(.running(since: Date()))
            startPump(client)
            if let listenPort { try? await applyListenPort(listenPort, client) }
            try? await reconcilePolicy()
            scheduleRefresh(nil)
        } catch {
            let mapped = Self.map(error)
            await teardown(stopDeadline: .seconds(5))
            if case .bridge(let code, let detail) = mapped {
                setState(.failed(code: code, detail: detail))
            } else {
                setState(.failed(code: "start_failed", detail: "\(mapped)"))
            }
            throw mapped
        }
    }

    /// Persists the alternate sync port in config.xml (`listenAddresses`,
    /// applied live by upstream) and in the app state.
    private func applyListenPort(_ port: Int, _ client: SyncthingRESTClient) async throws {
        let current = try await client.options().listenAddresses ?? ["default"]
        if let rewritten = ListenAddressPlanner.rewrite(current, port: port) {
            try await client.send("PATCH", "rest/config/options", json: ListenOptionsDTO(listenAddresses: rewritten))
        }
        if appState.listenPort != port {
            appState.listenPort = port
            try saveAppState()
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    private func waitForREST(_ client: SyncthingRESTClient) async throws {
        var lastError: Error = EngineError.notRunning
        for _ in 0..<50 {
            do { try await client.ping(); return } catch { lastError = error }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw lastError
    }

    private func doStop(_ deadline: Duration) async throws {
        guard lease != nil || bridgeStarted else {
            if case .failed = engineState { setState(.stopped) }
            return
        }
        setState(.stopping)
        let failure = await teardown(stopDeadline: deadline)
        if let failure {
            setState(.failed(code: BridgeContract.Code.stopTimeout.rawValue, detail: "\(failure)"))
            throw failure
        }
        setState(.stopped)
    }

    /// Stops pump, bridge, scopes and releases the lock. Returns a stop error
    /// if the bridge did not stop in time (state `.failed(stop_timeout)`; a
    /// later `start` is still allowed).
    @discardableResult
    private func teardown(stopDeadline: Duration) async -> EngineError? {
        pump?.cancel()
        pump = nil
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefresh = []
        refreshAll = false
        inProgress = [:]
        client = nil
        var failure: EngineError?
        if bridgeStarted {
            let bridge = bridge
            do {
                try await executor.run { try bridge.stop(timeout: stopDeadline) }
            } catch {
                let mapped = Self.map(error)
                if case .bridge(let code, _) = mapped, code == BridgeContract.Code.notRunning.rawValue {
                    // already gone
                } else {
                    // stop_timeout: the bridge keeps shutting down in the
                    // background and its next Start waits for that (WP-A
                    // 6261e01), so the process is not poisoned: a later
                    // `start` is allowed and simply takes longer.
                    failure = mapped
                }
            }
            bridgeStarted = false
        }
        // Even after a stop timeout the lock is released: holding it while
        // suspended gets the process killed (0xdead10cc).
        lease?.release()
        lease = nil
        for scope in externalScopes.values { scope.stop() }
        externalScopes = [:]
        return failure
    }

    private func openExternalScopes() {
        var changed = false
        for (id, attrs) in appState.folders {
            guard let bookmark = attrs.bookmark, externalScopes[FolderID(rawValue: id)] == nil else { continue }
            guard let scope = try? ExternalLocation.open(bookmark: bookmark, access: config.externalAccess) else { continue }
            externalScopes[FolderID(rawValue: id)] = scope
            if let fresh = scope.refreshedBookmark {
                appState.folders[id]?.bookmark = fresh
                changed = true
            }
        }
        if changed { try? appState.save(to: config.layout.engineHome) }
    }

    private func startPump(_ client: SyncthingRESTClient) {
        pump = EventPump(
            client: client,
            pollTimeout: config.eventPollTimeoutSeconds,
            handle: { [weak self] actions in await self?.handle(actions) },
            onUnreachable: { [weak self] error in await self?.engineUnreachable(error) }
        )
    }

    private func engineUnreachable(_ error: EngineError) {
        guard case .running = engineState else { return }
        setState(.failed(code: "engine_unreachable", detail: "\(error)"))
    }

    // MARK: Events

    public nonisolated func events() -> AsyncStream<EngineEvent> {
        broadcaster.stream()
    }

    func handle(_ actions: [EventAction]) async {
        for action in actions {
            switch action {
            case .emit(let event):
                track(event)
                broadcaster.yield(event)
            case .refreshPendingDevices:
                if let list = try? await pendingDevices() { broadcaster.yield(.pendingDevicesChanged(list)) }
            case .refreshPendingFolders:
                if let list = try? await pendingFolders() { broadcaster.yield(.pendingFoldersChanged(list)) }
            case .refreshFolder(let id):
                scheduleRefresh([id])
            case .refreshAllFolders:
                scheduleRefresh(nil)
            }
        }
    }

    private func track(_ event: EngineEvent) {
        switch event {
        case .downloadProgress(let f, let p, let done, _):
            inProgress[f, default: [:]][p] = done
        case .itemFinished(let f, let p, _):
            inProgress[f]?[p] = nil
        default:
            break
        }
    }

    private func scheduleRefresh(_ ids: Set<FolderID>?) {
        if let ids { pendingRefresh.formUnion(ids) } else { refreshAll = true }
        guard refreshTask == nil else { return }
        let debounce = config.folderRefreshDebounce
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            await self?.flushRefresh()
        }
    }

    private func flushRefresh() async {
        refreshTask = nil
        guard let client, case .running = engineState else { return }
        var ids = pendingRefresh
        if refreshAll, let folders = try? await client.configFolders() {
            ids.formUnion(folders.map { FolderID(rawValue: $0.id) })
        }
        pendingRefresh = []
        refreshAll = false
        for id in ids.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let status = try? await folderStatus(id) {
                broadcaster.yield(.folderStatusChanged(status))
            }
        }
    }

    // MARK: Snapshot

    public func snapshot() async throws -> EngineStatus {
        guard let client, case .running = engineState else {
            return EngineStatus(state: engineState, localDeviceID: await localDeviceID, policy: appState.decision,
                                connectedDevices: 0, totalDevices: 0, folders: [])
        }
        let devices = try await client.configDevices().filter { $0.deviceID != myID?.rawValue }
        let conns = try await client.connections().connections
        let connected = devices.filter { conns[$0.deviceID]?.connected == true }.count
        var statuses: [FolderStatus] = []
        for f in try await client.configFolders() {
            statuses.append(try await folderStatus(FolderID(rawValue: f.id)))
        }
        return EngineStatus(state: engineState, localDeviceID: myID, policy: appState.decision,
                            connectedDevices: connected, totalDevices: devices.count, folders: statuses)
    }

    private func requireClient() throws -> SyncthingRESTClient {
        guard let client, case .running = engineState else { throw EngineError.notRunning }
        return client
    }

    // MARK: Devices

    public func devices() async throws -> [Device] {
        let client = try requireClient()
        return try await client.configDevices()
            .filter { $0.deviceID != myID?.rawValue }
            .map { dto in
                Device(
                    id: DeviceID(rawValue: dto.deviceID),
                    name: dto.name,
                    addresses: dto.addresses,
                    paused: dto.paused && !appState.policyPausedDevices.contains(dto.deviceID),
                    introducer: dto.introducer,
                    autoAcceptFolders: dto.autoAcceptFolders
                )
            }
    }

    public func connections() async throws -> [DeviceConnection] {
        let client = try requireClient()
        async let devicesTask = client.configDevices()
        async let connsTask = client.connections()
        let stats = (try? await client.deviceStats()) ?? [:]
        let devices = try await devicesTask
        let conns = try await connsTask.connections
        return devices.filter { $0.deviceID != myID?.rawValue }.map { dto in
            let c = conns[dto.deviceID]
            let state: DeviceConnection.State = (c?.paused ?? dto.paused) ? .paused : (c?.connected == true ? .connected : .disconnected)
            return DeviceConnection(
                deviceID: DeviceID(rawValue: dto.deviceID),
                state: state,
                transport: c?.connected == true ? c?.type : nil,
                address: c?.connected == true ? c?.address : nil,
                clientVersion: c?.connected == true ? c?.clientVersion : nil,
                lastSeen: SyncthingDate.parseNonZero(stats[dto.deviceID]?.lastSeen),
                inBytesTotal: c?.inBytesTotal ?? 0,
                outBytesTotal: c?.outBytesTotal ?? 0
            )
        }
    }

    public func addDevice(_ device: Device) async throws {
        let client = try requireClient()
        var dto = DeviceConfigDTO(
            deviceID: device.id.rawValue, name: device.name, addresses: device.addresses.isEmpty ? ["dynamic"] : device.addresses,
            paused: device.paused, introducer: device.introducer, autoAcceptFolders: device.autoAcceptFolders
        )
        if appState.decision.hold != nil && !device.paused {
            dto.paused = true
            appState.policyPausedDevices.insert(device.id.rawValue)
            try saveAppState()
        }
        try await client.send("POST", "rest/config/devices", json: dto)
    }

    public func updateDevice(_ device: Device) async throws {
        let client = try requireClient()
        var paused = device.paused
        let id = device.id.rawValue
        if appState.policyPausedDevices.contains(id) {
            if device.paused {
                // The user now wants it paused: it is no longer ours to resume.
                appState.policyPausedDevices.remove(id)
                try saveAppState()
            } else {
                paused = true   // stays paused until the hold ends
            }
        } else if appState.decision.hold != nil && !device.paused {
            appState.policyPausedDevices.insert(id)
            try saveAppState()
            paused = true
        }
        struct Patch: Encodable { var name: String; var addresses: [String]; var paused: Bool; var introducer: Bool; var autoAcceptFolders: Bool }
        try await client.send("PATCH", "rest/config/devices/\(Self.pathEscape(id))", json: Patch(
            name: device.name, addresses: device.addresses.isEmpty ? ["dynamic"] : device.addresses, paused: paused,
            introducer: device.introducer, autoAcceptFolders: device.autoAcceptFolders
        ))
    }

    public func removeDevice(_ id: DeviceID) async throws {
        let client = try requireClient()
        guard id != myID else { throw EngineError.invalidArgument("cannot remove the local device") }
        try await client.send("DELETE", "rest/config/devices/\(Self.pathEscape(id.rawValue))")
        if appState.policyPausedDevices.remove(id.rawValue) != nil { try saveAppState() }
    }

    public func pendingDevices() async throws -> [PendingDevice] {
        let client = try requireClient()
        return try await client.pendingDevices()
            .map { PendingDevice(id: DeviceID(rawValue: $0.key), name: $0.value.name, address: $0.value.address, firstSeen: $0.value.time) }
            .sorted { $0.firstSeen < $1.firstSeen }
    }

    public func dismissPendingDevice(_ id: DeviceID) async throws {
        let client = try requireClient()
        try await client.send("DELETE", "rest/cluster/pending/devices", query: [.init(name: "device", value: id.rawValue)])
    }

    // MARK: Folders

    public func folders() async throws -> [Folder] {
        let client = try requireClient()
        return try await client.configFolders().map(makeFolder)
    }

    private func makeFolder(_ dto: FolderConfigDTO) -> Folder {
        let id = FolderID(rawValue: dto.id)
        let attrs = appState.folders[dto.id]
        let location: FolderLocation
        if Self.samePath(dto.path, config.layout.managedFolder(id)) {
            location = .managed
        } else {
            location = .external(bookmark: attrs?.bookmark ?? Data(), displayPath: attrs?.displayPath ?? dto.path)
        }
        return Folder(
            id: id,
            label: dto.label,
            type: FolderType(rawValue: dto.type) ?? .receiveOnly,   // receiveencrypted → read-only for UI purposes
            location: location,
            contentMode: attrs?.contentMode ?? .everything,
            devices: dto.devices.map { DeviceID(rawValue: $0.deviceID) }.filter { $0 != myID },
            paused: dto.paused
        )
    }

    private func folderConfig(_ id: FolderID) async throws -> FolderConfigDTO {
        let client = try requireClient()
        do {
            return try await client.get("rest/config/folders/\(Self.pathEscape(id.rawValue))")
        } catch EngineError.rest(status: 404, _) {
            throw EngineError.invalidArgument("unknown folder \(id.rawValue)")
        }
    }

    public func folderStatus(_ id: FolderID) async throws -> FolderStatus {
        let client = try requireClient()
        let folder = try await folderConfig(id)
        async let statusTask = client.dbStatus(id.rawValue)
        async let errorsTask = client.folderErrors(id.rawValue)
        async let connsTask = client.connections()
        let stats: [String: FolderStatsDTO] = (try? await client.get("rest/stats/folder")) ?? [:]
        let conns = try await connsTask.connections
        let peers = folder.devices.map(\.deviceID).filter { $0 != myID?.rawValue }
        let remotes = try await withThrowingTaskGroup(of: (String, CompletionDTO?).self) { group in
            for peer in peers {
                group.addTask { (peer, try? await client.completion(id.rawValue, device: peer)) }
            }
            var out: [DeviceID: FolderStatusInputs.RemoteCompletion] = [:]
            for try await (peer, c) in group {
                let connected = conns[peer]?.connected == true && conns[peer]?.paused != true
                out[DeviceID(rawValue: peer)] = .init(completion: c?.completion ?? 0, remoteState: c?.remoteState ?? "unknown", connected: connected)
            }
            return out
        }
        let status = try await statusTask
        let errors = (try? await errorsTask) ?? []
        let inputs = FolderStatusInputs(
            folderID: id,
            engineRunning: true,
            folderPaused: folder.paused,
            policyHeld: appState.decision.hold != nil,
            upstreamState: status.state,
            upstreamError: status.error ?? "",
            globalBytes: status.globalBytes,
            localBytes: status.localBytes,
            needBytes: status.needBytes,
            needItems: status.needTotalItems,
            inProgressBytes: inProgress[id]?.values.reduce(0, +) ?? 0,
            remotes: remotes,
            folderErrors: errors.map { .init(path: $0.path, error: $0.error) },
            stateChanged: SyncthingDate.parseNonZero(status.stateChanged)
        )
        var result = StatusMapper.map(inputs)
        if let s = stats[id.rawValue] {
            result.lastScan = SyncthingDate.parseNonZero(s.lastScan)
            if let name = s.lastFile?.filename, !name.isEmpty { result.lastSyncedFile = RelativePath(rawValue: name) }
        }
        return result
    }

    public func addFolder(_ folder: Folder) async throws {
        let client = try requireClient()
        try Self.validateFolderID(folder.id)
        let path: String
        var attrs = LiveEngineAppState.FolderAttributes(contentMode: folder.contentMode)
        switch folder.location {
        case .managed:
            let dir = config.layout.managedFolder(folder.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.standardizedFileURL.path(percentEncoded: false)
            if folder.contentMode == .onDemand {
                try writeOnDemandRulesToDisk(dir, present: [])
            }
        case .external(let bookmark, let displayPath):
            guard folder.contentMode == .everything else {
                throw EngineError.invalidArgument("external folders cannot be on-demand")
            }
            let scope: ExternalLocationScope
            do {
                scope = try ExternalLocation.open(bookmark: bookmark, access: config.externalAccess)
            } catch {
                throw EngineError.invalidArgument("external location: \(error)")
            }
            externalScopes[folder.id]?.stop()
            externalScopes[folder.id] = scope
            path = scope.path
            attrs.bookmark = scope.refreshedBookmark ?? bookmark
            attrs.displayPath = displayPath
        }
        appState.folders[folder.id.rawValue] = attrs
        try saveAppState()
        let dto = FolderConfigDTO(
            id: folder.id.rawValue, label: folder.label, path: path, type: folder.type.rawValue,
            devices: folder.devices.filter { $0 != myID }.map { FolderDeviceDTO(deviceID: $0.rawValue) },
            paused: folder.paused, fsWatcherEnabled: config.fsWatcherEnabled, rescanIntervalS: nil
        )
        do {
            try await client.send("POST", "rest/config/folders", json: dto)
        } catch {
            appState.folders[folder.id.rawValue] = nil
            try? saveAppState()
            throw error
        }
    }

    public func updateFolder(_ folder: Folder) async throws {
        let client = try requireClient()
        let existing = try await folderConfig(folder.id)
        let current = makeFolder(existing)
        switch (current.location, folder.location) {
        case (.managed, .managed): break
        case (.external(_, _), .external(_, _)): break
        default: throw EngineError.invalidArgument("folder location cannot change")
        }
        if folder.contentMode != current.contentMode {
            guard current.location == .managed else { throw EngineError.invalidArgument("external folders cannot be on-demand") }
            let dir = config.layout.managedFolder(folder.id)
            switch folder.contentMode {
            case .onDemand:
                // Keep what is already local; everything else becomes on-demand.
                let present = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)))?
                    .filter { !$0.hasPrefix(".st") && !$0.hasPrefix(".stignore") }
                    .map(RelativePath.init(rawValue:)) ?? []
                try await client.setIgnores(folder.id.rawValue, lines: try IgnoreRulesGenerator.lines(present: present))
            case .everything:
                try await client.setIgnores(folder.id.rawValue, lines: [IgnoreRulesGenerator.includeLine])
            }
            appState.folders[folder.id.rawValue, default: .init(contentMode: folder.contentMode)].contentMode = folder.contentMode
            try saveAppState()
        }
        struct Patch: Encodable { var label: String; var type: String; var devices: [FolderDeviceDTO]; var paused: Bool }
        try await client.send("PATCH", "rest/config/folders/\(Self.pathEscape(folder.id.rawValue))", json: Patch(
            label: folder.label, type: folder.type.rawValue,
            devices: folder.devices.filter { $0 != myID }.map { FolderDeviceDTO(deviceID: $0.rawValue) },
            paused: folder.paused
        ))
    }

    public func removeFolder(_ id: FolderID, deleteLocalFiles: Bool) async throws {
        let client = try requireClient()
        let existing = try await folderConfig(id)
        let managed = Self.samePath(existing.path, config.layout.managedFolder(id))
        try await client.send("DELETE", "rest/config/folders/\(Self.pathEscape(id.rawValue))")
        appState.folders[id.rawValue] = nil
        try saveAppState()
        externalScopes.removeValue(forKey: id)?.stop()
        inProgress[id] = nil
        if deleteLocalFiles && managed {
            let dir = config.layout.managedFolder(id)
            guard Self.isContained(dir, in: config.layout.foldersRoot) else {
                throw EngineError.invalidArgument("refusing to delete outside Folders/")
            }
            if FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: dir)
            }
        }
    }

    public func pendingFolders() async throws -> [PendingFolder] {
        let client = try requireClient()
        var out: [PendingFolder] = []
        for (folderID, entry) in try await client.pendingFolders() {
            for (device, offer) in entry.offeredBy {
                out.append(PendingFolder(folderID: FolderID(rawValue: folderID), label: offer.label,
                                         offeredBy: DeviceID(rawValue: device), receivedAt: offer.time))
            }
        }
        return out.sorted { ($0.receivedAt, $0.id) < ($1.receivedAt, $1.id) }
    }

    public func acceptPendingFolder(_ pending: PendingFolder, as folder: Folder) async throws {
        guard folder.id == pending.folderID else {
            throw EngineError.invalidArgument("folder ID must match the offered folder")
        }
        var folder = folder
        if !folder.devices.contains(pending.offeredBy) { folder.devices.append(pending.offeredBy) }
        try await addFolder(folder)
    }

    public func dismissPendingFolder(_ pending: PendingFolder) async throws {
        let client = try requireClient()
        try await client.send("DELETE", "rest/cluster/pending/folders", query: [
            .init(name: "folder", value: pending.folderID.rawValue),
            .init(name: "device", value: pending.offeredBy.rawValue),
        ])
    }

    // MARK: Operations

    public func scan(_ folder: FolderID, paths: [RelativePath]?) async throws {
        let client = try requireClient()
        guard let paths else {
            try await client.send("POST", "rest/db/scan", query: [.init(name: "folder", value: folder.rawValue)], timeout: 600)
            return
        }
        for p in paths {
            try await client.send("POST", "rest/db/scan", query: [
                .init(name: "folder", value: folder.rawValue), .init(name: "sub", value: p.rawValue),
            ], timeout: 600)
        }
    }

    public func prioritize(_ folder: FolderID, path: RelativePath) async throws {
        let client = try requireClient()
        try await client.send("POST", "rest/db/prio", query: [
            .init(name: "folder", value: folder.rawValue), .init(name: "file", value: path.rawValue),
        ])
    }

    public func setLocalPresence(_ folder: FolderID, paths: [RelativePath], present: Bool) async throws {
        let client = try requireClient()
        guard appState.folders[folder.rawValue]?.contentMode == .onDemand else {
            throw EngineError.invalidArgument("folder is not on-demand")
        }
        let existing = try await folderConfig(folder)
        let root = URL(filePath: existing.path, directoryHint: .isDirectory)
        var current = IgnoreRulesGenerator.presentPaths(from: try await client.ignores(folder.rawValue))
        for p in paths {
            do { _ = try IgnoreRulesGenerator.pattern(for: p) } catch {
                throw EngineError.invalidArgument("path cannot be expressed as an ignore rule: \(p.rawValue)")
            }
            if present {
                current.insert(p)
            } else {
                current = current.filter { $0 != p && !$0.rawValue.hasPrefix(p.rawValue + "/") }
            }
        }
        try await client.setIgnores(folder.rawValue, lines: try IgnoreRulesGenerator.lines(present: current))
        if !present {
            // Rules first, then delete: an ignored file's deletion is not propagated.
            for p in paths {
                let target = root.appending(path: p.rawValue)
                guard Self.isContained(target, in: root) else { throw EngineError.invalidArgument("path escapes folder") }
                if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: target)
                }
            }
        }
        try await scan(folder, paths: paths)
        if present {
            for p in paths { try? await prioritize(folder, path: p) }
        }
    }

    private func writeOnDemandRulesToDisk(_ dir: URL, present: [RelativePath]) throws {
        let user = dir.appending(path: IgnoreRulesGenerator.userFile)
        if !FileManager.default.fileExists(atPath: user.path(percentEncoded: false)) {
            try Data().write(to: user, options: .atomic)
        }
        try Data(IgnoreRulesGenerator.fileContents(present: present).utf8).write(to: dir.appending(path: ".stignore"), options: .atomic)
    }

    /// Reduced-load mode: one folder at a time and limits on LAN too; the
    /// previous values are saved once and restored when the mode ends.
    private func reconcileLoad(_ decision: PolicyDecision, _ options: OptionsDTO) async throws {
        let client = try requireClient()
        let current = LiveEngineAppState.SavedLoadOptions(
            maxFolderConcurrency: options.maxFolderConcurrency ?? 0,
            limitBandwidthInLan: options.limitBandwidthInLan ?? false)
        let target: LiveEngineAppState.SavedLoadOptions?
        if decision.reducedResourceUsage && decision.hold == nil {
            if appState.savedLoadOptions == nil {
                appState.savedLoadOptions = current
                try saveAppState()
            }
            target = .init(maxFolderConcurrency: 1, limitBandwidthInLan: true)
        } else {
            target = appState.savedLoadOptions
        }
        if let target, target != current {
            try await client.send("PATCH", "rest/config/options", json: LoadOptionsDTO(
                maxFolderConcurrency: target.maxFolderConcurrency, limitBandwidthInLan: target.limitBandwidthInLan))
        }
        if !(decision.reducedResourceUsage && decision.hold == nil), appState.savedLoadOptions != nil {
            appState.savedLoadOptions = nil
            try saveAppState()
        }
    }

    // MARK: Settings

    public func options() async throws -> EngineOptions {
        let client = try requireClient()
        let opts = try await client.options()
        let me = try await client.configDevices().first { $0.deviceID == myID?.rawValue }
        return EngineOptions(
            deviceName: me?.name ?? config.deviceName,
            globalDiscovery: opts.globalAnnounceEnabled ?? true,
            relays: opts.relaysEnabled ?? true,
            listenAddresses: opts.listenAddresses ?? ["default"]
        )
    }

    public func updateOptions(_ options: EngineOptions) async throws {
        let client = try requireClient()
        let name = options.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EngineError.invalidArgument("device name is empty") }
        let addresses = options.listenAddresses.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !addresses.isEmpty else { throw EngineError.invalidArgument("no listen addresses") }
        // Keep the shared-port protection (ListenAddressPlanner) when the user
        // goes back to "default" / :22000.
        let listen = appState.listenPort.flatMap { ListenAddressPlanner.rewrite(addresses, port: $0) } ?? addresses
        try await client.send("PATCH", "rest/config/options", json: EngineOptionsPatchDTO(
            globalAnnounceEnabled: options.globalDiscovery, relaysEnabled: options.relays, listenAddresses: listen))
        if let myID {
            let current = try await client.configDevices().first { $0.deviceID == myID.rawValue }
            if current?.name != name {
                try await client.send("PATCH", "rest/config/devices/\(myID.rawValue)", json: DeviceNamePatchDTO(name: name))
            }
        }
    }

    public func userIgnoreRules(_ folder: FolderID) async throws -> [String] {
        let client = try requireClient()
        if let file = try await userIgnoreFile(folder) {
            guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)) else { return [] }
            return Self.splitLines(String(decoding: data, as: UTF8.self))
        }
        return try await client.ignores(folder.rawValue)
    }

    public func setUserIgnoreRules(_ folder: FolderID, _ lines: [String]) async throws {
        let client = try requireClient()
        guard !lines.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") }) else {
            throw EngineError.invalidArgument("ignore rule contains a line break")
        }
        if let file = try await userIgnoreFile(folder) {
            // On-demand: the managed .stignore includes .stignore-user; rewrite
            // it, then re-post the managed section so upstream reloads.
            let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            try Data(body.utf8).write(to: file, options: .atomic)
            try await client.setIgnores(folder.rawValue, lines: try await client.ignores(folder.rawValue))
        } else {
            try await client.setIgnores(folder.rawValue, lines: lines)
        }
        try? await scan(folder, paths: nil)
    }

    /// `.stignore-user` for on-demand folders; nil when rules live in `.stignore` itself.
    private func userIgnoreFile(_ folder: FolderID) async throws -> URL? {
        let dto = try await folderConfig(folder)
        guard appState.folders[folder.rawValue]?.contentMode == .onDemand else { return nil }
        return URL(filePath: dto.path, directoryHint: .isDirectory).appending(path: IgnoreRulesGenerator.userFile)
    }

    static func splitLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        while lines.last == "" { lines.removeLast() }
        return lines
    }

    public var syncthingVersion: String {
        get async {
            if let client, let v = try? await client.get("rest/system/version") as SystemVersionDTO { return v.version }
            let bridge = bridge
            return (try? await executor.run { bridge.syncthingVersion() }) ?? ""
        }
    }

    // MARK: Policy

    public func apply(_ decision: PolicyDecision) async throws {
        appState.decision = decision
        try? saveAppState()
        guard case .running = engineState else { return }   // applied on next start
        try await reconcilePolicy()
    }

    private func reconcilePolicy() async throws {
        let client = try requireClient()
        let decision = appState.decision
        let devices = try await client.configDevices().filter { $0.deviceID != myID?.rawValue }
        if decision.hold != nil {
            for d in devices where !d.paused {
                appState.policyPausedDevices.insert(d.deviceID)
                try saveAppState()
                try await client.send("POST", "rest/system/pause", query: [.init(name: "device", value: d.deviceID)])
            }
        } else if !appState.policyPausedDevices.isEmpty {
            let known = Set(devices.map(\.deviceID))
            for id in appState.policyPausedDevices.sorted() {
                if known.contains(id) {
                    try await client.send("POST", "rest/system/resume", query: [.init(name: "device", value: id)])
                }
                appState.policyPausedDevices.remove(id)
                try saveAppState()
            }
        }
        let options = try await client.options()
        let send = max(0, decision.sendLimitKiBps), recv = max(0, decision.receiveLimitKiBps)
        if options.maxSendKbps != send || options.maxRecvKbps != recv {
            try await client.send("PATCH", "rest/config/options", json: OptionsDTO(maxSendKbps: send, maxRecvKbps: recv))
        }
        try await reconcileLoad(decision, options)
        scheduleRefresh(nil)
    }

    // MARK: Global index

    public nonisolated func globalIndex(_ folder: FolderID, pageSize: Int) -> AsyncThrowingStream<[GlobalIndexEntry], Error> {
        let (stream, continuation) = AsyncThrowingStream<[GlobalIndexEntry], Error>.makeStream()
        let task = Task { [weak self] in
            guard let self else { continuation.finish(); return }
            do {
                guard case .running = await self.state else { throw EngineError.notRunning }
                let bridge = self.bridge, executor = self.executor
                let box = try await executor.run { CursorBox(try bridge.openIndexStream(folder: folder)) }
                defer { box.close(on: executor) }
                while !Task.isCancelled {
                    let page = try await executor.run { try box.cursor.next(maxEntries: max(1, pageSize)) }
                    if page.isEmpty { break }
                    continuation.yield(page)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: Self.map(error))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Helpers

    private func saveAppState() throws {
        try appState.save(to: config.layout.engineHome)
    }

    /// Maps bridge/adapter errors to `EngineError`. The adapter's
    /// `PsyBridgeError` is only `CustomStringConvertible` ("psy:<code>: <detail>"),
    /// so its `localizedDescription` is the useless "…error 1"; prefer
    /// `LocalizedError.errorDescription`, then `description`, then NSError.
    static func map(_ error: Error) -> EngineError {
        if let e = error as? EngineError { return e }
        let nsMessage = (error as NSError).localizedDescription
        var candidates: [String] = []
        if let localized = (error as? LocalizedError)?.errorDescription { candidates.append(localized) }
        if let described = error as? CustomStringConvertible { candidates.append(described.description) }
        candidates.append(nsMessage)
        for message in candidates {
            let parsed = BridgeContract.parse(message)
            if let code = parsed.code { return .bridge(code: code.rawValue, detail: parsed.detail) }
        }
        return .bridge(code: "unknown", detail: candidates.first ?? nsMessage)
    }

    static func validateFolderID(_ id: FolderID) throws {
        let raw = id.rawValue
        guard !raw.isEmpty, raw != ".", raw != "..", !raw.contains("/"), !raw.contains("\0") else {
            throw EngineError.invalidArgument("invalid folder ID")
        }
    }

    static func canonical(_ path: String) -> String {
        var p = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func samePath(_ a: String, _ b: URL) -> Bool {
        canonical(a) == canonical(b.path(percentEncoded: false))
    }

    static func isContained(_ child: URL, in parent: URL) -> Bool {
        let c = canonical(child.path(percentEncoded: false))
        let p = canonical(parent.path(percentEncoded: false))
        return c.hasPrefix(p + "/")
    }

    static func pathEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }
}

struct FolderStatsDTO: Decodable {
    struct LastFile: Decodable { var filename: String? }
    var lastScan: String?
    var lastFile: LastFile?
}

/// Confines a non-Sendable bridge cursor to the executor queue.
private final class CursorBox: @unchecked Sendable {
    let cursor: any GlobalIndexCursor
    init(_ cursor: any GlobalIndexCursor) { self.cursor = cursor }
    func close(on executor: BridgeExecutor) {
        Task { _ = try? await executor.run { self.cursor.close() } }
    }
}
