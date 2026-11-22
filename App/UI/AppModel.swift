import Foundation
import Observation
import PsySync
import UIKit

struct Banner: Identifiable, Equatable {
    enum Kind { case error, info }
    let id = UUID()
    let kind: Kind
    let message: String
}

struct ActiveTransfer: Identifiable, Hashable {
    var id: String { "\(folderID.rawValue)/\(path.rawValue)" }
    let folderID: FolderID
    let path: RelativePath
    var bytesDone: Int64
    var bytesTotal: Int64
    var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

/// Presentation state only. All sync decisions live in the engine/host.
@MainActor
@Observable
final class AppModel {
    let engine: any SyncEngine
    let host: LiveEngineHost
    let settings: AppSettings
    let notifier: AppNotifier
    /// True under `-PsyUITestFixture` (FakeSyncEngine).
    let isFixture: Bool
    /// Designed for iPad on Mac: no QR scanning, engine keeps running in background.
    let isOnMac: Bool

    private(set) var engineState: EngineState = .stopped
    private(set) var localID: DeviceID?
    private(set) var devices: [Device] = []
    private(set) var connections: [DeviceID: DeviceConnection] = [:]
    private(set) var folders: [Folder] = []
    private(set) var statuses: [FolderID: FolderStatus] = [:]
    /// Files list being built per folder (FilesIntegration); see `status(of:)`.
    private(set) var listings: [FolderID: FilesListingProgress] = [:]
    /// When each folder's status last came from an event; `refreshAll` does
    /// not overwrite a newer one with its older snapshot.
    @ObservationIgnored private var statusEventAt: [FolderID: Date] = [:]
    private(set) var pendingDevices: [PendingDevice] = []
    private(set) var pendingFolders: [PendingFolder] = []
    private(set) var transfers: [String: ActiveTransfer] = [:]
    private(set) var banner: Banner?
    /// Counts of engine start/stop transitions (fixture diagnostics for UI tests).
    private(set) var engineStarts = 0
    private(set) var engineStops = 0
    var isActive = false {
        didSet {
            if isActive && !oldValue { autoContinueIfNeeded() }
        }
    }

    /// Last chance (willResignActive: still in the foreground, unlike
    /// didEnterBackground, where iOS refuses the request as "unavailable"):
    /// work is under way and no task covers it yet.
    func willResignActive() {
        guard folders.contains(where: { Self.isBackgroundWork(status(of: $0).state) }) else { return }
        continueForUserAction("resign-active", expectsWork: false)
    }
    /// Menu / keyboard command waiting to be handled by the UI.
    var pendingCommand: AppCommand?
    /// Transfers in progress (Mac closure confirmation, accessory).
    var hasActiveTransfers: Bool { !syncingFolders.isEmpty || !transfers.isEmpty }
    /// Engine-owned settings (Settings ▸ Advanced); nil while the engine is not running.
    private(set) var engineOptions: EngineOptions?
    private(set) var syncthingVersion = ""
    /// BG continued processing, set by AppEnvironment.
    @ObservationIgnored var scheduler: BackgroundScheduler? {
        didSet {
            scheduler?.composeStatuses = { [weak self] engine in
                guard let self else { return engine }
                return engine.map {
                    FolderStatusComposer.compose(folderID: $0.folderID, engine: $0, engineRunning: true,
                                                 listing: self.listings[$0.folderID])
                }
            }
            scheduler?.folderLabel = { [weak self] id in self?.folders.first { $0.id == id }?.label }
        }
    }
    private(set) var filesLocation: FilesLocationState = .unknown
    @ObservationIgnored var filesStatus: (any FilesLocationStatusProviding)?

    func notYetInFiles(_ folder: FolderID) async -> Int {
        await filesStatus?.notYetInFiles(folder) ?? 0
    }

    func refreshFilesLocation() async {
        guard let filesStatus else { return }
        filesLocation = await filesStatus.currentState()
    }
    /// Set while the onboarding cover is visible so adding the first device does not close it.
    var onboardingInProgress = false

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Serialises folder/device edits so each applies to the latest value.
    @ObservationIgnored private var editChain: Task<Void, Never>?
    @ObservationIgnored private var autoContinueGate = AutoContinueGate()
    /// The automatic continued-processing request was refused: Home offers
    /// the manual button again.
    private(set) var autoContinueFailed = false
    /// `debugAutoAccept()` bookkeeping (Debug acceptance hook).
    @ObservationIgnored var debugAccepted: Set<String> = []

    init(engine: any SyncEngine, host: LiveEngineHost, settings: AppSettings, notifier: AppNotifier, isFixture: Bool,
         isOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac) {
        self.isOnMac = isOnMac
        self.engine = engine
        self.host = host
        self.settings = settings
        self.notifier = notifier
        self.isFixture = isFixture
        host.onFailure = { [weak self] error in self?.report(error) }
    }

    // MARK: Observation

    func startObserving() {
        guard eventTask == nil else { return }
        let stream = engine.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
        Task { await refreshAll() }
    }

    private func apply(_ event: EngineEvent) {
        notifier.handle(event, isActive: isActive, enabled: settings.notificationsEnabled)
        switch event {
        case let .engineStateChanged(state):
            engineState = state
            if case .running = state { engineStarts += 1; scheduleRefresh() }
            if case .stopped = state { engineStops += 1; transfers.removeAll() }
            if !isRunning {
                // Nothing the engine said is current any more.
                connections.removeAll()
                listings.removeAll()
            }
        case let .deviceConnectionChanged(c):
            connections[c.deviceID] = c
            // DeviceConnected events carry no LAN flag: pull it from REST.
            if c.state == .connected && c.isLocalNetwork == nil { scheduleRefresh() }
        case let .pendingDevicesChanged(list):
            pendingDevices = list
            debugAutoAccept()
        case let .pendingFoldersChanged(list):
            pendingFolders = list
            debugAutoAccept()
        case let .folderStatusChanged(status):
            statuses[status.folderID] = status
            statusEventAt[status.folderID] = Date()
            if status.state == .syncing { debugContinueIfRequested() }
        case .configurationChanged:
            scheduleRefresh()
            Task { await refreshFilesLocation() }
        case let .downloadProgress(folder, path, done, total):
            let t = ActiveTransfer(folderID: folder, path: path, bytesDone: done, bytesTotal: total)
            transfers[t.id] = t
        case let .itemFinished(folder, path, _):
            transfers["\(folder.rawValue)/\(path.rawValue)"] = nil
        case .itemStarted, .indexChanged:
            break
        }
        autoContinueIfNeeded()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self?.refreshAll()
        }
    }

    /// Pulls a consistent snapshot. Failures while the engine is stopped
    /// (app in background) are silent: the last known state stays visible.
    func refreshAll() async {
        engineState = await engine.state
        localID = await engine.localDeviceID
        guard case .running = engineState else { return }
        let started = Date()
        do {
            devices = try await engine.devices()
            connections = Dictionary(uniqueKeysWithValues: try await engine.connections().map { ($0.deviceID, $0) })
            folders = try await engine.folders()
            pendingDevices = try await engine.pendingDevices()
            pendingFolders = try await engine.pendingFolders()
            debugAutoAccept()
            debugRemoveIfRequested()
            debugAddDeviceIfRequested()
            debugFileOpsIfRequested()
            let snap = try await engine.snapshot()
            var merged = Dictionary(uniqueKeysWithValues: snap.folders.map { ($0.folderID, $0) })
            for (id, at) in statusEventAt where at > started {
                if let newer = statuses[id], merged[id] != nil { merged[id] = newer }
            }
            statuses = merged
            localID = snap.localDeviceID ?? localID
            engineOptions = try? await engine.options()
            let version = await engine.syncthingVersion
            if !version.isEmpty { syncthingVersion = version }
            // Existing configuration (e.g. reinstall with kept identity): no first-run guide.
            if !settings.onboardingDone && !onboardingInProgress && (!devices.isEmpty || !folders.isEmpty) {
                settings.onboardingDone = true
            }
            autoContinueIfNeeded()
        } catch {
            if case EngineError.notRunning = error { return }
            // The engine stopped (backgrounding) or died while we were
            // reading: "Could not talk to the sync engine" is not actionable.
            engineState = await engine.state
            guard case .running = engineState else { return }
            report(error)
        }
    }

    // MARK: Derived state

    var policyHold: PolicyDecision.HoldReason? { host.decision.hold }
    var connectedCount: Int { connections.values.filter { $0.state == .connected }.count }
    var allIssues: [SyncIssue] {
        statuses.values.flatMap(\.issues).sorted { $0.occurredAt > $1.occurredAt }
    }
    var pendingCount: Int { pendingDevices.count + pendingFolders.count }
    var syncingFolders: [Folder] { folders.filter { status(of: $0).state == .syncing } }
    var isRunning: Bool { if case .running = engineState { true } else { false } }

    /// Engine status plus App-side work (FolderStatusComposer): never
    /// "up to date" while the file list is arriving or Files' list is being
    /// built, and never current while the engine is stopped.
    func status(of folder: Folder) -> FolderStatus {
        FolderStatusComposer.compose(
            folderID: folder.id, engine: statuses[folder.id], engineRunning: isRunning, listing: listings[folder.id])
    }

    func listing(of folder: Folder) -> FilesListingProgress? { listings[folder.id] }

    func setListing(_ folder: FolderID, _ progress: FilesListingProgress?) {
        listings[folder] = progress
    }

    func deviceName(_ id: DeviceID) -> String {
        devices.first { $0.id == id }?.name.nilIfEmpty ?? pendingDevices.first { $0.id == id }?.name.nilIfEmpty ?? id.short
    }

    var displayName: String {
        engineOptions?.deviceName.nilIfEmpty ?? DefaultDeviceName.current
    }

    // MARK: Engine options / ignore rules

    /// Applies a change to the engine's options immediately (no Save button).
    func updateOptions(_ change: (inout EngineOptions) -> Void) async {
        guard var options = engineOptions else {
            show(error: Self.message(for: EngineError.notRunning))
            return
        }
        change(&options)
        guard options != engineOptions else { return }
        if await perform({ try await engine.updateOptions(options) }) {
            engineOptions = (try? await engine.options()) ?? options
        } else {
            engineOptions = try? await engine.options()   // revert the UI to the engine's truth
        }
    }

    func userIgnoreRules(_ folder: Folder) async -> [String]? {
        do { return try await engine.userIgnoreRules(folder.id) } catch {
            report(error)
            return nil
        }
    }

    func setUserIgnoreRules(_ folder: Folder, text: String) async -> Bool {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last == "" { lines.removeLast() }
        let ok = await perform { try await engine.setUserIgnoreRules(folder.id, lines) }
        if ok { show(info: String(localized: "Ignore patterns saved.")) }
        return ok
    }

    // MARK: Continue in background

    var canContinueInBackground: Bool { scheduler?.canContinueInBackground ?? false }
    var isContinuingInBackground: Bool { host.continuedProcessing }

    func continueInBackground() async {
        guard let scheduler else { return }
        let ok = await scheduler.continueInBackground(
            title: String(localized: "Syncing files"),
            subtitle: String(localized: "Psynguechthyngue keeps syncing until your transfers finish.")
        )
        if ok { autoContinueFailed = false }
        if ok {
            show(info: String(localized: "Syncing will continue after you leave the app."))
        } else {
            show(error: String(localized: "iOS can’t continue syncing in the background right now. Keep the app open to finish."))
        }
    }

    /// "Keep syncing in background automatically" (Settings ▸ Background).
    /// App Review: Apple intends BGContinuedProcessingTask to be started by
    /// an explicit user action. Turning this setting on is that action: the
    /// user consents once to every sync burst continuing in the background,
    /// instead of tapping "Keep Syncing in Background" each time. Requests
    /// are made only while the app is in the foreground, once per burst
    /// (AutoContinueGate), and the task finishes when transfers end.
    private func autoContinueIfNeeded() {
        // Index exchange counts: stopping the engine on every app switch
        // restarted it from the last full batch each time.
        let transfersActive = folders.contains { Self.isBackgroundWork(status(of: $0).state) }
        if !transfersActive { autoContinueFailed = false }
        guard autoContinueGate.shouldRequest(
            enabled: settings.autoContinueInBackground, appActive: isActive, canContinue: canContinueInBackground,
            transfersActive: transfersActive, alreadyContinuing: isContinuingInBackground, now: .now),
              let scheduler else { return }
        LifecycleLog.shared.record("continued-auto-request", "")
        Task {
            let ok = await scheduler.continueInBackground(
                title: String(localized: "Syncing files"),
                subtitle: String(localized: "Psynguechthyngue keeps syncing until your transfers finish.")
            )
            // Silent either way: no banner for something the user did not just tap.
            autoContinueFailed = !ok
        }
    }

    /// Work a continued background task keeps going: the file list, the
    /// Files list, scanning and syncing.
    nonisolated static func isBackgroundWork(_ state: FolderSyncState) -> Bool {
        [.syncing, .scanning, .fetchingIndex, .preparingFiles].contains(state)
    }

    /// The user just accepted a share / added a folder or device: with
    /// "Keep syncing in background automatically" on, request the task now,
    /// before any status says there is work (closing the app right after
    /// accepting lost it: the request waited for a later status event).
    func continueForUserAction(_ reason: String, label: String? = nil, expectsWork: Bool = true) {
        guard settings.autoContinueInBackground, canContinueInBackground, let scheduler else { return }
        if expectsWork { scheduler.expectWork() }
        guard !isContinuingInBackground else {
            LifecycleLog.shared.record("continued-extend", "reason=\(reason)")
            return
        }
        LifecycleLog.shared.record("continued-auto-request", "reason=\(reason)")
        let title = label.map { "\(String(localized: "Getting file list")) · \($0)" } ?? String(localized: "Syncing files")
        Task {
            let ok = await scheduler.continueInBackground(
                title: title, subtitle: String(localized: "Psynguechthyngue keeps syncing until your transfers finish."))
            autoContinueFailed = !ok
        }
    }

    // MARK: Banner

    func show(error message: String) { present(Banner(kind: .error, message: message)) }

    /// Shows an engine/operation error, except cancellations: a task cancelled
    /// because the app went to the background (or a view went away) is not a
    /// failure the user can act on ("Swift.CancellationError error 1").
    func report(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        show(error: Self.message(for: error))
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
    func show(info message: String) { present(Banner(kind: .info, message: message)) }

    private func present(_ banner: Banner) {
        self.banner = banner
        bannerTask?.cancel()
        let id = banner.id
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.banner?.id == id else { return }
            self?.banner = nil
        }
    }

    func dismissBanner() { banner = nil; bannerTask?.cancel() }

    /// Runs an engine mutation; shows a friendly banner on failure. Returns success.
    @discardableResult
    func perform(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            return true
        } catch {
            report(error)
            return false
        }
    }

    nonisolated static func message(for error: Error) -> String {
        guard let e = error as? EngineError else { return error.localizedDescription }
        switch e {
        case .lockUnavailable:
            return String(localized: "Syncing is busy in another part of the app. Please try again in a moment.")
        case .notRunning:
            return String(localized: "Syncing is paused while the app is in the background. Open the app and try again.")
        case let .bridge(code, _):
            switch code {
            case BridgeContract.Code.listen.rawValue:
                return String(localized: "The sync engine could not open its network port.")
            case BridgeContract.Code.stopTimeout.rawValue:
                return String(localized: "The sync engine took too long to stop. It will restart when you return to the app.")
            case BridgeContract.Code.invalidArgument.rawValue:
                return String(localized: "That value is not valid.")
            default:
                return String(localized: "The sync engine reported a problem.")
            }
        case let .rest(status, _):
            return status == 0
                ? String(localized: "Could not talk to the sync engine.")
                : String(localized: "The sync engine rejected the request.")
        case let .invalidArgument(detail):
            // LiveSyncEngine wraps ExternalLocationError as "external location: <case>".
            if detail.hasPrefix("external location:") {
                return detail.contains("cloudBacked")
                    ? String(localized: "iCloud Drive and other cloud folders can’t be synced in place. Choose a folder on this device.")
                    : String(localized: "That folder could not be opened.")
            }
            return detail.isEmpty ? String(localized: "That value is not valid.") : detail
        }
    }

    // MARK: Actions — devices

    func addDevice(id: DeviceID, name: String) async -> Bool {
        if devices.contains(where: { $0.id == id }) {
            show(error: String(localized: "This device has already been added."))
            return false
        }
        if id == localID {
            show(error: String(localized: "This is the ID of this device. Enter the ID of the other device."))
            return false
        }
        let finalName = name.trimmingCharacters(in: .whitespaces)
        let ok = await perform { try await engine.addDevice(Device(id: id, name: finalName.isEmpty ? id.short : finalName)) }
        if ok { await refreshAll() }
        return ok
    }

    func acceptPending(_ device: PendingDevice) async {
        // Its folders follow (offered, or auto-accepted).
        continueForUserAction("accept-device")
        _ = await addDevice(id: device.id, name: device.name)
    }

    func dismissPending(_ device: PendingDevice) async {
        if await perform({ try await engine.dismissPendingDevice(device.id) }) { pendingDevices.removeAll { $0.id == device.id } }
    }

    func rename(_ device: Device, to name: String) async {
        await updateDevice(id: device.id) { $0.name = name }
    }

    func setPaused(_ device: Device, _ paused: Bool) async {
        await updateDevice(id: device.id) { $0.paused = paused }
    }

    /// Applies `mutate` to the device's latest value (not a render-time copy),
    /// so quick consecutive edits do not revert each other.
    func updateDevice(id: DeviceID, _ mutate: @escaping (inout Device) -> Void) async {
        if let i = devices.firstIndex(where: { $0.id == id }) { mutate(&devices[i]) }   // show it now
        await serializedEdit {
            guard var d = self.devices.first(where: { $0.id == id }) else { return }
            mutate(&d)
            await self.perform { try await self.engine.updateDevice(d) }
            await self.refreshAll()
        }
    }

    /// Edits run one after another; each re-reads the latest value when it
    /// runs (an earlier edit's refresh may have replaced the array).
    private func serializedEdit(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = editChain
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        editChain = task
        await task.value
    }

    func remove(_ device: Device) async -> Bool {
        let ok = await perform { try await engine.removeDevice(device.id) }
        if ok { await refreshAll() }
        return ok
    }

    // MARK: Actions — folders

    static func makeFolderID() -> FolderID {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        func part() -> String { String((0..<5).map { _ in chars.randomElement()! }) }
        return FolderID(rawValue: "\(part())-\(part())")
    }

    func createFolder(label: String, location: FolderLocation, mode: PsySync.ContentMode, devices: [DeviceID]) async -> Bool {
        let folder = Folder(id: Self.makeFolderID(), label: label, location: location,
                            contentMode: location == .managed ? mode : .everything, devices: devices)
        continueForUserAction("add-folder", label: label)
        let ok = await perform { try await engine.addFolder(folder) }
        if ok { await refreshAll() }
        return ok
    }

    func accept(_ pending: PendingFolder, label: String, location: FolderLocation, mode: PsySync.ContentMode) async -> Bool {
        let folder = Folder(id: pending.folderID, label: label, location: location,
                            contentMode: location == .managed ? mode : .everything, devices: [pending.offeredBy])
        continueForUserAction("accept-folder", label: label)
        let ok = await perform { try await engine.acceptPendingFolder(pending, as: folder) }
        if ok { await refreshAll() }
        return ok
    }

    func dismissPending(_ pending: PendingFolder) async {
        if await perform({ try await engine.dismissPendingFolder(pending) }) { pendingFolders.removeAll { $0.id == pending.id } }
    }

    func update(_ folder: Folder) async {
        if await perform({ try await engine.updateFolder(folder) }) { await refreshAll() }
    }

    /// Applies `mutate` to the folder's latest value (see `updateDevice`).
    func updateFolder(id: FolderID, _ mutate: @escaping (inout Folder) -> Void) async {
        if let i = folders.firstIndex(where: { $0.id == id }) { mutate(&folders[i]) }   // show it now
        await serializedEdit {
            guard var f = self.folders.first(where: { $0.id == id }) else { return }
            mutate(&f)
            await self.perform { try await self.engine.updateFolder(f) }
            await self.refreshAll()
        }
    }

    func remove(_ folder: Folder, deleteLocalFiles: Bool) async -> Bool {
        let ok = await perform { try await engine.removeFolder(folder.id, deleteLocalFiles: deleteLocalFiles) }
        if ok { await refreshAll() }
        return ok
    }

    func rescan(_ folder: Folder) async {
        if await perform({ try await engine.scan(folder.id, paths: nil) }) { show(info: String(localized: "Scan started.")) }
    }

    func syncNow() async {
        // Upstream rejects scanning a paused folder ("rejected" banner each).
        for f in folders where !f.paused { _ = await perform { try await engine.scan(f.id, paths: nil) } }
    }

    func resetConfiguration() async {
        for f in folders { _ = await perform { try await engine.removeFolder(f.id, deleteLocalFiles: false) } }
        for d in devices { _ = await perform { try await engine.removeDevice(d.id) } }
        await refreshAll()
    }

    // MARK: Diagnostics

    func diagnosticsText() -> String {
        var lines = [
            "Psynguechthyngue \(AppInfo.version) (\(AppInfo.build))",
            "Syncthing \(syncthingVersion.isEmpty ? "?" : syncthingVersion)",
            "Engine: \(engineState)",
            "Policy hold: \(policyHold?.rawValue ?? "none")",
            "Devices: \(devices.count) (\(connectedCount) connected)",
            "Folders: \(folders.count)",
        ]
        for f in folders {
            let s = status(of: f)
            lines.append("- \(f.id.rawValue): \(s.state.rawValue) need=\(s.progress.needBytes)B issues=\(s.issues.count)")
        }
        lines.append("Lifecycle:")
        for e in LifecycleLog.shared.entries.suffix(30) { lines.append("  \(e.stage) \(e.detail)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: Real-device acceptance hooks (Debug only)

extension AppModel {
    /// `-PsyDebugAutoAccept <prefix>`: accept pending devices and folders whose
    /// name/label starts with `<prefix>` (e.g. `psy-test-`), as tapping Accept
    /// would (managed location, all content). Lets real-device acceptance run
    /// without UI automation. Compiled out of Release.
    func debugAutoAccept() {
        #if DEBUG
        guard !isFixture, let prefix = UserDefaults.standard.string(forKey: "PsyDebugAutoAccept"), !prefix.isEmpty else { return }
        for device in pendingDevices where device.name.hasPrefix(prefix) && debugAccepted.insert(device.id.rawValue).inserted {
            LifecycleLog.shared.record("debug-auto-accept", "device \(device.id.short) \(device.name)")
            Task { await acceptPending(device) }
        }
        for folder in pendingFolders where folder.label.hasPrefix(prefix) && debugAccepted.insert(folder.id).inserted {
            LifecycleLog.shared.record("debug-auto-accept", "folder \(folder.folderID.rawValue)")
            Task { _ = await accept(folder, label: folder.label, location: .managed, mode: .everything) }
        }
        #endif
    }

    /// `-PsyDebugAddDevice <deviceID>@<address>`: add a test peer (named
    /// `psy-test-peer`) so the phone dials it; the peer then sees this device
    /// as pending. Real-device tests without UI automation. Debug only.
    func debugAddDeviceIfRequested() {
        #if DEBUG
        guard !isFixture, let spec = UserDefaults.standard.string(forKey: "PsyDebugAddDevice"),
              let at = spec.firstIndex(of: "@"), debugAccepted.insert("add-device").inserted else { return }
        let id = DeviceID(rawValue: String(spec[..<at]))
        let address = String(spec[spec.index(after: at)...])
        guard !devices.contains(where: { $0.id == id }) else { return }
        LifecycleLog.shared.record("debug-add-device", "\(id.short) \(address)")
        Task { _ = await perform { try await self.engine.addDevice(Device(id: id, name: "psy-test-peer", addresses: [address])) } }
        #endif
    }

    /// `-PsyDebugRemovePrefix <prefix>`: remove folders (deleting their local
    /// files) and devices whose label/name starts with `<prefix>`, to clean
    /// up after a real-device test. Compiled out of Release.
    func debugRemoveIfRequested() {
        #if DEBUG
        guard !isFixture, let prefix = UserDefaults.standard.string(forKey: "PsyDebugRemovePrefix"), !prefix.isEmpty,
              debugAccepted.insert("remove-prefix").inserted else { return }
        let folders = self.folders.filter { $0.label.hasPrefix(prefix) }
        let devices = self.devices.filter { $0.name.hasPrefix(prefix) }
        Task {
            for f in folders {
                LifecycleLog.shared.record("debug-remove", "folder \(f.id.rawValue)")
                _ = await remove(f, deleteLocalFiles: true)
            }
            for d in devices {
                LifecycleLog.shared.record("debug-remove", "device \(d.id.short)")
                _ = await remove(d)
            }
        }
        #endif
    }

    /// `-PsyDebugWriteFile <folderID>/<name>` / `-PsyDebugDeleteFile <folderID>/<name>`:
    /// once per launch, write (create or overwrite, timestamped content) or
    /// delete a file in a managed folder, so local-change upload can be checked
    /// on a real device without UI automation. Compiled out of Release.
    func debugFileOpsIfRequested() {
        #if DEBUG
        guard !isFixture, let layout = try? AppGroupResolver.layout() else { return }
        for (key, write) in [("PsyDebugWriteFile", true), ("PsyDebugDeleteFile", false)] {
            guard let spec = UserDefaults.standard.string(forKey: key), let slash = spec.firstIndex(of: "/") else { continue }
            let folderID = FolderID(rawValue: String(spec[..<slash]))
            let name = String(spec[spec.index(after: slash)...])
            guard !name.isEmpty, !name.contains(".."), folders.contains(where: { $0.id == folderID && $0.location == .managed }),
                  debugAccepted.insert("\(key):\(spec)").inserted else { continue }
            let url = layout.managedFolder(folderID).appending(path: name)
            do {
                if write {
                    try Data("written on iPhone at \(Date())\n".utf8).write(to: url, options: .atomic)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
                LifecycleLog.shared.record("debug-file-op", "\(write ? "write" : "delete") \(spec)")
            } catch {
                LifecycleLog.shared.record("debug-file-op-failed", "\(spec): \(error)")
            }
        }
        #endif
    }

    /// `-PsyDebugContinueWhenSyncing YES`: request "Keep syncing in background"
    /// (as the Home button does) the first time a folder starts syncing while
    /// the app is active. Compiled out of Release.
    func debugContinueIfRequested() {
        #if DEBUG
        guard !isFixture, isActive, UserDefaults.standard.bool(forKey: "PsyDebugContinueWhenSyncing"),
              debugAccepted.insert("continue-in-background").inserted else { return }
        LifecycleLog.shared.record("debug-continue-request", "")
        Task { await continueInBackground() }
        #endif
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }

}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
