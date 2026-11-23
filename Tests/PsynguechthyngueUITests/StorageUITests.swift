import XCTest

/// Settings ▸ Storage against FakeSyncEngine (fixed 128 GB device, 41.3 GB
/// free; Photos 300 MB, Documents 5 MB, Notes 900 bytes on this device).
/// With `TEST_RUNNER_PSY_SHOTS_DIR` set, saves screenshots named
/// `storage-<PSY_SHOT_TAG>` (e.g. light / dark).
final class StorageUITests: MetricsUITestCase {
    func testStoragePageShowsDeviceBarAndFoldersLargestFirst() {
        launch()
        tab("Settings")
        let entry = el("settings.storage")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(el("storage.bar").waitForExistence(timeout: 5), "segmented bar")
        XCTAssertTrue(anyLabel("128 GB").exists, "device total")
        XCTAssertTrue(anyLabel("Other apps & system").exists)
        XCTAssertTrue(anyLabel("Available").exists)
        let photos = el("storage.folder.Photos"), documents = el("storage.folder.Documents"), notes = el("storage.folder.Notes")
        XCTAssertTrue(photos.waitForExistence(timeout: 5) && documents.exists && notes.exists)
        XCTAssertLessThan(photos.frame.minY, documents.frame.minY, "largest first")
        XCTAssertLessThan(documents.frame.minY, notes.frame.minY)
        XCTAssertTrue(anyLabel("On demand").exists, "Photos is on demand")
        // File counts arrive from the engine on the first refresh.
        XCTAssertTrue(anyLabel(" files").waitForExistence(timeout: 5))
        let tag = ProcessInfo.processInfo.environment["PSY_SHOT_TAG"] ?? "light"
        shot("storage-\(tag)")
        photos.tap()
        XCTAssertTrue(el("folder.state").waitForExistence(timeout: 5), "opens the folder detail")
    }
}
