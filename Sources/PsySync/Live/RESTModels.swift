import Foundation

// Upstream Syncthing v2.1.x REST payloads (subset). Field names follow the
// JSON exactly; anything we do not need is ignored on decode. Fixtures recorded
// from a throwaway 2.1.6 instance live in Tests/Fixtures/rest/.

/// Upstream timestamps are RFC 3339 with 0–9 fractional digits and either `Z`
/// or a numeric offset (`2026-11-21T15:29:39.651636+08:00`).
enum SyncthingDate {
    static func parse(_ raw: String) -> Date? {
        // Normalise the fraction to milliseconds so ISO8601DateFormatter accepts it.
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
            let digits = text[text.index(after: dot)..<end]
            let millis = String((digits + "000").prefix(3))
            text.replaceSubrange(dot..<end, with: "." + millis)
        }
        if let date = fractional.date(from: text) { return date }
        return plain.date(from: text)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Go's zero time (`0001-01-01T00:00:00Z`) means "never".
    static func parseNonZero(_ raw: String?) -> Date? {
        guard let raw, !raw.hasPrefix("0001-01-01") else { return nil }
        return parse(raw)
    }
}

enum RESTCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            let raw = try c.decode(String.self)
            if raw.hasPrefix("0001-01-01") { return .distantPast }
            guard let date = SyncthingDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(raw)")
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Minimal dynamic JSON for event payloads.
enum JSONValue: Decodable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var int64: Int64? { double.map { Int64($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

struct SystemStatusDTO: Decodable {
    var myID: String
}

struct DeviceConfigDTO: Codable, Hashable {
    var deviceID: String
    var name: String
    var addresses: [String]
    var paused: Bool
    var introducer: Bool
    var autoAcceptFolders: Bool
}

struct FolderDeviceDTO: Codable, Hashable {
    var deviceID: String
}

struct FolderConfigDTO: Codable, Hashable {
    var id: String
    var label: String
    var path: String
    var type: String
    var devices: [FolderDeviceDTO]
    var paused: Bool
    var fsWatcherEnabled: Bool?
    var rescanIntervalS: Int?
}

struct OptionsDTO: Codable, Hashable {
    var maxSendKbps: Int
    var maxRecvKbps: Int
    /// Read-only here: written via `ListenOptionsDTO` / `EngineOptionsPatchDTO`
    /// (nil = omitted on PATCH).
    var listenAddresses: [String]? = nil
    var globalAnnounceEnabled: Bool? = nil
    var relaysEnabled: Bool? = nil
    var maxFolderConcurrency: Int? = nil
    var limitBandwidthInLan: Bool? = nil
}

struct LoadOptionsDTO: Codable, Hashable {
    var maxFolderConcurrency: Int
    var limitBandwidthInLan: Bool
}

struct EngineOptionsPatchDTO: Codable, Hashable {
    var globalAnnounceEnabled: Bool
    var relaysEnabled: Bool
    var listenAddresses: [String]
}

struct DeviceNamePatchDTO: Codable, Hashable {
    var name: String
}

struct SystemVersionDTO: Decodable {
    var version: String
}

struct ListenOptionsDTO: Codable, Hashable {
    var listenAddresses: [String]
}

struct ConnectionDTO: Decodable {
    var connected: Bool
    var paused: Bool
    var address: String?
    var type: String?
    var clientVersion: String?
    var inBytesTotal: Int64
    var outBytesTotal: Int64
}

struct ConnectionsDTO: Decodable {
    var connections: [String: ConnectionDTO]
}

struct DeviceStatsDTO: Decodable {
    var lastSeen: String?
}

struct PendingDeviceDTO: Decodable {
    var time: Date
    var name: String
    var address: String
}

struct PendingFolderOfferDTO: Decodable {
    var time: Date
    var label: String
}

struct PendingFolderDTO: Decodable {
    var offeredBy: [String: PendingFolderOfferDTO]
}

struct DBStatusDTO: Decodable {
    var state: String
    var error: String?
    var stateChanged: String?
    var globalBytes: Int64
    var localBytes: Int64
    var needBytes: Int64
    var needTotalItems: Int64
    var inSyncBytes: Int64?
    var pullErrors: Int64?
}

struct CompletionDTO: Decodable {
    var completion: Double
    var needBytes: Int64
    var needItems: Int64
    var needDeletes: Int64
    var remoteState: String?
}

struct FolderErrorDTO: Decodable, Hashable {
    var path: String
    var error: String
}

struct FolderErrorsDTO: Decodable {
    var errors: [FolderErrorDTO]?
}

struct IgnoresDTO: Codable {
    var ignore: [String]?
}

struct RawEventDTO: Decodable {
    var id: Int
    var type: String
    var time: String?
    var data: JSONValue?
}
