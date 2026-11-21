import Foundation
import Testing
@testable import PsySync

@Suite struct ReducedResourcePolicyTests {
    let policy = DefaultSyncPolicy()

    @Test func throttlesButNeverPauses() {
        var p = PolicyPreferences()
        let wifi = policy.decide(inputs: .init(network: .wifiOrWired, systemPrefersReducedResourceUsage: true), preferences: p)
        #expect(wifi == PolicyDecision(sendLimitKiBps: 1024, receiveLimitKiBps: 4096, reducedResourceUsage: true))
        // A stricter cellular limit wins; a looser one is capped.
        p.cellularSendLimitKiBps = 100
        p.cellularReceiveLimitKiBps = 100_000
        let cell = policy.decide(inputs: .init(network: .cellular, systemPrefersReducedResourceUsage: true), preferences: p)
        #expect(cell == PolicyDecision(sendLimitKiBps: 100, receiveLimitKiBps: 4096, reducedResourceUsage: true))
        // Holds take precedence and carry no reduced flag.
        #expect(policy.decide(inputs: .init(network: .none, systemPrefersReducedResourceUsage: true), preferences: p)
                == PolicyDecision(hold: .noNetwork))
    }

    @Test func decodesValuesPersistedBeforeTheField() throws {
        let d = try JSONDecoder().decode(PolicyDecision.self, from: Data(#"{"hold":"thermal","sendLimitKiBps":0,"receiveLimitKiBps":0}"#.utf8))
        #expect(d == PolicyDecision(hold: .thermal))
        let i = try JSONDecoder().decode(PolicyInputs.self, from: Data(
            #"{"network":"cellular","isExpensive":true,"isConstrained":false,"isLowPowerMode":false,"isCharging":false,"thermalSerious":false}"#.utf8))
        #expect(i == PolicyInputs(network: .cellular, isExpensive: true))
        let round = PolicyDecision(sendLimitKiBps: 1, receiveLimitKiBps: 2, reducedResourceUsage: true)
        #expect(try JSONDecoder().decode(PolicyDecision.self, from: JSONEncoder().encode(round)) == round)
    }
}

extension LiveSyncEngineTests {
    @Test func reducedLoadAppliesAndRestoresEngineOptions() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.fake.setLoadOptions(maxFolderConcurrency: 3, limitBandwidthInLan: false)   // user/upstream values
        try await h.engine.start(context: .foreground)
        try await h.engine.apply(DefaultSyncPolicy().decide(
            inputs: .init(network: .wifiOrWired, systemPrefersReducedResourceUsage: true), preferences: .init()))
        var o = h.fake.currentOptions
        #expect(o.maxSendKbps == 1024 && o.maxRecvKbps == 4096)
        #expect(o.maxFolderConcurrency == 1 && o.limitBandwidthInLan == true)
        // No device is paused for it.
        #expect(h.fake.device(FakeSyncEngine.sampleIDs[0]) == nil || h.fake.device(FakeSyncEngine.sampleIDs[0])?.paused == false)
        // Survives a restart while still reduced (saved values kept, not overwritten by 1/true).
        try await h.engine.stop(deadline: .seconds(1))
        try await h.engine.start(context: .foreground)
        try await h.engine.apply(.run)
        o = h.fake.currentOptions
        #expect(o.maxSendKbps == 0 && o.maxRecvKbps == 0)
        #expect(o.maxFolderConcurrency == 3 && o.limitBandwidthInLan == false)
        #expect(LiveEngineAppState.load(from: AppGroupLayout(root: h.root).engineHome).savedLoadOptions == nil)
        try await h.engine.stop(deadline: .seconds(1))
    }
}
