import Foundation
import Observation
import PsySync

/// Statistics shown on Home, device and folder detail and Settings ▸ Diagnostics.
///
/// Nothing here is pushed by the engine: each screen that shows a statistic
/// calls one of the `watch…` functions from `.task`, which polls only while
/// that screen is visible (SwiftUI cancels the task when it disappears), the
/// app is in the foreground and the engine runs. Several screens watching the
/// same thing share one poll loop. Battery: no polling in the background, and
/// none at all when no statistics screen is open.
@MainActor
@Observable
final class MetricsMonitor {
    /// Smoothed total and per-device rates.
    private(set) var totalRate: TransferRate = .zero
    private(set) var deviceRates: [DeviceID: TransferRate] = [:]
    /// Latest raw counters (session totals, connection counts).
    private(set) var traffic: TrafficSample?
    private(set) var systemInfo: EngineSystemInfo?
    /// This process' memory footprint (the engine runs in-process).
    private(set) var appFootprintBytes: Int64?
    private(set) var folderDetails: [FolderID: FolderDetails] = [:]
    /// Download rate of a folder (growth of its local bytes), while it syncs.
    private(set) var folderRates: [FolderID: Double] = [:]

    @ObservationIgnored private let engine: any SyncEngine
    /// True while polling makes sense: app active and engine running.
    @ObservationIgnored var isLive: @MainActor () -> Bool = { false }
    @ObservationIgnored private var meter = TrafficRateMeter()
    @ObservationIgnored private var watchers: [Kind: Int] = [:]
    @ObservationIgnored private var loops: [Kind: Task<Void, Never>] = [:]
    @ObservationIgnored private var folderSamples: [FolderID: (at: Date, bytes: Int64)] = [:]

    enum Kind: Hashable {
        case traffic
        case system
        case folder(FolderID)

        var interval: Duration {
            switch self {
            case .traffic: .seconds(2)
            case .system: .seconds(5)
            case .folder: .seconds(3)
            }
        }
    }

    init(engine: any SyncEngine) {
        self.engine = engine
    }

    func watchTraffic() async { await watch(.traffic) }
    func watchSystem() async { await watch(.system) }
    func watchFolder(_ id: FolderID) async { await watch(.folder(id)) }

    /// Engine stopped: counters restart from zero next time.
    func engineStopped() {
        meter.reset()
        totalRate = .zero
        deviceRates = [:]
        traffic = nil
        folderSamples = [:]
        folderRates = [:]
    }

    /// Runs until the calling task is cancelled (the view went away).
    private func watch(_ kind: Kind) async {
        watchers[kind, default: 0] += 1
        if loops[kind] == nil {
            loops[kind] = Task { [weak self] in await self?.pollLoop(kind) }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        watchers[kind, default: 1] -= 1
        if watchers[kind] == 0 {
            watchers[kind] = nil
            loops.removeValue(forKey: kind)?.cancel()
        }
    }

    private func pollLoop(_ kind: Kind) async {
        while !Task.isCancelled {
            if isLive() { await poll(kind) }
            try? await Task.sleep(for: kind.interval)
        }
    }

    private func poll(_ kind: Kind) async {
        switch kind {
        case .traffic:
            guard let sample = try? await engine.traffic() else { return }
            traffic = sample
            if meter.add(sample) {
                if totalRate != meter.total { totalRate = meter.total }
                if deviceRates != meter.devices { deviceRates = meter.devices }
            }
        case .system:
            if let info = try? await engine.systemInfo(), info != systemInfo { systemInfo = info }
            appFootprintBytes = ProcessStats.physicalFootprint()
        case .folder(let id):
            guard let details = try? await engine.folderDetails(id) else { return }
            if folderDetails[id] != details { folderDetails[id] = details }
            let now = Date()
            if let last = folderSamples[id], now.timeIntervalSince(last.at) > 0.5 {
                let rate = max(0, Double(details.local.bytes - last.bytes) / now.timeIntervalSince(last.at))
                if folderRates[id] != rate { folderRates[id] = rate }
            }
            folderSamples[id] = (now, details.local.bytes)
        }
    }
}
