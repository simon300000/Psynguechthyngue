import XCTest

/// UI tests against `FakeSyncEngine` (`-PsyUITestFixture`). Run on an iPhone
/// and an iPad simulator; `ZhHansUITests` repeats key flows in Simplified Chinese.
class PsyUITestCase: XCTestCase {
    var app: XCUIApplication!
    var language: String { "en" }

    /// Valid IDs known to the fixture (FakeSyncEngine.sampleIDs).
    let homeServerID = "UJZDEGX-DNCF32H-EPF3DHO-DZDOCIE-S2JHTLG-MXGEDNB-73U55XT-PLPFT7K"
    let newPeerID = "ZYMLOPI-FQYF7MF-2NXYNJ5-LVFF6U5-ZCRA3NX-F5M5DWO-INK4LLC-HBK62F5"

    override func setUp() {
        continueAfterFailure = false
    }

    func launch(_ scenario: String = "populated", onboardingDone: Bool = true, extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-PsyUITestFixture", "-PsyUITestScenario", scenario,
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        if onboardingDone { app.launchArguments += ["-psy.onboardingDone", "YES"] }
        app.launchArguments += extra
        app.launch()
    }

    func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    /// Any element whose label contains `label`.
    func anyLabel(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    /// Scrolls lazily rendered forms/lists until `e` exists and is hittable.
    @discardableResult
    func scrollTo(_ e: XCUIElement, maxSwipes: Int = 6) -> Bool {
        for _ in 0..<maxSwipes {
            if e.exists && e.isHittable { return true }
            app.swipeUp()
        }
        return e.exists
    }

    func tab(_ label: String) {
        let inBar = app.tabBars.buttons[label]
        if inBar.waitForExistence(timeout: 3) { inBar.tap(); return }
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.tap()
    }

    func tapSwitch(_ id: String) {
        let s = app.switches[id]
        XCTAssertTrue(s.waitForExistence(timeout: 5), "switch \(id)")
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    func waitGone(_ e: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let exp = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    func typeDeviceID(_ id: String) {
        let field = el("adddevice.id")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(id)
    }
}

final class PsynguechthyngueUITests: PsyUITestCase {
    // MARK: Sync tab

    func testHomeShowsStatusTransfersAndDeviceID() {
        launch()
        XCTAssertTrue(el("home.status").waitForExistence(timeout: 5))
        XCTAssertTrue(text("1 of 2 devices connected").exists)
        XCTAssertTrue(el("transfer.photo-s0001").exists, "syncing folder shows progress")
        XCTAssertTrue(el("home.deviceid").exists)
        XCTAssertTrue(el("home.copyid").exists)
    }

    func testHomeShowsProblemsAndOpensDetail() {
        launch("errors")
        XCTAssertTrue(text("Some folders have problems").waitForExistence(timeout: 5))
        let issue = el("issue.e1")
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        issue.tap()
        XCTAssertTrue(text("Free up some storage").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Technical details"].exists || text("Technical details").exists)
    }

    func testPendingDeviceAcceptMovesToDevices() {
        launch("pending")
        let accept = el("pending.device.accept")
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        XCTAssertTrue(text("Anna's Laptop wants to connect").exists)
        accept.tap()
        XCTAssertTrue(waitGone(text("Anna's Laptop wants to connect")))
        tab("Devices")
        XCTAssertTrue(text("Anna's Laptop").waitForExistence(timeout: 5))
    }

    func testPendingDeviceIgnore() {
        launch("pending")
        let ignore = el("pending.device.ignore")
        XCTAssertTrue(ignore.waitForExistence(timeout: 5))
        ignore.tap()
        XCTAssertTrue(waitGone(el("pending.device.ignore")))
        tab("Devices")
        XCTAssertFalse(text("Anna's Laptop").waitForExistence(timeout: 2))
    }

    func testAcceptPendingFolderOnDemand() {
        launch("pending")
        let accept = el("pending.folder.accept")
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(el("acceptfolder.name").waitForExistence(timeout: 5))
        app.buttons["On demand"].tap()
        XCTAssertTrue(text("downloaded when you open them").exists)
        el("acceptfolder.accept").tap()
        XCTAssertTrue(waitGone(el("pending.folder.accept")))
        tab("Folders")
        XCTAssertTrue(el("folder.row.Photos").waitForExistence(timeout: 5))
    }

    // MARK: Devices tab

    func testAddDeviceByEnteringID() {
        launch()
        tab("Devices")
        el("devices.add").tap()
        typeDeviceID(newPeerID.lowercased())
        XCTAssertTrue(el("adddevice.valid").waitForExistence(timeout: 3), "lower-case input is normalised")
        let name = el("adddevice.name")
        name.tap(); name.typeText("Studio Mac")
        el("adddevice.add").tap()
        XCTAssertTrue(text("Studio Mac").waitForExistence(timeout: 5))
    }

    func testAddDeviceRejectsInvalidID() {
        launch()
        tab("Devices")
        el("devices.add").tap()
        typeDeviceID("NOT-A-DEVICE-ID")
        XCTAssertTrue(el("adddevice.invalid").waitForExistence(timeout: 3))
        XCTAssertFalse(el("adddevice.add").isEnabled)
    }

    func testAddingExistingDeviceShowsBannerThatDismissesItself() {
        launch()
        tab("Devices")
        el("devices.add").tap()
        typeDeviceID(homeServerID)
        el("adddevice.add").tap()
        let banner = el("error-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(text("already been added").exists)
        XCTAssertTrue(waitGone(banner, timeout: 12), "error overlay auto-dismisses")
    }

    func testDeviceDetailPauseAndRemoveReturnsToList() {
        launch()
        tab("Devices")
        let row = text("Work Laptop")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        tapSwitch("device.pause")
        XCTAssertTrue(app.switches["device.pause"].value as? String == "1")
        let remove = el("device.remove")
        scrollTo(remove)
        remove.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Remove")).firstMatch.tap()
        XCTAssertTrue(el("devices.add").waitForExistence(timeout: 5))
        XCTAssertTrue(waitGone(text("Work Laptop"), timeout: 5))
    }

    // MARK: Folders tab

    func testCreateManagedOnDemandFolderSharedWithDevice() {
        launch()
        tab("Folders")
        el("folders.new").tap()
        let name = el("newfolder.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(el("newfolder.create").isEnabled, "name required")
        name.tap(); name.typeText("Music")
        app.buttons["On demand"].tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'newfolder.share.'")).count == 2)
        el("newfolder.create").tap()
        XCTAssertTrue(el("folder.row.Music").waitForExistence(timeout: 5))
    }

    func testNewFolderOffersExternalLocation() {
        launch()
        tab("Folders")
        el("folders.new").tap()
        XCTAssertTrue(anyLabel("A folder I choose").waitForExistence(timeout: 5))
        XCTAssertTrue(anyLabel("In this app").exists)
    }

    func testFolderDetailShowsErrorsConflictsAndAdvanced() {
        launch("errors")
        tab("Folders")
        el("folder.row.Notes").tap()
        XCTAssertTrue(text("Not enough storage").waitForExistence(timeout: 5))
        XCTAssertTrue(scrollTo(anyLabel("sync-conflict")), "conflict listed")
        let advanced = app.buttons["Advanced"]
        scrollTo(advanced)
        XCTAssertFalse(el("folder.rescan").exists, "advanced section starts collapsed")
        advanced.tap()
        XCTAssertTrue(el("folder.rescan").waitForExistence(timeout: 3))
        el("folder.rescan").tap()
        XCTAssertTrue(text("Scan started").waitForExistence(timeout: 3))
    }

    func testRemoveFolderKeepFiles() {
        launch()
        tab("Folders")
        el("folder.row.Documents").tap()
        let remove = el("folder.remove")
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        scrollTo(remove)
        remove.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Stop Syncing, Keep Files")).firstMatch.tap()
        XCTAssertTrue(waitGone(el("folder.row.Documents"), timeout: 5))
    }

    // MARK: Settings

    func testSettingsApplyImmediatelyAndAdvancedIsCollapsed() {
        launch()
        tab("Settings")
        XCTAssertTrue(app.switches["settings.cellular"].waitForExistence(timeout: 5))
        XCTAssertTrue(anyLabel("Cellular upload limit").exists)
        tapSwitch("settings.cellular")
        XCTAssertTrue(waitGone(anyLabel("Cellular upload limit"), timeout: 3),
                      "limits hide immediately when cellular sync is off")
        XCTAssertFalse(app.switches["settings.globaldiscovery"].exists, "advanced collapsed by default")
        let advanced = app.buttons["Advanced"]
        scrollTo(advanced)
        advanced.tap()
        XCTAssertTrue(scrollTo(app.switches["settings.globaldiscovery"]))
        XCTAssertEqual(app.switches["settings.globaldiscovery"].value as? String, "1", "global discovery on by default")
    }

    // MARK: Onboarding

    func testOnboardingAddsFirstDevice() {
        launch("empty", onboardingDone: false)
        XCTAssertTrue(el("onboarding.title").waitForExistence(timeout: 5))
        el("onboarding.next").tap()
        el("onboarding.adddevice").tap()
        typeDeviceID(newPeerID)
        el("adddevice.add").tap()
        XCTAssertTrue(text("1 devices added").waitForExistence(timeout: 5))
        el("onboarding.next").tap()
        XCTAssertTrue(el("onboarding.newfolder").waitForExistence(timeout: 3))
        el("onboarding.skip").tap()
        XCTAssertTrue(el("home.status").waitForExistence(timeout: 5))
    }

    func testOnboardingSkipShowsEmptyStates() {
        launch("empty", onboardingDone: false)
        XCTAssertTrue(el("onboarding.skip").waitForExistence(timeout: 5))
        el("onboarding.skip").tap()
        XCTAssertTrue(text("Add a device to start").waitForExistence(timeout: 5))
        tab("Devices")
        XCTAssertTrue(el("devices.empty.add").waitForExistence(timeout: 3))
        tab("Folders")
        XCTAssertTrue(el("folders.empty.new").waitForExistence(timeout: 3))
    }

    // MARK: Lifecycle (fixture engine)

    func testReturningFromBackgroundRestartsEngine() {
        launch()
        XCTAssertTrue(text("1 of 2 devices connected").waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(text("1 of 2 devices connected").waitForExistence(timeout: 10))
        XCTAssertFalse(text("Syncing is paused").exists)
        let probe = el("debug.engine")
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(probe.label.contains("stops=1"), "engine was drained in background: \(probe.label)")
        XCTAssertTrue(probe.label.contains("starts=2"), "engine restarted on return: \(probe.label)")
    }

    func testMacBranchKeepsEngineRunningAndOffersPaste() {
        launch(extra: ["-PsySimulateMac", "-PsyUITestFilesDisabled"])
        XCTAssertTrue(text("1 of 2 devices connected").waitForExistence(timeout: 5))
        XCTAssertTrue(anyLabel("Closing the window stops syncing").exists, "Mac window-close hint")
        XCTAssertTrue(anyLabel("Login Items & Extensions").waitForExistence(timeout: 5), "Mac Files-location guidance")
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        let probe = el("debug.engine")
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(probe.label.contains("stops=0"), "Mac must not stop the engine in background: \(probe.label)")
        tab("Devices")
        el("devices.add").tap()
        XCTAssertTrue(text("Copy the ID from the other device").waitForExistence(timeout: 5))
        XCTAssertFalse(el("adddevice.scan").exists, "no QR scanning on Mac")
        XCTAssertTrue(el("adddevice.paste").exists)
    }
}

final class EngineSettingsUITests: PsyUITestCase {
    /// Opens Settings ▸ Advanced; the disclosure state survives tab switches,
    /// so it may already be expanded and scrolled.
    private func openAdvancedSettings() {
        tab("Settings")
        if el("settings.devicename").waitForExistence(timeout: 2) { return }
        let advanced = app.buttons["Advanced"]
        for _ in 0..<4 where !advanced.exists { app.swipeDown() }
        scrollTo(advanced)
        XCTAssertTrue(advanced.exists, "Advanced disclosure")
        advanced.tap()
    }

    func testAdvancedOptionsAreReadFromAndWrittenToEngine() {
        launch()
        openAdvancedSettings()
        let name = el("settings.devicename")
        XCTAssertTrue(scrollTo(name))
        XCTAssertEqual(name.value as? String, "iPhone", "device name comes from engine options")
        name.tap()
        name.typeText(" Pro\n")
        let relays = app.switches["settings.relays"]
        XCTAssertTrue(scrollTo(relays))
        XCTAssertEqual(relays.value as? String, "1")
        tapSwitch("settings.relays")
        XCTAssertTrue(anyLabel("Syncthing").exists)
        // Leave Settings and come back: values are re-read from the engine.
        tab("Sync")
        openAdvancedSettings()
        XCTAssertTrue(scrollTo(el("settings.devicename")))
        XCTAssertEqual(el("settings.devicename").value as? String, "iPhone Pro")
        XCTAssertTrue(scrollTo(app.switches["settings.relays"]))
        XCTAssertEqual(app.switches["settings.relays"].value as? String, "0")
        XCTAssertTrue(scrollTo(el("settings.syncthingversion")))
        XCTAssertTrue(anyLabel("v2.1.6").exists, "version from engine.syncthingVersion")
    }

    func testIgnorePatternsEditorSavesToEngine() {
        launch()
        tab("Folders")
        el("folder.row.Documents").tap()
        let advanced = app.buttons["Advanced"]
        scrollTo(advanced)
        advanced.tap()
        let ignores = el("folder.ignores")
        XCTAssertTrue(scrollTo(ignores))
        ignores.tap()
        let editor = el("ignores.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(el("ignores.save").isEnabled, "nothing to save yet")
        editor.tap()
        editor.typeText("*.tmp\n/Archive")
        el("ignores.save").tap()
        XCTAssertTrue(anyLabel("Ignore patterns saved").waitForExistence(timeout: 5))
        // Reopen: rules are read back from the engine.
        XCTAssertTrue(scrollTo(el("folder.ignores")))
        el("folder.ignores").tap()
        XCTAssertTrue(el("ignores.editor").waitForExistence(timeout: 5))
        XCTAssertTrue((el("ignores.editor").value as? String ?? "").contains("/Archive"))
    }

    func testStopTimeoutRestartsAutomaticallyOnReturn() {
        launch(extra: ["-PsyUITestStopTimeout"])
        XCTAssertTrue(text("1 of 2 devices connected").waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(text("1 of 2 devices connected").waitForExistence(timeout: 10), "engine restarted on return")
        let probe = el("debug.engine")
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(probe.label.contains("starts=2"), "restarted: \(probe.label)")
        XCTAssertFalse(anyLabel("Please restart the app").exists, "no manual restart prompt")
        XCTAssertFalse(text("Sync engine stopped").exists)
    }

    func testKeepSyncingInBackgroundKeepsEngineRunning() {
        launch(extra: ["-PsyUITestSimulateContinued"])
        let button = el("home.continueinbg")
        XCTAssertTrue(scrollTo(button), "offered while a folder is syncing")
        button.tap()
        XCTAssertTrue(el("home.continuing").waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        let probe = el("debug.engine")
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(probe.label.contains("stops=0"), "engine kept running in background: \(probe.label)")
    }
}

final class ZhHansUITests: PsyUITestCase {
    override var language: String { "zh-Hans" }

    func testTabsAndHomeAreLocalized() {
        launch()
        XCTAssertTrue(app.navigationBars["同步"].waitForExistence(timeout: 5) || text("同步").exists)
        XCTAssertTrue(text("已连接 1 / 2 台设备").waitForExistence(timeout: 5))
        XCTAssertTrue(text("正在传输").exists)
        tab("设置")
        XCTAssertTrue(app.switches["settings.cellular"].waitForExistence(timeout: 5))
        XCTAssertTrue(anyLabel("使用蜂窝网络同步").exists)
    }

    func testAddDeviceFlowInChinese() {
        launch()
        tab("设备")
        el("devices.add").tap()
        XCTAssertTrue(app.navigationBars["添加设备"].waitForExistence(timeout: 5))
        typeDeviceID("abc")
        XCTAssertTrue(text("这不是有效的设备 ID").waitForExistence(timeout: 3))
    }

    func testPendingInboxInChinese() {
        launch("pending")
        XCTAssertTrue(anyLabel("待处理").waitForExistence(timeout: 5))
        XCTAssertTrue(text("请求连接").exists)
        el("pending.folder.accept").tap()
        XCTAssertTrue(app.navigationBars["接受文件夹"].waitForExistence(timeout: 5))
        XCTAssertTrue(anyLabel("按需下载").waitForExistence(timeout: 3))
    }
}
