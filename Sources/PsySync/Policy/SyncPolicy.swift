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
    /// iOS 27+: `UIApplication.systemPrefersReducedResourceUsage` (also a
    /// trait and a notification). The system asks apps to lower resource use;
    /// policy throttles but never pauses for it. false on iOS < 27 / Mac.
    public var systemPrefersReducedResourceUsage: Bool

    public init(
        network: Network,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        isLowPowerMode: Bool = false,
        isCharging: Bool = false,
        batteryLevel: Double? = nil,
        thermalSerious: Bool = false,
        systemPrefersReducedResourceUsage: Bool = false
    ) {
        self.network = network
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isLowPowerMode = isLowPowerMode
        self.isCharging = isCharging
        self.batteryLevel = batteryLevel
        self.thermalSerious = thermalSerious
        self.systemPrefersReducedResourceUsage = systemPrefersReducedResourceUsage
    }
}

extension PolicyInputs {
    /// Tolerates values encoded before `systemPrefersReducedResourceUsage` existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            network: try c.decode(Network.self, forKey: .network),
            isExpensive: try c.decode(Bool.self, forKey: .isExpensive),
            isConstrained: try c.decode(Bool.self, forKey: .isConstrained),
            isLowPowerMode: try c.decode(Bool.self, forKey: .isLowPowerMode),
            isCharging: try c.decode(Bool.self, forKey: .isCharging),
            batteryLevel: try c.decodeIfPresent(Double.self, forKey: .batteryLevel),
            thermalSerious: try c.decode(Bool.self, forKey: .thermalSerious),
            systemPrefersReducedResourceUsage: try c.decodeIfPresent(Bool.self, forKey: .systemPrefersReducedResourceUsage) ?? false
        )
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
    /// Reduced-load mode (system prefers reduced resource usage): besides the
    /// rate limits above, the engine syncs one folder at a time
    /// (`maxFolderConcurrency = 1`) and applies the limits to LAN peers too
    /// (`limitBandwidthInLan = true`); both are restored when this turns off.
    /// Always false while `hold` is set (nothing runs then).
    public var reducedResourceUsage: Bool

    public init(hold: HoldReason? = nil, sendLimitKiBps: Int = 0, receiveLimitKiBps: Int = 0,
                reducedResourceUsage: Bool = false) {
        self.hold = hold
        self.sendLimitKiBps = sendLimitKiBps
        self.receiveLimitKiBps = receiveLimitKiBps
        self.reducedResourceUsage = reducedResourceUsage
    }

    public static let run = PolicyDecision()
}

extension PolicyDecision {
    /// Tolerates decisions persisted before `reducedResourceUsage` existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hold: try c.decodeIfPresent(HoldReason.self, forKey: .hold),
            sendLimitKiBps: try c.decode(Int.self, forKey: .sendLimitKiBps),
            receiveLimitKiBps: try c.decode(Int.self, forKey: .receiveLimitKiBps),
            reducedResourceUsage: try c.decodeIfPresent(Bool.self, forKey: .reducedResourceUsage) ?? false
        )
    }
}

/// Pure function; must be deterministic and side-effect free so it can be
/// unit-tested exhaustively.
public protocol SyncPolicy: Sendable {
    func decide(inputs: PolicyInputs, preferences: PolicyPreferences) -> PolicyDecision
}
