import Foundation

/// Engine-wide settings shown in Settings ▸ Advanced (DESIGN §7, §12 Q1).
/// Contract change approved per Docs/REWRITE/notes/contract-change-WP-D-engine-options.md.
public struct EngineOptions: Hashable, Codable, Sendable {
    /// This device's name as shown to peers.
    public var deviceName: String
    /// Global discovery (`globalAnnounceEnabled`); default on (§12 Q1).
    public var globalDiscovery: Bool
    /// Relays (`relaysEnabled`); default on (§12 Q1).
    public var relays: Bool
    /// Sync protocol listen addresses; upstream default is `["default"]`.
    public var listenAddresses: [String]

    public init(deviceName: String, globalDiscovery: Bool = true, relays: Bool = true, listenAddresses: [String] = ["default"]) {
        self.deviceName = deviceName
        self.globalDiscovery = globalDiscovery
        self.relays = relays
        self.listenAddresses = listenAddresses
    }
}
