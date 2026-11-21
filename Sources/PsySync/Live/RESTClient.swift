import Foundation

/// Thin async client for the Syncthing REST API on loopback.
///
/// - All I/O is `URLSession` async — never blocks a cooperative thread.
/// - The API key is only ever placed in the `X-API-Key` header; it is never
///   logged, never part of an error, never part of a URL.
/// - Errors are `EngineError.rest(status:body:)`; status 0 = transport failure.
public final class SyncthingRESTClient: Sendable {
    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let defaultTimeout: TimeInterval

    public init(endpoint: RESTEndpoint, configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 30) {
        self.baseURL = endpoint.baseURL
        self.apiKey = endpoint.apiKey
        self.defaultTimeout = timeout
        let config = configuration
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]   // loopback only, never via proxy
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Generic

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval? = nil, as: T.Type = T.self) async throws -> T {
        let data = try await request("GET", path, query: query, body: nil, timeout: timeout)
        do {
            return try RESTCoding.decoder().decode(T.self, from: data)
        } catch {
            throw EngineError.rest(status: -1, body: "decode \(path): \(error)")
        }
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: (any Encodable)? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        let body = try json.map { try RESTCoding.encoder().encode(AnyEncodable($0)) }
        return try await request(method, path, query: query, body: body, timeout: timeout)
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, timeout: TimeInterval?) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            // '+' is a space in form decoding on the Go side; encode it explicitly.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.timeoutInterval = timeout ?? defaultTimeout
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw EngineError.rest(status: 0, body: "\(method) \(path): \(error.code.rawValue) \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError.rest(status: status, body: text)
        }
        return data
    }

    // MARK: Typed endpoints

    func ping() async throws {
        _ = try await request("GET", "rest/system/ping", query: [], body: nil, timeout: 5)
    }

    func systemStatus() async throws -> SystemStatusDTO { try await get("rest/system/status") }

    func configDevices() async throws -> [DeviceConfigDTO] { try await get("rest/config/devices") }
    func configFolders() async throws -> [FolderConfigDTO] { try await get("rest/config/folders") }
    func options() async throws -> OptionsDTO { try await get("rest/config/options") }
    func connections() async throws -> ConnectionsDTO { try await get("rest/system/connections") }
    func deviceStats() async throws -> [String: DeviceStatsDTO] { try await get("rest/stats/device") }
    func pendingDevices() async throws -> [String: PendingDeviceDTO] { try await get("rest/cluster/pending/devices") }
    func pendingFolders() async throws -> [String: PendingFolderDTO] { try await get("rest/cluster/pending/folders") }

    func dbStatus(_ folder: String) async throws -> DBStatusDTO {
        try await get("rest/db/status", query: [.init(name: "folder", value: folder)])
    }

    func completion(_ folder: String, device: String? = nil) async throws -> CompletionDTO {
        var q = [URLQueryItem(name: "folder", value: folder)]
        if let device { q.append(.init(name: "device", value: device)) }
        return try await get("rest/db/completion", query: q)
    }

    func folderErrors(_ folder: String) async throws -> [FolderErrorDTO] {
        let dto: FolderErrorsDTO = try await get("rest/folder/errors", query: [.init(name: "folder", value: folder)])
        return dto.errors ?? []
    }

    func ignores(_ folder: String) async throws -> [String] {
        let dto: IgnoresDTO = try await get("rest/db/ignores", query: [.init(name: "folder", value: folder)])
        return dto.ignore ?? []
    }

    func setIgnores(_ folder: String, lines: [String]) async throws {
        try await send("POST", "rest/db/ignores", query: [.init(name: "folder", value: folder)], json: IgnoresDTO(ignore: lines))
    }

    func events(since: Int, mask: [String], timeout: Int) async throws -> [RawEventDTO] {
        try await get(
            "rest/events",
            query: [
                .init(name: "since", value: String(since)),
                .init(name: "timeout", value: String(timeout)),
                .init(name: "events", value: mask.joined(separator: ",")),
            ],
            timeout: TimeInterval(timeout + 15)
        )
    }
}

/// Type-erasing wrapper so `send(json:)` accepts any Encodable.
private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
