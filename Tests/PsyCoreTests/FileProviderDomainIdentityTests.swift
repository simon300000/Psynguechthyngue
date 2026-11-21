import XCTest

@testable import PsyCore

final class FileProviderDomainIdentityTests: XCTestCase {
    func testShareIdentifiersAreStableOpaqueAndFileProviderSafe() throws {
        let first = try XCTUnwrap(FolderID(rawValue: "documents/private"))
        let second = try XCTUnwrap(FolderID(rawValue: "documents:private"))

        let identifier = FileProviderDomainIdentity.identifier(for: first)

        XCTAssertEqual(identifier, FileProviderDomainIdentity.identifier(for: first))
        XCTAssertNotEqual(identifier, FileProviderDomainIdentity.identifier(for: second))
        XCTAssertTrue(identifier.hasPrefix(FileProviderDomainIdentity.sharePrefix))
        XCTAssertFalse(identifier.contains(first.rawValue))
        XCTAssertFalse(identifier.contains("/"))
        XCTAssertFalse(identifier.contains(":"))

        let folderItemIdentifier = FileProviderDomainIdentity.folderItemIdentifier(for: first)
        XCTAssertEqual(
            folderItemIdentifier,
            FileProviderDomainIdentity.folderItemIdentifier(for: first)
        )
        XCTAssertNotEqual(
            folderItemIdentifier,
            FileProviderDomainIdentity.folderItemIdentifier(for: second)
        )
        XCTAssertTrue(folderItemIdentifier.hasPrefix("folder-"))
        XCTAssertFalse(folderItemIdentifier.contains(first.rawValue))
    }

    func testIdentifierResolvesOnlyAnExactCurrentUniqueShare() throws {
        let folderID = try XCTUnwrap(FolderID(rawValue: "documents"))
        let folder = FolderRecord(id: folderID, label: "Documents", localPath: "/documents")
        let identifier = FileProviderDomainIdentity.identifier(for: folderID)

        XCTAssertEqual(
            FileProviderDomainIdentity.folder(
                in: CoreSnapshot(folders: [folder]),
                matching: identifier
            ),
            folder
        )
        XCTAssertNil(
            FileProviderDomainIdentity.folder(
                in: CoreSnapshot(),
                matching: identifier
            )
        )
        XCTAssertNil(
            FileProviderDomainIdentity.folder(
                in: CoreSnapshot(folders: [folder]),
                matching: FileProviderDomainIdentity.legacyAggregateIdentifier
            )
        )
    }
}
