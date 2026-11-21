import XCTest

@MainActor
final class PhysicalFilesUIE2ETests: XCTestCase {
    private let providerLocationName = "Psynguechthyngue"
    private let shareFolderName = "Psy v1 E2E"
    private let sourceName = "Psy-v1-e2e-4fbe0c9d-source"
    private let finalName = "Psy-v1-e2e-4fbe0c9d-final"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCreateAndRenameDirectoryInFiles() throws {
        let files = launchFiles()
        try openTemporaryLocation(in: files)
        try createFolder(named: sourceName, in: files)
        try renameItem(from: sourceName, to: finalName, in: files)
        XCTAssertTrue(item(named: finalName, in: files).waitForExistence(timeout: 15))
        XCTAssertFalse(item(named: sourceName, in: files).exists)
    }

    func testDeleteRenamedDirectoryInFiles() throws {
        let files = launchFiles()
        try openTemporaryLocation(in: files)
        let target = item(named: finalName, in: files)
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        target.press(forDuration: 1.0)
        try tapFirstLabel(["Delete", "删除"], in: files)
        let confirmation = firstLabel(["Delete", "删除"], in: files)
        if confirmation.waitForExistence(timeout: 2) { confirmation.tap() }
        XCTAssertTrue(waitUntil(timeout: 15) { !self.item(named: self.finalName, in: files).exists })
    }

    private func launchFiles() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            waitUntil(timeout: 5) { XCUIDevice.shared.orientation == .portrait },
            "The physical Files gate requires a stable portrait orientation."
        )
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        return files
    }

    private func openTemporaryLocation(in files: XCUIApplication) throws {
        let browse = firstLabel(["Browse", "浏览"], in: files)
        if browse.waitForExistence(timeout: 5) { browse.tap() }
        if firstExistingItem(named: [providerLocationName], in: files, timeout: 2) == nil {
            let sidebar = firstLabel(
                ["Show Sidebar", "显示边栏", "Sidebar", "边栏"],
                in: files,
                buttonsOnly: true
            )
            if sidebar.waitForExistence(timeout: 5) { sidebar.tap() }
        }
        if firstExistingItem(named: [providerLocationName], in: files, timeout: 2) == nil {
            let locations = firstLabel(["Locations", "位置"], in: files)
            if locations.waitForExistence(timeout: 2), locations.isHittable {
                locations.tap()
            }
        }
        guard
            let providerLocation = firstExistingItem(
                named: [providerLocationName],
                in: files,
                timeout: 10
            )
        else {
            throw PhysicalFilesUIError.elementMissing("Psynguechthyngue Files location")
        }
        providerLocation.tap()

        // The aggregate provider root is intentionally read-only. Enter the
        // reserved share before exposing New Folder or mutating test content.
        guard
            let shareFolder = firstExistingItem(
                named: [shareFolderName],
                in: files,
                timeout: 15
            )
        else {
            throw PhysicalFilesUIError.elementMissing("temporary share folder")
        }
        shareFolder.tap()
    }

    private func createFolder(named name: String, in files: XCUIApplication) throws {
        if let newFolder = firstHittableLabel(["New Folder", "新建文件夹"], in: files) {
            newFolder.tap()
        } else {
            let more = firstLabel(["More", "更多"], in: files, buttonsOnly: true)
            guard more.waitForExistence(timeout: 10) else {
                throw PhysicalFilesUIError.elementMissing("More")
            }
            more.tap()
            try tapFirstLabel(["New Folder", "新建文件夹"], in: files)
        }
        let field = files.textFields.firstMatch
        guard field.waitForExistence(timeout: 30) else {
            throw PhysicalFilesUIError.elementMissing("New Folder name")
        }
        field.typeText(name)
        try tapFirstLabel(["Done", "完成"], in: files)
        guard item(named: name, in: files).waitForExistence(timeout: 15) else {
            throw PhysicalFilesUIError.elementMissing("created folder")
        }
    }

    private func renameItem(from source: String, to destination: String, in files: XCUIApplication)
        throws
    {
        let sourceItem = item(named: source, in: files)
        guard sourceItem.waitForExistence(timeout: 10) else {
            throw PhysicalFilesUIError.elementMissing("source folder")
        }
        sourceItem.press(forDuration: 1.0)
        try tapFirstLabel(["Rename", "重命名"], in: files)
        let field = files.textFields.firstMatch
        guard field.waitForExistence(timeout: 30) else {
            throw PhysicalFilesUIError.elementMissing("Rename field")
        }
        field.clearAndType(destination)
        try tapFirstLabel(["Done", "完成"], in: files)
    }

    private func tapFirstLabel(_ labels: [String], in app: XCUIApplication) throws {
        let deadline = Date().addingTimeInterval(5)
        var element: XCUIElement?
        repeat {
            element = firstHittableLabel(labels, in: app)
            if element != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        guard let element else {
            throw PhysicalFilesUIError.elementMissing(labels.joined(separator: "/"))
        }
        element.tap()
    }

    private func firstHittableLabel(
        _ labels: [String],
        in app: XCUIApplication
    ) -> XCUIElement? {
        for label in labels {
            let predicate = NSPredicate(format: "label == %@", label)
            let queries = [
                app.buttons.matching(predicate),
                app.staticTexts.matching(predicate),
                app.otherElements.matching(predicate),
            ]
            for query in queries {
                if let candidate = query.allElementsBoundByIndex.first(where: \.isHittable) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func firstLabel(
        _ labels: [String],
        in app: XCUIApplication,
        buttonsOnly: Bool = false
    ) -> XCUIElement {
        for label in labels {
            let button = app.buttons[label].firstMatch
            if button.exists { return button }
            if !buttonsOnly {
                let text = app.staticTexts[label].firstMatch
                if text.exists { return text }
                let other = app.otherElements[label].firstMatch
                if other.exists { return other }
            }
        }
        return app.buttons[labels[0]].firstMatch
    }

    private func item(named name: String, in app: XCUIApplication) -> XCUIElement {
        let cell = app.cells[name].firstMatch
        if cell.exists { return cell }
        let text = app.staticTexts[name].firstMatch
        if text.exists { return text }
        return app.otherElements[name].firstMatch
    }

    private func firstExistingItem(
        named names: [String],
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for name in names {
                let candidate = item(named: name, in: app)
                if candidate.exists { return candidate }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return names.lazy.map { self.item(named: $0, in: app) }.first(where: \.exists)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }
}

private enum PhysicalFilesUIError: LocalizedError {
    case elementMissing(String)

    var errorDescription: String? {
        switch self {
        case .elementMissing(let name): "The Files UI element is missing: \(name)."
        }
    }
}

extension XCUIElement {
    fileprivate func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeText(text)
    }
}
