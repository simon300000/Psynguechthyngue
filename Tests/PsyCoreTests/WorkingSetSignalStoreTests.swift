import Foundation
import XCTest

@testable import PsyCore

final class WorkingSetSignalStoreTests: XCTestCase {
    func testConcurrentRequestsPersistOnlyGreatestGeneration() async throws {
        let url = try makeStateURL()
        let store = WorkingSetSignalStore(url: url)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for generation in (0...128).reversed() {
                group.addTask {
                    _ = try store.request(generation: UInt64(generation))
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(try store.pending(), 128)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), Set(["pendingGeneration", "schemaVersion"]))
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(url.path))
    }

    func testAcknowledgeOfObservedGenerationPreservesNewerRequest() throws {
        let url = try makeStateURL()
        let store = WorkingSetSignalStore(url: url)
        _ = try store.request(generation: 7)
        let generationBeingSent = try XCTUnwrap(store.pending())

        _ = try store.request(generation: 9)
        XCTAssertEqual(try store.acknowledge(upTo: generationBeingSent), 9)
        XCTAssertEqual(try store.pending(), 9)
        XCTAssertNil(try store.acknowledge(upTo: 9))
        XCTAssertNil(try store.pending())
    }

    func testPendingRequestSurvivesStoreRestartAndSameGenerationCanBeRequestedAgain() throws {
        let url = try makeStateURL()
        _ = try WorkingSetSignalStore(url: url).request(generation: 42)

        let restarted = WorkingSetSignalStore(url: url)
        XCTAssertEqual(try restarted.pending(), 42)
        XCTAssertNil(try restarted.acknowledge(upTo: 42))
        XCTAssertNil(try restarted.pending())
        XCTAssertEqual(try restarted.request(generation: 42), 42)
        XCTAssertEqual(try WorkingSetSignalStore(url: url).pending(), 42)
    }

    func testCorruptAndUnknownSchemaStateFailClosedWithoutBeingReplaced() throws {
        let url = try makeStateURL()
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url, options: .atomic)
        let corruptStore = WorkingSetSignalStore(url: url)

        XCTAssertThrowsError(try corruptStore.pending()) {
            XCTAssertEqual($0 as? WorkingSetSignalStoreError, .corruptState)
        }
        XCTAssertThrowsError(try corruptStore.request(generation: 5)) {
            XCTAssertEqual($0 as? WorkingSetSignalStoreError, .corruptState)
        }
        XCTAssertThrowsError(try corruptStore.acknowledge(upTo: 5)) {
            XCTAssertEqual($0 as? WorkingSetSignalStoreError, .corruptState)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)

        let unknown = Data(#"{"pendingGeneration":8,"schemaVersion":99}"#.utf8)
        try unknown.write(to: url, options: .atomic)
        let unknownStore = WorkingSetSignalStore(url: url)
        XCTAssertThrowsError(try unknownStore.pending()) {
            XCTAssertEqual($0 as? WorkingSetSignalStoreError, .unsupportedSchema(99))
        }
        XCTAssertThrowsError(try unknownStore.request(generation: 10)) {
            XCTAssertEqual($0 as? WorkingSetSignalStoreError, .unsupportedSchema(99))
        }
        XCTAssertThrowsError(try unknownStore.acknowledge(upTo: 8)) {
            XCTAssertEqual($0 as? WorkingSetSignalStoreError, .unsupportedSchema(99))
        }
        XCTAssertEqual(try Data(contentsOf: url), unknown)
    }

    private func makeStateURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkingSetSignalStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("working-set-signal.json")
    }
}
