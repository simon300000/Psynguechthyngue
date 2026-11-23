#if os(macOS)
import Darwin
import Foundation
@testable import PsySync

/// Test-only `SyncthingBridge` that runs the official Syncthing binary as a
/// child process (stand-in for psybridge until lands). Mirrors what the
/// real bridge promises: REST on 127.0.0.1 only, a fresh random API key per
/// start, no upgrades/usage reporting/crash reporting. For isolation it also
/// disables global/local discovery, relays and NAT and listens on loopback.
final class ProcessSyncthingBridge: SyncthingBridge, @unchecked Sendable {
    static let binary = "/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing"

    let listenPort: Int
    private let lock = NSLock()
    private var process: Process?
    private(set) var endpoint: RESTEndpoint?

    init() {
        listenPort = Self.freePort()
    }

    // MARK: Identity

    func generateIdentity() throws -> DeviceIdentity {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "psy-gen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Self.run(["generate", "--home=\(tmp.path(percentEncoded: false))", "--no-port-probing"])
        let cert = try Data(contentsOf: tmp.appending(path: "cert.pem"))
        let key = try Data(contentsOf: tmp.appending(path: "key.pem"))
        let upstreamID = try Self.run(["device-id", "--home=\(tmp.path(percentEncoded: false))"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let id = try DeviceIDCodec.deviceID(certificatePEM: cert)
        guard id.rawValue == upstreamID else {
            throw TestBridgeError(message: "psy:identity: codec mismatch \(id) vs \(upstreamID)")
        }
        return DeviceIdentity(certificatePEM: cert, privateKeyPEM: key, deviceID: id)
    }

    func applyMemoryProfile(_ profile: MemoryProfile) {}
    func syncthingVersion() -> String { (try? Self.run(["--version"])) ?? "" }
    func onMemoryWarning() {}

    func openIndexStream(folder: FolderID) throws -> any GlobalIndexCursor {
        throw TestBridgeError(message: "psy:not_implemented: index stream needs psybridge")
    }

    // MARK: Lifecycle

    func start(homeDirectory: URL, identity: DeviceIdentity, deviceName: String, timeout: Duration) throws -> RESTEndpoint {
        if lock.withLock({ process?.isRunning == true }) {
            throw TestBridgeError(message: "psy:already_running: running")
        }
        let home = homeDirectory.path(percentEncoded: false)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        try identity.certificatePEM.write(to: homeDirectory.appending(path: "cert.pem"), options: .atomic)
        try identity.privateKeyPEM.write(to: homeDirectory.appending(path: "key.pem"), options: .atomic)
        let configURL = homeDirectory.appending(path: "config.xml")
        if !FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)) {
            try Self.run(["generate", "--home=\(home)", "--no-port-probing"], env: ["STNODEFAULTFOLDER": "1"])
        }
        try configure(configURL, deviceID: identity.deviceID, deviceName: deviceName)

        let guiPort = Self.freePort()
        let apiKey = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.prefix(8)
        let p = Process()
        p.executableURL = URL(filePath: Self.binary)
        p.arguments = [
            "serve", "--home=\(home)", "--no-browser", "--no-upgrade", "--no-restart",
            "--gui-address=http://127.0.0.1:\(guiPort)",
            "--log-file=\(homeDirectory.appending(path: "syncthing.log").path(percentEncoded: false))",
        ]
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PSY_E2E") }
        env["STNODEFAULTFOLDER"] = "1"
        env["STNOUPGRADE"] = "1"
        env["STGUIAPIKEY"] = apiKey   // env, not argv: never visible in `ps`
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        lock.withLock { process = p }

        let base = URL(string: "http://127.0.0.1:\(guiPort)/")!
        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
        while Date() < deadline {
            if !p.isRunning { throw TestBridgeError(message: "psy:listen: syncthing exited with \(p.terminationStatus)") }
            if Self.syncPing(base, apiKey: apiKey) {
                let ep = RESTEndpoint(baseURL: base, apiKey: apiKey, deviceID: identity.deviceID)
                lock.withLock { endpoint = ep }
                return ep
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        p.terminate()
        throw TestBridgeError(message: "psy:deadline: REST did not come up")
    }

    func stop(timeout: Duration) throws {
        guard let p = lock.withLock({ process }) else { throw TestBridgeError(message: "psy:not_running: not running") }
        defer { lock.withLock { process = nil; endpoint = nil } }
        guard p.isRunning else { return }
        p.terminate()   // SIGTERM → graceful shutdown upstream
        let deadline = Date().addingTimeInterval(max(1, Double(timeout.components.seconds)))
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            throw TestBridgeError(message: "psy:stop_timeout: syncthing did not exit")
        }
    }

    // MARK: Helpers

    private func configure(_ url: URL, deviceID: DeviceID, deviceName: String) throws {
        let doc = try XMLDocument(contentsOf: url)
        func set(_ xpath: String, _ value: String) throws {
            for node in try doc.nodes(forXPath: xpath) { node.stringValue = value }
        }
        try set("/configuration/options/listenAddress", "tcp://127.0.0.1:\(listenPort)")
        try set("/configuration/options/globalAnnounceEnabled", "false")
        try set("/configuration/options/localAnnounceEnabled", "false")
        try set("/configuration/options/relaysEnabled", "false")
        try set("/configuration/options/natEnabled", "false")
        try set("/configuration/options/urAccepted", "-1")
        try set("/configuration/options/autoUpgradeIntervalH", "0")
        try set("/configuration/options/crashReportingEnabled", "false")
        try set("/configuration/options/startBrowser", "false")
        try set("/configuration/gui/address", "127.0.0.1:0")
        for case let el as XMLElement in try doc.nodes(forXPath: "/configuration/device[@id='\(deviceID.rawValue)']") {
            el.attribute(forName: "name")?.stringValue = deviceName
        }
        try doc.xmlData(options: .nodePrettyPrint).write(to: url, options: .atomic)
    }

    @discardableResult
    static func run(_ args: [String], env: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: binary)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PSY_E2E") }.merging(env) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TestBridgeError(message: "psy:config: syncthing \(args.first ?? "") failed") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func syncPing(_ base: URL, apiKey: String) -> Bool {
        var req = URLRequest(url: base.appending(path: "rest/system/ping"))
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 1
        let sem = DispatchSemaphore(value: 0)
        let ok = Box(false)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok.value = (resp as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        sem.wait()
        return ok.value
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
#endif
