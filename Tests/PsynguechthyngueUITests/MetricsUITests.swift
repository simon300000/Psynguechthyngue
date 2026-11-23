import XCTest

/// Statistics against FakeSyncEngine: Home rates, device connection details,
/// folder contents and device completion, Settings ▸ Diagnostics.
/// Fixture: Home Server connected (TCP, LAN, 2 connections, 1.5 MB/s down,
/// 256 kB/s up), Work Laptop offline; Documents = 1,206 files, 100 folders,
/// 60 deleted entries, Work Laptop at 82 %.
///
/// With `TEST_RUNNER_PSY_SHOTS_DIR=<dir>` each test also saves screenshots there.
class MetricsUITestCase: PsyUITestCase {
    func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PSY_SHOTS_DIR"], !dir.isEmpty else { return }
        let url = URL(filePath: dir).appending(path: "\(language)-\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    func openDocumentsFolder() {
        tab(language == "en" ? "Folders" : "文件夹")
        let row = el("folder.row.Documents")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    func openHomeServer() {
        tab(language == "en" ? "Devices" : "设备")
        let row = text("Home Server")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    func openDiagnostics() {
        tab(language == "en" ? "Settings" : "设置")
        let link = el("settings.diagnostics")
        XCTAssertTrue(scrollTo(link), "diagnostics link")
        link.tap()
    }
}

final class MetricsUITests: MetricsUITestCase {
    func testHomeShowsTransferRates() {
        launch()
        // First reading has no rate; the second (2 s later) shows the fixture's MB/s.
        XCTAssertTrue(anyLabel("MB/s").waitForExistence(timeout: 8), "download rate on Home")
        XCTAssertTrue(anyLabel("kB/s").exists, "upload rate on Home")
        shot("home")
    }

    func testDeviceRowsAndDetailShowConnectionStatistics() {
        launch()
        tab("Devices")
        XCTAssertTrue(el("device.row.rates").waitForExistence(timeout: 5), "rates on the connected device's row")
        XCTAssertTrue(anyLabel("MB/s").waitForExistence(timeout: 8))
        shot("devices")
        text("Home Server").tap()
        XCTAssertTrue(anyLabel("TCP, local network").waitForExistence(timeout: 5))
        XCTAssertTrue(anyLabel("192.168.1.5:22000").exists)
        let connections = el("device.connections")
        XCTAssertTrue(scrollTo(connections), "connection count")
        XCTAssertTrue(connections.label.contains("2") || anyLabel("Connections").exists)
        XCTAssertTrue(anyLabel("Received this session").exists)
        XCTAssertTrue(anyLabel("v2.1.6").exists, "client version")
        shot("device-detail")
        app.navigationBars.buttons.firstMatch.tap()
        text("Work Laptop").tap()
        XCTAssertTrue(el("device.lastseen").waitForExistence(timeout: 5), "last seen for an offline device")
    }

    func testFolderDetailShowsContentsAndCompletion() {
        launch()
        openDocumentsFolder()
        XCTAssertTrue(anyLabel("1,206").waitForExistence(timeout: 5), "file count")
        XCTAssertTrue(el("folder.deleted").exists, "deleted entries")
        XCTAssertTrue(el("folder.lastfile").exists, "last synced file")
        shot("folder-detail")
        let laptop = el("folder.completion.\(String(homeServerID.prefix(7)))")
        XCTAssertTrue(scrollTo(laptop), "completion of Home Server")
        XCTAssertTrue(anyLabel("82%").exists, "Work Laptop completion")
        shot("folder-completion")
    }

    func testDiagnosticsShowsEngineStatistics() {
        launch()
        openDiagnostics()
        XCTAssertTrue(el("diagnostics.uptime").waitForExistence(timeout: 8))
        XCTAssertTrue(el("diagnostics.enginememory").exists)
        shot("diagnostics")
        XCTAssertTrue(scrollTo(el("diagnostics.discovery")))
        XCTAssertTrue(anyLabel("3 of 3 working").exists, "discovery status")
        XCTAssertTrue(scrollTo(el("diagnostics.relays")))
        XCTAssertTrue(anyLabel("tcp://192.168.1.23:22000").exists, "listening address")
        shot("diagnostics-2")
    }
}

final class ZhHansMetricsUITests: MetricsUITestCase {
    override var language: String { "zh-Hans" }

    func testStatisticsAreLocalized() {
        launch()
        XCTAssertTrue(anyLabel("MB/s").waitForExistence(timeout: 8))
        shot("home")
        openHomeServer()
        XCTAssertTrue(anyLabel("TCP，本地网络").waitForExistence(timeout: 5))
        XCTAssertTrue(anyLabel("本次已接收").exists)
        shot("device-detail")
        openDocumentsFolder()
        XCTAssertTrue(anyLabel("已删除条目").waitForExistence(timeout: 5))
        shot("folder-detail")
        openDiagnostics()
        XCTAssertTrue(anyLabel("运行时间").waitForExistence(timeout: 8))
        shot("diagnostics")
        XCTAssertTrue(scrollTo(el("diagnostics.discovery")))
        XCTAssertTrue(anyLabel("3 / 3 正常").exists)
    }
}
