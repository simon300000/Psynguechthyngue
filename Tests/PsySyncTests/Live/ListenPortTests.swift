import Darwin
import Foundation
import Testing
@testable import PsySync

@Suite struct ListenAddressPlannerTests {
    @Test func rewritesDefaultKeepingRelays() {
        #expect(ListenAddressPlanner.rewrite(["default"], port: 22007) ==
                ["tcp://:22007", "quic://:22007", "dynamic+https://relays.syncthing.net/endpoint"])
    }

    @Test func rewritesExplicitDefaultPortOnly() {
        let input = ["tcp://0.0.0.0:22000", "quic://[::]:22000", "tcp://:22000", "dynamic+https://relays.syncthing.net/endpoint", "tcp://:4000"]
        #expect(ListenAddressPlanner.rewrite(input, port: 22050) ==
                ["tcp://0.0.0.0:22050", "quic://[::]:22050", "tcp://:22050", "dynamic+https://relays.syncthing.net/endpoint", "tcp://:4000"])
    }

    @Test func leavesCustomOrAlreadyMovedAddressesAlone() {
        #expect(ListenAddressPlanner.rewrite(["tcp://:4000", "quic://:4000"], port: 22001) == nil)
        #expect(ListenAddressPlanner.rewrite(["tcp://:22001", "quic://:22001", ListenAddressPlanner.defaultRelay], port: 22001) == nil)
        #expect(ListenAddressPlanner.rewrite(["relay://host:122000"], port: 22001) == nil)
        #expect(ListenAddressPlanner.rewrite(["dynamic+https://relays.syncthing.net/endpoint"], port: 22001) == nil)
    }

    @Test func alternatePortDecision() {
        let busy: Set<Int> = [22001, 22002]
        let isFree: (Int) -> Bool = { !busy.contains($0) }
        // 22000 free, not on Mac → keep the default.
        #expect(ListenAddressPlanner.alternatePort(stored: nil, defaultFree: true, preferAlternate: false, isFree: isFree) == nil)
        // 22000 taken → first free port in 22001…22099.
        #expect(ListenAddressPlanner.alternatePort(stored: nil, defaultFree: false, preferAlternate: false, isFree: isFree) == 22003)
        // Mac → always move, even if 22000 looks free.
        #expect(ListenAddressPlanner.alternatePort(stored: nil, defaultFree: true, preferAlternate: true, isFree: isFree) == 22003)
        // A previously chosen port wins (stable address for peers).
        #expect(ListenAddressPlanner.alternatePort(stored: 22042, defaultFree: false, preferAlternate: true, isFree: { _ in false }) == 22042)
        // Nothing free in the range → random port.
        #expect(ListenAddressPlanner.alternatePort(stored: nil, defaultFree: false, preferAlternate: false, isFree: { _ in false }) == 0)
    }

    /// A socket bound with SO_REUSEPORT (as upstream Syncthing does) must make
    /// the probe report the port as taken; after closing it is free again.
    @Test func probeDetectsReusePortListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        #expect(bound)
        #expect(listen(fd, 1) == 0)
        let port = Int(UInt16(bigEndian: addr.sin_port))
        #expect(!ListenAddressPlanner.isPortFree(port))
        close(fd)
        #expect(ListenAddressPlanner.isPortFree(port))
        #expect(!ListenAddressPlanner.isPortFree(0))
    }
}

extension LiveSyncEngineTests {
    @Test func movesListenerOffBusyDefaultPortAndPersistsIt() async throws {
        let probed = Box<[Int]>([])
        let lock = NSLock()
        let h = try makeHarness { cfg in
            cfg.portProbe = { port in
                lock.withLock { probed.value.append(port) }
                return port > 22002   // 22000–22002 taken
            }
        }
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        #expect(h.fake.currentOptions.listenAddresses ==
                ["tcp://:22003", "quic://:22003", "dynamic+https://relays.syncthing.net/endpoint"])
        #expect(lock.withLock { probed.value.first } == 22000)
        try await h.engine.stop(deadline: .seconds(1))
        #expect(LiveEngineAppState.load(from: AppGroupLayout(root: h.root).engineHome).listenPort == 22003)

        // Next launch: the stored port is reused without probing again.
        lock.withLock { probed.value = [] }
        let h2 = try makeHarness(root: h.root) { cfg in
            cfg.portProbe = { port in lock.withLock { probed.value.append(port) }; return false }
        }
        try await h2.engine.start(context: .foreground)
        #expect(h2.fake.currentOptions.listenAddresses ==
                ["tcp://:22003", "quic://:22003", "dynamic+https://relays.syncthing.net/endpoint"])
        #expect(lock.withLock { probed.value }.isEmpty)
        try await h2.engine.stop(deadline: .seconds(1))
    }

    @Test func keepsDefaultListenerWhenFreeOffMac() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        #expect(h.fake.currentOptions.listenAddresses == ["default"])
        let listenPatches = StubURLProtocol.requests(authority: h.authority).filter {
            $0.method == "PATCH" && $0.path == "/rest/config/options" && String(decoding: $0.body ?? Data(), as: UTF8.self).contains("listenAddresses")
        }
        #expect(listenPatches.isEmpty)
        try await h.engine.stop(deadline: .seconds(1))
        #expect(LiveEngineAppState.load(from: AppGroupLayout(root: h.root).engineHome).listenPort == nil)
    }

    @Test func onMacAlwaysMovesListener() async throws {
        let h = try makeHarness { cfg in cfg.preferAlternateListenPort = true }
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        #expect(h.fake.currentOptions.listenAddresses?.first == "tcp://:22001")
        try await h.engine.stop(deadline: .seconds(1))
    }

    @Test func refusesNonLoopbackRESTEndpoint() async throws {
        let h = try makeHarness(baseURL: URL(string: "http://192.0.2.10:8384/")!)
        defer { try? FileManager.default.removeItem(at: h.root) }
        await #expect(throws: EngineError.bridge(code: "listen", detail: "REST endpoint is not on loopback")) {
            try await h.engine.start(context: .foreground)
        }
        #expect(h.lock.currentHolder() == nil)
        #expect(h.bridge.callList.contains("stop"))
    }

    @Test func loopbackHosts() {
        #expect(LiveSyncEngine.isLoopback(URL(string: "http://127.0.0.1:1234/")!))
        #expect(LiveSyncEngine.isLoopback(URL(string: "http://[::1]:1234/")!))
        #expect(!LiveSyncEngine.isLoopback(URL(string: "http://0.0.0.0:1234/")!))
        #expect(!LiveSyncEngine.isLoopback(URL(string: "http://10.0.0.1:1234/")!))
    }
}
