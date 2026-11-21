import Foundation
import XCTest

@testable import PsyCore

final class FolderIncarnationStoreTests: XCTestCase {
    private let firstCommandID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondCommandID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let thirdCommandID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    func testCreationReplayIsIdempotentAndDifferentLiveCreationFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = FolderIncarnationStore(url: fixture.url)
        let folderID = try folder("alpha")

        let first = try store.recordSuccessfulCreation(
            folderID: folderID,
            commandID: firstCommandID
        )
        XCTAssertEqual(
            first.folderIncarnationDigest,
            "40135598e5636646ddf373e8e933325517e6feabf4fbbc430cd6f14f525978eb"
        )
        let firstBytes = try Data(contentsOf: fixture.url)

        XCTAssertEqual(
            try store.recordSuccessfulCreation(folderID: folderID, commandID: firstCommandID),
            first
        )
        XCTAssertEqual(try Data(contentsOf: fixture.url), firstBytes)
        XCTAssertEqual(try store.snapshot().generation, 1)

        XCTAssertThrowsError(
            try store.recordSuccessfulCreation(
                folderID: folderID,
                commandID: secondCommandID
            )
        ) { error in
            XCTAssertEqual(
                error as? FolderIncarnationStoreError,
                .incarnationConflict(folderID.rawValue)
            )
        }
        XCTAssertEqual(try store.snapshot().generation, 1)
        XCTAssertEqual(try store.policyContext(for: folderID), first)
    }

    func testSuccessfulDeleteIsIdempotentAndReaddGetsNewIncarnation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = FolderIncarnationStore(url: fixture.url)
        let folderID = try folder("remove-readd")
        let first = try store.recordSuccessfulCreation(
            folderID: folderID,
            commandID: firstCommandID
        )

        XCTAssertTrue(
            try store.removeAfterSuccessfulDeletion(
                folderID: folderID,
                expectedFolderIncarnationDigest: first.folderIncarnationDigest
            )
        )
        XCTAssertFalse(
            try store.removeAfterSuccessfulDeletion(
                folderID: folderID,
                expectedFolderIncarnationDigest: first.folderIncarnationDigest
            )
        )
        XCTAssertEqual(try store.snapshot().generation, 2)
        XCTAssertThrowsError(try store.policyContext(for: folderID)) { error in
            XCTAssertEqual(
                error as? FolderIncarnationStoreError,
                .missingFolderIncarnation(folderID.rawValue)
            )
        }

        let readded = try store.recordSuccessfulCreation(
            folderID: folderID,
            commandID: thirdCommandID
        )
        XCTAssertNotEqual(readded.folderIncarnationDigest, first.folderIncarnationDigest)
        XCTAssertEqual(try store.snapshot().generation, 3)

        XCTAssertThrowsError(
            try store.recordSuccessfulCreation(
                folderID: folderID,
                commandID: firstCommandID
            )
        ) { error in
            XCTAssertEqual(
                error as? FolderIncarnationStoreError,
                .incarnationConflict(folderID.rawValue)
            )
        }
        XCTAssertThrowsError(
            try store.removeAfterSuccessfulDeletion(
                folderID: folderID,
                expectedFolderIncarnationDigest: first.folderIncarnationDigest
            )
        ) { error in
            XCTAssertEqual(
                error as? FolderIncarnationStoreError,
                .incarnationMismatch(folderID.rawValue)
            )
        }
        XCTAssertEqual(try store.policyContext(for: folderID), readded)
        XCTAssertEqual(try store.snapshot().generation, 3)
    }

    func testCreationCommandCannotAuthorizeTwoFolders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = FolderIncarnationStore(url: fixture.url)
        let alpha = try folder("alpha")
        let beta = try folder("beta")
        let alphaContext = try store.recordSuccessfulCreation(
            folderID: alpha,
            commandID: firstCommandID
        )

        XCTAssertThrowsError(
            try store.recordSuccessfulCreation(
                folderID: beta,
                commandID: firstCommandID
            )
        ) { error in
            XCTAssertEqual(
                error as? FolderIncarnationStoreError,
                .creationCommandReused(firstCommandID.uuidString.lowercased())
            )
        }
        XCTAssertEqual(try store.policyContext(for: alpha), alphaContext)
        XCTAssertThrowsError(try store.policyContext(for: beta))
        XCTAssertEqual(try store.snapshot().generation, 1)
    }

    func testLegacyReconciliationPreservesExistingAndPrunesOnlyWhenAuthoritative() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = FolderIncarnationStore(url: fixture.url)
        let alpha = try folder("alpha")
        let beta = try folder("beta")
        let originalAlpha = try store.recordSuccessfulCreation(
            folderID: alpha,
            commandID: firstCommandID
        )

        let contexts = try store.ensureLegacyConfiguredFolders([beta, alpha, beta])
        XCTAssertEqual(contexts.map(\.folderID), [alpha, beta])
        XCTAssertEqual(contexts.first, originalAlpha)
        let betaContext = try XCTUnwrap(contexts.last)
        XCTAssertTrue(isCanonicalDigest(betaContext.folderIncarnationDigest))
        let afterInitialEnsure = try Data(contentsOf: fixture.url)
        XCTAssertEqual(try store.snapshot().generation, 2)
        XCTAssertNil(
            try store.snapshot().records.first(where: { $0.folderID == beta })?.creationCommandID
        )

        _ = try store.ensureLegacyConfiguredFolders([alpha, beta])
        XCTAssertEqual(try Data(contentsOf: fixture.url), afterInitialEnsure)
        _ = try store.ensureLegacyConfiguredFolders([beta])
        XCTAssertEqual(try store.policyContext(for: alpha), originalAlpha)
        XCTAssertEqual(try store.snapshot().generation, 2)

        _ = try store.ensureLegacyConfiguredFolders(
            [beta],
            authoritativeReconciliation: true
        )
        XCTAssertEqual(try store.snapshot().records.map(\.folderID), [beta])
        XCTAssertEqual(try store.policyContext(for: beta), betaContext)
        XCTAssertEqual(try store.snapshot().generation, 3)
        XCTAssertThrowsError(try store.policyContext(for: alpha))
    }

    func testStrictSchemaRejectsUnknownDuplicateCorruptAndOversizedDocuments() throws {
        let invalidDocuments: [Data] = [
            Data(#"{"generation":0,"records":[],"schemaVersion":1,"unknown":true}"#.utf8),
            Data(#"{"generation":0,"generation":0,"records":[],"schemaVersion":1}"#.utf8),
            Data(#"{"generation":0,"records":[],"schemaVersion":2}"#.utf8),
            Data(
                #"{"generation":1,"records":[{"folderID":"a","folderIncarnationDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"folderID":"a","folderIncarnationDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],"schemaVersion":1}"#
                    .utf8),
            Data(
                #"{"generation":1,"records":[{"folderID":"a","folderIncarnationDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"folderID":"b","folderIncarnationDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}],"schemaVersion":1}"#
                    .utf8),
            Data(
                #"{"generation":1,"records":[{"folderID":"a","folderIncarnationDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","unknown":true}],"schemaVersion":1}"#
                    .utf8),
            Data("not-json".utf8),
            Data(repeating: 0x20, count: Int(FolderIncarnationStore.maximumDocumentBytes + 1)),
        ]

        for data in invalidDocuments {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try SecureLockFile.writeAtomically(data, to: fixture.url)
            XCTAssertThrowsError(try FolderIncarnationStore(url: fixture.url).snapshot())
        }
    }

    func testSymlinkAndDirectoryDocumentsAreRejectedWithoutFollowing() throws {
        let symlinkFixture = try Fixture()
        defer { symlinkFixture.cleanup() }
        let target = symlinkFixture.root.appendingPathComponent("target.json")
        try Data(#"{"generation":0,"records":[],"schemaVersion":1}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: symlinkFixture.url,
            withDestinationURL: target
        )
        XCTAssertThrowsError(try FolderIncarnationStore(url: symlinkFixture.url).snapshot())

        let directoryFixture = try Fixture()
        defer { directoryFixture.cleanup() }
        try FileManager.default.createDirectory(at: directoryFixture.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try FolderIncarnationStore(url: directoryFixture.url).snapshot())
    }

    func testConcurrentReplayHasOneLinearizedMutation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = FolderIncarnationStore(url: fixture.url)
        let folderID = try folder("concurrent")
        let results = ConcurrentContextCollector()
        let commandID = firstCommandID

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                results.record(
                    try store.recordSuccessfulCreation(
                        folderID: folderID,
                        commandID: commandID
                    )
                )
            } catch {
                results.record(error)
            }
        }

        XCTAssertTrue(results.errors.isEmpty, "Unexpected failures: \(results.errors)")
        XCTAssertEqual(Set(results.contexts).count, 1)
        XCTAssertEqual(results.contexts.count, 64)
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(snapshot.records.count, 1)
    }

    func testCanonicalBytesDoNotDependOnMutationOrder() throws {
        let firstFixture = try Fixture()
        defer { firstFixture.cleanup() }
        let secondFixture = try Fixture()
        defer { secondFixture.cleanup() }
        let alpha = try folder("alpha")
        let beta = try folder("beta")
        let firstStore = FolderIncarnationStore(url: firstFixture.url)
        let secondStore = FolderIncarnationStore(url: secondFixture.url)

        _ = try firstStore.recordSuccessfulCreation(folderID: beta, commandID: secondCommandID)
        _ = try firstStore.recordSuccessfulCreation(folderID: alpha, commandID: firstCommandID)
        _ = try secondStore.recordSuccessfulCreation(folderID: alpha, commandID: firstCommandID)
        _ = try secondStore.recordSuccessfulCreation(folderID: beta, commandID: secondCommandID)

        let firstBytes = try Data(contentsOf: firstFixture.url)
        XCTAssertEqual(firstBytes, try Data(contentsOf: secondFixture.url))
        XCTAssertEqual(
            String(decoding: firstBytes, as: UTF8.self),
            #"{"generation":2,"records":[{"creationCommandID":"00000000-0000-0000-0000-000000000001","folderID":"alpha","folderIncarnationDigest":"40135598e5636646ddf373e8e933325517e6feabf4fbbc430cd6f14f525978eb"},{"creationCommandID":"00000000-0000-0000-0000-000000000002","folderID":"beta","folderIncarnationDigest":"a61a966163796220c4a5ff8dad1b33dff7c037903b37e200f63b0801d55c5248"}],"schemaVersion":1}"#
        )
    }

    func testSharedContainerExposesRegistryPath() {
        let root = URL(fileURLWithPath: "/tmp/folder-incarnation-path-test", isDirectory: true)
        XCTAssertEqual(
            SharedContainerPaths(root: root).folderIncarnations,
            root.appendingPathComponent("Metadata/folder-incarnations.json")
        )
    }

    private func folder(_ rawValue: String) throws -> FolderID {
        try XCTUnwrap(FolderID(rawValue: rawValue))
    }

    private func isCanonicalDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

private final class ConcurrentContextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedContexts: [FolderPolicyContext] = []
    private var storedErrors: [String] = []

    var contexts: [FolderPolicyContext] {
        lock.withLock { storedContexts }
    }

    var errors: [String] {
        lock.withLock { storedErrors }
    }

    func record(_ context: FolderPolicyContext) {
        lock.withLock { storedContexts.append(context) }
    }

    func record(_ error: any Error) {
        lock.withLock { storedErrors.append(String(describing: error)) }
    }
}

private struct Fixture {
    let root: URL
    let url: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "folder-incarnations-\(UUID().uuidString)",
            isDirectory: true
        )
        url = root.appendingPathComponent("folder-incarnations.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
