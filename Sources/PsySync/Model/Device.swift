import Foundation

/// A configured remote device (Syncthing `config.devices[]`, minus self).
public struct Device: Identifiable, Hashable, Codable, Sendable {
    public var id: DeviceID
    public var name: String
    /// "dynamic" or explicit "tcp://host:port" / "quic://..." addresses.
    public var addresses: [String]
    public var paused: Bool
    /// Devices this device may introduce (Syncthing introducer flag).
    public var introducer: Bool
    /// Auto-accept folders shared by this device into the default location.
    public var autoAcceptFolders: Bool

    public init(
        id: DeviceID,
        name: String,
        addresses: [String] = ["dynamic"],
        paused: Bool = false,
        introducer: Bool = false,
        autoAcceptFolders: Bool = false
    ) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.paused = paused
        self.introducer = introducer
        self.autoAcceptFolders = autoAcceptFolders
    }
}

/// Live connection state (REST `/rest/system/connections` + events).
public struct DeviceConnection: Hashable, Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case connected
        case disconnected
        case paused
    }

    public var deviceID: DeviceID
    public var state: State
    /// Upstream connection `type`, e.g. "tcp-client", "quic-server",
    /// "relay-client". It does not say LAN vs WAN; see `isLocalNetwork`.
    public var transport: String?
    /// Upstream `isLocal` (LAN per the engine's LAN classification); nil when
    /// unknown (e.g. built from a `DeviceConnected` event).
    public var isLocalNetwork: Bool?
    public var address: String?
    public var clientVersion: String?
    public var lastSeen: Date?
    public var inBytesTotal: Int64
    public var outBytesTotal: Int64

    public init(
        deviceID: DeviceID,
        state: State,
        transport: String? = nil,
        isLocalNetwork: Bool? = nil,
        address: String? = nil,
        clientVersion: String? = nil,
        lastSeen: Date? = nil,
        inBytesTotal: Int64 = 0,
        outBytesTotal: Int64 = 0
    ) {
        self.deviceID = deviceID
        self.state = state
        self.transport = transport
        self.isLocalNetwork = isLocalNetwork
        self.address = address
        self.clientVersion = clientVersion
        self.lastSeen = lastSeen
        self.inBytesTotal = inBytesTotal
        self.outBytesTotal = outBytesTotal
    }
}

/// An unknown device that tried to connect (REST `/rest/cluster/pending/devices`).
public struct PendingDevice: Identifiable, Hashable, Codable, Sendable {
    public var id: DeviceID
    public var name: String
    public var address: String
    public var firstSeen: Date

    public init(id: DeviceID, name: String, address: String, firstSeen: Date) {
        self.id = id
        self.name = name
        self.address = address
        self.firstSeen = firstSeen
    }
}
