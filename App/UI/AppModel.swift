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
    private(set) var pendingDevices: [PendingDevice] = []
    private(set) var pendingFolders: [PendingFolder] = []
    private(set) var transfers: [String: ActiveTransfer] = [:]
    private(set) var banner: Banner?
    /// Counts of engine start/stop transitions (fixture diagnostics for UI tests).
    private(set) var engineStarts = 0
    private(set) var engineStops = 0
    var isActive = false
    /// Engine-owned settings (Settings ▸ Advanced); nil while the engine is not running.
    private(set) var engineOptions: EngineOptions?
    private(set) var syncthingVersion = ""
    /// BG continued processing (iOS 26+), set by AppEnvironment.
    @ObservationIgnored var scheduler: BackgroundScheduler?
    private(set) var filesLocation: FilesLocationState = .unknown
    @ObservationIgnored var filesStatus: (any FilesLocationStatusProviding)?

    func refreshFilesLocation() async {
        guard let filesStatus else { return }
        filesLocation = await filesStatus.currentState()
    }
    /// Set while the onboarding cover is visible so adding the first device does not close it.
    var onboardingInProgress = false

    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(engine: any SyncEngine, host: LiveEngineHost, settings: AppSettings, notifier: AppNotifier, isFixture: Bool,
         isOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac) {
        self.isOnMac = isOnMac
        self.engine = engine
        self.host = host
        self.settings = settings
        self.notifier = notifier
        self.isFixture = isFixture
        host.onFailure = { [weak self] error in self?.show(error: Self.message(for: error)) }
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
        case let .deviceConnectionChanged(c):
            connections[c.deviceID] = c
        case let .pendingDevicesChanged(list):
            pendingDevices = list
        case let .pendingFoldersChanged(list):
            pendingFolders = list
        case let .folderStatusChanged(status):
            statuses[status.folderID] = status
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
        do {
            devices = try await engine.devices()
            connections = Dictionary(uniqueKeysWithValues: try await engine.connections().map { ($0.deviceID, $0) })
            folders = try await engine.folders()
            pendingDevices = try await engine.pendingDevices()
            pendingFolders = try await engine.pendingFolders()
            let snap = try await engine.snapshot()
            statuses = Dictionary(uniqueKeysWithValues: snap.folders.map { ($0.folderID, $0) })
            localID = snap.localDeviceID ?? localID
            engineOptions = try? await engine.options()
            let version = await engine.syncthingVersion
            if !version.isEmpty { syncthingVersion = version }
            // Existing configuration (e.g. reinstall with kept identity): no first-run guide.
            if !settings.onboardingDone && !onboardingInProgress && (!devices.isEmpty || !folders.isEmpty) {
                settings.onboardingDone = true
            }
        } catch {
            if case EngineError.notRunning = error { return }
            show(error: Self.message(for: error))
        }
    }

    // MARK: Derived state

    var policyHold: PolicyDecision.HoldReason? { host.decision.hold }
    var connectedCount: Int { connections.values.filter { $0.state == .connected }.count }
    var allIssues: [SyncIssue] {
        statuses.values.flatMap(\.issues).sorted { $0.occurredAt > $1.occurredAt }
    }
    var pendingCount: Int { pendingDevices.count + pendingFolders.count }
    var syncingFolders: [Folder] { folders.filter { statuses[$0.id]?.state == .syncing } }
    var isRunning: Bool { if case .running = engineState { true } else { false } }

    func status(of folder: Folder) -> FolderStatus {
        statuses[folder.id] ?? FolderStatus(folderID: folder.id, state: isRunning ? .upToDate : .offline)
    }

    func deviceName(_ id: DeviceID) -> String {
        devices.first { $0.id == id }?.name.nilIfEmpty ?? pendingDevices.first { $0.id == id }?.name.nilIfEmpty ?? id.short
    }

    var displayName: String {
        engineOptions?.deviceName.nilIfEmpty ?? UIDevice.current.name
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
            show(error: Self.message(for: error))
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

    // MARK: Continue in background (iOS 26+)

    var canContinueInBackground: Bool { scheduler?.canContinueInBackground ?? false }
    var isContinuingInBackground: Bool { host.continuedProcessing }

    func continueInBackground() {
        guard let scheduler else { return }
        let ok = scheduler.continueInBackground(
            title: String(localized: "Syncing files"),
            subtitle: String(localized: "Psynguechthyngue keeps syncing until your transfers finish.")
        )
        if ok {
            show(info: String(localized: "Syncing will continue after you leave the app."))
        } else {
            show(error: String(localized: "iOS can’t continue syncing in the background right now. Keep the app open to finish."))
        }
    }

    // MARK: Banner

    func show(error message: String) { present(Banner(kind: .error, message: message)) }
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
            show(error: Self.message(for: error))
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
        _ = await addDevice(id: device.id, name: device.name)
    }

    func dismissPending(_ device: PendingDevice) async {
        if await perform({ try await engine.dismissPendingDevice(device.id) }) { pendingDevices.removeAll { $0.id == device.id } }
    }

    func rename(_ device: Device, to name: String) async {
        var d = device; d.name = name
        if await perform({ try await engine.updateDevice(d) }) { await refreshAll() }
    }

    func setPaused(_ device: Device, _ paused: Bool) async {
        var d = device; d.paused = paused
        if await perform({ try await engine.updateDevice(d) }) { await refreshAll() }
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
        let ok = await perform { try await engine.addFolder(folder) }
        if ok { await refreshAll() }
        return ok
    }

    func accept(_ pending: PendingFolder, label: String, location: FolderLocation, mode: PsySync.ContentMode) async -> Bool {
        let folder = Folder(id: pending.folderID, label: label, location: location,
                            contentMode: location == .managed ? mode : .everything, devices: [pending.offeredBy])
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

    func remove(_ folder: Folder, deleteLocalFiles: Bool) async -> Bool {
        let ok = await perform { try await engine.removeFolder(folder.id, deleteLocalFiles: deleteLocalFiles) }
        if ok { await refreshAll() }
        return ok
    }

    func rescan(_ folder: Folder) async {
        if await perform({ try await engine.scan(folder.id, paths: nil) }) { show(info: String(localized: "Scan started.")) }
    }

    func syncNow() async {
        for f in folders { _ = await perform { try await engine.scan(f.id, paths: nil) } }
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

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }

}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
