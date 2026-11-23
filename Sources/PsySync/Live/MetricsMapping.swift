import Foundation

// REST payloads and pure mapping for the statistics API (`SyncEngine.traffic`,
// `folderDetails`, `systemInfo`). Kept apart from the status path
// (StatusMapper) so they can evolve independently.

/// `/rest/system/connections` with the counters the status path ignores.
struct ConnectionsStatsDTO: Decodable {
    struct Counters: Decodable {
        var at: String?
        var inBytesTotal: Int64
        var outBytesTotal: Int64
    }

    struct Device: Decodable {
        var connected: Bool
        var inBytesTotal: Int64
        var outBytesTotal: Int64
        var primary: Counters?
        var secondary: [Counters]?
    }

    var connections: [String: Device]
    var total: Counters?
}

/// `/rest/db/status` counts (the status path decodes only what it maps).
struct DBCountsDTO: Decodable {
    var globalFiles: Int64?
    var globalDirectories: Int64?
    var globalSymlinks: Int64?
    var globalDeleted: Int64?
    var globalBytes: Int64?
    var localFiles: Int64?
    var localDirectories: Int64?
    var localSymlinks: Int64?
    var localDeleted: Int64?
    var localBytes: Int64?
    var needBytes: Int64?
    var needTotalItems: Int64?
}

/// One folder of `/rest/stats/folder`.
struct FolderStatsDetailDTO: Decodable {
    struct LastFile: Decodable {
        var at: String?
        var filename: String?
        var deleted: Bool?
    }

    var lastScan: String?
    var lastFile: LastFile?
}

/// `/rest/system/status` (diagnostics subset).
struct SystemStatusDetailDTO: Decodable {
    struct Listener: Decodable {
        var error: String?
        var lanAddresses: [String]?
        var wanAddresses: [String]?
    }

    struct DiscoveryStatus: Decodable {
        var error: String?
    }

    var alloc: Int64?
    var sys: Int64?
    var goroutines: Int?
    var uptime: Double?
    var startTime: String?
    var connectionServiceStatus: [String: Listener]?
    var discoveryEnabled: Bool?
    var discoveryStatus: [String: DiscoveryStatus]?
}

enum MetricsMapping {
    static func traffic(_ dto: ConnectionsStatsDTO, excluding me: DeviceID?, now: Date = Date()) -> TrafficSample {
        var devices: [DeviceID: DeviceTraffic] = [:]
        for (id, c) in dto.connections where id != me?.rawValue {
            let count = c.connected ? (c.primary == nil ? 1 : 1 + (c.secondary?.count ?? 0)) : 0
            devices[DeviceID(rawValue: id)] = DeviceTraffic(inBytesTotal: c.inBytesTotal, outBytesTotal: c.outBytesTotal, connectionCount: count)
        }
        let at = dto.total?.at.flatMap(SyncthingDate.parseNonZero) ?? now
        return TrafficSample(at: at, inBytesTotal: dto.total?.inBytesTotal ?? 0, outBytesTotal: dto.total?.outBytesTotal ?? 0,
                             devices: devices)
    }

    static func folderDetails(_ db: DBCountsDTO, stats: FolderStatsDetailDTO?) -> FolderDetails {
        let lastName = stats?.lastFile?.filename.flatMap { $0.isEmpty ? nil : $0 }
        return FolderDetails(
            global: .init(files: db.globalFiles ?? 0, directories: db.globalDirectories ?? 0, symlinks: db.globalSymlinks ?? 0,
                          deleted: db.globalDeleted ?? 0, bytes: db.globalBytes ?? 0),
            local: .init(files: db.localFiles ?? 0, directories: db.localDirectories ?? 0, symlinks: db.localSymlinks ?? 0,
                         deleted: db.localDeleted ?? 0, bytes: db.localBytes ?? 0),
            needBytes: db.needBytes ?? 0,
            needItems: db.needTotalItems ?? 0,
            lastScan: SyncthingDate.parseNonZero(stats?.lastScan),
            lastFile: lastName.map(RelativePath.init(rawValue:)),
            lastFileAt: lastName == nil ? nil : SyncthingDate.parseNonZero(stats?.lastFile?.at),
            lastFileDeleted: lastName == nil ? false : (stats?.lastFile?.deleted ?? false)
        )
    }

    static func systemInfo(_ s: SystemStatusDetailDTO, version: String) -> EngineSystemInfo {
        let listeners = (s.connectionServiceStatus ?? [:])
            .map { EngineSystemInfo.Listener(address: $0.key, lanAddresses: $0.value.lanAddresses ?? [],
                                             wanAddresses: $0.value.wanAddresses ?? [], error: $0.value.error) }
            .sorted { $0.address < $1.address }
        let discovery = (s.discoveryStatus ?? [:])
            .map { EngineSystemInfo.Discovery(method: $0.key, error: $0.value.error) }
            .sorted { $0.method < $1.method }
        return EngineSystemInfo(
            version: version,
            startedAt: SyncthingDate.parseNonZero(s.startTime),
            uptime: s.uptime ?? 0,
            memoryAllocBytes: s.alloc ?? 0,
            memorySysBytes: s.sys ?? 0,
            goroutines: s.goroutines ?? 0,
            listeners: listeners,
            discoveryEnabled: s.discoveryEnabled ?? false,
            discovery: discovery
        )
    }
}
