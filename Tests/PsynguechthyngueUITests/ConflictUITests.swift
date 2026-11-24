import XCTest

/// Conflict copies: ignore one, ignore all (FakeSyncEngine "conflicts":
/// three copies in Notes, one in Documents). Ignoring only hides them.
class ConflictUITestCase: PsyUITestCase {
    let notesRow = "issue.conflicts.notes-00001"
    let documentsRow = "issue.conflicts.docum-ents1"
    let todo = "todo.sync-conflict-20261120-120000-ABCDEFG.txt"

    func openConflicts(_ row: String) {
        let e = el(row)
        XCTAssertTrue(e.waitForExistence(timeout: 5), row)
        scrollTo(e)
        e.tap()
    }
}

final class ConflictUITests: ConflictUITestCase {
    func testIgnoreOneThenAllFromHome() {
        launch("conflicts")
        XCTAssertTrue(el(notesRow).waitForExistence(timeout: 5))
        XCTAssertTrue(el(documentsRow).exists, "one row per folder")
        XCTAssertTrue(anyLabel("3 file conflicts").exists)

        openConflicts(notesRow)
        let week = "plans/week.sync-conflict-20261121-090000-ABCDEFG.md"
        let ignoreWeek = el("conflict.ignore.\(week)")
        XCTAssertTrue(ignoreWeek.waitForExistence(timeout: 5))
        XCTAssertTrue(anyLabel("week.sync-conflict-20261121-090000-ABCDEFG.md").exists)
        XCTAssertTrue(anyLabel("plans").exists, "directory shown under the name")
        ignoreWeek.tap()
        XCTAssertTrue(waitGone(ignoreWeek), "ignored conflict leaves the list")
        XCTAssertTrue(el("conflict.ignore.\(todo)").exists, "the others stay")
        XCTAssertTrue(anyLabel("2 file conflicts").waitForExistence(timeout: 3))

        el("conflicts.ignoreAll").tap()
        // Nothing left in the folder: the sheet closes, and Home drops the row.
        XCTAssertTrue(waitGone(el("conflicts.ignoreAll")))
        XCTAssertTrue(waitGone(el(notesRow)))
        XCTAssertTrue(el(documentsRow).exists, "other folder's conflict still listed")

        // The last conflict: a single one has no Ignore All.
        openConflicts(documentsRow)
        let ignoreReport = el("conflict.ignore.report.sync-conflict-20261123-100000-ABCDEFG.pdf")
        XCTAssertTrue(ignoreReport.waitForExistence(timeout: 5))
        XCTAssertFalse(el("conflicts.ignoreAll").exists)
        ignoreReport.tap()
        XCTAssertTrue(waitGone(ignoreReport))
        XCTAssertTrue(waitGone(el(documentsRow)))
        XCTAssertTrue(waitGone(anyLabel("Recent problems")), "nothing left to show")
    }

    func testIgnoreAllInFolderDetail() {
        launch("conflicts")
        tab("Folders")
        el("folder.row.Notes").tap()
        let ignoreAll = el("folder.conflicts.ignoreAll")
        XCTAssertTrue(scrollTo(ignoreAll), "Ignore All offered for several conflicts")
        XCTAssertTrue(anyLabel(todo).exists)
        ignoreAll.tap()
        XCTAssertTrue(waitGone(anyLabel(todo)))
        XCTAssertFalse(ignoreAll.exists)
        tab("Sync")
        XCTAssertTrue(el(documentsRow).waitForExistence(timeout: 5))
        XCTAssertFalse(el(notesRow).exists, "Home leaves out ignored conflicts")
    }
}

final class ZhHansConflictUITests: ConflictUITestCase {
    override var language: String { "zh-Hans" }

    func testConflictSheetInChinese() {
        launch("conflicts")
        XCTAssertTrue(anyLabel("3 个文件冲突").waitForExistence(timeout: 5))
        openConflicts(notesRow)
        XCTAssertTrue(el("conflicts.ignoreAll").waitForExistence(timeout: 5))
        XCTAssertTrue(anyLabel("全部忽略").exists)
        XCTAssertTrue(anyLabel("冲突副本会留在文件夹中").exists)
        el("conflicts.ignoreAll").tap()
        XCTAssertTrue(waitGone(el(notesRow)))
    }
}
