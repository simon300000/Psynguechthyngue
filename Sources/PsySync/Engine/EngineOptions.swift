import Foundation

/// Engine-wide settings shown in Settings ▸ Advanced.
public struct EngineOptions: Hashable, Codable, Sendable {
    /// This device's name as shown to peers.
    public var deviceName: String
    /// Global discovery (`globalAnnounceEnabled`); default on.
    public var globalDiscovery: Bool
    /// Relays (`relaysEnabled`); default on.
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
