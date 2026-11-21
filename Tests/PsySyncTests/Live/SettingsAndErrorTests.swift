import Foundation
import Testing
@testable import PsySync

/// Mirrors Platform/PsyBridgeAdapter.swift's `PsyBridgeError`: only
/// CustomStringConvertible, so `localizedDescription` is "… error 1".
private struct AdapterLikeError: Error, CustomStringConvertible {
    let code: BridgeContract.Code?
    let detail: String
    var description: String { code.map { "psy:\($0.rawValue): \(detail)" } ?? detail }
}

private struct LocalizedBridgeError: LocalizedError {
    var errorDescription: String? { "psy:no_peer: nobody online" }
}

@Suite struct BridgeErrorMappingTests {
    @Test func mapsAdapterErrorCodes() {
        #expect(String(describing: (AdapterLikeError(code: .stopTimeout, detail: "x") as NSError).localizedDescription).contains("error"))
        #expect(LiveSyncEngine.map(AdapterLikeError(code: .stopTimeout, detail: "still running")) ==
                .bridge(code: "stop_timeout", detail: "still running"))
        #expect(LiveSyncEngine.map(AdapterLikeError(code: .listen, detail: "address in use")) ==
                .bridge(code: "listen", detail: "address in use"))
        #expect(LiveSyncEngine.map(AdapterLikeError(code: nil, detail: "Start returned no result")) ==
                .bridge(code: "unknown", detail: "Start returned no result"))
        #expect(LiveSyncEngine.map(LocalizedBridgeError()) == .bridge(code: "no_peer", detail: "nobody online"))
        #expect(LiveSyncEngine.map(EngineError.notRunning) == .notRunning)
        #expect(LiveSyncEngine.map(NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "psy:io: disk"])) ==
                .bridge(code: "io", detail: "disk"))
    }
}

@Suite struct TransientFolderErrorTests {
    let f = FolderID(rawValue: "f")
    let a = DeviceID(rawValue: "A")

    @Test func classifiesDisconnectErrors() {
        for m in ["peers who had this file went away, or the file has changed while syncing. will retry later",
                  "pull: no connected device has the required version of this file",
                  "pull: connection closed", "read tcp 1.2.3.4:22000: i/o timeout", "pull: EOF", "unexpected EOF",
                  "context canceled", "write: broken pipe", "connection reset by peer"] {
            #expect(StatusMapper.isTransientDisconnectError(m), "\(m)")
        }
        for m in ["permission denied", "insufficient space", "file modified but not rescanned; will try again later",
                  "geoffrey", "not a directory"] {
            #expect(!StatusMapper.isTransientDisconnectError(m), "\(m)")
        }
    }

    @Test func waitingForDevicesHidesFileErrors() {
        let s = StatusMapper.map(FolderStatusInputs(
            folderID: f, needBytes: 10, needItems: 2,
            remotes: [a: .init(completion: 100, remoteState: "valid", connected: false)],
            folderErrors: [.init(path: "x", error: "permission denied"), .init(path: "y", error: "pull: connection closed")]))
        #expect(s.state == .waitingForDevices)
        #expect(s.issues.isEmpty)
    }

    @Test func waitingForDevicesKeepsFolderLevelError() {
        let s = StatusMapper.map(FolderStatusInputs(
            folderID: f, upstreamError: "insufficient space on disk", needItems: 1,
            remotes: [a: .init(completion: 100, remoteState: "valid", connected: false)]))
        #expect(s.issues.map(\.kind) == [.outOfSpace])
    }

    @Test func disconnectErrorsWithPeerOnlineAreNotProblems() {
        let s = StatusMapper.map(FolderStatusInputs(
            folderID: f, needItems: 1,
            remotes: [a: .init(completion: 100, remoteState: "valid", connected: true)],
            folderErrors: [.init(path: "x", error: "peers who had this file went away, or the file has changed while syncing. will retry later")]))
        #expect(s.state == .syncing)   // not .error: upstream retries on its own
        #expect(s.issues.isEmpty)
        // Real errors are still reported next to transient ones.
        let t = StatusMapper.map(FolderStatusInputs(
            folderID: f, needItems: 2,
            remotes: [a: .init(completion: 100, remoteState: "valid", connected: true)],
            folderErrors: [.init(path: "x", error: "pull: EOF"), .init(path: "y", error: "permission denied")]))
        #expect(t.issues.map(\.path) == [RelativePath(rawValue: "y")])
    }
}

extension LiveSyncEngineTests {
    @Test func engineOptionsRoundTrip() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        await #expect(throws: EngineError.notRunning) { _ = try await h.engine.options() }
        try await h.engine.start(context: .foreground)
        #expect(try await h.engine.options() == EngineOptions(deviceName: "me"))
        try await h.engine.updateOptions(EngineOptions(deviceName: "  Test iPad ", globalDiscovery: false, relays: false,
                                                       listenAddresses: ["tcp://:23000"]))
        #expect(try await h.engine.options() == EngineOptions(deviceName: "Test iPad", globalDiscovery: false, relays: false,
                                                              listenAddresses: ["tcp://:23000"]))
        await #expect(throws: EngineError.self) { try await h.engine.updateOptions(EngineOptions(deviceName: " ")) }
        await #expect(throws: EngineError.self) {
            try await h.engine.updateOptions(EngineOptions(deviceName: "x", listenAddresses: [" "]))
        }
        #expect(await h.engine.syncthingVersion == "v2.1.6")
        try await h.engine.stop(deadline: .seconds(1))
        #expect(await h.engine.syncthingVersion == "v2.1.6")   // from the bridge when stopped
    }

    @Test func resettingListenAddressesKeepsSharedPortProtection() async throws {
        let h = try makeHarness { cfg in cfg.preferAlternateListenPort = true }
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        try await h.engine.updateOptions(EngineOptions(deviceName: "me", listenAddresses: ["default"]))
        #expect(try await h.engine.options().listenAddresses.first == "tcp://:22001")
        try await h.engine.stop(deadline: .seconds(1))
    }

    @Test func userIgnoreRulesForBothContentModes() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        // Everything mode: rules are the folder's .stignore via REST.
        let all = FolderID(rawValue: "all")
        try await h.engine.addFolder(Folder(id: all, label: "All", contentMode: .everything))
        try await h.engine.setUserIgnoreRules(all, ["*.tmp", "/build"])
        #expect(try await h.engine.userIgnoreRules(all) == ["*.tmp", "/build"])
        await #expect(throws: EngineError.self) { try await h.engine.setUserIgnoreRules(all, ["a\nb"]) }

        // On-demand: .stignore-user, managed section untouched.
        let od = FolderID(rawValue: "od")
        try await h.engine.addFolder(Folder(id: od, label: "OD", contentMode: .onDemand))
        let managed = try await h.engine.userIgnoreRules(od)
        #expect(managed.isEmpty)
        let before = StubURLProtocol.requests(authority: h.authority).filter { $0.method == "POST" && $0.path == "/rest/db/ignores" && $0.query["folder"] == "od" }.count
        try await h.engine.setUserIgnoreRules(od, ["*.psd"])
        #expect(try await h.engine.userIgnoreRules(od) == ["*.psd"])
        let dir = AppGroupLayout(root: h.root).managedFolder(od)
        #expect(try String(contentsOf: dir.appending(path: ".stignore-user"), encoding: .utf8) == "*.psd\n")
        let after = StubURLProtocol.requests(authority: h.authority).filter { $0.method == "POST" && $0.path == "/rest/db/ignores" && $0.query["folder"] == "od" }
        #expect(after.count == before + 1)   // managed section re-posted so upstream reloads the include
        try await h.engine.stop(deadline: .seconds(1))
    }
}

@Suite struct FakeSyncEngineSettingsTests {
    @Test func fakeSupportsSettings() async throws {
        let e = FakeSyncEngine(named: "empty")
        var o = try await e.options()
        o.relays = false
        try await e.updateOptions(o)
        #expect(try await e.options().relays == false)
        try await e.setUserIgnoreRules(FolderID(rawValue: "f"), ["*.tmp"])
        #expect(try await e.userIgnoreRules(FolderID(rawValue: "f")) == ["*.tmp"])
        #expect(await e.syncthingVersion == "v2.1.6")
    }
}
