import Foundation
import Testing
@testable import PsySync

@Suite struct HelperIgnoreRulesTests {
    @Test func everythingLinesRoundTrip() {
        let user = ["*.tmp", "// note", "!/keep", "/Archive"]
        let lines = IgnoreRulesGenerator.everythingLines(user: user)
        #expect(lines == [IgnoreRulesGenerator.helperComment, "/.stignore-user"] + user)
        #expect(IgnoreRulesGenerator.userLines(fromEverything: lines) == user)
        // Idempotent, and plain user files pass through.
        #expect(IgnoreRulesGenerator.everythingLines(user: lines) == lines)
        #expect(IgnoreRulesGenerator.userLines(fromEverything: user) == user)
        #expect(IgnoreRulesGenerator.everythingLines(user: []) == [IgnoreRulesGenerator.helperComment, "/.stignore-user"])
    }

    @Test func engineInternalNames() {
        for n in [".stfolder", ".stignore", ".stignore-user", ".stversions", ".syncthing.a.txt.tmp", "~syncthing~a.txt.tmp"] {
            #expect(IgnoreRulesGenerator.isEngineInternal(n), "\(n)")
        }
        for n in [".stuff", ".st", ".stignore.bak", "notes.txt", ".syncthing.txt"] {
            #expect(!IgnoreRulesGenerator.isEngineInternal(n), "\(n)")
        }
    }

    @Test func keptAncestor() {
        let present: Set<RelativePath> = [RelativePath(rawValue: "Photos"), RelativePath(rawValue: "Docs/a.pdf")]
        #expect(LiveSyncEngine.keptAncestor(of: RelativePath(rawValue: "Photos/2026/x.jpg"), in: present) == RelativePath(rawValue: "Photos"))
        #expect(LiveSyncEngine.keptAncestor(of: RelativePath(rawValue: "Photos"), in: present) == nil)
        #expect(LiveSyncEngine.keptAncestor(of: RelativePath(rawValue: "Docs/a.pdf"), in: present) == nil)
        #expect(LiveSyncEngine.keptAncestor(of: RelativePath(rawValue: "Photosx/y"), in: present) == nil)
    }

    @Test func missedEventDetection() {
        #expect(!EventTranslator.missedEvents(since: 0, ids: [40, 41]))      // first poll
        #expect(!EventTranslator.missedEvents(since: 5, ids: [6, 7]))
        #expect(!EventTranslator.missedEvents(since: 5, ids: []))
        #expect(!EventTranslator.missedEvents(since: 5, ids: [4, 5, 6]))     // older ids are skipped
        #expect(EventTranslator.missedEvents(since: 5, ids: [9, 10]))
        #expect(EventTranslator.missedEvents(since: 5, ids: [8, 7]))         // unsorted
    }
}

extension LiveSyncEngineTests {
    func stignore(_ dir: URL) throws -> [String] {
        LiveSyncEngine.splitLines(try String(contentsOf: dir.appending(path: ".stignore"), encoding: .utf8))
    }

    /// Regression: switching to on-demand posted `#include .stignore-user`
    /// without creating that file (upstream then fails the folder) and threw
    /// the user's rules away; switching back left the include line, which the
    /// editor showed and saving dropped the rules. `.stuff` was never kept.
    @Test func contentModeRoundTripKeepsUserRules() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let id = FolderID(rawValue: "rt")
        try await h.engine.addFolder(Folder(id: id, label: "RT"))
        let dir = AppGroupLayout(root: h.root).managedFolder(id)
        for name in [".stuff", "a.txt"] { try Data("x".utf8).write(to: dir.appending(path: name)) }
        let user = ["*.tmp", "// comment", "/Archive"]
        try await h.engine.setUserIgnoreRules(id, user)
        #expect(try stignore(dir) == IgnoreRulesGenerator.everythingLines(user: user))
        #expect(try await h.engine.userIgnoreRules(id) == user)

        // Everything → on demand.
        var folder = try #require(try await h.engine.folders().first { $0.id == id })
        folder.contentMode = .onDemand
        try await h.engine.updateFolder(folder)
        let userFile = dir.appending(path: ".stignore-user")
        #expect(LiveSyncEngine.splitLines(try String(contentsOf: userFile, encoding: .utf8)) == user)
        let managed = try stignore(dir)
        #expect(IgnoreRulesGenerator.isManaged(managed))
        #expect(managed.contains("/.stignore-user"))
        #expect(IgnoreRulesGenerator.presentPaths(from: managed) == [RelativePath(rawValue: ".stuff"), RelativePath(rawValue: "a.txt")])
        #expect(try await h.engine.userIgnoreRules(id) == user)

        // Edit while on demand, then back to everything.
        let edited = user + ["*.log"]
        try await h.engine.setUserIgnoreRules(id, edited)
        folder.contentMode = .everything
        try await h.engine.updateFolder(folder)
        #expect(try stignore(dir) == IgnoreRulesGenerator.everythingLines(user: edited))
        #expect(try await h.engine.userIgnoreRules(id) == edited)

        // And on demand once more: still lossless.
        folder.contentMode = .onDemand
        try await h.engine.updateFolder(folder)
        #expect(try await h.engine.userIgnoreRules(id) == edited)
        // No temporary helper files are left in the synced folder.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
        try await h.engine.stop(deadline: .seconds(1))
    }

    /// Folders switched back to "everything" by older versions hold only
    /// `#include .stignore-user` and no helper ignore line (the file synced to
    /// peers). Start adds the line without deleting the file; the editor shows
    /// the included rules and saving keeps them.
    @Test func legacyIncludeIsMigratedAtStart() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let id = FolderID(rawValue: "legacy")
        try await h.engine.addFolder(Folder(id: id, label: "L"))
        let od = FolderID(rawValue: "legacy-od")
        try await h.engine.addFolder(Folder(id: od, label: "O", contentMode: .onDemand))
        try await h.engine.stop(deadline: .seconds(1))

        let dir = AppGroupLayout(root: h.root).managedFolder(id)
        try Data("*.bak\n/Old\n".utf8).write(to: dir.appending(path: ".stignore-user"))
        try Data("#include .stignore-user\n".utf8).write(to: dir.appending(path: ".stignore"))
        let odDir = AppGroupLayout(root: h.root).managedFolder(od)
        try Data((IgnoreRulesGenerator.header + "\n#include .stignore-user\n!/keep.txt\n*\n").utf8).write(to: odDir.appending(path: ".stignore"))

        try await h.engine.start(context: .foreground)
        #expect(try stignore(dir) == IgnoreRulesGenerator.everythingLines(user: ["*.bak", "/Old"]))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: ".stignore-user").path(percentEncoded: false)))
        #expect(try await h.engine.userIgnoreRules(id) == ["*.bak", "/Old"])
        #expect(try stignore(odDir) == (try IgnoreRulesGenerator.lines(present: [RelativePath(rawValue: "keep.txt")])))
        try await h.engine.stop(deadline: .seconds(1))
    }

    /// Regression (latent): removing a download inside a kept folder left the
    /// file un-ignored, so deleting it would spread the deletion to peers.
    /// Now the folder's rule is split into rules for what stays local
    /// (a directory kept as one rule at the switch to on-demand; the
    /// extension never asks this below a "Keep Downloaded" pin).
    @Test func removingDownloadInsideKeptFolderSplitsItsRule() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        let id = FolderID(rawValue: "kept")
        try await h.engine.addFolder(Folder(id: id, label: "K", contentMode: .onDemand))
        let dir = AppGroupLayout(root: h.root).managedFolder(id)
        let file = dir.appending(path: "Photos/a.jpg")
        for p in ["Photos/a.jpg", "Photos/b.jpg", "Photos/2024/c.jpg", "Other/d.txt"] {
            let url = dir.appending(path: p)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try await h.engine.setLocalPresence(id, paths: [RelativePath(rawValue: "Photos")], present: true)
        try await h.engine.setLocalPresence(id, paths: [RelativePath(rawValue: "Other")], present: true)
        try await h.engine.setLocalPresence(id, paths: [RelativePath(rawValue: "Photos/a.jpg")], present: false)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Photos/b.jpg").path(percentEncoded: false)))
        #expect(IgnoreRulesGenerator.presentPaths(from: try stignore(dir))
                == Set(["Photos/b.jpg", "Photos/2024", "Other"].map(RelativePath.init(rawValue:))))
        // Removing a kept folder itself drops everything below it.
        try await h.engine.setLocalPresence(id, paths: [RelativePath(rawValue: "Photos")], present: false)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "Photos/b.jpg").path(percentEncoded: false)))
        #expect(IgnoreRulesGenerator.presentPaths(from: try stignore(dir)) == [RelativePath(rawValue: "Other")])
        try await h.engine.stop(deadline: .seconds(1))
    }

    @Test func splitKeptOnlyTouchesTheAncestorsOfTheRemovedPath() {
        let r = { (s: [String]) in Set(s.map(RelativePath.init(rawValue:))) }
        let local = ["A/x", "A/B/y", "A/B/z", "A/C/w", "Q/q"].map(RelativePath.init(rawValue:))
        #expect(LiveSyncEngine.splitKept(r(["A", "Q"]), removing: RelativePath(rawValue: "A/B/y"), local: local)
                == r(["A/x", "A/B/z", "A/C", "Q"]))
        // Removing a directory below the rule keeps nothing of it.
        #expect(LiveSyncEngine.splitKept(r(["A"]), removing: RelativePath(rawValue: "A/B"), local: local)
                == r(["A/x", "A/C"]))
        // Nested rules are split down to the removed path.
        #expect(LiveSyncEngine.splitKept(r(["A", "A/B"]), removing: RelativePath(rawValue: "A/B/y"), local: local)
                == r(["A/x", "A/B/z", "A/C"]))
        #expect(LiveSyncEngine.splitKept(r(["Q"]), removing: RelativePath(rawValue: "A/x"), local: local) == r(["Q"]))
    }

    /// Regression: a folder scheduled while flushRefresh awaited
    /// configFolders() was cleared without ever being refreshed.
    @Test func refreshScheduledDuringFlushIsNotLost() async throws {
        // Timeline: flush starts at +500 ms and waits for configFolders until
        // +800 ms; "late" is scheduled at +650 ms, its own flush is due at
        // +1150 ms, so the first flush resumes in between.
        let h = try makeHarness { $0.folderRefreshDebounce = .milliseconds(500) }
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        try await h.engine.addFolder(Folder(id: FolderID(rawValue: "a"), label: "a"))
        try await Task.sleep(for: .milliseconds(1000))   // start-up refresh done
        let events = h.engine.events()
        h.fake.configFoldersDelay = 0.3
        await h.engine.handle([.refreshAllFolders])
        try await Task.sleep(for: .milliseconds(650))
        let late = FolderConfigDTO(id: "late", label: "late", path: h.root.appending(path: "late").path(percentEncoded: false),
                                   type: "sendreceive", devices: [], paused: false)
        h.fake.addFolderConfig(late)
        await h.engine.handle([.refreshFolder(FolderID(rawValue: "late"))])
        h.fake.configFoldersDelay = 0
        let seen = await firstEvent(events, within: .seconds(3)) {
            if case .folderStatusChanged(let s) = $0 { return s.folderID.rawValue == "late" }
            return false
        }
        #expect(seen)
        try await h.engine.stop(deadline: .seconds(1))
    }

    /// Missed events (id gap) refresh folders and pending lists, drop stale
    /// per-file progress and tell index consumers to re-read.
    @Test func eventGapTriggersResync() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.engine.start(context: .foreground)
        try await h.engine.addFolder(Folder(id: FolderID(rawValue: "g"), label: "g"))
        let events = h.engine.events()
        h.fake.pushEvents(#"[{"id":1,"type":"DownloadProgress","data":{"g":{"big.bin":{"bytesDone":500,"bytesTotal":1000}}}}]"#)
        h.fake.pushEvents(#"[{"id":7,"type":"FolderSummary","data":{"folder":"g"}}]"#)
        let resynced = await firstEvent(events, within: .seconds(3)) {
            if case .indexChanged(let f, nil) = $0 { return f.rawValue == "g" }
            return false
        }
        #expect(resynced)
        var progress: Int64 = -1
        for _ in 0..<50 {
            progress = try await h.engine.folderStatus(FolderID(rawValue: "g")).progress.inProgressBytes
            if progress == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(progress == 0)
        try await h.engine.stop(deadline: .seconds(1))
    }

    func firstEvent(_ stream: AsyncStream<EngineEvent>, within timeout: Duration,
                    _ match: @escaping @Sendable (EngineEvent) -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await e in stream where match(e) { return true }
                return false
            }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
