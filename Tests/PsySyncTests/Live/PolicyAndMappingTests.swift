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
            (i.thermalSerious && p.pauseWhenHot, .thermal),
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
                    for hot in [false, true] {
                        for send in [0, 128, 2048] {
                            for recv in [0, 512, 8192] {
                                var p = PolicyPreferences()
                                p.syncOnCellular = cellular
                                p.respectLowDataMode = ldm
                                p.pauseInLowPowerMode = lpm
                                p.pauseWhenHot = hot
                                p.cellularSendLimitKiBps = send
                                p.cellularReceiveLimitKiBps = recv
                                out.append(p)
                            }
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
        #expect(count == 3 * 2 * 2 * 2 * 2 * 5 * 2 * 2 * (2 * 2 * 2 * 2 * 3 * 3))
    }

    @Test func thermalPauseIsOnByDefaultAndCanBeTurnedOff() {
        let policy = DefaultSyncPolicy()
        let hot = PolicyInputs(network: .wifiOrWired, thermalSerious: true)
        var prefs = PolicyPreferences()
        #expect(prefs.pauseWhenHot)
        #expect(policy.decide(inputs: hot, preferences: prefs).hold == .thermal)
        prefs.pauseWhenHot = false
        #expect(policy.decide(inputs: hot, preferences: prefs) == .run)
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
        #expect(state { $0.upstreamState = "sync-preparing" } == .fetchingIndex)
        #expect(state { $0.upstreamState = "sync-preparing"; $0.inProgressBytes = 1 } == .syncing)
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

    /// Honest status (user report: a re-added folder showed "Up to date,
    /// 0 KB" while the peer's 1059-file index was still arriving).
    @Test func neverUpToDateWhileTheFileListIsArriving() {
        let now = Date()
        // Peer connected, shares the folder, its index not in yet.
        #expect(state {
            $0.remotes = [a: .init(completion: 0, remoteState: "unknown", connected: true)]
        } == .fetchingIndex)
        // Index batches arrived just now (on-demand: nothing to pull, so no
        // "syncing" either).
        #expect(state {
            $0.now = now; $0.lastRemoteIndexAt = now.addingTimeInterval(-1); $0.globalItems = 400
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .fetchingIndex)
        // Upstream briefly reports needs while it applies the new entries;
        // nothing is moving, so it is still the file list arriving.
        #expect(state {
            $0.now = now; $0.lastRemoteIndexAt = now.addingTimeInterval(-1)
            $0.upstreamState = "sync-preparing"; $0.needItems = 5000; $0.needBytes = 33_000
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .fetchingIndex)
        // Slow link: last batch 20 s ago, still nothing moving.
        #expect(state {
            $0.now = now; $0.lastRemoteIndexAt = now.addingTimeInterval(-20)
            $0.upstreamState = "syncing"; $0.needItems = 7127; $0.needBytes = 7000
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .fetchingIndex)
        // Long after the index: real needs are syncing.
        #expect(state {
            $0.now = now; $0.lastRemoteIndexAt = now.addingTimeInterval(-(StatusMapper.indexActiveInterval + 1))
            $0.upstreamState = "syncing"; $0.needItems = 3
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .syncing)
        // Real transfer under way while more index arrives: syncing.
        #expect(state {
            $0.now = now; $0.lastRemoteIndexAt = now.addingTimeInterval(-1)
            $0.upstreamState = "syncing"; $0.needItems = 5; $0.inProgressBytes = 4096
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .syncing)
        // Settled.
        #expect(state {
            $0.now = now; $0.lastRemoteIndexAt = now.addingTimeInterval(-(StatusMapper.indexSettleInterval + 1))
            $0.globalItems = 1059
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .upToDate)
        // Nothing known and nobody connected: waiting, not "up to date 0 B".
        #expect(state {
            $0.remotes = [a: .init(completion: 0, remoteState: "unknown", connected: false)]
        } == .waitingForDevices)
        // A genuinely empty folder the peer has indexed is up to date.
        #expect(state {
            $0.remotes = [a: .init(completion: 100, remoteState: "valid", connected: true)]
        } == .upToDate)
        // No peers at all (local-only folder) stays up to date.
        #expect(state { _ in } == .upToDate)
        // Item count reaches the progress.
        var i = FolderStatusInputs(folderID: f); i.globalItems = 7
        #expect(StatusMapper.map(i).progress.globalItems == 7)
    }

    /// Real-device report: re-added "big-folder" (670k deletions beside 263
    /// files) showed "Up to date, 87.4 MB" 20 s in, while the peer was still
    /// sending its index. With the bridge's protocol-level phases the timing
    /// heuristics no longer decide anything.
    @Test func indexPhasesFromTheBridgeDecide() {
        let now = Date()
        let valid = [a: FolderStatusInputs.RemoteCompletion(completion: 100, remoteState: "valid", connected: true)]
        func map(_ phase: FolderStatusInputs.IndexPeer.Phase, _ build: (inout FolderStatusInputs) -> Void = { _ in })
            -> FolderStatus
        {
            var i = FolderStatusInputs(folderID: f)
            i.now = now
            i.remotes = valid
            i.globalBytes = 87_400_000
            i.globalItems = 19
            i.indexPeers = [a: .init(phase: phase, entries: 37_000, deletions: 36_981)]
            build(&i)
            return StatusMapper.map(i)
        }
        // Batches still full, last one long ago (slow phone): still arriving.
        let receiving = map(.receiving) { $0.lastRemoteIndexAt = now.addingTimeInterval(-120) }
        #expect(receiving.state == .fetchingIndex)
        #expect(receiving.progress.sizeIsPartial)
        #expect(receiving.progress.indexEntriesReceived == 37_000)
        #expect(receiving.progress.indexDeletionsReceived == 36_981)
        // Before the first batch, even with a "valid" remote state.
        #expect(map(.awaiting).state == .fetchingIndex)
        // Drained (short last batch): up to date at once, even 1 s after
        // the last batch (the 3 s settle window no longer applies).
        let done = map(.complete) { $0.lastRemoteIndexAt = now.addingTimeInterval(-1) }
        #expect(done.state == .upToDate)
        #expect(!done.progress.sizeIsPartial)
        // remoteState "unknown" alone no longer means "fetching".
        #expect(map(.complete) {
            $0.remotes = [a: .init(completion: 0, remoteState: "unknown", connected: true)]
        }.state == .upToDate)
        // A transfer already running shows as syncing, sizes still partial.
        let pulling = map(.receiving) { $0.upstreamState = "syncing"; $0.needBytes = 10; $0.needItems = 1; $0.inProgressBytes = 5 }
        #expect(pulling.state == .syncing)
        #expect(pulling.progress.sizeIsPartial)
        // A peer that does not share the folder back is not waited for.
        #expect(map(.awaiting) {
            $0.remotes = [a: .init(completion: 0, remoteState: "notSharing", connected: true)]
        }.state == .upToDate)
        // Cut off mid-transfer and the peer not back yet: partial, waiting.
        let cut = map(.interrupted) {
            $0.remotes = [a: .init(completion: 100, remoteState: "unknown", connected: false)]
        }
        #expect(cut.state == .waitingForDevices)
        #expect(cut.progress.sizeIsPartial)
        // Paused: no index work shown.
        #expect(map(.receiving) { $0.folderPaused = true }.state == .paused)
        #expect(!map(.receiving) { $0.folderPaused = true }.progress.sizeIsPartial)
    }

    @Test func composerAddsAppWorkAndNeverCallsAStoppedEngineCurrent() {
        let up = FolderStatus(folderID: f, state: .upToDate, progress: .init(globalBytes: 10, globalItems: 1000))
        // No status yet: unknown, not up to date.
        #expect(FolderStatusComposer.compose(folderID: f, engine: nil, engineRunning: true, listing: nil).state == .fetchingIndex)
        // Files list being filled behind the index.
        #expect(FolderStatusComposer.compose(
            folderID: f, engine: up, engineRunning: true, listing: .init(processed: 300, listedAtStart: 0)).state == .preparingFiles)
        // A re-read over a complete list is not shown.
        #expect(FolderStatusComposer.compose(
            folderID: f, engine: up, engineRunning: true, listing: .init(processed: 300, listedAtStart: 1000)).state == .upToDate)
        // Engine work wins over the listing.
        var syncing = up; syncing.state = .syncing
        #expect(FolderStatusComposer.compose(
            folderID: f, engine: syncing, engineRunning: true, listing: .init(processed: 1, listedAtStart: 0)).state == .syncing)
        // Stopped / failed engine: offline, last numbers kept.
        let off = FolderStatusComposer.compose(folderID: f, engine: up, engineRunning: false, listing: nil)
        #expect(off.state == .offline && off.progress.globalBytes == 10)
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

    @Test func conflictCopiesBecomeConflictIssues() {
        let when = Date(timeIntervalSince1970: 42)
        let i = FolderStatusInputs(folderID: f, conflicts: [.init(path: "a/b.sync-conflict-20261122-001844-76HLXND.txt", modified: when)])
        let s = StatusMapper.map(i)
        #expect(s.state == .upToDate, "a conflict is not a sync failure")
        #expect(s.issues.map(\.kind) == [.conflict])
        #expect(s.issues[0].path == RelativePath(rawValue: "a/b.sync-conflict-20261122-001844-76HLXND.txt"))
        #expect(s.issues[0].occurredAt == when)
        #expect(StatusMapper.isConflictCopy("x/notes.sync-conflict-20261122-001844-ABCDEFG.md"))
        #expect(!StatusMapper.isConflictCopy("x.sync-conflict-dir/plain.txt"))
        #expect(!StatusMapper.isConflictCopy("readme.txt"))
    }
}

@Suite struct IgnoreRulesGeneratorTests {
    @Test func generatesManagedFile() throws {
        let lines = try IgnoreRulesGenerator.lines(present: [RelativePath(rawValue: "Photos/2026"), RelativePath(rawValue: "Docs/report.pdf")])
        #expect(lines == [IgnoreRulesGenerator.header, "/.stignore-user", "#include .stignore-user", "!/Docs/report.pdf", "!/Photos/2026", "*"])
        #expect(try IgnoreRulesGenerator.lines(present: []) == [IgnoreRulesGenerator.header, "/.stignore-user", "#include .stignore-user", "*"])
    }

    @Test func escapesGlobCharactersAndRoundTrips() throws {
        let tricky = ["a*b?.txt", "[x]{y}", "back\\slash", "!bang", "#hash", "(?i)x", "x/(?d)y", "中文 文件.txt", "sp ace/ok"]
        let paths = tricky.map(RelativePath.init(rawValue:))
        let lines = try IgnoreRulesGenerator.lines(present: paths)
        #expect(lines.contains("!/a\\*b\\?.txt"))
        #expect(lines.contains("!/\\[x\\]\\{y\\}"))
        #expect(lines.contains("!/back\\\\slash"))
        #expect(lines.allSatisfy { $0 == IgnoreRulesGenerator.header || $0 == IgnoreRulesGenerator.helperIgnoreLine || $0.hasPrefix("!/") || $0 == "*" || $0.hasPrefix("#include") })
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

    /// Review: per-file rules after a switch to on-demand made each scan
    /// quadratic (20k files: 1.0 s → 4.3 s CPU per full scan on a Mac).
    @Test func collapsesFullyLocalDirectoriesOnly() {
        let r = { (s: String) in RelativePath(rawValue: s) }
        let local = ["a/1.txt", "a/b/2.txt", "c/3.txt", "c/d/4.txt", "top.md"].map(r)
        let remote = ["c/d/5.txt"].map(r)
        // "a" is fully local → one rule; "c" and "c/d" hold a remote-only
        // file → c/3.txt and c/d/4.txt stay per file; root files stay files.
        #expect(IgnoreRulesGenerator.collapsedPresent(local: local, remoteOnly: remote).map(\.rawValue)
                == ["a", "c/3.txt", "c/d/4.txt", "top.md"])
        // Nothing remote: top-level entries only.
        #expect(IgnoreRulesGenerator.collapsedPresent(local: local, remoteOnly: []).map(\.rawValue) == ["a", "c", "top.md"])
        // 200 dirs × 100 files, all local → 200 rules.
        let many = (0..<200).flatMap { i in (0..<100).map { r("d\(i)/f\($0)") } }
        #expect(IgnoreRulesGenerator.collapsedPresent(local: many, remoteOnly: []).count == 200)
    }

    @Test func dedupes() throws {
        let p = RelativePath(rawValue: "a")
        #expect(try IgnoreRulesGenerator.lines(present: [p, p]).filter { $0 == "!/a" }.count == 1)
    }
}
