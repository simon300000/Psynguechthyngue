import Foundation
import Network
import PsySync
import UIKit

/// Collects network / power / thermal state and forwards it to the host as
/// `PolicyInputs`. It never talks to the engine.
@MainActor
final class PolicyMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.psynguechthyngue.policy-monitor")
    private weak var host: LiveEngineHost?
    private var observers: [NSObjectProtocol] = []
    private var lastPath: NWPath?
    private(set) var inputs = PolicyInputs(network: .wifiOrWired)
    private var started = false

    init(host: LiveEngineHost) { self.host = host }

    func start() {
        guard !started else { return }
        started = true
        let onMac = ProcessInfo.processInfo.isiOSAppOnMac
        if !onMac { UIDevice.current.isBatteryMonitoringEnabled = true }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.lastPath = path
                self?.publish()
            }
        }
        monitor.start(queue: queue)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification,
            UIDevice.batteryLevelDidChangeNotification,
        ]
        var allNames = names
        if #available(iOS 27.0, *) {
            // iOS 27: the system asks apps to scale back resource-intensive work.
            allNames.append(UIApplication.systemPrefersReducedResourceUsageDidChangeNotification)
        }
        for name in allNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.publish() }
            })
        }
        publish()
    }

    func stop() {
        monitor.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        started = false
    }

    private func publish() {
        inputs = Self.currentInputs(path: lastPath)
        let value = inputs
        Task { await host?.policyInputsChanged(value) }
    }

    static func currentInputs(path: NWPath?) -> PolicyInputs {
        let info = ProcessInfo.processInfo
        let network: PolicyInputs.Network
        if let path {
            if path.status != .satisfied { network = .none }
            else if path.usesInterfaceType(.cellular) { network = .cellular }
            else { network = .wifiOrWired }
        } else {
            network = .wifiOrWired   // optimistic until the first path callback
        }
        let onMac = info.isiOSAppOnMac
        let device = UIDevice.current
        let level: Double? = (onMac || device.batteryLevel < 0) ? nil : Double(device.batteryLevel)
        let charging = !onMac && (device.batteryState == .charging || device.batteryState == .full)
        let thermal = info.thermalState == .serious || info.thermalState == .critical
        var reduced = false
        if #available(iOS 27.0, *) {
            reduced = UIApplication.shared.systemPrefersReducedResourceUsage
        }
        var inputs = PolicyInputs(
            network: network,
            isExpensive: path?.isExpensive ?? false,
            isConstrained: path?.isConstrained ?? false,
            isLowPowerMode: info.isLowPowerModeEnabled,
            isCharging: charging,
            batteryLevel: level,
            thermalSerious: thermal,
            systemPrefersReducedResourceUsage: reduced
        )
        #if DEBUG
        Self.applyDebugOverride(&inputs)
        #endif
        return inputs
    }

    #if DEBUG
    /// Simulator acceptance only: `-psy.debug.policy cellular,constrained,lowpower,thermal,reduced,offline`
    /// forces policy inputs the simulator cannot produce. Never compiled into Release.
    static func applyDebugOverride(_ inputs: inout PolicyInputs) {
        guard let raw = UserDefaults.standard.string(forKey: "psy.debug.policy"), !raw.isEmpty else { return }
        for flag in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch flag {
            case "cellular": inputs.network = .cellular; inputs.isExpensive = true
            case "offline": inputs.network = .none
            case "constrained": inputs.isConstrained = true
            case "lowpower": inputs.isLowPowerMode = true
            case "thermal": inputs.thermalSerious = true
            case "reduced": inputs.systemPrefersReducedResourceUsage = true
            default: break
            }
        }
    }
    #endif
}
