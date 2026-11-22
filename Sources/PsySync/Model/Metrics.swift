import Foundation

// Read-only statistics for the UI (Home rates, device/folder detail,
// Settings ▸ Diagnostics). Fetched on demand while a screen is visible;
// never part of the event stream.

/// Byte counters of one device's connection(s) (`/rest/system/connections`).
public struct DeviceTraffic: Hashable, Codable, Sendable {
    public var inBytesTotal: Int64
    public var outBytesTotal: Int64
    /// Open connections to the device (upstream primary + secondary); 0 when disconnected.
    public var connectionCount: Int

    public init(inBytesTotal: Int64, outBytesTotal: Int64, connectionCount: Int) {
        self.inBytesTotal = inBytesTotal
        self.outBytesTotal = outBytesTotal
        self.connectionCount = connectionCount
    }
}

/// One reading of the engine's cumulative traffic counters.
public struct TrafficSample: Hashable, Codable, Sendable {
    /// When the engine took the reading (upstream `total.at`), else when it was read.
    public var at: Date
    public var inBytesTotal: Int64
    public var outBytesTotal: Int64
    public var devices: [DeviceID: DeviceTraffic]

    public init(at: Date, inBytesTotal: Int64, outBytesTotal: Int64, devices: [DeviceID: DeviceTraffic] = [:]) {
        self.at = at
        self.inBytesTotal = inBytesTotal
        self.outBytesTotal = outBytesTotal
        self.devices = devices
    }
}

/// Download (in) and upload (out) rate in bytes per second.
public struct TransferRate: Hashable, Codable, Sendable {
    public var inPerSecond: Double
    public var outPerSecond: Double

    public static let zero = TransferRate(inPerSecond: 0, outPerSecond: 0)

    public init(inPerSecond: Double, outPerSecond: Double) {
        self.inPerSecond = inPerSecond
        self.outPerSecond = outPerSecond
    }

    public var isIdle: Bool { inPerSecond < 1 && outPerSecond < 1 }
}

/// Turns successive counter readings into rates.
///
/// - A counter that went down (engine restarted, device reconnected) gives 0
///   for that interval instead of a negative rate.
/// - Readings closer than `minimumInterval` are ignored (no division by ~0).
/// - Rates are smoothed (exponential moving average, `smoothing` = weight of
///   the newest interval) so a bursty transfer does not flicker; an idle
///   interval drops straight to 0 so "nothing is moving" shows at once.
public struct TrafficRateMeter: Sendable {
    public var smoothing: Double
    public var minimumInterval: TimeInterval
    public private(set) var last: TrafficSample?
    public private(set) var total: TransferRate = .zero
    public private(set) var devices: [DeviceID: TransferRate] = [:]

    public init(smoothing: Double = 0.5, minimumInterval: TimeInterval = 0.25) {
        self.smoothing = smoothing
        self.minimumInterval = minimumInterval
    }

    /// Feeds one reading; returns true when the rates changed.
    @discardableResult
    public mutating func add(_ sample: TrafficSample) -> Bool {
        guard let previous = last else {
            last = sample
            return false
        }
        let dt = sample.at.timeIntervalSince(previous.at)
        guard dt >= minimumInterval else { return false }
        last = sample
        let before = (total, devices)
        total = blend(total, Self.rate(from: (previous.inBytesTotal, previous.outBytesTotal),
                                       to: (sample.inBytesTotal, sample.outBytesTotal), seconds: dt))
        var next: [DeviceID: TransferRate] = [:]
        for (id, now) in sample.devices {
            guard let old = previous.devices[id] else { next[id] = .zero; continue }
            let r = Self.rate(from: (old.inBytesTotal, old.outBytesTotal), to: (now.inBytesTotal, now.outBytesTotal), seconds: dt)
            next[id] = blend(devices[id] ?? .zero, r)
        }
        devices = next
        return before.0 != total || before.1 != devices
    }

    /// Forget everything (engine stopped): the next reading starts afresh.
    public mutating func reset() {
        last = nil
        total = .zero
        devices = [:]
    }

    static func rate(from a: (Int64, Int64), to b: (Int64, Int64), seconds: TimeInterval) -> TransferRate {
        guard seconds > 0 else { return .zero }
        func per(_ x: Int64, _ y: Int64) -> Double { y >= x ? Double(y - x) / seconds : 0 }
        return TransferRate(inPerSecond: per(a.0, b.0), outPerSecond: per(a.1, b.1))
    }

    private func blend(_ old: TransferRate, _ new: TransferRate) -> TransferRate {
        func mix(_ o: Double, _ n: Double) -> Double {
            if n == 0 { return 0 }
            if o == 0 { return n }
            return o + smoothing * (n - o)
        }
        return TransferRate(inPerSecond: mix(old.inPerSecond, new.inPerSecond),
                            outPerSecond: mix(old.outPerSecond, new.outPerSecond))
    }
}

/// Item counts and sizes of one folder (`/rest/db/status` + `/rest/stats/folder`).
public struct FolderDetails: Hashable, Codable, Sendable {
    public struct Counts: Hashable, Codable, Sendable {
        public var files: Int64
        public var directories: Int64
        public var symlinks: Int64
        /// Deleted entries the index still remembers (tombstones).
        public var deleted: Int64
        public var bytes: Int64

        public init(files: Int64 = 0, directories: Int64 = 0, symlinks: Int64 = 0, deleted: Int64 = 0, bytes: Int64 = 0) {
            self.files = files
            self.directories = directories
            self.symlinks = symlinks
            self.deleted = deleted
            self.bytes = bytes
        }
    }

    public var global: Counts
    public var local: Counts
    /// Bytes / items still to download.
    public var needBytes: Int64
    public var needItems: Int64
    public var lastScan: Date?
    public var lastFile: RelativePath?
    public var lastFileAt: Date?
    public var lastFileDeleted: Bool

    public init(global: Counts = .init(), local: Counts = .init(), needBytes: Int64 = 0, needItems: Int64 = 0,
                lastScan: Date? = nil, lastFile: RelativePath? = nil, lastFileAt: Date? = nil, lastFileDeleted: Bool = false) {
        self.global = global
        self.local = local
        self.needBytes = needBytes
        self.needItems = needItems
        self.lastScan = lastScan
        self.lastFile = lastFile
        self.lastFileAt = lastFileAt
        self.lastFileDeleted = lastFileDeleted
    }
}

/// Engine-wide diagnostics (`/rest/system/status`, `/rest/system/version`).
public struct EngineSystemInfo: Hashable, Codable, Sendable {
    public struct Listener: Hashable, Codable, Sendable {
        /// Configured address, e.g. "tcp://0.0.0.0:22001" or "dynamic+https://relays…".
        public var address: String
        public var lanAddresses: [String]
        public var wanAddresses: [String]
        public var error: String?
        public var isRelay: Bool { address.contains("relay") }

        public init(address: String, lanAddresses: [String] = [], wanAddresses: [String] = [], error: String? = nil) {
            self.address = address
            self.lanAddresses = lanAddresses
            self.wanAddresses = wanAddresses
            self.error = error
        }
    }

    public struct Discovery: Hashable, Codable, Sendable {
        public var method: String
        public var error: String?

        public init(method: String, error: String? = nil) {
            self.method = method
            self.error = error
        }
    }

    public var version: String
    public var startedAt: Date?
    public var uptime: TimeInterval
    /// Go heap in use / obtained from the OS by the Go runtime.
    public var memoryAllocBytes: Int64
    public var memorySysBytes: Int64
    public var goroutines: Int
    public var listeners: [Listener]
    public var discoveryEnabled: Bool
    public var discovery: [Discovery]

    public init(version: String, startedAt: Date? = nil, uptime: TimeInterval = 0, memoryAllocBytes: Int64 = 0,
                memorySysBytes: Int64 = 0, goroutines: Int = 0, listeners: [Listener] = [], discoveryEnabled: Bool = false,
                discovery: [Discovery] = []) {
        self.version = version
        self.startedAt = startedAt
        self.uptime = uptime
        self.memoryAllocBytes = memoryAllocBytes
        self.memorySysBytes = memorySysBytes
        self.goroutines = goroutines
        self.listeners = listeners
        self.discoveryEnabled = discoveryEnabled
        self.discovery = discovery
    }

    public var relayListeners: [Listener] { listeners.filter(\.isRelay) }
    public var syncListeners: [Listener] { listeners.filter { !$0.isRelay } }
    /// Relays are configured and at least one relay listener has no error.
    public var relayConnected: Bool { relayListeners.contains { $0.error == nil && !$0.wanAddresses.isEmpty } }
    public var discoveryWorking: Int { discovery.filter { $0.error == nil }.count }
}

/// Locale-aware text for the statistics (shared by the App and tests).
public enum MetricsFormat {
    /// "1.2 MB/s"; values below 1 B/s read as "0 bytes/s" so idle never shows noise.
    public static func rate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let value = bytesPerSecond.isFinite && bytesPerSecond >= 1 ? Int64(bytesPerSecond.rounded()) : 0
        return value.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale)) + "/s"
    }

    public static func bytes(_ value: Int64, locale: Locale = .current) -> String {
        max(0, value).formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    /// "3 d 4 h", "2 h 5 min", "42 s" — at most two units.
    public static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let s = max(0, Int64(seconds.rounded(.down)))
        let units: Set<Duration.UnitsFormatStyle.Unit> = s >= 86_400 ? [.days, .hours] : s >= 3600 ? [.hours, .minutes] : s >= 60 ? [.minutes, .seconds] : [.seconds]
        return Duration.seconds(s).formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2).locale(locale))
    }

    public static func count(_ value: Int64, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }
}
