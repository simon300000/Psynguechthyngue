// SPDX-License-Identifier: MIT
//
// Swift adapter over PsyBridge.xcframework (GoBridge/psybridge, bridge API v2).
// Compiled into the App and File Provider targets; SwiftPM code depends only
// on the `SyncthingBridge` / `RestrictedFetchBridge` protocols in PsySync.
//
// Threading (DESIGN.md §4.3): every gomobile call blocks the calling thread
// (Start waits for REST health, FetchFile can take 90 s). The protocol
// methods below are synchronous and must not run on the Swift cooperative
// pool. Use `PsyBridgeThread.run { … }` (or your own serial queue, as WP-B's
// LiveSyncEngine does) to get an async API whose blocking part runs on one
// dedicated, long-lived thread.

import Foundation
import PsyBridge
import PsySync

// MARK: - Errors

/// Error thrown by the adapter. `code` is the stable bridge code
/// (`psy:<code>: <detail>`), nil for non-bridge failures.
public struct PsyBridgeError: Error, CustomStringConvertible, Sendable {
    public let code: BridgeContract.Code?
    public let detail: String

    public var description: String {
        code.map { "psy:\($0.rawValue): \(detail)" } ?? detail
    }

    init(code: BridgeContract.Code?, detail: String) {
        self.code = code
        self.detail = detail
    }

    /// gomobile turns Go errors into NSError whose localizedDescription is
    /// the Go error string.
    init(_ error: Error) {
        let parsed = BridgeContract.parse((error as NSError).localizedDescription)
        self.init(code: parsed.code, detail: parsed.detail)
    }

    static func missingResult(_ what: String) -> PsyBridgeError {
        PsyBridgeError(code: nil, detail: "\(what) returned no result")
    }
}

// MARK: - Dedicated thread

/// One long-lived thread that executes blocking bridge calls in FIFO order.
/// Never blocks the cooperative pool: callers suspend on a continuation.
public final class PsyBridgeThread: @unchecked Sendable {
    public static let shared = PsyBridgeThread(name: "app.psynguechthyngue.psybridge")

    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var thread: Thread?

    public init(name: String, stackSize: Int = 4 << 20) {
        let thread = Thread { [unowned self] in self.loop() }
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job() }
        }
    }

    private func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    /// Runs `body` on the dedicated thread and resumes the caller with its result.
    public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            enqueue {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Non-throwing variant.
    public func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            enqueue { continuation.resume(returning: body()) }
        }
    }
}

// MARK: - Callbacks from Go

/// Receives engine log lines (API key already redacted by the bridge).
public typealias PsyBridgeLogHandler = @Sendable (_ level: String, _ message: String) -> Void
/// Told when the engine stops for any reason other than `stop`.
public typealias PsyBridgeExitHandler = @Sendable (_ code: BridgeContract.Code?, _ detail: String) -> Void

private final class LogSinkBox: NSObject, PsybridgeLogSinkProtocol, @unchecked Sendable {
    let handler: PsyBridgeLogHandler
    init(_ handler: @escaping PsyBridgeLogHandler) { self.handler = handler }
    func log(_ level: String?, message: String?) { handler(level ?? "info", message ?? "") }
}

private final class ExitObserverBox: NSObject, PsybridgeExitObserverProtocol, @unchecked Sendable {
    let handler: PsyBridgeExitHandler
    init(_ handler: @escaping PsyBridgeExitHandler) { self.handler = handler }
    func engineExited(_ code: String?, detail: String?) {
        handler(code.flatMap(BridgeContract.Code.init(rawValue:)), detail ?? "")
    }
}

private final class FetchProgressBox: NSObject, PsybridgeFetchProgressProtocol, @unchecked Sendable {
    let onProgress: @Sendable (Int64, Int64) -> Void
    let cancelled: @Sendable () -> Bool
    init(progress: @escaping @Sendable (Int64, Int64) -> Void, isCancelled: @escaping @Sendable () -> Bool) {
        onProgress = progress
        cancelled = isCancelled
    }
    func progress(_ completed: Int64, total: Int64) { onProgress(completed, total) }
    func isCancelled() -> Bool { cancelled() }
}

// MARK: - Adapter

/// `SyncthingBridge` + `RestrictedFetchBridge` over gomobile `Psybridge*`.
/// Thread-safe; all methods block (see file header).
public final class PsyBridgeAdapter: SyncthingBridge, RestrictedFetchBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: PsybridgeEngine?
    private let logSink: LogSinkBox?
    private let exitObserver: ExitObserverBox?
    /// Fixed loopback API address; nil = "127.0.0.1:0" (random port). Tests only.
    private let apiAddress: String?
    private let logLevel: String

    public init(
        apiAddress: String? = nil,
        logLevel: String = "info",
        log: PsyBridgeLogHandler? = nil,
        onExit: PsyBridgeExitHandler? = nil
    ) {
        self.apiAddress = apiAddress
        self.logLevel = logLevel
        self.logSink = log.map(LogSinkBox.init)
        self.exitObserver = onExit.map(ExitObserverBox.init)
    }

    /// `psybridge.APIVersion()`; must equal `BridgeContract.apiVersion`.
    public static var apiVersion: Int64 { PsybridgeAPIVersion() }

    /// Throws if the linked framework speaks a different bridge API.
    public static func checkAPIVersion() throws {
        guard apiVersion == BridgeContract.apiVersion else {
            throw PsyBridgeError(code: .invalidArgument,
                                 detail: "PsyBridge API \(apiVersion) != contract \(BridgeContract.apiVersion)")
        }
    }

    // MARK: Identity / runtime

    public func generateIdentity() throws -> DeviceIdentity {
        var error: NSError?
        let identity = PsybridgeGenerateIdentity(&error)
        if let error { throw PsyBridgeError(error) }
        guard let identity, let cert = identity.certPEM, let key = identity.keyPEM else {
            throw PsyBridgeError.missingResult("GenerateIdentity")
        }
        return DeviceIdentity(certificatePEM: cert, privateKeyPEM: key, deviceID: DeviceID(rawValue: identity.deviceID))
    }

    /// Device ID for a stored certificate (e.g. to verify a Keychain item).
    public func deviceID(certificatePEM: Data) throws -> DeviceID {
        var error: NSError?
        let id = PsybridgeDeviceIDFromCertificate(certificatePEM, &error)
        if let error { throw PsyBridgeError(error) }
        return DeviceID(rawValue: id)
    }

    public func validateDeviceID(_ input: String) throws -> DeviceID {
        var error: NSError?
        let id = PsybridgeValidateDeviceID(input, &error)
        if let error { throw PsyBridgeError(error) }
        return DeviceID(rawValue: id)
    }

    public func applyMemoryProfile(_ profile: MemoryProfile) {
        _ = PsybridgeApplyMemoryProfile(profile.limitMiB, profile.gcPercent)
    }

    public func syncthingVersion() -> String { PsybridgeSyncthingVersion() }

    // MARK: Engine lifecycle

    public func start(homeDirectory: URL, identity: DeviceIdentity, deviceName: String, timeout: Duration) throws -> RESTEndpoint {
        lock.lock()
        defer { lock.unlock() }
        if let engine, engine.isRunning() {
            throw PsyBridgeError(code: .alreadyRunning, detail: "engine already started")
        }
        let config = PsybridgeEngineConfig()
        config.homeDir = homeDirectory.path
        config.certPEM = identity.certificatePEM
        config.keyPEM = identity.privateKeyPEM
        config.deviceName = deviceName
        config.memoryLimitMiB = MemoryProfile.foreground.limitMiB
        config.gcPercent = MemoryProfile.foreground.gcPercent
        config.apiAddress = apiAddress ?? ""
        config.logLevel = logLevel

        var error: NSError?
        let engine = PsybridgeNewEngine(config, logSink, exitObserver, &error)
        if let error { throw PsyBridgeError(error) }
        guard let engine else { throw PsyBridgeError.missingResult("NewEngine") }

        let endpoint: PsybridgeAPIEndpoint
        do {
            endpoint = try engine.start(timeout.milliseconds)
        } catch {
            throw PsyBridgeError(error)
        }
        guard let url = URL(string: endpoint.baseURL), url.host == "127.0.0.1" || url.host == "::1" else {
            _ = try? engine.stop(5_000)
            throw PsyBridgeError(code: .listen, detail: "engine API is not on loopback")
        }
        self.engine = engine
        return RESTEndpoint(baseURL: url, apiKey: endpoint.apiKey, deviceID: DeviceID(rawValue: endpoint.deviceID))
    }

    public func stop(timeout: Duration) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let engine else { throw PsyBridgeError(code: .notRunning, detail: "engine is not running") }
        // The Go engine is unusable after Stop either way. On .stopTimeout it
        // keeps shutting down in the background; the next `start` (a new
        // engine) waits for that instead of failing, so the process is not
        // poisoned.
        self.engine = nil
        do {
            try engine.stop(timeout.milliseconds)
        } catch {
            throw PsyBridgeError(error)
        }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return engine?.isRunning() ?? false
    }

    public func onMemoryWarning() {
        lock.lock()
        let engine = self.engine
        lock.unlock()
        if let engine { engine.onMemoryWarning() } else { PsybridgeFreeOSMemory() }
    }

    public func openIndexStream(folder: FolderID) throws -> any GlobalIndexCursor {
        lock.lock()
        let engine = self.engine
        lock.unlock()
        guard let engine else { throw PsyBridgeError(code: .notRunning, detail: "engine is not running") }
        do {
            return IndexCursor(try engine.openIndexStream(folder.rawValue))
        } catch {
            throw PsyBridgeError(error)
        }
    }

    public func ignoreMatcher(folderRoot: URL, lines: [String]) throws -> (any IgnoreMatching)? {
        try Self.makeIgnoreMatcher(folderRoot: folderRoot, lines: lines)
    }

    /// psybridge.NewIgnoreMatcher (upstream lib/ignore semantics).
    public static func makeIgnoreMatcher(folderRoot: URL, lines: [String]) throws -> any IgnoreMatching {
        var error: NSError?
        guard let m = PsybridgeNewIgnoreMatcher(folderRoot.path(percentEncoded: false), lines.joined(separator: "\n"), &error)
        else { throw PsyBridgeError(error ?? NSError(domain: "psybridge", code: -1)) }
        return GoIgnoreMatcher(m)
    }

    // MARK: Restricted fetch (File Provider extension)

    /// Routes restricted-core logs (fetch / recordFetchedFile) to `handler`.
    /// level: "warn" (default; production), "trace" (adds one line per fetch
    /// phase with phys_footprint, peak RSS and Go memory — use to measure the
    /// extension), "info"/"debug" (verbose; not for production). nil = drop.
    public static func setRestrictedLog(level: String = "warn", _ handler: PsyBridgeLogHandler?) {
        PsybridgeSetFetchLogSink(handler.map(LogSinkBox.init), level)
    }

    public func fetch(
        homeDirectory: URL,
        identity: DeviceIdentity,
        folder: FolderID,
        path: RelativePath,
        expectedVersion: String?,
        destination: URL,
        budget: RestrictedFetchBudget,
        progress: @escaping @Sendable (_ completed: Int64, _ total: Int64) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> RestrictedFetchResult {
        let request = PsybridgeFetchRequest()
        request.homeDir = homeDirectory.path
        request.certPEM = identity.certificatePEM
        request.keyPEM = identity.privateKeyPEM
        request.folderID = folder.rawValue
        request.path = path.rawValue
        request.expectedVersion = expectedVersion ?? ""
        request.destinationPath = destination.path
        request.deadlineMillis = budget.deadline.milliseconds
        request.memoryLimitMiB = budget.memory.limitMiB
        request.maxFileBytes = budget.maxFileBytes
        request.connectGraceMillis = budget.connectGrace.milliseconds

        let box = FetchProgressBox(progress: progress, isCancelled: isCancelled)
        var error: NSError?
        let result = PsybridgeFetchFile(request, box, &error)
        if let error { throw PsyBridgeError(error) }
        guard let result else { throw PsyBridgeError.missingResult("FetchFile") }
        let servedBy = result.servedBy
            .split(separator: ",")
            .map { DeviceID(rawValue: String($0)) }
        return RestrictedFetchResult(stagedFile: destination, size: result.size, version: result.version, servedBy: servedBy)
    }

    /// `psybridge.RecordFetchedFile`: after `fetch` and after the staged file
    /// was renamed to `<folder>/<path>` (engine lock still held), record it in
    /// the local index with the global version so the App's next scan does
    /// not mint a new version. Part of `RestrictedFetchBridge` (contract change
    /// accepted 2026-11-21, Docs/REWRITE/notes/contract-change-WP-A-record-fetched-file.md).
    public func recordFetchedFile(
        homeDirectory: URL,
        identity: DeviceIdentity,
        folder: FolderID,
        path: RelativePath,
        version: String
    ) throws {
        let request = PsybridgeRecordRequest()
        request.homeDir = homeDirectory.path
        request.certPEM = identity.certificatePEM
        request.keyPEM = identity.privateKeyPEM
        request.folderID = folder.rawValue
        request.path = path.rawValue
        request.expectedVersion = version
        var error: NSError?
        _ = PsybridgeRecordFetchedFile(request, &error)
        if let error { throw PsyBridgeError(error) }
    }
}

// MARK: - Index cursor

private final class IndexCursor: GlobalIndexCursor {
    private let stream: PsybridgeIndexStream
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = IndexCursor.parseDate(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        return decoder
    }()

    init(_ stream: PsybridgeIndexStream) { self.stream = stream }
    deinit { stream.close() }

    func next(maxEntries: Int) throws -> [GlobalIndexEntry] {
        let data: Data
        do {
            data = try stream.next(Int64(maxEntries))
        } catch {
            throw PsyBridgeError(error)
        }
        return try Self.decoder.decode([GlobalIndexEntry].self, from: data)
    }

    func close() { stream.close() }

    /// RFC 3339 with optional fractional seconds (Go's RFC3339Nano trims zeros).
    /// ISO8601DateFormatter is thread-safe, so the formatters are shared.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }
}

// MARK: - Helpers

private extension Duration {
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}

/// gomobile object; upstream's Matcher is internally synchronised.
private final class GoIgnoreMatcher: IgnoreMatching, @unchecked Sendable {
    private let matcher: PsybridgeIgnoreMatcher
    init(_ matcher: PsybridgeIgnoreMatcher) { self.matcher = matcher }
    func isIgnored(_ path: RelativePath) -> Bool { matcher.match(path.rawValue) }
}
