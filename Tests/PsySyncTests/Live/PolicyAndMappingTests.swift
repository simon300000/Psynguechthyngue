import Foundation
import Testing
@testable import PsySync

@Suite struct DefaultSyncPolicyTests {
    /// Independent oracle written straight from DESIGN.md §4.4's table.
    static func oracle(_ i: PolicyInputs, _ p: PolicyPreferences) -> PolicyDecision {
        let rows: [(Bool, PolicyDecision.HoldReason)] = [
            (i.network == .none, .noNetwork),
            (i.network == .cellular && !p.syncOnCellular, .cellularDisallowed),
            (i.isConstrained && p.respectLowDataMode, .lowDataMode),
            (i.isLowPowerMode && p.pauseInLowPowerMode, .lowPowerMode),
            (i.thermalSerious, .thermal),
        ]
        if let hit = rows.first(where: { $0.0 }) { return PolicyDecision(hold: hit.1) }
        var send = 0, recv = 0
        if i.network == .cellular {
            send = p.cellularSendLimitKiBps; recv = p.cellularReceiveLimitKiBps
        }
        guard i.systemPrefersReducedResourceUsage else {
            return PolicyDecision(sendLimitKiBps: send, receiveLimitKiBps: recv)
        }
        // Reduced load: 0 (unlimited) → cap; a stricter user limit wins.
        return PolicyDecision(sendLimitKiBps: send == 0 ? 1024 : min(send, 1024),
                              receiveLimitKiBps: recv == 0 ? 4096 : min(recv, 4096),
                              reducedResourceUsage: true)
    }

    static var allInputs: [PolicyInputs] {
        var out: [PolicyInputs] = []
        for network in [PolicyInputs.Network.none, .wifiOrWired, .cellular] {
            for expensive in [false, true] {
                for constrained in [false, true] {
                    for lowPower in [false, true] {
                        for charging in [false, true] {
                            for battery in [nil, 0.01, 0.19, 0.5, 1.0] as [Double?] {
                                for thermal in [false, true] {
                                    for reduced in [false, true] {
                                        out.append(PolicyInputs(network: network, isExpensive: expensive, isConstrained: constrained,
                                                                isLowPowerMode: lowPower, isCharging: charging, batteryLevel: battery,
                                                                thermalSerious: thermal, systemPrefersReducedResourceUsage: reduced))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    static var allPreferences: [PolicyPreferences] {
        var out: [PolicyPreferences] = []
        for cellular in [false, true] {
            for ldm in [false, true] {
                for lpm in [false, true] {
                    for send in [0, 128, 2048] {
                        for recv in [0, 512, 8192] {
                            var p = PolicyPreferences()
                            p.syncOnCellular = cellular
                            p.respectLowDataMode = ldm
                            p.pauseInLowPowerMode = lpm
                            p.cellularSendLimitKiBps = send
                            p.cellularReceiveLimitKiBps = recv
                            out.append(p)
                        }
                    }
                }
            }
        }
        return out
    }

    @Test func exhaustiveMatchesDesignTable() {
        let policy = DefaultSyncPolicy()
        var count = 0
        for i in Self.allInputs {
            for p in Self.allPreferences {
                let d = policy.decide(inputs: i, preferences: p)
                #expect(d == Self.oracle(i, p), "inputs=\(i) prefs=\(p)")
                // Invariants
                if d.hold != nil { #expect(d.sendLimitKiBps == 0 && d.receiveLimitKiBps == 0) }
                if i.network == .wifiOrWired && d.hold == nil && !i.systemPrefersReducedResourceUsage { #expect(d == .run) }
                // Reduced resource usage never causes a hold and never loosens a limit.
                var calm = i
                calm.systemPrefersReducedResourceUsage = false
                let base = policy.decide(inputs: calm, preferences: p)
                #expect(d.hold == base.hold)
                if i.systemPrefersReducedResourceUsage && d.hold == nil {
                    #expect(d.reducedResourceUsage)
                    #expect(d.sendLimitKiBps > 0 && d.sendLimitKiBps <= DefaultSyncPolicy.reducedSendLimitKiBps)
                    #expect(d.receiveLimitKiBps > 0 && d.receiveLimitKiBps <= DefaultSyncPolicy.reducedReceiveLimitKiBps)
                    if base.sendLimitKiBps > 0 { #expect(d.sendLimitKiBps <= base.sendLimitKiBps) }
                    if base.receiveLimitKiBps > 0 { #expect(d.receiveLimitKiBps <= base.receiveLimitKiBps) }
                } else {
                    #expect(!d.reducedResourceUsage)
                }
                // Battery level / charging never change the decision.
                var j = i
                j.batteryLevel = 0.01
                j.isCharging.toggle()
                #expect(policy.decide(inputs: j, preferences: p) == d)
                count += 1
            }
        }
        #expect(count == 3 * 2 * 2 * 2 * 2 * 5 * 2 * 2 * (2 * 2 * 2 * 3 * 3))
    }

    @Test func defaultsArePermissive() {
        let policy = DefaultSyncPolicy()
        let prefs = PolicyPreferences()
        #expect(policy.decide(inputs: .init(network: .cellular, isExpensive: true), preferences: prefs) == .run)
        #expect(policy.decide(inputs: .init(network: .wifiOrWired, isLowPowerMode: true, batteryLevel: 0.05), preferences: prefs) == .run)
        #expect(policy.decide(inputs: .init(network: .wifiOrWired, isConstrained: true), preferences: prefs).hold == .lowDataMode)
        #expect(policy.decide(inputs: .init(network: .none), preferences: prefs).hold == .noNetwork)
    }

    @Test func pure() {
        let policy = DefaultSyncPolicy()
        let i = PolicyInputs(network: .cellular, isConstrained: true)
        let p = PolicyPreferences()
        #expect(Set((0..<100).map { _ in policy.decide(inputs: i, preferences: p) }).count == 1)
    }
}

@Suite struct StatusMapperTests {
    let f = FolderID(rawValue: "f1")
    let a = DeviceID(rawValue: "A"), b = DeviceID(rawValue: "B")

    func state(_ build: (inout FolderStatusInputs) -> Void) -> FolderSyncState {
        var i = FolderStatusInputs(folderID: f)
        build(&i)
        return StatusMapper.map(i).state
    }

    @Test func precedence() {
        #expect(state { $0.engineRunning = false; $0.folderPaused = true } == .offline)
        #expect(state { $0.folderPaused = true; $0.policyHeld = true } == .paused)
        #expect(state { $0.policyHeld = true; $0.upstreamState = "error" } == .heldByPolicy)
        #expect(state { $0.upstreamState = "error"; $0.upstreamError = "folder path missing" } == .error)
        #expect(state { $0.upstreamState = "scanning" } == .scanning)
        #expect(state { $0.upstreamState = "scan-waiting" } == .scanning)
        #expect(state { $0.upstreamState = "syncing" } == .syncing)
        #expect(state { $0.upstreamState = "sync-preparing" } == .syncing)
        #expect(state { _ in } == .upToDate)
    }

    @Test func offlinePeersNeverBlockUpToDate() {
        // A online and complete, B offline and behind (AUDIT P0 scenario).
        #expect(state {
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true),
                          b: .init(completion: 10, remoteState: "valid", connected: false)]
        } == .upToDate)
        // Never-seen device next to an online, complete peer: ignored.
        #expect(state {
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true),
                          b: .init(completion: 0, remoteState: "unknown", connected: false)]
        } == .upToDate)
        // Connected peer that does not share the folder back: ignored.
        #expect(state {
            $0.remotes = [a: .init(completion: 0, remoteState: "notSharing", connected: true)]
        } == .upToDate)
    }

    @Test func waitingForDevices() {
        // Local needs, nobody online.
        #expect(state {
            $0.needBytes = 10; $0.needItems = 1
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: false)]
        } == .waitingForDevices)
        // Our changes not yet uploaded, nobody online (upstream reports a
        // disconnected peer as "unknown"/"paused", not "valid").
        for rs in ["valid", "unknown", "paused"] {
            #expect(state {
                $0.remotes = [a: .init(completion: 50, remoteState: rs, connected: false)]
            } == .waitingForDevices)
        }
        // Same with a peer online → syncing (upload).
        #expect(state {
            $0.remotes = [a: .init(completion: 50, remoteState: "valid", connected: true)]
        } == .syncing)
        // Local needs with a peer online → syncing.
        #expect(state {
            $0.needItems = 2
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .syncing)
    }

    @Test func blockedByFileErrors() {
        #expect(state {
            $0.needItems = 1
            $0.folderErrors = [.init(path: "x", error: "permission denied")]
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .error)
        // Some items still progressing → not an error.
        #expect(state {
            $0.needItems = 3
            $0.folderErrors = [.init(path: "x", error: "boom")]
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .syncing)
    }

    @Test func issuesAndProgress() {
        var i = FolderStatusInputs(folderID: f, upstreamState: "error", upstreamError: "folder marker missing (.stfolder)",
                                   globalBytes: 100, needBytes: 25,
                                   remotes: [a: .init(completion: 80, remoteState: "valid", connected: true),
                                             b: .init(completion: 0, remoteState: "notSharing", connected: true)],
                                   folderErrors: [.init(path: "p/q", error: "insufficient space")])
        i.now = Date(timeIntervalSince1970: 1)
        let s = StatusMapper.map(i)
        #expect(s.issues.map(\.kind) == [.folderPathMissing, .outOfSpace])
        #expect(s.issues[1].path == RelativePath(rawValue: "p/q"))
        #expect(s.progress.fractionCompleted == 0.75)
        #expect(s.progress.remoteCompletion == [a: 80])
        #expect(StatusMapper.classify("open /x: permission denied") == .permissionDenied)
    }
}

@Suite struct IgnoreRulesGeneratorTests {
    @Test func generatesManagedFile() throws {
        let lines = try IgnoreRulesGenerator.lines(present: [RelativePath(rawValue: "Photos/2026"), RelativePath(rawValue: "Docs/report.pdf")])
        #expect(lines == [IgnoreRulesGenerator.header, "#include .stignore-user", "!/Docs/report.pdf", "!/Photos/2026", "*"])
        #expect(try IgnoreRulesGenerator.lines(present: []) == [IgnoreRulesGenerator.header, "#include .stignore-user", "*"])
    }

    @Test func escapesGlobCharactersAndRoundTrips() throws {
        let tricky = ["a*b?.txt", "[x]{y}", "back\\slash", "!bang", "#hash", "(?i)x", "x/(?d)y", "中文 文件.txt", "sp ace/ok"]
        let paths = tricky.map(RelativePath.init(rawValue:))
        let lines = try IgnoreRulesGenerator.lines(present: paths)
        #expect(lines.contains("!/a\\*b\\?.txt"))
        #expect(lines.contains("!/\\[x\\]\\{y\\}"))
        #expect(lines.contains("!/back\\\\slash"))
        #expect(lines.allSatisfy { $0 == IgnoreRulesGenerator.header || $0.hasPrefix("!/") || $0 == "*" || $0.hasPrefix("#include") })
        #expect(IgnoreRulesGenerator.presentPaths(from: lines) == Set(paths.map { RelativePath(rawValue: $0.rawValue.precomposedStringWithCanonicalMapping) }))
    }

    @Test func rejectsUnrepresentable() {
        for bad in ["", "/abs", "a/../b", "a//b", "line\nbreak", "./x", "a/"] {
            #expect(throws: IgnoreRulesGenerator.RuleError.self) { try IgnoreRulesGenerator.pattern(for: RelativePath(rawValue: bad)) }
        }
    }

    @Test func unmanagedFilesYieldNoPresence() {
        #expect(IgnoreRulesGenerator.presentPaths(from: ["!/x", "*"]).isEmpty)
        #expect(!IgnoreRulesGenerator.isManaged(["foo"]))
    }

    @Test func dedupes() throws {
        let p = RelativePath(rawValue: "a")
        #expect(try IgnoreRulesGenerator.lines(present: [p, p]).filter { $0 == "!/a" }.count == 1)
    }
}
