import Foundation
@testable import PsySync

enum Fixtures {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()   // Live
        .deletingLastPathComponent()   // PsySyncTests
        .deletingLastPathComponent()   // Tests
        .appending(path: "Fixtures/rest")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: root.appending(path: name))
    }
}

/// URLProtocol stub routed by host:port so concurrent tests stay isolated.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var body: Data
        init(_ status: Int = 200, _ body: Data = Data("{}".utf8)) { self.status = status; self.body = body }
        static func json(_ s: String, status: Int = 200) -> Response { Response(status, Data(s.utf8)) }
    }

    struct Recorded: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        var body: Data?
        var apiKey: String?
    }

    typealias Handler = @Sendable (Recorded) -> Response

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var recorded: [String: [Recorded]] = [:]
    private static let lock = NSLock()

    static func register(authority: String, handler: @escaping Handler) {
        lock.withLock { handlers[authority] = handler; recorded[authority] = [] }
    }

    static func requests(authority: String) -> [Recorded] {
        lock.withLock { recorded[authority] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let authority = "\(url.host() ?? ""):\(url.port ?? 80)"
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let rec = Recorded(method: request.httpMethod ?? "GET", path: url.path(percentEncoded: false), query: query,
                           body: body, apiKey: request.value(forHTTPHeaderField: "X-API-Key"))
        let handler = Self.lock.withLock { () -> Handler? in
            Self.recorded[authority, default: []].append(rec)
            return Self.handlers[authority]
        }
        let response = handler?(rec) ?? Response(404, Data("no handler".utf8))
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return c
    }

    private static let portLock = NSLock()
    nonisolated(unsafe) private static var nextPort = 40000
    static func uniqueAuthority() -> (url: URL, authority: String) {
        let port = portLock.withLock { () -> Int in nextPort += 1; return nextPort }
        return (URL(string: "http://127.0.0.1:\(port)/")!, "127.0.0.1:\(port)")
    }
}

/// In-memory EngineLock with an observable holder.
final class FakeEngineLock: EngineLock, @unchecked Sendable {
    private let lock = NSLock()
    private var holder: EngineLockOwner?
    var available = true

    final class Lease: EngineLockLease, @unchecked Sendable {
        let owner: EngineLockOwner
        weak var parent: FakeEngineLock?
        init(owner: EngineLockOwner, parent: FakeEngineLock) { self.owner = owner; self.parent = parent }
        func release() { parent?.releaseHolder() }
    }

    func acquire(owner: EngineLockOwner, timeout: Duration) async -> (any EngineLockLease)? {
        lock.withLock { () -> (any EngineLockLease)? in
            guard available, holder == nil else { return nil }
            holder = owner
            return Lease(owner: owner, parent: self)
        }
    }

    func currentHolder() -> EngineLockOwner? { lock.withLock { holder } }
    func releaseHolder() { lock.withLock { holder = nil } }
}

/// Fake bridge: records which queue each blocking call ran on.
final class FakeBridge: SyncthingBridge, @unchecked Sendable {
    let endpoint: RESTEndpoint
    private let lock = NSLock()
    private(set) var calls: [String] = []
    private(set) var queueLabels: [String] = []
    var stopError: Error?
    var startError: Error?
    /// When set, every index stream returns these entries as one page.
    var indexEntries: [GlobalIndexEntry]?
    /// Returned by folderIndexState (nil: not available).
    var indexState: FolderIndexState?
    func folderIndexState(folder: FolderID) throws -> FolderIndexState? { lock.withLock { indexState } }

    init(endpoint: RESTEndpoint) { self.endpoint = endpoint }

    private func record(_ name: String) {
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.withLock { calls.append(name); queueLabels.append(label) }
    }

    func generateIdentity() throws -> DeviceIdentity {
        record("generateIdentity")
        let pem = try Fixtures.data("identity/cert.pem")
        return DeviceIdentity(certificatePEM: pem, privateKeyPEM: DeviceIDCodec.pem(der: Data([1, 2, 3]), type: "PRIVATE KEY"),
                              deviceID: try DeviceIDCodec.deviceID(certificatePEM: pem))
    }
    func applyMemoryProfile(_ profile: MemoryProfile) { record("applyMemoryProfile:\(profile.limitMiB)") }
    func syncthingVersion() -> String { "v2.1.6" }
    func start(homeDirectory: URL, identity: DeviceIdentity, deviceName: String, timeout: Duration) throws -> RESTEndpoint {
        record("start")
        if let startError { throw startError }
        return endpoint
    }
    func stop(timeout: Duration) throws {
        record("stop")
        if let stopError { throw stopError }
    }
    func onMemoryWarning() { record("onMemoryWarning") }
    func openIndexStream(folder: FolderID) throws -> any GlobalIndexCursor {
        record("openIndexStream")
        let cursor = FakeCursor()
        cursor.entries = lock.withLock { indexEntries }
        return cursor
    }

    /// Suffix matcher standing in for psybridge.NewIgnoreMatcher; records the lines.
    var ignoreLinesSeen: [String]?
    func ignoreMatcher(folderRoot: URL, lines: [String]) throws -> (any IgnoreMatching)? {
        lock.withLock { ignoreLinesSeen = lines }
        return SuffixMatcher(suffixes: lines.filter { $0.hasPrefix("*.") }.map { String($0.dropFirst()) })
    }

    var callList: [String] { lock.withLock { calls } }
    var labels: [String] { lock.withLock { queueLabels } }
}

struct SuffixMatcher: IgnoreMatching {
    let suffixes: [String]
    func isIgnored(_ path: RelativePath) -> Bool { suffixes.contains { path.rawValue.hasSuffix($0) } }
}

final class FakeCursor: GlobalIndexCursor {
    var remaining = 3
    var entries: [GlobalIndexEntry]?
    func next(maxEntries: Int) throws -> [GlobalIndexEntry] {
        if let e = entries { entries = []; return e }
        guard remaining > 0 else { return [] }
        remaining -= 1
        return [GlobalIndexEntry(name: RelativePath(rawValue: "f\(remaining)"), type: .file, size: 1, modified: Date(),
                                 deleted: false, invalid: false, sequence: Int64(remaining), version: "v", blocksHash: "h", localPresent: true)]
    }
    func close() {}
}

struct TestBridgeError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
