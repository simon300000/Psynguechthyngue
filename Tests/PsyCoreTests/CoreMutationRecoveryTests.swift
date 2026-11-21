import Foundation
import XCTest

@testable import PsyCore

final class CoreMutationRecoveryTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let recoveryID = String(repeating: "b", count: 64)

    func testSummaryRejectsPrivateOrMalformedPayloadFields() throws {
        let valid = try summary(status: .retainedRequiresUserConfirmation)
        XCTAssertEqual(valid.relativePath, "Reports/recoverable.txt")
        XCTAssertEqual(valid.digest, digest)

        for path in [
            "/private/var/mobile/recoverable.txt",
            "../recoverable.txt",
            "Reports\\recoverable.txt",
            "Reports//recoverable.txt",
            "file:///private/recoverable.txt",
        ] {
            XCTAssertThrowsError(
                try summary(relativePath: path, status: .retainedRequiresUserConfirmation)
            )
        }
        XCTAssertThrowsError(
            try summary(recoveryID: UUID().uuidString, status: .retainedRequiresUserConfirmation)
        )
        XCTAssertThrowsError(
            try summary(digest: "not-a-digest", status: .retainedRequiresUserConfirmation)
        )
        XCTAssertThrowsError(
            try summary(bytes: -1, status: .retainedRequiresUserConfirmation)
        )
    }

    func testSummaryDecodingCannotBypassRedactionValidation() throws {
        let valid = try JSONEncoder().encode(
            summary(status: .retainedRequiresUserConfirmation)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["relativePath"] = "/private/var/mobile/hidden"
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CoreMutationRecoverySummary.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        object["relativePath"] = "Reports/recoverable.txt"
        object["recoveryID"] = UUID().uuidString
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CoreMutationRecoverySummary.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testNormalDisposalUsesOnlyExactReviewedSummaryFields() throws {
        for status in [
            CoreMutationRecoveryStatus.retainedRequiresUserConfirmation,
            .disposalApprovedPendingCleanup,
        ] {
            let summary = try summary(status: status)
            let command = try CoreMutationRecoveryCommandBuilder.dispose(
                summary,
                id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
            )
            XCTAssertEqual(command.kind, .disposeRecovery)
            XCTAssertNil(command.folderID)
            XCTAssertNil(command.itemID)
            XCTAssertEqual(
                command.arguments,
                [
                    "recoveryID": recoveryID,
                    "digest": digest,
                    "byteCount": "17",
                    "status": status.rawValue,
                    "confirmed": "true",
                ]
            )
            XCTAssertNil(command.arguments["relativePath"])
            XCTAssertNil(command.arguments["folderID"])
            XCTAssertNil(command.arguments["payloadKind"])
            XCTAssertTrue(command.supportsNativeFailureReplay)
            XCTAssertTrue(command.isCoreMutationRecoveryDisposal)
        }
    }

    func testPreparedAndConflictRequireReviewedDisposalAndPayloadKind() throws {
        for status in [
            CoreMutationRecoveryStatus.prepared,
            .conflictRequiresManualCleanup,
        ] {
            let summary = try summary(status: status)
            XCTAssertThrowsError(try CoreMutationRecoveryCommandBuilder.dispose(summary))
            let command = try CoreMutationRecoveryCommandBuilder.disposeAfterDangerousReview(summary)
            XCTAssertEqual(command.kind, .disposeRecoveryReviewed)
            XCTAssertEqual(command.arguments["payloadKind"], "file")
            XCTAssertEqual(command.arguments["status"], status.rawValue)
            XCTAssertEqual(command.arguments["confirmed"], "true")
            XCTAssertTrue(command.supportsNativeFailureReplay)
            XCTAssertTrue(command.isCoreMutationRecoveryDisposal)
        }

        XCTAssertThrowsError(
            try CoreMutationRecoveryCommandBuilder.disposeAfterDangerousReview(
                summary(status: .retainedRequiresUserConfirmation)
            )
        )
    }

    func testQueryContractEncodesOnlyAllowedKeysAndEnforcesCapacityBounds() throws {
        let request = try CoreMutationRecoveryQueryRequest(
            requestID: "query-request",
            cursor: "opaque-cursor",
            limit: 200
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["schemaVersion", "requestID", "query", "cursor", "limit"]
        )
        XCTAssertEqual(object["query"] as? String, "recoveries")
        XCTAssertThrowsError(
            try CoreMutationRecoveryQueryRequest(requestID: "query-request", limit: 0)
        )
        XCTAssertThrowsError(
            try CoreMutationRecoveryQueryRequest(requestID: "query-request", limit: 201)
        )
    }

    func testPageRejectsDuplicateIdentityAndInconsistentCursorState() throws {
        let record = try summary(status: .retainedRequiresUserConfirmation)
        XCTAssertThrowsError(
            try CoreMutationRecoveryPage(
                recoveries: [record, record],
                nextCursor: nil,
                hasMore: false
            )
        )
        XCTAssertThrowsError(
            try CoreMutationRecoveryPage(
                recoveries: [record],
                nextCursor: nil,
                hasMore: true
            )
        )
        XCTAssertThrowsError(
            try CoreMutationRecoveryPage(
                recoveries: [record],
                nextCursor: "unexpected",
                hasMore: false
            )
        )
    }

    func testExportBuilderUsesOpaqueContainerAndExactSummaryArguments() throws {
        let summary = try summary(status: .retainedRequiresUserConfirmation)
        let exportID = try XCTUnwrap(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let outputName = CoreMutationRecoveryExportBuilder.outputName(
            for: summary,
            exportID: exportID
        )
        XCTAssertEqual(outputName, "recoverable Recovery 11111111.txt")
        XCTAssertEqual(
            try CoreMutationRecoveryExportBuilder.arguments(
                for: summary,
                exportID: exportID,
                outputName: outputName
            ),
            [
                "recoveryID": recoveryID,
                "folderID": "documents",
                "commandKind": "modify",
                "relativePath": "Reports/recoverable.txt",
                "payloadKind": "file",
                "digest": digest,
                "byteCount": "17",
                "status": "retainedRequiresUserConfirmation",
                "exportID": "11111111-2222-3333-4444-555555555555",
                "outputName": "recoverable Recovery 11111111.txt",
            ]
        )
        XCTAssertThrowsError(
            try CoreMutationRecoveryExportBuilder.arguments(
                for: summary,
                exportID: exportID,
                outputName: "../escaped"
            )
        )

        let paths = SharedContainerPaths(root: URL(fileURLWithPath: "/private/tmp/app-group"))
        let export = try CoreMutationRecoveryExportBuilder.export(
            for: summary,
            exportID: exportID,
            paths: paths
        )
        XCTAssertEqual(export.payloadKind, .file)
        XCTAssertTrue(
            export.url.path.hasSuffix(
                "/Core/Bridge/MutationRecoveryExports/.psy-core-recovery-export-11111111-2222-3333-4444-555555555555/recoverable Recovery 11111111.txt"
            )
        )
        XCTAssertFalse(export.url.path.contains(recoveryID))
    }

    private func summary(
        recoveryID: String? = nil,
        relativePath: String = "Reports/recoverable.txt",
        digest: String? = nil,
        bytes: Int64 = 17,
        status: CoreMutationRecoveryStatus
    ) throws -> CoreMutationRecoverySummary {
        try CoreMutationRecoverySummary(
            recoveryID: recoveryID ?? self.recoveryID,
            folderID: FolderID(rawValue: "documents")!,
            commandKind: .modify,
            relativePath: relativePath,
            payloadKind: .file,
            digest: digest ?? self.digest,
            bytes: bytes,
            createdAt: Date(timeIntervalSince1970: 1),
            status: status
        )
    }
}
