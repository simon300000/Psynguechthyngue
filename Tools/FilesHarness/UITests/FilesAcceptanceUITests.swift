import XCTest

/// WP-C acceptance in the Files app (DESIGN.md §11): browse, open via all three
/// content paths, create, edit, rename, delete. Run in order by
/// `Tools/FilesHarness/run-acceptance.sh`, which also prepares the peers and
/// verifies the results on the official Syncthing instance between steps.
@MainActor
final class FilesAcceptanceUITests: XCTestCase {
    let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
    let harness = XCUIApplication(bundleIdentifier: "com.example.PsyFilesHarness")

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func dump(_ name: String) {
        try? files.debugDescription.write(toFile: "/Users/user/SyncthingTest/wpc/ui-\(name).txt", atomically: true, encoding: .utf8)
    }

    func launchHarness(_ extra: [String] = []) {
        let env = ProcessInfo.processInfo.environment
        harness.launchArguments = [
            "-PsyHarnessREST", env["PSY_HARNESS_REST"] ?? "http://127.0.0.1:8484",
            "-PsyHarnessKey", env["PSY_HARNESS_KEY"] ?? "",
            "-PsyHarnessKeepAlive", "1",
        ] + extra
        harness.launch()
        let status = harness.staticTexts["harness.status"].firstMatch
        let running = expectation(for: NSPredicate(format: "label == 'running'"), evaluatedWith: status)
        wait(for: [running], timeout: 40)
    }

    func openFolder() {
        files.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        files.terminate()
        files.launch()
        let browse = files.tabBars.buttons["Browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        browse.tap()
        browse.tap()
        let location = files.cells["DOC.sidebar.item.PsyFilesHarness"].firstMatch
        let found = location.waitForExistence(timeout: 10)
        if !found { dump("no-location") }
        XCTAssertTrue(found)
        location.tap()
    }

    func cell(_ name: String, _ ext: String? = "txt") -> XCUIElement {
        files.cells[ext.map { "\(name), \($0)" } ?? "\(name), Folder"].firstMatch
    }

    /// Opens a file in Quick Look and waits for `text` to be rendered.
    func open(_ name: String, expect text: String) {
        let c = cell(name)
        XCTAssertTrue(c.waitForExistence(timeout: 15), "\(name) listed")
        for _ in 0..<4 where !c.isHittable || c.frame.maxY > 760 { files.swipeUp() }
        c.tap()
        let match = files.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        let shown = match.waitForExistence(timeout: 60)
        dump("open-\(name)")
        XCTAssertTrue(shown, "contents of \(name) shown")
        let done = files.buttons["Done"].firstMatch
        if done.exists { done.tap() } else { files.navigationBars.buttons.firstMatch.tap() }
    }

    func contextMenu(_ element: XCUIElement, _ item: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        element.press(forDuration: 1.2)
        let button = files.buttons[item].firstMatch
        let found = button.waitForExistence(timeout: 5)
        if !found { dump("menu-\(item)") }
        XCTAssertTrue(found, "menu item \(item)")
        button.tap()
    }

    func test01Browse() {
        launchHarness()
        openFolder()
        for (name, ext) in [("hello", "txt"), ("remote-only", "txt"), ("fetched-offline", "txt"), ("docs", nil)] {
            XCTAssertTrue(cell(name, ext).waitForExistence(timeout: 15), "\(name) listed")
        }
        dump("browse")
    }

    /// remote-only.txt is not local (on-demand) and the App engine runs → delegatedToApp.
    func test02OpenDelegated() {
        launchHarness()
        openFolder()
        open("remote-only", expect: "opened through delegatedToApp")
    }

    /// hello.txt was made local by the script beforehand → localClone.
    func test03OpenLocal() {
        openFolder()
        open("hello", expect: "hello from the official instance")
    }

    func test04CreateFolderAndDuplicate() {
        launchHarness()
        openFolder()
        contextMenu(cell("hello"), "Duplicate")
        XCTAssertTrue(cell("hello 2").waitForExistence(timeout: 15))
        // New folder via the "More" menu.
        files.buttons["OverflowBarButtonItem"].firstMatch.tap()
        let newFolder = files.buttons["New Folder"].firstMatch
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5))
        newFolder.tap()
        files.typeText("made-in-files\n")
        XCTAssertTrue(cell("made-in-files", nil).waitForExistence(timeout: 15))
        dump("created")
    }

    func test05Rename() {
        launchHarness()
        openFolder()
        contextMenu(cell("hello 2"), "Rename")
        files.typeText("renamed-in-files\n")
        XCTAssertTrue(cell("renamed-in-files").waitForExistence(timeout: 15))
        dump("renamed")
    }

    func test06Delete() {
        launchHarness()
        openFolder()
        contextMenu(cell("remote-only"), "Delete Now")
        let confirm = files.alerts.buttons["Delete"].firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: cell("remote-only"))
        waitForExpectations(timeout: 15)
        dump("deleted")
    }

    func test07EditThroughCoordinator() {
        launchHarness(["-PsyHarnessEdit", "renamed-in-files.txt", "-PsyHarnessEditText", "edited through Files coordination\n"])
        XCTAssertTrue(harness.staticTexts["edited renamed-in-files.txt"].waitForExistence(timeout: 20))
        openFolder()
        open("renamed-in-files", expect: "edited through Files coordination")
    }

    /// App not running (lock free) → restrictedFetch.
    func test08OpenRestricted() {
        harness.terminate()
        openFolder()
        open("fetched-offline", expect: "opened through restrictedFetch")
    }

    /// Nested, never-downloaded file with the App engine running → delegatedToApp.
    func test09OpenDelegatedNested() {
        launchHarness()
        openFolder()
        let docs = cell("docs", nil)
        XCTAssertTrue(docs.waitForExistence(timeout: 15))
        docs.tap()
        open("report", expect: "nested report")
    }

    /// Second offline open (file created on the official instance) + App relaunch
    /// so the journal is drained; the script then checks no new version appeared.
    func test10OpenRestrictedThenAppDrains() {
        harness.terminate()
        openFolder()
        open("offline-2", expect: "second offline file")
        launchHarness()
        sleep(8)
    }

    /// Real bridge (integration): the App's engine is stopped gracefully by
    /// backgrounding, then terminated; Files opens a never-downloaded file →
    /// restrictedFetch through PsyBridgeAdapter.FetchFile against the peer.
    func test11OpenRealRestricted() {
        files.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        files.launch()  // backgrounds the harness → engine.stop + lock released
        sleep(8)
        harness.terminate()
        openFolder()
        open("fetched-offline", expect: "opened through the real restricted fetch")
    }

    /// Larger file through the real restricted fetch (RSS measurement run).
    func test12OpenRealRestrictedLarge() {
        files.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        files.launch()
        sleep(8)
        harness.terminate()
        openFolder()
        open("large-offline", expect: "LARGE-START")
    }

    /// Parameterised offline open (env PSY_OPEN_NAME / PSY_OPEN_EXPECT) for
    /// repeated real restricted-fetch runs.
    func test13OpenRealRestrictedNamed() {
        let env = ProcessInfo.processInfo.environment
        files.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        files.launch()
        sleep(6)
        harness.terminate()
        openFolder()
        open(env["PSY_OPEN_NAME"] ?? "offline-1", expect: env["PSY_OPEN_EXPECT"] ?? "via real restricted fetch")
    }
}
