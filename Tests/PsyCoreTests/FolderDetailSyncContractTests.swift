import Foundation
import XCTest

#if os(macOS)
    final class FolderDetailSyncContractTests: XCTestCase {
        func testFolderDetailQueuesOnlyItsExactFolderAndDoesNotClaimImplementedModesAreDrafts() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let foldersView = try String(
                contentsOf: repositoryRoot.appendingPathComponent("App/FoldersView.swift"),
                encoding: .utf8
            )

            XCTAssertTrue(foldersView.contains("Button(\"Sync Folder Now\""))
            XCTAssertTrue(foldersView.contains("kind: .sync,\n                            folderID: folder.id"))
            XCTAssertTrue(
                foldersView.contains(
                    "expectedFolderIncarnationDigest: expectedFolderIncarnationDigest"
                )
            )
            XCTAssertTrue(
                foldersView.contains(
                    ".disabled(folder.isPaused || expectedFolderIncarnationDigest == nil)"
                )
            )
            XCTAssertTrue(
                foldersView.contains(
                    "Full Sync, Manual Selection, Glob, and Regex define which global-index items this device keeps downloaded. Syncthing alone interprets the user's .stignore file."
                )
            )
            XCTAssertFalse(foldersView.contains("Other modes remain local drafts"))

            let selectionView = try String(
                contentsOf: repositoryRoot.appendingPathComponent("App/FolderSelectionView.swift"),
                encoding: .utf8
            )
            let appModel = try applicationModelSource(root: repositoryRoot)
            XCTAssertTrue(selectionView.contains("Apply Retention Policy"))
            XCTAssertTrue(selectionView.contains("supportsRetentionApplication"))
            XCTAssertTrue(appModel.contains("retentionApplicationContext"))
            XCTAssertFalse(selectionView.contains("SelectionApplication"))
            XCTAssertFalse(appModel.contains("SelectionApplication"))
        }

        func testFolderSyncControlIsLocalizedInEnglishAndSimplifiedChinese() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let english = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "App/Resources/en.lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            let simplifiedChinese = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "App/Resources/zh-Hans.lproj/Localizable.strings"
                ),
                encoding: .utf8
            )

            for key in [
                "Sync Folder Now",
                "Resume this folder before requesting synchronization.",
                "Apply Retention Policy",
            ] {
                XCTAssertTrue(english.contains("\"\(key)\" ="), "Missing English key: \(key)")
                XCTAssertTrue(
                    simplifiedChinese.contains("\"\(key)\" ="),
                    "Missing Simplified Chinese key: \(key)"
                )
            }
        }
    }
#endif
