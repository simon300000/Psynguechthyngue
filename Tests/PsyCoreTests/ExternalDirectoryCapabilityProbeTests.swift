import Foundation
import XCTest

@testable import PsyCore

final class ExternalDirectoryCapabilityProbeTests: XCTestCase {
    func testWritableLocalDirectoryPassesAllProbeOperationsAndLeavesNoFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capabilities = ExternalDirectoryCapabilityProbe().run(at: root)
        let failures = capabilities.failures.joined(separator: "; ")
        XCTAssertTrue(capabilities.canEnumerate, failures)
        XCTAssertTrue(capabilities.canRead, failures)
        XCTAssertTrue(capabilities.canCreate, failures)
        XCTAssertTrue(capabilities.canWrite, failures)
        XCTAssertTrue(capabilities.canAtomicallyReplace, failures)
        XCTAssertTrue(capabilities.canRename, failures)
        XCTAssertTrue(capabilities.canDelete, failures)
        XCTAssertTrue(capabilities.canAccessRecursively, failures)
        XCTAssertTrue(capabilities.cleanupSucceeded, failures)
        XCTAssertEqual(capabilities.recommendedMode, .direct)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCoordinatorThatSkipsAccessorsFailsClosedWithoutTouchingRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)

        let capabilities = ExternalDirectoryCapabilityProbe(
            fileAccess: SkippingFileCoordination()
        ).run(at: root)

        XCTAssertFalse(capabilities.canEnumerate)
        XCTAssertFalse(capabilities.canRead)
        XCTAssertFalse(capabilities.canCreate)
        XCTAssertFalse(capabilities.canWrite)
        XCTAssertFalse(capabilities.canAtomicallyReplace)
        XCTAssertFalse(capabilities.canRename)
        XCTAssertFalse(capabilities.canDelete)
        XCTAssertFalse(capabilities.canAccessRecursively)
        XCTAssertFalse(capabilities.cleanupSucceeded)
        XCTAssertEqual(capabilities.recommendedMode, .readOnly)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["sentinel.txt"])
    }
}

private struct SkippingFileCoordination: ExternalDirectoryFileCoordinating {
    func coordinateReading(
        at _: URL,
        operation _: (URL) throws -> Void
    ) throws {}

    func coordinateWriting(
        at _: URL,
        operation _: (URL) throws -> Void
    ) throws {}
}
