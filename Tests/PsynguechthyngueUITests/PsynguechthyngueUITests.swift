import XCTest

@MainActor
final class PsynguechthyngueUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testEnglishOverviewExposesStatusAndPrimaryActions() throws {
        let app = launch(language: "en", locale: "en_US")
        XCTAssertTrue(app.staticTexts["Sync Status"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Connect a device to begin"].exists)
        XCTAssertTrue(app.buttons["Sync Now"].exists)
        let connect = app.buttons["Connect your first device"]
        makeHittable(connect, in: app)
        connect.tap()
        XCTAssertTrue(app.navigationBars["Add Device"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Name"].exists)
        XCTAssertTrue(app.buttons["Scan QR Code"].exists)
        XCTAssertFalse(app.textFields["Addresses (one per line)"].exists)
    }

    func testSimplifiedChineseOverviewUsesLocalizedAccessibleLabels() throws {
        let app = launch(language: "zh-Hans", locale: "zh_CN")
        XCTAssertTrue(app.staticTexts["同步状态"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["连接一台设备以开始使用"].exists)
        XCTAssertTrue(app.buttons["立即同步"].exists)
        let connect = app.buttons["连接第一台设备"]
        makeHittable(connect, in: app)
        connect.tap()
        XCTAssertTrue(app.navigationBars["添加设备"].waitForExistence(timeout: 5))
    }

    func testCleanInstallPublishesIdentityAndSyncNowReportsZeroFolderNoOp() throws {
        let app = launch(language: "en", locale: "en_US")
        let sync = app.buttons["Sync Now"]
        XCTAssertTrue(sync.waitForExistence(timeout: 30))
        makeHittable(sync, in: app)
        sync.tap()
        XCTAssertTrue(app.staticTexts["There are no configured folders to synchronize."].waitForExistence(timeout: 10))
        let share = app.buttons["Share Device ID"].firstMatch
        makeHittable(share, in: app)
        share.tap()
        XCTAssertTrue(app.buttons["Copy Device ID"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Share Device ID"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Local device ID QR code").firstMatch.exists)
    }

    func testSettingsSeparatesCommonTasksFromAdvancedOptions() throws {
        let app = launch(language: "en", locale: "en_US")
        XCTAssertTrue(app.staticTexts["Sync Status"].waitForExistence(timeout: 30))
        selectTab("Settings", in: app)
        XCTAssertTrue(app.buttons["Network & Data Usage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Power & Background Sync"].exists)
        app.buttons["Network & Data Usage"].tap()
        XCTAssertTrue(app.navigationBars["Advanced Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Automatic on Wi-Fi"].exists)
    }

    func testZCreateShareAndPauseUpdatesOpenDetail() throws {
        let app = launch(language: "en", locale: "en_US")
        let connect = app.buttons["Connect your first device"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        makeHittable(connect, in: app)
        connect.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Offline Test Peer")
        let id = app.textFields["Device ID"].exists ? app.textFields["Device ID"] : app.textViews["Device ID"]
        id.tap()
        id.typeText("AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH")
        app.navigationBars.buttons["Add"].tap()
        let create = app.buttons["Create a shared folder"]
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        makeHittable(create, in: app)
        create.tap()
        let label = app.textFields["Label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.tap()
        label.typeText("Test Share")
        let share = app.switches["Share with Offline Test Peer"]
        makeHittable(share, in: app)
        share.tap()
        app.navigationBars.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))
        selectTab("Folders", in: app)
        let folder = app.buttons["Test Share"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        let pause = app.buttons["Pause"]
        makeHittable(pause, in: app)
        pause.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 20))
    }

    func testZZFilesCreatesAndRenamesInsideManagedShare() throws {
        let sourceName = "Files Check " + String(UUID().uuidString.prefix(8))
        let renamed = sourceName + " Renamed"
        let app = launch(language: "en", locale: "en_US")
        XCTAssertTrue(app.staticTexts["Sync Status"].waitForExistence(timeout: 30))
        selectTab("Folders", in: app)
        let share = app.buttons["Test Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let resume = app.buttons["Resume"]
        if resume.waitForExistence(timeout: 3) {
            makeHittable(resume, in: app)
            resume.tap()
        }
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 15))
        app.terminate()

        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        files.launch()
        enableProviderIfPrompted(in: files)
        let browse = fileElement(["Browse", "浏览"], in: files)
        if browse.waitForExistence(timeout: 5), browse.isHittable { browse.tap() }
        let sidebar =
            files.buttons["ToggleSideBar"].exists
            ? files.buttons["ToggleSideBar"] : fileElement(["Show Sidebar", "Toggle sidebar", "显示边栏"], in: files)
        if sidebar.exists, sidebar.isHittable { sidebar.tap() }
        let location = files.cells["DOC.sidebar.item.Psynguechthyngue"]
        if !location.waitForExistence(timeout: 3) {
            let more = fileElement(["More", "更多"], in: files)
            XCTAssertTrue(more.waitForExistence(timeout: 5), files.debugDescription)
            more.tap()
            let edit = fileElement(["Edit Sidebar", "Edit", "编辑边栏", "编辑"], in: files)
            XCTAssertTrue(edit.waitForExistence(timeout: 5), files.debugDescription)
            edit.tap()
            let toggle = files.switches["Psynguechthyngue"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), files.debugDescription)
            if toggle.value as? String == "0" { toggle.tap() }
            fileElement(["Done", "完成"], in: files).tap()
        }
        XCTAssertTrue(location.waitForExistence(timeout: 10), files.debugDescription)
        location.tap()
        enableProviderIfPrompted(in: files)
        let managed = fileElement(["Test Share"], in: files)
        XCTAssertTrue(managed.waitForExistence(timeout: 15), files.debugDescription)
        managed.tap()
        let newFolder = fileElement(["New Folder", "新建文件夹"], in: files)
        if !newFolder.exists {
            let more = fileElement(["More", "更多"], in: files)
            XCTAssertTrue(more.waitForExistence(timeout: 5), files.debugDescription)
            more.tap()
        }
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5), files.debugDescription)
        newFolder.tap()
        XCTAssertTrue(files.keyboards.firstMatch.waitForExistence(timeout: 10), files.debugDescription)
        files.typeText(sourceName + "\n")
        let created = fileElement([sourceName], in: files)
        XCTAssertTrue(created.waitForExistence(timeout: 20), files.debugDescription)
        created.press(forDuration: 1)
        let rename = fileElement(["Rename", "重命名"], in: files)
        XCTAssertTrue(rename.waitForExistence(timeout: 5), files.debugDescription)
        rename.tap()
        XCTAssertTrue(files.keyboards.firstMatch.waitForExistence(timeout: 10), files.debugDescription)
        files.typeText(renamed + "\n")
        XCTAssertTrue(
            fileElement([renamed], in: files).waitForExistence(timeout: 20), files.debugDescription)
    }

    private func fileElement(_ labels: [String], in app: XCUIApplication) -> XCUIElement {
        for label in labels {
            let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
            if let element = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) { return element }
        }
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", labels[0])).firstMatch
    }

    private func enableProviderIfPrompted(in files: XCUIApplication) {
        let turnOn = files.alerts.buttons["Turn On"]
        if turnOn.waitForExistence(timeout: 3) { turnOn.tap() }
    }

    private func selectTab(_ label: String, in app: XCUIApplication) {
        // iPadOS 27 exposes floating tab items with a distinct accessibility
        // role. Match the user-visible title across phone and tablet roles.
        let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
    }

    private func launch(language: String, locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            "-foregroundSyncEnabledV1", "NO",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()
        return app
    }

    private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
}
