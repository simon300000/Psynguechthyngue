import Foundation

/// Inputs the policy layer observes. Collected by the App (NWPathMonitor,
/// ProcessInfo thermal/low-power, UIDevice battery) — never by the engine.
public struct PolicyInputs: Hashable, Codable, Sendable {
    public enum Network: String, Codable, Sendable {
        case none
        case wifiOrWired
        case cellular
    }

    public var network: Network
    /// NWPath.isExpensive (cellular, personal hotspot).
    public var isExpensive: Bool
    /// NWPath.isConstrained (Low Data Mode).
    public var isConstrained: Bool
    public var isLowPowerMode: Bool
    public var isCharging: Bool
    public var batteryLevel: Double?   // 0...1, nil if unknown (Mac)
    public var thermalSerious: Bool    // .serious or .critical

    public init(
        network: Network,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        isLowPowerMode: Bool = false,
        isCharging: Bool = false,
        batteryLevel: Double? = nil,
        thermalSerious: Bool = false
    ) {
        self.network = network
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isLowPowerMode = isLowPowerMode
        self.isCharging = isCharging
        self.batteryLevel = batteryLevel
        self.thermalSerious = thermalSerious
    }
}

/// User preferences (Settings → Network / Power). Defaults are permissive:
/// sync on any network, only throttle on Low Data Mode.
public struct PolicyPreferences: Hashable, Codable, Sendable {
    public var syncOnCellular: Bool = true
    public var respectLowDataMode: Bool = true
    public var pauseInLowPowerMode: Bool = false
    /// KiB/s, 0 = unlimited. Applied via Syncthing options.maxSendKbps/maxRecvKbps.
    public var cellularSendLimitKiBps: Int = 0
    public var cellularReceiveLimitKiBps: Int = 0

    public init() {}
}

/// Output of the policy layer. The *only* things policy may do are pause /
/// resume the whole engine's networking and set rate limits. It never
/// restructures folders or schedules work (DESIGN.md §4.4).
public struct PolicyDecision: Hashable, Codable, Sendable {
    public enum HoldReason: String, Codable, Sendable {
        case noNetwork
        case cellularDisallowed
        case lowDataMode
        case lowPowerMode
        case thermal
    }

    /// nil = run. Non-nil = pause all devices (REST `POST /rest/system/pause`).
    public var hold: HoldReason?
    /// KiB/s, 0 = unlimited.
    public var sendLimitKiBps: Int
    public var receiveLimitKiBps: Int

    public init(hold: HoldReason? = nil, sendLimitKiBps: Int = 0, receiveLimitKiBps: Int = 0) {
        self.hold = hold
        self.sendLimitKiBps = sendLimitKiBps
        self.receiveLimitKiBps = receiveLimitKiBps
    }

    public static let run = PolicyDecision()
}

/// Pure function; must be deterministic and side-effect free so it can be
/// unit-tested exhaustively.
public protocol SyncPolicy: Sendable {
    func decide(inputs: PolicyInputs, preferences: PolicyPreferences) -> PolicyDecision
}
