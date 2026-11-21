import Foundation
import XCTest

@testable import PsyCore

final class FileProviderMutationAccessTests: XCTestCase {
    private let folderID = FolderID(rawValue: "file-provider-access")!

    func testFolderRootCreationRequiresWritableActiveHealthyFolder() {
        for type in [FolderType.sendReceive, .sendOnly] {
            XCTAssertTrue(
                FileProviderMutationAccess.evaluate(
                    folder: folder(type: type),
                    item: nil
                ).allowsAddingSubItems
            )
        }

        for type in [FolderType.receiveOnly, .receiveEncrypted] {
            XCTAssertEqual(
                FileProviderMutationAccess.evaluate(
                    folder: folder(type: type),
                    item: nil
                ),
                .readOnly
            )
        }

        XCTAssertEqual(
            FileProviderMutationAccess.evaluate(
                folder: folder(type: .sendReceive, isPaused: true),
                item: nil
            ),
            .readOnly
        )
        XCTAssertEqual(
            FileProviderMutationAccess.evaluate(
                folder: folder(type: .sendReceive, error: "scan_failed"),
                item: nil
            ),
            .readOnly
        )
        XCTAssertTrue(
            FileProviderMutationAccess.evaluate(
                folder: folder(type: .sendReceive, selectionMode: .indexOnly),
                item: nil
            ).allowsAddingSubItems,
            "retention mode must never change whether a writable folder accepts local edits"
        )
    }

    func testLocalItemsExposeOnlyMutationsThatTheBridgeCanCommit() {
        for type in [FolderType.sendReceive, .sendOnly] {
            let fileAccess = FileProviderMutationAccess.evaluate(
                folder: folder(type: type),
                item: item(availability: .local, isDirectory: false)
            )
            XCTAssertTrue(fileAccess.allowsWriting)
            XCTAssertTrue(fileAccess.allowsRenaming)
            XCTAssertTrue(fileAccess.allowsReparenting)
            XCTAssertTrue(fileAccess.allowsDeleting)
            XCTAssertFalse(fileAccess.allowsAddingSubItems)

            let directoryAccess = FileProviderMutationAccess.evaluate(
                folder: folder(type: type),
                item: item(availability: .local, isDirectory: true)
            )
            XCTAssertTrue(directoryAccess.allowsAddingSubItems)
            XCTAssertTrue(directoryAccess.allowsWriting)
            XCTAssertTrue(directoryAccess.allowsRenaming)
            XCTAssertTrue(directoryAccess.allowsReparenting)
            XCTAssertTrue(directoryAccess.allowsDeleting)
        }
    }

    func testUnsafeOrUnavailableItemsAreReadOnly() {
        for availability in [
            FileAvailability.remoteOnly, .downloading, .conflict, .ignored, .error,
        ] {
            XCTAssertEqual(
                FileProviderMutationAccess.evaluate(
                    folder: folder(type: .sendReceive),
                    item: item(availability: availability, isDirectory: true)
                ),
                .readOnly,
                "unexpected mutation access for \(availability)"
            )
        }
    }

    func testUploadingItemsRemainLocallyMutable() {
        let access = FileProviderMutationAccess.evaluate(
            folder: folder(type: .sendReceive),
            item: item(availability: .uploading, isDirectory: false)
        )

        XCTAssertTrue(access.allowsWriting)
        XCTAssertTrue(access.allowsRenaming)
        XCTAssertTrue(access.allowsReparenting)
        XCTAssertTrue(access.allowsDeleting)
    }

    func testFolderIdentityIndexOmitsEveryDuplicateID() {
        let uniqueID = FolderID(rawValue: "unique-folder")!
        var duplicate = folder(type: .sendReceive)
        duplicate.label = "Duplicate"
        let unique = folder(id: uniqueID, type: .sendOnly)

        let index = UniqueFolderIdentityIndex([
            folder(type: .sendReceive), duplicate, unique,
        ])

        XCTAssertNil(index.folder(folderID))
        XCTAssertEqual(index.uniqueFolders.map(\.id), [uniqueID])
        XCTAssertEqual(index.folder(uniqueID), unique)
    }

    private func folder(
        id: FolderID? = nil,
        type: FolderType,
        selectionMode: ContentSelectionMode = .full,
        isPaused: Bool = false,
        error: String? = nil
    ) -> FolderRecord {
        FolderRecord(
            id: id ?? folderID,
            label: "Access",
            localPath: "/tmp/file-provider-access",
            type: type,
            selectionMode: selectionMode,
            isPaused: isPaused,
            error: error
        )
    }

    private func item(
        availability: FileAvailability,
        isDirectory: Bool
    ) -> IndexedItem {
        IndexedItem(
            id: "item",
            folderID: folderID,
            relativePath: isDirectory ? "Folder" : "File.txt",
            isDirectory: isDirectory,
            modifiedAt: Date(timeIntervalSince1970: 1),
            contentVersion: Data([1]),
            metadataVersion: Data([2]),
            availability: availability,
            generation: 1
        )
    }
}
