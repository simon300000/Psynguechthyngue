import Foundation
import Testing
@testable import PsySync

@Suite struct ConflictAttentionTests {
    let a = FolderID(rawValue: "aaaaa-aaaaa")
    let b = FolderID(rawValue: "bbbbb-bbbbb")

    func conflict(_ folder: FolderID, _ path: String) -> SyncIssue {
        SyncIssue(id: "\(folder.rawValue):conflict:\(path)", kind: .conflict, folderID: folder,
                  path: RelativePath(rawValue: path), technicalDetail: path, occurredAt: Date(timeIntervalSince1970: 1))
    }

    func status(_ folder: FolderID, _ issues: [SyncIssue], checked: Bool = true) -> FolderStatus {
        FolderStatus(folderID: folder, state: .upToDate, issues: issues, conflictsChecked: checked)
    }

    let one = "notes.sync-conflict-20261120-120000-ABCDEFG.txt"
    let two = "plans/week.sync-conflict-20261121-090000-ABCDEFG.md"

    // MARK: Notification de-duplication

    @Test func aConflictIsFreshOnlyTheFirstTimeItIsSeen() {
        var att = ConflictAttention()
        let first = att.observe(status(a, [conflict(a, one)]))
        #expect(first.fresh.map(\.path?.rawValue) == [one])
        #expect(first.changed)
        // Every later status (each sync) repeats the same conflict: no new notification.
        for _ in 0..<5 {
            let again = att.observe(status(a, [conflict(a, one)]))
            #expect(again.fresh.isEmpty)
            #expect(!again.changed)
        }
        // A second copy is new; the first is still known.
        let more = att.observe(status(a, [conflict(a, one), conflict(a, two)]))
        #expect(more.fresh.map(\.path?.rawValue) == [two])
    }

    @Test func otherIssuesAreNotTracked() {
        var att = ConflictAttention()
        let error = SyncIssue(id: "e", kind: .outOfSpace, folderID: a, path: nil, technicalDetail: "", occurredAt: Date())
        let r = att.observe(status(a, [error]))
        #expect(r.fresh.isEmpty && !r.changed)
        #expect(att.visible([error]) == [error])
        let ignoredError = att.ignore([error])
        #expect(!ignoredError)
    }

    @Test func dedupSurvivesARelaunch() throws {
        let suite = "psy.test.conflicts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConflictAttentionStore(defaults: defaults)
        var att = store.load()
        let firstRun = att.observe(status(a, [conflict(a, one)]))
        #expect(firstRun.fresh.count == 1)
        store.save(att)
        // New process (background launch): the conflict was already announced.
        var relaunched = ConflictAttentionStore(defaults: defaults).load()
        let afterRelaunch = relaunched.observe(status(a, [conflict(a, one)]))
        #expect(afterRelaunch.fresh.isEmpty)
    }

    // MARK: Ignoring

    @Test func ignoredConflictsAreHiddenAndNeverNotified() {
        var att = ConflictAttention()
        let c1 = conflict(a, one), c2 = conflict(a, two)
        let firstIgnore = att.ignore([c1])
        let secondIgnore = att.ignore([c1])
        #expect(firstIgnore)
        #expect(!secondIgnore, "ignoring twice changes nothing")
        #expect(att.isIgnored(c1) && !att.isIgnored(c2))
        #expect(att.visible([c1, c2]) == [c2])
        // Seen for the first time after being ignored: still no notification.
        let bothSeen = att.observe(status(a, [c1, c2]))
        #expect(bothSeen.fresh == [c2])
        let ignoredBoth = att.ignore([c1, c2])
        #expect(ignoredBoth)
        #expect(att.visible([c1, c2]).isEmpty)
    }

    @Test func aNewConflictOnTheSameFileIsANewConflict() {
        var att = ConflictAttention()
        let old = conflict(a, "todo.sync-conflict-20261120-120000-ABCDEFG.txt")
        let new = conflict(a, "todo.sync-conflict-20261124-080000-ABCDEFG.txt")
        _ = att.observe(status(a, [old]))
        att.ignore([old])
        let r = att.observe(status(a, [old, new]))
        #expect(r.fresh == [new], "a later timestamp is another conflict copy")
        #expect(att.visible([old, new]) == [new])
    }

    @Test func theSamePathInAnotherFolderIsADifferentConflict() {
        var att = ConflictAttention()
        att.ignore([conflict(a, one)])
        #expect(!att.isIgnored(conflict(b, one)))
        let otherFolder = att.observe(status(b, [conflict(b, one)]))
        #expect(otherFolder.fresh.count == 1)
    }

    @Test func ignoredConflictsPersist() throws {
        let suite = "psy.test.conflicts.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var att = ConflictAttention()
        att.ignore([conflict(a, one)])
        ConflictAttentionStore(defaults: defaults).save(att)
        let loaded = ConflictAttentionStore(defaults: defaults).load()
        #expect(loaded == att)
        #expect(loaded.isIgnored(conflict(a, one)))
        // Unreadable data starts empty rather than failing.
        defaults.set(Data("x".utf8), forKey: ConflictAttentionStore.defaultsKey)
        #expect(ConflictAttentionStore(defaults: defaults).load() == ConflictAttention())
    }

    // MARK: Clean-up

    @Test func recordsAreDroppedWhenTheConflictCopyIsGone() {
        var att = ConflictAttention()
        let c1 = conflict(a, one), c2 = conflict(a, two), other = conflict(b, one)
        _ = att.observe(status(a, [c1, c2]))
        _ = att.observe(status(b, [other]))
        att.ignore([c1])
        // The user deleted the first copy in Files.
        let r = att.observe(status(a, [c2]))
        #expect(r.changed && r.fresh.isEmpty)
        #expect(!att.ignored.contains(ConflictAttention.Key(folderID: a, path: RelativePath(rawValue: one))))
        #expect(!att.notified.contains(ConflictAttention.Key(folderID: a, path: RelativePath(rawValue: one))))
        #expect(att.notified.contains(ConflictAttention.Key(folderID: b, path: RelativePath(rawValue: one))), "other folders untouched")
        // Should the same name ever come back, it is new again.
        let reappeared = att.observe(status(a, [c1, c2]))
        #expect(reappeared.fresh == [c1])
    }

    @Test func anUncheckedStatusDropsNothing() {
        var att = ConflictAttention()
        let c1 = conflict(a, one)
        _ = att.observe(status(a, [c1]))
        att.ignore([c1])
        // Right after an engine start the folder lists no conflicts until its
        // index has been walked: not a deletion, and no re-notification after.
        let r = att.observe(status(a, [], checked: false))
        #expect(!r.changed)
        #expect(att.isIgnored(c1))
        let afterScan = att.observe(status(a, [c1]))
        #expect(afterScan.fresh.isEmpty)
    }

    @Test func mapperPassesConflictsChecked() {
        #expect(StatusMapper.map(FolderStatusInputs(folderID: a)).conflictsChecked)
        #expect(!StatusMapper.map(FolderStatusInputs(folderID: a, conflictsChecked: false)).conflictsChecked)
        #expect(!FolderStatusComposer.compose(folderID: a, engine: nil, engineRunning: true, listing: nil).conflictsChecked)
        #expect(!FolderStatusComposer.compose(folderID: a, engine: nil, engineRunning: false, listing: nil).conflictsChecked)
    }
}
