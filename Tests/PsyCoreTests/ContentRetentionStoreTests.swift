import Foundation
import XCTest

@testable import PsyCore

final class ContentRetentionStoreTests: XCTestCase {
    private let folderID = FolderID(rawValue: "retention")!
    private let incarnation = String(repeating: "a", count: 64)
    private let configurationRevision = String(repeating: "b", count: 64)

    func testPlansAreLocalRetentionOnlyAndNeverReadOrWriteStignore() throws {
        let fixture = try Fixture()
        let ignoreURL = fixture.root.appendingPathComponent(".stignore")
        let original = Data("user-owned/**\n(?d)cache/**\n".utf8)
        try original.write(to: ignoreURL)

        let store = ContentRetentionStore(url: fixture.storeURL)
        let plan = FolderSelectionPlan(
            mode: .globRules,
            globRules: [
                SelectionRule(
                    syntax: .syncthingGlob,
                    action: .include,
                    pattern: "Photos/**"
                ),
                SelectionRule(
                    syntax: .syncthingGlob,
                    action: .exclude,
                    pattern: "**"
                ),
            ]
        )
        _ = try store.applyPlan(
            folderID: folderID,
            folderIncarnationDigest: incarnation,
            expectedGeneration: 0,
            plan: plan
        )

        let retained = try store.status(
            for: item(id: "photo", path: "Photos/a.jpg"),
            folderIncarnationDigest: incarnation
        )
        let ordinary = try store.status(
            for: item(id: "note", path: "Notes/a.txt"),
            folderIncarnationDigest: incarnation
        )
        XCTAssertTrue(retained.isPinned)
        XCTAssertFalse(ordinary.isPinned)
        XCTAssertEqual(try Data(contentsOf: ignoreURL), original)
    }

    func testManualAndRegexPlansDetermineRetentionFromGlobalIndexMetadata() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let manual = FolderSelectionPlan(
            mode: .manualSelection,
            manualDefault: .excluded,
            manualDirectives: [
                .init(relativePath: "Books", isDirectory: true, value: .included)
            ]
        )
        _ = try store.applyPlan(
            folderID: folderID,
            folderIncarnationDigest: incarnation,
            expectedGeneration: 0,
            plan: manual
        )
        XCTAssertTrue(
            try store.status(
                for: item(id: "book", path: "Books/new/one.epub"),
                folderIncarnationDigest: incarnation
            ).isPinned
        )

        let regex = FolderSelectionPlan(
            mode: .regexRules,
            regexRules: [
                SelectionRule(
                    syntax: .re2SafeRegex,
                    action: .include,
                    pattern: "^Archive/.+\\.pdf$"
                ),
                SelectionRule(
                    syntax: .re2SafeRegex,
                    action: .exclude,
                    pattern: ".*"
                ),
            ]
        )
        _ = try store.applyPlan(
            folderID: folderID,
            folderIncarnationDigest: incarnation,
            expectedGeneration: 1,
            plan: regex
        )
        XCTAssertTrue(
            try store.status(
                for: item(id: "pdf", path: "Archive/one.pdf"),
                folderIncarnationDigest: incarnation
            ).isPinned
        )
        XCTAssertFalse(
            try store.status(
                for: item(id: "jpg", path: "Archive/one.jpg"),
                folderIncarnationDigest: incarnation
            ).isPinned
        )

        let pdf = item(id: "pdf", path: "Archive/one.pdf")
        _ = try store.applyPlan(
            folderID: folderID,
            folderIncarnationDigest: incarnation,
            expectedGeneration: 2,
            plan: FolderSelectionPlan(mode: .indexOnly)
        )
        XCTAssertFalse(
            try store.status(for: pdf, folderIncarnationDigest: incarnation).isPinned,
            "a derived rule match must not become a permanent per-item override"
        )

        try store.keepDownloaded(
            itemID: pdf.id,
            folderID: folderID,
            relativePath: pdf.relativePath,
            isDirectory: false,
            folderIncarnationDigest: incarnation
        )
        _ = try store.applyPlan(
            folderID: folderID,
            folderIncarnationDigest: incarnation,
            expectedGeneration: 3,
            plan: regex
        )
        _ = try store.applyPlan(
            folderID: folderID,
            folderIncarnationDigest: incarnation,
            expectedGeneration: 4,
            plan: FolderSelectionPlan(mode: .indexOnly)
        )
        XCTAssertTrue(
            try store.status(for: pdf, folderIncarnationDigest: incarnation).isPinned,
            "an explicit Keep Downloaded choice must continue to override later folder plans"
        )
    }

    func testRemoveDownloadQueuesUntilExactVersionIsUploaded() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let local = item(id: "draft", path: "draft.txt", uploaded: false)

        let disposition = try store.requestEviction(
            of: local,
            folderIncarnationDigest: incarnation,
            configurationRevision: configurationRevision
        )
        XCTAssertEqual(disposition, .waitingForUpload)
        var status = try store.status(for: local, folderIncarnationDigest: incarnation)
        XCTAssertFalse(status.isPinned)
        XCTAssertTrue(status.pendingEvict)
        XCTAssertNil(status.evictionTransactionID)

        var uploaded = local
        uploaded.hasUnuploadedChanges = false
        uploaded.remoteReplicaCount = 1
        let transaction = try XCTUnwrap(
            store.recordUploadEvidence(
                for: uploaded,
                folderIncarnationDigest: incarnation,
                configurationRevision: configurationRevision
            )
        )
        status = try store.status(for: uploaded, folderIncarnationDigest: incarnation)
        XCTAssertTrue(status.isUploaded)
        XCTAssertEqual(status.evictionTransactionID, transaction.id)
    }

    func testUploadedFileStartsDurableEvictionImmediately() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let uploaded = item(id: "ready", path: "ready.txt", uploaded: true)

        let disposition = try store.requestEviction(
            of: uploaded,
            folderIncarnationDigest: incarnation,
            configurationRevision: configurationRevision
        )
        guard case .ready(let transaction) = disposition else {
            return XCTFail("Expected a durable eviction transaction")
        }
        XCTAssertEqual(transaction.itemID, uploaded.id)
        XCTAssertEqual(transaction.contentVersion, uploaded.contentVersion)

        let restarted = ContentRetentionStore(url: fixture.storeURL)
        XCTAssertEqual(try restarted.pendingTransactions(), [transaction])
        guard
            case .ready(let replayed) = try restarted.requestEviction(
                of: uploaded,
                folderIncarnationDigest: incarnation,
                configurationRevision: configurationRevision
            )
        else {
            return XCTFail("Expected the durable transaction to be resumed")
        }
        XCTAssertEqual(replayed, transaction)
        try restarted.completeEviction(transactionID: transaction.id)
        let status = try restarted.status(for: uploaded, folderIncarnationDigest: incarnation)
        XCTAssertFalse(status.pendingEvict)
        XCTAssertNil(status.evictionTransactionID)
    }

    func testOfflineExactUploadEvidenceRemainsEligibleUntilTheLocalVersionChanges() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let uploaded = item(id: "offline", path: "offline.txt", uploaded: true)
        _ = try store.recordUploadEvidence(
            for: uploaded,
            folderIncarnationDigest: incarnation,
            configurationRevision: configurationRevision
        )

        var offline = uploaded
        offline.remoteReplicaCount = 0
        XCTAssertTrue(
            try store.status(for: offline, folderIncarnationDigest: incarnation).isUploaded
        )
        guard
            case .ready = try store.requestEviction(
                of: offline,
                folderIncarnationDigest: incarnation,
                configurationRevision: configurationRevision
            )
        else {
            return XCTFail("The unchanged version should retain its last exact upload proof offline")
        }
    }

    func testMaterializedSetReconciliationMarkerSurvivesRestartUntilCompleted() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        XCTAssertFalse(try store.isMaterializedSetReconciliationPending())

        try store.markMaterializedSetReconciliationPending()
        let restarted = ContentRetentionStore(url: fixture.storeURL)
        XCTAssertTrue(try restarted.isMaterializedSetReconciliationPending())

        try restarted.completeMaterializedSetReconciliation()
        XCTAssertFalse(try store.isMaterializedSetReconciliationPending())
    }

    func testMaterializedSetReconciliationMarkersAreIndependentPerDomain() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let first = "share-v1-aaa"
        let second = "share-v1-bbb"

        try store.markMaterializedSetReconciliationPending(domainIdentifier: first)
        try store.markMaterializedSetReconciliationPending(domainIdentifier: second)
        try store.completeMaterializedSetReconciliation(domainIdentifier: first)

        let restarted = ContentRetentionStore(url: fixture.storeURL)
        XCTAssertFalse(
            try restarted.isMaterializedSetReconciliationPending(domainIdentifier: first)
        )
        XCTAssertTrue(
            try restarted.isMaterializedSetReconciliationPending(domainIdentifier: second)
        )
    }

    func testBackgroundScanCursorSurvivesRestartAndCanWrapToBeginning() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let cursor = IndexedItemPageCursor(relativePath: "Later/file.txt", itemID: "later")

        XCTAssertNil(try store.backgroundScanCursor())
        try store.advanceBackgroundScanCursor(to: cursor)
        XCTAssertEqual(
            try ContentRetentionStore(url: fixture.storeURL).backgroundScanCursor(),
            cursor
        )

        try store.advanceBackgroundScanCursor(to: nil)
        XCTAssertNil(try ContentRetentionStore(url: fixture.storeURL).backgroundScanCursor())
    }

    func testKeepDownloadedCancelsPendingEvictionAndDirectoryPinIsInherited() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let file = item(id: "child", path: "Albums/2026/a.flac", uploaded: false)
        _ = try store.requestEviction(
            of: file,
            folderIncarnationDigest: incarnation,
            configurationRevision: configurationRevision
        )

        try store.keepDownloaded(
            itemID: file.id,
            folderID: folderID,
            relativePath: file.relativePath,
            isDirectory: false,
            folderIncarnationDigest: incarnation
        )
        var status = try store.status(for: file, folderIncarnationDigest: incarnation)
        XCTAssertTrue(status.isPinned)
        XCTAssertFalse(status.pendingEvict)

        try store.keepDownloaded(
            itemID: "albums",
            folderID: folderID,
            relativePath: "Albums",
            isDirectory: true,
            folderIncarnationDigest: incarnation
        )
        let future = item(id: "future", path: "Albums/2027/future.flac", uploaded: true)
        status = try store.status(for: future, folderIncarnationDigest: incarnation)
        XCTAssertTrue(status.isPinned)
    }

    func testDirectoryRemoveDownloadClearsExistingDescendantPinsAndFutureInheritance() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let child = item(id: "kept-child", path: "Albums/2026/a.flac", uploaded: true)
        try store.keepDownloaded(
            itemID: child.id,
            folderID: folderID,
            relativePath: child.relativePath,
            isDirectory: false,
            folderIncarnationDigest: incarnation
        )
        try store.keepDownloaded(
            itemID: "albums",
            folderID: folderID,
            relativePath: "Albums",
            isDirectory: true,
            folderIncarnationDigest: incarnation
        )

        try store.allowAutomaticEviction(
            itemID: "albums",
            folderID: folderID,
            relativePath: "Albums",
            isDirectory: true,
            folderIncarnationDigest: incarnation
        )

        XCTAssertFalse(
            try store.status(for: child, folderIncarnationDigest: incarnation).isPinned
        )
        XCTAssertFalse(
            try store.status(
                for: item(id: "future-child", path: "Albums/2027/new.flac"),
                folderIncarnationDigest: incarnation
            ).isPinned
        )
    }

    func testDirectoryBatchCannotOverwriteNewerKeepDownloadedIntent() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let child = item(id: "race-child", path: "Albums/race.flac", uploaded: true)

        try store.allowAutomaticEviction(
            itemID: "albums",
            folderID: folderID,
            relativePath: "Albums",
            isDirectory: true,
            folderIncarnationDigest: incarnation
        )
        try store.keepDownloaded(
            itemID: child.id,
            folderID: folderID,
            relativePath: child.relativePath,
            isDirectory: false,
            folderIncarnationDigest: incarnation
        )

        XCTAssertEqual(
            try store.requestEviction(
                of: child,
                folderIncarnationDigest: incarnation,
                configurationRevision: configurationRevision,
                preservingCurrentPin: true
            ),
            .retained
        )
        let status = try store.status(for: child, folderIncarnationDigest: incarnation)
        XCTAssertTrue(status.isPinned)
        XCTAssertFalse(status.pendingEvict)
        XCTAssertNil(status.evictionTransactionID)
    }

    func testDirectoryTraversalCursorRecoversAndNewerPinCancelsIt() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let intent = try store.beginDirectoryEviction(
            itemID: "albums",
            folderID: folderID,
            relativePath: "Albums",
            folderIncarnationDigest: incarnation,
            configurationRevision: configurationRevision,
            indexGeneration: 7
        )
        let cursor = IndexedItemPageCursor(relativePath: "Albums/b.flac", itemID: "b")
        try store.advanceDirectoryEviction(
            intentID: intent.id,
            indexGeneration: 7,
            nextCursor: cursor
        )

        var recovered = try XCTUnwrap(
            ContentRetentionStore(url: fixture.storeURL).directoryEvictionIntents().first
        )
        XCTAssertEqual(recovered.cursor, cursor)
        recovered = try XCTUnwrap(
            store.restartDirectoryEviction(intentID: recovered.id, indexGeneration: 8)
        )
        XCTAssertNil(recovered.cursor)
        XCTAssertEqual(recovered.indexGeneration, 8)

        try store.keepDownloaded(
            itemID: "albums",
            folderID: folderID,
            relativePath: "Albums",
            isDirectory: true,
            folderIncarnationDigest: incarnation
        )
        XCTAssertTrue(try store.directoryEvictionIntents().isEmpty)
        XCTAssertNil(try store.restartDirectoryEviction(intentID: recovered.id, indexGeneration: 9))
        XCTAssertTrue(
            try store.status(
                for: item(id: "future", path: "Albums/future.flac"),
                folderIncarnationDigest: incarnation
            ).isPinned
        )
    }

    func testNewerKeepDownloadedSurvivesAnAlreadyStartedEvictionCompletion() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let uploaded = item(id: "repin", path: "repin.txt", uploaded: true)
        guard
            case .ready(let transaction) = try store.requestEviction(
                of: uploaded,
                folderIncarnationDigest: incarnation,
                configurationRevision: configurationRevision
            )
        else {
            return XCTFail("Expected transaction")
        }
        try store.keepDownloaded(
            itemID: uploaded.id,
            folderID: folderID,
            relativePath: uploaded.relativePath,
            isDirectory: false,
            folderIncarnationDigest: incarnation
        )
        XCTAssertEqual(try store.pendingTransactions(), [transaction])
        try store.completeEviction(transactionID: transaction.id)
        XCTAssertTrue(
            try store.status(for: uploaded, folderIncarnationDigest: incarnation).isPinned
        )
    }

    func testNewVersionInvalidatesPersistedUploadedEvidence() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let uploaded = item(id: "versioned", path: "versioned.txt", uploaded: true)
        _ = try store.recordUploadEvidence(
            for: uploaded,
            folderIncarnationDigest: incarnation,
            configurationRevision: configurationRevision
        )

        var changed = uploaded
        changed.contentVersion = Data("v2".utf8)
        changed.metadataVersion = Data("m2".utf8)
        changed.hasUnuploadedChanges = true
        changed.remoteReplicaCount = 1
        let status = try store.status(for: changed, folderIncarnationDigest: incarnation)
        XCTAssertFalse(status.isUploaded)
    }

    func testIncarnationChangeInvalidatesIntentAndTransactions() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let uploaded = item(id: "old", path: "old.txt", uploaded: true)
        _ = try store.requestEviction(
            of: uploaded,
            folderIncarnationDigest: incarnation,
            configurationRevision: configurationRevision
        )

        let replacement = String(repeating: "b", count: 64)
        let status = try store.status(for: uploaded, folderIncarnationDigest: replacement)
        XCTAssertFalse(status.isPinned)
        XCTAssertFalse(status.pendingEvict)
        XCTAssertTrue(try store.pendingTransactions().isEmpty)
    }

    func testFailedEvictionRestoresPriorPinAndLeavesContentRecoverable() throws {
        let fixture = try Fixture()
        let store = ContentRetentionStore(url: fixture.storeURL)
        let uploaded = item(id: "pinned", path: "pinned.txt", uploaded: true)
        try store.keepDownloaded(
            itemID: uploaded.id,
            folderID: folderID,
            relativePath: uploaded.relativePath,
            isDirectory: false,
            folderIncarnationDigest: incarnation
        )
        guard
            case .ready(let transaction) = try store.requestEviction(
                of: uploaded,
                folderIncarnationDigest: incarnation,
                configurationRevision: configurationRevision
            )
        else {
            return XCTFail("Expected transaction")
        }

        try store.failEviction(transactionID: transaction.id)
        let status = try store.status(for: uploaded, folderIncarnationDigest: incarnation)
        XCTAssertTrue(status.isPinned)
        XCTAssertFalse(status.pendingEvict)
        XCTAssertNil(status.evictionTransactionID)
    }

    private func item(
        id: String,
        path: String,
        uploaded: Bool = true
    ) -> IndexedItem {
        IndexedItem(
            id: id,
            folderID: folderID,
            relativePath: path,
            isDirectory: false,
            size: 8,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentVersion: Data("v1".utf8),
            metadataVersion: Data("m1".utf8),
            availability: .local,
            isPinned: false,
            hasUnuploadedChanges: !uploaded,
            remoteReplicaCount: uploaded ? 1 : 0,
            generation: 1
        )
    }
}

private final class Fixture {
    let root: URL
    let storeURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ContentRetentionStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        storeURL = root.appendingPathComponent("content-retention.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
