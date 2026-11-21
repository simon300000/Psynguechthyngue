import Foundation
import XCTest

#if os(macOS)
    final class FileProviderEnumeratorContractTests: XCTestCase {
        func testChangeEnumerationUsesTheAtomicValidatedJournalRead() throws {
            let source = try repositorySource("FileProvider/ProviderEnumerator.swift")
            let body = try functionBody(
                "    func enumerateChanges(",
                in: source,
                endingAt: "    func currentSyncAnchor("
            )

            let journalRead = try XCTUnwrap(
                body.range(of: "validatedPage = try await store.validatedChanges(")?.lowerBound
            )
            let expectedGeneration = try XCTUnwrap(
                body.range(
                    of: "expectedCurrentGeneration: snapshot.generation",
                    range: journalRead..<body.endIndex
                )?.lowerBound
            )
            let expiredGuard = try XCTUnwrap(
                body.range(
                    of: "guard case .page(let page) = validatedPage",
                    range: expectedGeneration..<body.endIndex
                )?.lowerBound
            )
            let firstObserverMutation = try XCTUnwrap(
                ["observer.update(", "observer.delete(", "observer.finish("]
                    .compactMap { body.range(of: $0, range: journalRead..<body.endIndex)?.lowerBound }
                    .min()
            )

            XCTAssertLessThan(journalRead, expectedGeneration)
            XCTAssertLessThan(expectedGeneration, expiredGuard)
            XCTAssertLessThan(expiredGuard, firstObserverMutation)
            XCTAssertFalse(body.contains("store.containsChange"))
            XCTAssertFalse(body.contains("store.changes("))
        }

        func testFullEnumerationStillFallsBackToTheCanonicalSnapshotWhenTheIndexIsStale() throws {
            let source = try repositorySource("FileProvider/ProviderEnumerator.swift")
            let body = try functionBody(
                "    func enumerateItems(",
                in: source,
                endingAt: "    func enumerateChanges("
            )

            XCTAssertTrue(body.contains("store.currentGeneration() == snapshot.generation"))
            XCTAssertTrue(body.contains("Self.enumerateSnapshotFallback("))
            let pageRead = try XCTUnwrap(
                body.range(of: "let result = try await Self.page(")?.lowerBound
            )
            let postReadGenerationCheck = try XCTUnwrap(
                body.range(
                    of: "let finalStoreGeneration = try await store.currentGeneration()",
                    range: pageRead..<body.endIndex
                )?.lowerBound
            )
            let firstObserverCallback = try XCTUnwrap(
                body.range(of: "observer.enumerate(", range: pageRead..<body.endIndex)?.lowerBound
            )
            XCTAssertLessThan(pageRead, postReadGenerationCheck)
            XCTAssertLessThan(postReadGenerationCheck, firstObserverCallback)
            XCTAssertTrue(body.contains("guard finalStoreGeneration == snapshot.generation"))
            XCTAssertTrue(body.contains("try ProviderSupport.snapshot(paths: paths).generation == snapshot.generation"))
        }

        func testFullEnumerationKeepsSnapshotTokensOnFallbackAndCanResumeAnIndexToken() throws {
            let source = try repositorySource("FileProvider/ProviderEnumerator.swift")
            let enumeration = try functionBody(
                "    func enumerateItems(",
                in: source,
                endingAt: "    func enumerateChanges("
            )
            let fallback = try functionBody(
                "    private static func enumerateSnapshotFallback(",
                in: source,
                endingAt: "    private static func providerItems("
            )

            XCTAssertTrue(enumeration.contains("case .offset = pageValues.position"))
            XCTAssertTrue(enumeration.contains("Self.enumerateSnapshotFallback("))
            XCTAssertTrue(fallback.contains("case .itemID(let itemID):"))
            XCTAssertTrue(fallback.contains("sorted.firstIndex(where: { $0.id == itemID })"))
        }

        func testIndexItemCursorIsValidatedAgainstItsCurrentContainerScope() throws {
            let source = try repositorySource("FileProvider/ProviderEnumerator.swift")
            let cursor = try functionBody(
                "    private static func cursor(",
                in: source,
                endingAt: "    private static func item("
            )
            let membership = try functionBody(
                "    private static func item(",
                in: source,
                endingAt: "    private static func page("
            )

            XCTAssertTrue(cursor.contains("belongsTo: container"))
            XCTAssertTrue(membership.contains("container == .workingSet"))
            XCTAssertTrue(membership.contains("item.folderID == folder.id && item.parentID == nil"))
            XCTAssertTrue(membership.contains("item.parentID == parentID"))
            XCTAssertTrue(membership.contains("item.folderID == parent.folderID"))
        }

        func testChangeAnchorCarriesTheValidatedCumulativeRowBoundary() throws {
            let source = try repositorySource("FileProvider/ProviderSupport.swift")
            let encoder = try functionBody(
                "    static func anchor(",
                in: source,
                endingAt: "    static func anchorValues("
            )
            let body = try functionBody(
                "    static func anchorValues(",
                in: source,
                endingAt: "    static func page("
            )

            XCTAssertTrue(encoder.contains("data.append(2)"))
            XCTAssertTrue(encoder.contains("bigEndianData(cursor.rowOffset)"))
            XCTAssertTrue(body.contains("case 1 where data.count == 26:"))
            XCTAssertTrue(body.contains("return nil"))
            XCTAssertTrue(body.contains("let cursorGeneration = readBigEndianUInt64"))
            XCTAssertTrue(body.contains("let rowOffset = readBigEndianUInt64(data, offset: 26)"))
            XCTAssertTrue(body.contains("guard cursorGeneration > generation, rowOffset > 0"))
            XCTAssertTrue(body.contains("rowOffset: rowOffset"))
        }

        func testValidatedJournalReadAndPruningShareTransactionalCoverageState() throws {
            let source = try repositorySource(
                "Sources/PsyCore/Storage/IndexedMetadataStore.swift"
            )
            let validatedRead = try functionBody(
                "    public func validatedChanges(",
                in: source,
                endingAt: "    private func readChanges("
            )
            let prune = try functionBody(
                "    public func pruneChangeJournal(",
                in: source,
                endingAt: "    @discardableResult\n    public func recoverIfNeeded("
            )

            XCTAssertTrue(validatedRead.contains("database.transaction(mode: \"DEFERRED\")"))
            XCTAssertTrue(validatedRead.contains("generation >= (try journalPrunedThrough())"))
            XCTAssertTrue(validatedRead.contains("changeBoundaryRowCount("))
            XCTAssertTrue(validatedRead.contains("== cursor.rowOffset"))
            XCTAssertTrue(prune.contains("database.transaction"))
            XCTAssertTrue(prune.contains("journal_pruned_through = MAX"))
        }

        func testProviderUsesShortLivedReadOnlyMetadataConnectionsAndKeepsTemporariesInMemory() throws {
            let enumerator = try repositorySource("FileProvider/ProviderEnumerator.swift")
            let metadata = try repositorySource(
                "Sources/PsyCore/Storage/IndexedMetadataStore.swift"
            )

            XCTAssertFalse(enumerator.contains("ProviderMetadataStoreCache"))
            XCTAssertGreaterThanOrEqual(
                enumerator.components(separatedBy: "accessMode: .readOnly").count - 1,
                2
            )
            XCTAssertTrue(metadata.contains("PRAGMA temp_store = MEMORY"))
            XCTAssertFalse(metadata.contains("PRAGMA temp_store = FILE"))
        }

        private func repositorySource(_ path: String) throws -> String {
            try String(
                contentsOf: repositoryRoot().appendingPathComponent(path),
                encoding: .utf8
            )
        }

        private func functionBody(
            _ marker: String,
            in source: String,
            endingAt endMarker: String
        ) throws -> String {
            let start = try XCTUnwrap(source.range(of: marker)?.lowerBound)
            let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
            return String(source[start..<end])
        }

        private func repositoryRoot() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
    }
#endif
