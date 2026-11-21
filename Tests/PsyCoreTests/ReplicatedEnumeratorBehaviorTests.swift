#if os(iOS)
    import FileProvider
    import Foundation
    import XCTest
    import PsyCore

    @MainActor
    final class ReplicatedEnumeratorBehaviorTests: XCTestCase {
        func testWorkingSetIncludesEmptySharesAndRemotePlaceholdersAcrossPages() async throws {
            let fixture = try await fixture(itemCount: 405)
            defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
            let enumerator = ProviderEnumerator(
                container: .workingSet, domainIdentifier: FileProviderDomainIdentity.legacyAggregateIdentifier,
                paths: fixture.paths)
            var page = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
            var identifiers = Set<String>()
            var count = 0
            repeat {
                let result = try await enumerate(enumerator, page: page)
                for item in result.items { XCTAssertTrue(identifiers.insert(item.itemIdentifier.rawValue).inserted) }
                count += result.items.count
                guard let next = result.next else { break }
                page = next
            } while count < 1000
            XCTAssertEqual(count, 407)  // Two virtual share roots, including an empty share.
            XCTAssertTrue(
                identifiers.contains(ProviderSupport.folderIdentifier(fixture.snapshot.folders[1].id).rawValue))
            XCTAssertTrue(identifiers.contains("item-file-404"))
        }

        func testCacheRemovalPublishesUpdateWithoutDeletingPlaceholder() async throws {
            var fixture = try await fixture(itemCount: 1, availability: .local)
            defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
            let enumerator = ProviderEnumerator(
                container: .workingSet, domainIdentifier: FileProviderDomainIdentity.legacyAggregateIdentifier,
                paths: fixture.paths)
            let anchor = await withCheckedContinuation { continuation in
                enumerator.currentSyncAnchor { continuation.resume(returning: $0!) }
            }
            fixture.snapshot.generation = 2
            fixture.snapshot.items[0].generation = 2
            fixture.snapshot.items[0].availability = .remoteOnly
            try SharedSnapshotStore(snapshotURL: fixture.paths.snapshot).write(fixture.snapshot)
            _ = await MetadataIndexProjector(
                databaseURL: fixture.paths.metadataIndex, statusURL: fixture.paths.metadataIndexStatus
            ).project(fixture.snapshot)
            let result = try await changes(enumerator, anchor: anchor)
            XCTAssertEqual(result.updated.map(\.itemIdentifier.rawValue), ["item-file-0"])
            XCTAssertTrue(result.deleted.isEmpty)
        }

        func testChangedShareNamespaceExpiresAnchorForCompleteReconciliation() async throws {
            var fixture = try await fixture(itemCount: 0)
            defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
            let enumerator = ProviderEnumerator(
                container: .workingSet, domainIdentifier: FileProviderDomainIdentity.legacyAggregateIdentifier,
                paths: fixture.paths)
            let anchor = await withCheckedContinuation { continuation in
                enumerator.currentSyncAnchor { continuation.resume(returning: $0!) }
            }
            fixture.snapshot.generation = 2
            fixture.snapshot.folders.removeLast()
            fixture.snapshot.folders[0].label = "Renamed"
            try SharedSnapshotStore(snapshotURL: fixture.paths.snapshot).write(fixture.snapshot)
            _ = await MetadataIndexProjector(
                databaseURL: fixture.paths.metadataIndex, statusURL: fixture.paths.metadataIndexStatus
            ).project(fixture.snapshot)
            do {
                _ = try await changes(enumerator, anchor: anchor)
                XCTFail("Accepted obsolete virtual hierarchy")
            } catch { XCTAssertEqual((error as NSError).code, NSFileProviderError.Code.syncAnchorExpired.rawValue) }
        }

        private func fixture(itemCount: Int, availability: FileAvailability = .remoteOnly) async throws -> (
            paths: SharedContainerPaths, snapshot: CoreSnapshot
        ) {
            let paths = SharedContainerPaths(
                root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let first = FolderRecord(
                id: FolderID(rawValue: "first")!, label: "Photos",
                localPath: paths.root.appendingPathComponent("a").path)
            let second = FolderRecord(
                id: FolderID(rawValue: "second")!, label: "Photos",
                localPath: paths.root.appendingPathComponent("b").path)
            let items = (0..<itemCount).map { index in
                IndexedItem(
                    id: "file-\(index)", folderID: first.id, relativePath: String(format: "%04d.txt", index),
                    isDirectory: false,
                    modifiedAt: Date(timeIntervalSince1970: 1), contentVersion: Data([1]), metadataVersion: Data([2]),
                    availability: availability, generation: 1)
            }
            let snapshot = CoreSnapshot(
                generation: 1, configurationRevision: String(repeating: "a", count: 64), folders: [first, second],
                items: items)
            try SharedSnapshotStore(snapshotURL: paths.snapshot).write(snapshot)
            _ = await MetadataIndexProjector(databaseURL: paths.metadataIndex, statusURL: paths.metadataIndexStatus)
                .project(snapshot)
            return (paths, snapshot)
        }

        private func enumerate(_ enumerator: ProviderEnumerator, page: NSFileProviderPage) async throws -> CapturedItems
        {
            try await withCheckedThrowingContinuation { continuation in
                enumerator.enumerateItems(for: ItemObserver(continuation), startingAt: page)
            }
        }
        private func changes(_ enumerator: ProviderEnumerator, anchor: NSFileProviderSyncAnchor) async throws
            -> CapturedChanges
        {
            try await withCheckedThrowingContinuation { continuation in
                enumerator.enumerateChanges(for: ChangeObserver(continuation), from: anchor)
            }
        }
    }

    private struct CapturedItems: @unchecked Sendable {
        var items: [NSFileProviderItem] = []
        var next: NSFileProviderPage?
    }
    private struct CapturedChanges: @unchecked Sendable {
        var updated: [NSFileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []
    }
    private final class ItemObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
        private var captured = CapturedItems()
        private let continuation: CheckedContinuation<CapturedItems, Error>
        init(_ continuation: CheckedContinuation<CapturedItems, Error>) { self.continuation = continuation }
        func didEnumerate(_ items: [NSFileProviderItem]) { captured.items += items }
        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            captured.next = nextPage
            continuation.resume(returning: captured)
        }
        func finishEnumeratingWithError(_ error: Error) { continuation.resume(throwing: error) }
    }
    private final class ChangeObserver: NSObject, NSFileProviderChangeObserver, @unchecked Sendable {
        private var captured = CapturedChanges()
        private let continuation: CheckedContinuation<CapturedChanges, Error>
        init(_ continuation: CheckedContinuation<CapturedChanges, Error>) { self.continuation = continuation }
        func didUpdate(_ items: [NSFileProviderItem]) { captured.updated += items }
        func didDeleteItems(withIdentifiers identifiers: [NSFileProviderItemIdentifier]) {
            captured.deleted += identifiers
        }
        func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
            continuation.resume(returning: captured)
        }
        func finishEnumeratingWithError(_ error: Error) { continuation.resume(throwing: error) }
    }
#endif
