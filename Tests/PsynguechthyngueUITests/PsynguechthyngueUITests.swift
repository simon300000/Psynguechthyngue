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
    /// Also keeps the element out of the bottom area, where the tab bar and the
    /// sync-progress accessory float over content (isHittable ignores overlays).
    @discardableResult
    func scrollTo(_ e: XCUIElement, maxSwipes: Int = 6) -> Bool {
        var lastY: CGFloat?
        for _ in 0..<maxSwipes {
            if e.exists && e.isHittable {
                if inSafeZone(e) { return true }
                // Reached the end of the content: it cannot move further up.
                if let lastY, abs(lastY - e.frame.minY) < 1 { return true }
                lastY = e.frame.minY
            }
            if e.exists && e.frame.minY < app.frame.height * 0.12 {
                app.swipeDown()
            } else {
                gentleSwipeUp()
            }
        }
        return e.exists
    }

    /// Clear of the navigation bar and of the tab bar + accessory at the bottom.
    private func inSafeZone(_ e: XCUIElement) -> Bool {
        let h = app.frame.height
        return e.frame.maxY < h - 170 && e.frame.minY > h * 0.1
    }

    /// A short drag (about a third of the screen) so targets don't overshoot.
    private func gentleSwipeUp() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func tab(_ label: String) {
        let inBar = app.tabBars.buttons[label]
        // The iPhone tab bar minimizes on scroll; scrolling back up restores it.
        for _ in 0..<3 where !inBar.waitForExistence(timeout: 1.5) && !anyTabButton(label).exists {
            app.swipeDown()
        }
        if inBar.exists { inBar.tap(); return }
        anyTabButton(label).tap()
    }

    private func anyTabButton(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
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

final class HomeUITests: PsyUITestCase {
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

}

final class DeviceUITests: PsyUITestCase {
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

    /// Regression: after Remove, onDisappear committed the edited name and
    /// PATCHed the deleted device, which showed a "rejected" error banner.
    func testRemoveDeviceAfterEditingNameShowsNoError() {
        launch()
        tab("Devices")
        let row = text("Work Laptop")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let name = el("device.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" 2")   // not submitted
        let remove = el("device.remove")
        scrollTo(remove)
        remove.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Remove")).firstMatch.tap()
        XCTAssertTrue(waitGone(text("Work Laptop"), timeout: 5))
        sleep(1)
        XCTAssertFalse(anyLabel("rejected the request").exists, "no error banner after removing")
    }

}

final class FolderUITests: PsyUITestCase {
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
        // Regression (simulator acceptance): the folder picker never appeared.
        app.buttons["A folder I choose"].firstMatch.tap()
        let picker = app.buttons["DOCPicker.actionButton"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "folder picker shown")
        XCTAssertTrue(el("newfolder.create").exists, "the New Folder form stays open under the picker")
    }

    /// The whole folder card opens the detail, not just its text. (On an iOS 27.3
    /// device only the text reacted; the simulator never reproduced it, so this
    /// guards the hit area rather than reproducing that bug.)
    func testFolderCardOpensFromEmptyArea() {
        launch("errors")
        tab("Folders")
        let row = el("folder.row.Notes")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        XCTAssertTrue(text("Not enough storage").waitForExistence(timeout: 5), "detail opened")
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
        XCTAssertTrue(el("folder.state").waitForExistence(timeout: 5))
        // The detail form is lazy and long (contents, device completion):
        // the button exists only once scrolled into view.
        let remove = el("folder.remove")
        XCTAssertTrue(scrollTo(remove, maxSwipes: 10))
        remove.tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Stop Syncing, Keep Files")).firstMatch.tap()
        XCTAssertTrue(waitGone(el("folder.row.Documents"), timeout: 5))
    }

}

final class SettingsOnboardingUITests: PsyUITestCase {
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
        XCTAssertTrue(text("1 device added").waitForExistence(timeout: 5), "English plural (was “1 devices added”)")
        XCTAssertFalse(text("1 devices added").exists)
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

}

final class LifecycleUITests: PsyUITestCase {
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

    /// Mac has no cellular and no BGTaskScheduler: those settings are hidden,
    /// the window-close hint takes their place.
    func testMacSettingsHideCellularAndBackgroundSync() {
        launch(extra: ["-PsySimulateMac"])
        tab("Settings")
        XCTAssertTrue(el("settings.lowpower").waitForExistence(timeout: 5))
        XCTAssertFalse(el("settings.cellular").exists, "no cellular options on Mac")
        XCTAssertFalse(el("settings.lowdata").exists)
        XCTAssertTrue(scrollTo(el("settings.machint")), "Mac background hint")
        XCTAssertFalse(el("settings.background").exists, "no background-sync toggle on Mac")
        XCTAssertFalse(el("settings.autocontinue").exists, "no continued processing on Mac")
    }

    func testIOSSettingsKeepCellularAndBackgroundSync() {
        launch()
        tab("Settings")
        XCTAssertTrue(el("settings.cellular").waitForExistence(timeout: 5))
        XCTAssertTrue(scrollTo(el("settings.background")))
        XCTAssertTrue(scrollTo(app.switches["settings.autocontinue"]), "automatic continue toggle next to background sync")
        XCTAssertEqual(app.switches["settings.autocontinue"].value as? String, "1", "on by default")
        XCTAssertFalse(el("settings.machint").exists)
    }
}

final class EngineSettingsUITests: PsyUITestCase {
    /// Opens Settings ▸ Advanced; the disclosure state survives tab switches,
    /// so it may already be expanded and scrolled.
    private func openAdvancedSettings() {
        tab("Settings")
        // The form keeps its scroll position across tab switches; when it is
        // scrolled to the end, the first (lazily built) rows do not exist.
        let cellular = app.switches["settings.cellular"]
        for _ in 0..<6 where !cellular.waitForExistence(timeout: 1) { app.swipeDown() }
        XCTAssertTrue(cellular.waitForExistence(timeout: 5))
        // Advanced is the last section: scroll to the end so lazily built rows exist,
        // then expand only if it is still collapsed (tapping again would collapse it).
        for _ in 0..<4 { app.swipeUp() }
        if el("settings.devicename").waitForExistence(timeout: 1) { return }
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
}

/// Engine options outside Settings ▸ Advanced (ignore patterns, background).
final class EngineOptionsUITests: PsyUITestCase {
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

    /// Default: "Keep syncing in background automatically" requests continued
    /// processing as soon as transfers run, without the button.
    func testAutomaticContinueInBackground() {
        launch(extra: ["-PsyUITestSimulateContinued"])
        XCTAssertTrue(scrollTo(el("home.continuing")), "requested automatically while syncing")
        XCTAssertFalse(el("home.continueinbg").exists, "no button while the automatic request is active")
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        let probe = el("debug.engine")
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(probe.label.contains("stops=0"), "engine kept running in background: \(probe.label)")
    }

    func testKeepSyncingInBackgroundKeepsEngineRunning() {
        launch(extra: ["-PsyUITestSimulateContinued", "-psy.autoContinueInBackground", "NO"])
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

final class MenuCommandUITests: PsyUITestCase {
    /// The "Sync" menu commands double as iPad keyboard shortcuts (and Mac menu items).
    func testKeyboardShortcutsOpenAddDeviceAndNewFolder() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "hardware keyboard shortcuts are an iPad feature")
        launch()
        XCTAssertTrue(el("home.status").waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(el("adddevice.id").waitForExistence(timeout: 5), "⇧⌘D opens Add Device")
        app.buttons["Cancel"].firstMatch.tap()
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(el("newfolder.name").waitForExistence(timeout: 5), "⇧⌘N opens New Folder")
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
