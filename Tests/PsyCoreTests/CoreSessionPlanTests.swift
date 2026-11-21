import CryptoKit
import Foundation
import XCTest

@testable import PsyCore

final class CoreSessionPlanTests: XCTestCase {
    func testNetworkPlanUsesGoDomainSeparatedDigestContract() throws {
        let taskID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let folderID = try XCTUnwrap(FolderID(rawValue: "folder-alpha"))
        let revision = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

        let plan = try CoreNetworkSessionPlan(
            taskID: taskID,
            folderID: folderID,
            expectedConfigurationRevision: revision,
            maximumNetworkBytes: try CoreNetworkByteLimit(byteCount: 4_096)
        )

        XCTAssertEqual(plan.taskID, taskID)
        XCTAssertEqual(plan.folderID, folderID)
        XCTAssertEqual(plan.expectedConfigurationRevision, revision)
        XCTAssertEqual(plan.operation, .sync)
        XCTAssertEqual(
            plan.planDigest,
            "559f1d3ac7686316060203fcb31c0cfefb974b97c51eb61784de096c8570cf39"
        )
    }

    func testNetworkPlanMatchesFinalGoV3ContractVector() {
        XCTAssertEqual(
            CoreSessionDigest.networkPlan(
                taskID: "task",
                folderID: "folder",
                configurationRevision:
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                maximumNetworkBytes: "0",
                operation: "sync"
            ),
            "2d99ee9b3be1fa761f60ac19950b380846fe24438eeb1f3d147268a652360ac4"
        )
    }

    func testPendingFolderObservationPlanMatchesGoV1ContractVector() throws {
        XCTAssertEqual(
            CoreSessionDigest.pendingFolderObservationPlan(
                taskID: "task",
                folderID: "folder",
                offeringDeviceID: "device",
                configurationRevision: String(repeating: "0", count: 64),
                maximumNetworkBytes: "0"
            ),
            "a9e4de03dcb281f56bbc648351892bdfb7841de76804b9e9b3ccda22485ccef7"
        )

        let plan = try PendingFolderObservationPlan(
            taskID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            folderID: XCTUnwrap(FolderID(rawValue: "offered-folder")),
            offeringDeviceID: XCTUnwrap(
                DeviceID(
                    rawValue:
                        "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
                )
            ),
            expectedConfigurationRevision: String(repeating: "a", count: 64),
            maximumNetworkBytes: 8 * 1_024 * 1_024
        )
        XCTAssertEqual(plan.maximumNetworkBytes, 8_388_608)
        XCTAssertEqual(plan.maximumNetworkBytesWireValue, "8388608")
        XCTAssertThrowsError(
            try PendingFolderObservationPlan(
                taskID: plan.taskID,
                folderID: plan.folderID,
                offeringDeviceID: plan.offeringDeviceID,
                expectedConfigurationRevision: plan.expectedConfigurationRevision,
                maximumNetworkBytes: -1
            )
        )
        XCTAssertThrowsError(
            try PendingFolderObservationPlan(
                taskID: plan.taskID,
                folderID: plan.folderID,
                offeringDeviceID: plan.offeringDeviceID,
                expectedConfigurationRevision: plan.expectedConfigurationRevision,
                maximumNetworkBytes: 8_388_609
            )
        )
    }

    func testPendingFolderDiscoveryPlanMatchesGoV1ContractVector() throws {
        XCTAssertEqual(
            CoreSessionDigest.pendingFolderDiscoveryPlan(
                taskID: "task",
                offeringDeviceID: "device",
                configurationRevision: String(repeating: "0", count: 64),
                maximumNetworkBytes: "0"
            ),
            "a93131b2dd7347a7735366a61efbde3ea63b50f749bf6da371477cba10a5da17"
        )

        let plan = try discoveryPlan(maximumNetworkBytes: 8_388_608)
        XCTAssertEqual(plan.maximumNetworkBytes, 8_388_608)
        XCTAssertEqual(plan.maximumNetworkBytesWireValue, "8388608")
        XCTAssertThrowsError(try discoveryPlan(maximumNetworkBytes: -1))
        XCTAssertThrowsError(try discoveryPlan(maximumNetworkBytes: 8_388_609))
    }

    func testPendingFolderDiscoveryBindingUsesFolderlessExactShapes() throws {
        let plan = try discoveryPlan(maximumNetworkBytes: 4_096)
        let binding = CoreExplicitSessionBinding.pendingFolderDiscovery(
            sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            plan: plan
        )
        XCTAssertEqual(binding.mode, .pendingFolderDiscovery)
        XCTAssertNil(binding.folderID)
        XCTAssertEqual(binding.offeringDeviceID, plan.offeringDeviceID)

        let common: [String: Any] = [
            "schemaVersion": 1,
            "requestID": "discovery-request",
            "sessionID": binding.sessionIDString,
            "offeringDeviceID": plan.offeringDeviceID.rawValue,
            "taskID": binding.taskIDString!,
            "planDigest": binding.planDigest!,
            "expectedConfigurationRevision": binding.expectedConfigurationRevision!,
            "maximumNetworkBytes": binding.maximumNetworkBytes!,
        ]
        for command in [
            "openPendingFolderDiscoverySession", "capturePendingFolderDiscovery",
        ] {
            var request = common
            request["command"] = command
            XCTAssertNoThrow(
                try CoreSessionBridgeContract.validateRequestBinding(
                    try jsonString(request),
                    binding: binding,
                    folder: .absent
                )
            )

            for forbidden in ["folderID", "itemID", "commandConfigurationRevision", "arguments"] {
                var malformed = request
                malformed[forbidden] = forbidden == "arguments" ? ["x": "y"] : "forbidden"
                XCTAssertThrowsError(
                    try CoreSessionBridgeContract.validateRequestBinding(
                        try jsonString(malformed),
                        binding: binding,
                        folder: .unconstrained
                    )
                )
            }
        }

        var close = common
        close.removeValue(forKey: "offeringDeviceID")
        close["command"] = "closeSession"
        XCTAssertNoThrow(
            try CoreSessionBridgeContract.validateRequestBinding(
                try jsonString(close),
                binding: binding,
                folder: .absent
            )
        )
    }

    func testPendingFolderDiscoveryLifecycleAndCaptureBatchAreStrict() throws {
        let plan = try discoveryPlan(maximumNetworkBytes: 8_388_608)
        let binding = CoreExplicitSessionBinding.pendingFolderDiscovery(
            sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            plan: plan
        )
        for (command, lifecycle) in [
            ("openPendingFolderDiscoverySession", CoreExplicitSessionLifecycle.running),
            ("closeSession", CoreExplicitSessionLifecycle.stopped),
        ] {
            XCTAssertNoThrow(
                try CoreSessionBridgeContract.validateLifecycleResponse(
                    lifecycleEnvelope(
                        requestID: command,
                        command: command,
                        lifecycle: lifecycle.rawValue,
                        generation: 7,
                        binding: binding,
                        configurationRevision: plan.expectedConfigurationRevision
                    ),
                    requestID: command,
                    command: command,
                    lifecycle: lifecycle,
                    binding: binding
                )
            )
        }

        let observedAt = "2026-08-10T00:00:00Z"
        let lastSeen = "2026-08-09T23:59:59.5Z"
        let connectionEpoch = stableVersion("discovery-connection-epoch")
        let offerVersion = stableVersion(
            "pending-folder-v1",
            "discovered-folder",
            "Discovered folder",
            plan.offeringDeviceID.rawValue,
            lastSeen,
            "false",
            "true"
        )
        let offer: [String: Any] = [
            "folderID": "discovered-folder",
            "offeringDeviceID": plan.offeringDeviceID.rawValue,
            "label": "Discovered folder",
            "lastSeen": lastSeen,
            "offerVersion": offerVersion,
            "receiveEncrypted": false,
            "remoteEncrypted": true,
            "connectionEpoch": connectionEpoch,
            "observedAt": observedAt,
        ]
        let batch: [String: Any] = [
            "offeringDeviceID": plan.offeringDeviceID.rawValue,
            "connectionEpoch": connectionEpoch,
            "observedAt": observedAt,
            "offers": [offer],
            "truncated": false,
        ]
        let receipt = try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
            discoveryCaptureEnvelope(
                requestID: "capture-discovery",
                binding: binding,
                batch: batch
            ),
            requestID: "capture-discovery",
            binding: binding,
            now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
        )
        XCTAssertEqual(receipt.offers.count, 1)
        XCTAssertEqual(receipt.offers[0].folderID.rawValue, "discovered-folder")
        XCTAssertEqual(receipt.offeringDeviceID, plan.offeringDeviceID)
        XCTAssertFalse(receipt.truncated)

        var empty = batch
        empty["offers"] = []
        XCTAssertNoThrow(
            try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                discoveryCaptureEnvelope(
                    requestID: "capture-empty",
                    binding: binding,
                    batch: empty
                ),
                requestID: "capture-empty",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )

        var rawConnection = batch
        rawConnection["connectionID"] = "raw-connection-must-never-cross-abi"
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                discoveryCaptureEnvelope(
                    requestID: "capture-raw",
                    binding: binding,
                    batch: rawConnection
                ),
                requestID: "capture-raw",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )

        var mismatchedOffer = offer
        mismatchedOffer["connectionEpoch"] = stableVersion("other-epoch")
        var mismatchedBatch = batch
        mismatchedBatch["offers"] = [mismatchedOffer]
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                discoveryCaptureEnvelope(
                    requestID: "capture-epoch",
                    binding: binding,
                    batch: mismatchedBatch
                ),
                requestID: "capture-epoch",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )

        var duplicates = batch
        duplicates["offers"] = [offer, offer]
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                discoveryCaptureEnvelope(
                    requestID: "capture-duplicates",
                    binding: binding,
                    batch: duplicates
                ),
                requestID: "capture-duplicates",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )

        var maliciousLabel = offer
        maliciousLabel["label"] = "evil\nlabel"
        var maliciousBatch = batch
        maliciousBatch["offers"] = [maliciousLabel]
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                discoveryCaptureEnvelope(
                    requestID: "capture-label",
                    binding: binding,
                    batch: maliciousBatch
                ),
                requestID: "capture-label",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )

        var oversized = batch
        oversized["offers"] = Array(repeating: offer, count: 513)
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                discoveryCaptureEnvelope(
                    requestID: "capture-oversized",
                    binding: binding,
                    batch: oversized
                ),
                requestID: "capture-oversized",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )

        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                discoveryCaptureEnvelope(
                    requestID: "capture-future",
                    binding: binding,
                    batch: batch
                ),
                requestID: "capture-future",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-09T23:59:58Z"))
            )
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                discoveryCaptureEnvelope(
                    requestID: "capture-stale",
                    binding: binding,
                    batch: batch
                ),
                requestID: "capture-stale",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:05:02Z"))
            )
        )
    }

    func testDiscoveryCapturePreservesOnlyStableOperationalErrors() throws {
        let binding = CoreExplicitSessionBinding.pendingFolderDiscovery(
            sessionID: UUID(),
            plan: try discoveryPlan()
        )
        for code in [
            "network_byte_limit_reached", "pending_folder_discovery_pending",
            "pending_folder_discovery_store_unavailable", "unsupported_command",
        ] {
            let response = try jsonString([
                "schemaVersion": 1,
                "requestID": "discovery-error",
                "kind": "command",
                "ok": false,
                "error": ["code": code, "message": "stable"],
            ])
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                    response,
                    requestID: "discovery-error",
                    binding: binding
                )
            ) { error in
                XCTAssertEqual(error as? CoreClientError, .coreRejected(code))
            }
        }

        let unknown = try jsonString([
            "schemaVersion": 1,
            "requestID": "discovery-error",
            "kind": "command",
            "ok": false,
            "error": ["code": "future_discovery_error", "message": "unknown"],
        ])
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderDiscoveryCaptureResponse(
                unknown,
                requestID: "discovery-error",
                binding: binding
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreClientError,
                .invalidResponse("discovery_capture_error")
            )
        }
    }

    func testPendingFolderOfferEvidenceIsStrictAndLegacyDefaultsFailClosed() throws {
        let folderID = try XCTUnwrap(FolderID(rawValue: "discovered-folder"))
        let deviceID = try discoveryPlan().offeringDeviceID
        let version = stableVersion("legacy-offer")
        let live = try PendingFolderOffer(
            folderID: folderID,
            label: "Discovered folder",
            offeringDeviceID: deviceID,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            offerVersion: version,
            receiveEncrypted: false,
            remoteEncrypted: false,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true,
            evidenceSource: .live,
            requiresNetworkRevalidation: false
        )
        XCTAssertEqual(live.evidenceSource, .live)
        XCTAssertFalse(live.requiresNetworkRevalidation)
        XCTAssertThrowsError(
            try PendingFolderOffer(
                folderID: folderID,
                label: "Discovered folder",
                offeringDeviceID: deviceID,
                lastSeen: live.lastSeen,
                offerVersion: version,
                receiveEncrypted: false,
                remoteEncrypted: false,
                requiresManagedLocalPath: true,
                requiresExplicitDeviceSelection: true,
                evidenceSource: .durableSummary,
                requiresNetworkRevalidation: false
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(live)) as? [String: Any]
        )
        legacy.removeValue(forKey: "evidenceSource")
        legacy.removeValue(forKey: "requiresNetworkRevalidation")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            PendingFolderOffer.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(decoded.evidenceSource, .durableSummary)
        XCTAssertTrue(decoded.requiresNetworkRevalidation)

        legacy["evidenceSource"] = "live"
        XCTAssertThrowsError(
            try decoder.decode(
                PendingFolderOffer.self,
                from: JSONSerialization.data(withJSONObject: legacy)
            )
        )
    }

    func testPendingFolderObservationBindingUsesExactOpenCaptureAndCloseShapes() throws {
        let plan = try observationPlan()
        let binding = CoreExplicitSessionBinding.pendingFolderObservation(
            sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            plan: plan
        )
        XCTAssertEqual(binding.mode, .pendingFolderObservation)
        XCTAssertEqual(binding.offeringDeviceID, plan.offeringDeviceID)

        let common: [String: Any] = [
            "schemaVersion": 1,
            "requestID": "request-1",
            "sessionID": binding.sessionIDString,
            "taskID": binding.taskIDString!,
            "planDigest": binding.planDigest!,
            "expectedConfigurationRevision": binding.expectedConfigurationRevision!,
            "maximumNetworkBytes": binding.maximumNetworkBytes!,
        ]
        for command in [
            "openPendingFolderObservationSession", "capturePendingFolderObservation",
        ] {
            var request = common
            request["command"] = command
            request["folderID"] = plan.folderID.rawValue
            request["offeringDeviceID"] = plan.offeringDeviceID.rawValue
            XCTAssertNoThrow(
                try CoreSessionBridgeContract.validateRequestBinding(
                    try jsonString(request),
                    binding: binding,
                    folder: .exact(plan.folderID)
                )
            )

            var missingCap = request
            missingCap.removeValue(forKey: "maximumNetworkBytes")
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.validateRequestBinding(
                    try jsonString(missingCap),
                    binding: binding,
                    folder: .exact(plan.folderID)
                )
            )

            var rawConnection = request
            rawConnection["connectionID"] = "must-never-cross-the-abi"
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.validateRequestBinding(
                    try jsonString(rawConnection),
                    binding: binding,
                    folder: .exact(plan.folderID)
                )
            )
        }

        var close = common
        close["command"] = "closeSession"
        XCTAssertNoThrow(
            try CoreSessionBridgeContract.validateRequestBinding(
                try jsonString(close),
                binding: binding,
                folder: .absent
            )
        )
        close["offeringDeviceID"] = plan.offeringDeviceID.rawValue
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateRequestBinding(
                try jsonString(close),
                binding: binding,
                folder: .absent
            )
        )
    }

    func testPendingFolderObservationLifecycleAndCaptureProofAreStrict() throws {
        let plan = try observationPlan()
        let binding = CoreExplicitSessionBinding.pendingFolderObservation(
            sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            plan: plan
        )
        for (command, lifecycle) in [
            ("openPendingFolderObservationSession", CoreExplicitSessionLifecycle.running),
            ("closeSession", CoreExplicitSessionLifecycle.stopped),
        ] {
            XCTAssertNoThrow(
                try CoreSessionBridgeContract.validateLifecycleResponse(
                    lifecycleEnvelope(
                        requestID: command,
                        command: command,
                        lifecycle: lifecycle.rawValue,
                        generation: 7,
                        binding: binding,
                        configurationRevision: plan.expectedConfigurationRevision
                    ),
                    requestID: command,
                    command: command,
                    lifecycle: lifecycle,
                    binding: binding
                )
            )
        }

        let observedAt = "2026-08-10T00:00:00Z"
        let expiresAt = "2026-08-10T00:05:00Z"
        let lastSeen = "2026-08-09T23:59:59.5Z"
        let offerVersion = stableVersion(
            "pending-folder-v1",
            plan.folderID.rawValue,
            "Observed folder",
            plan.offeringDeviceID.rawValue,
            lastSeen,
            "false",
            "false"
        )
        let connectionEpoch = stableVersion("test-connection-epoch", plan.offeringDeviceID.rawValue)
        let proofID = stableVersion(
            "pending-folder-observation-proof-v1",
            plan.folderID.rawValue,
            plan.offeringDeviceID.rawValue,
            offerVersion,
            "Observed folder",
            lastSeen,
            "false",
            "false",
            plan.expectedConfigurationRevision,
            binding.sessionIDString,
            connectionEpoch,
            observedAt,
            expiresAt
        )
        let proof: [String: Any] = [
            "proofID": proofID,
            "folderID": plan.folderID.rawValue,
            "offeringDeviceID": plan.offeringDeviceID.rawValue,
            "offerVersion": offerVersion,
            "label": "Observed folder",
            "lastSeen": lastSeen,
            "receiveEncrypted": false,
            "remoteEncrypted": false,
            "configurationRevision": plan.expectedConfigurationRevision,
            "observationSessionID": binding.sessionIDString,
            "connectionEpoch": connectionEpoch,
            "observedAt": observedAt,
            "expiresAt": expiresAt,
        ]
        let response = captureEnvelope(
            requestID: "capture-1",
            binding: binding,
            proof: proof
        )
        let receipt = try CoreSessionBridgeContract.validatePendingFolderObservationCaptureResponse(
            response,
            requestID: "capture-1",
            binding: binding,
            now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
        )
        XCTAssertEqual(receipt.proof.proofID, proofID)
        XCTAssertEqual(receipt.proof.folderID, plan.folderID)
        XCTAssertEqual(receipt.proof.offeringDeviceID, plan.offeringDeviceID)
        XCTAssertEqual(receipt.proof.expiresAt.timeIntervalSince(receipt.proof.observedAt), 300)

        var rawConnection = proof
        rawConnection["connectionID"] = "raw-connection-must-never-cross-abi"
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderObservationCaptureResponse(
                captureEnvelope(
                    requestID: "capture-raw",
                    binding: binding,
                    proof: rawConnection
                ),
                requestID: "capture-raw",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )

        var wrongTTL = proof
        wrongTTL["expiresAt"] = "2026-08-10T00:04:59Z"
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderObservationCaptureResponse(
                captureEnvelope(requestID: "capture-ttl", binding: binding, proof: wrongTTL),
                requestID: "capture-ttl",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )

        let duplicate = response.replacingOccurrences(
            of: "\"proofID\":\"\(proofID)\"",
            with: "\"proofID\":\"\(proofID)\",\"proofID\":\"\(proofID)\""
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderObservationCaptureResponse(
                duplicate,
                requestID: "capture-1",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )

        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderObservationCaptureResponse(
                response,
                requestID: "capture-1",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-09T23:59:58Z"))
            )
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderObservationCaptureResponse(
                response,
                requestID: "capture-1",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:05:02Z"))
            )
        )

        var invalidDigest = proof
        invalidDigest["connectionEpoch"] = String(repeating: "a", count: 64)
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderObservationCaptureResponse(
                captureEnvelope(
                    requestID: "capture-digest",
                    binding: binding,
                    proof: invalidDigest
                ),
                requestID: "capture-digest",
                binding: binding,
                now: try XCTUnwrap(canonicalDate("2026-08-10T00:00:01Z"))
            )
        )
    }

    func testObservationCapturePreservesOnlyStableOperationalErrors() throws {
        let binding = CoreExplicitSessionBinding.pendingFolderObservation(
            sessionID: UUID(),
            plan: try observationPlan()
        )
        for code in ["network_byte_limit_reached", "unsupported_command"] {
            let response = try jsonString([
                "schemaVersion": 1,
                "requestID": "capture-error",
                "kind": "command",
                "ok": false,
                "error": ["code": code, "message": "stable"],
            ])
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.validatePendingFolderObservationCaptureResponse(
                    response,
                    requestID: "capture-error",
                    binding: binding
                )
            ) { error in
                XCTAssertEqual(error as? CoreClientError, .coreRejected(code))
            }
        }

        let unknown = try jsonString([
            "schemaVersion": 1,
            "requestID": "capture-error",
            "kind": "command",
            "ok": false,
            "error": ["code": "future_observation_error", "message": "unknown"],
        ])
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validatePendingFolderObservationCaptureResponse(
                unknown,
                requestID: "capture-error",
                binding: binding
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreClientError,
                .invalidResponse("observation_capture_error")
            )
        }
    }

    func testProofBackedFolderDecisionAloneCarriesWireRevision() throws {
        let binding = CoreExplicitSessionBinding.configuration(sessionID: UUID())
        let revision = String(repeating: "a", count: 64)
        let proofID = stableVersion("proof")
        let offerVersion = stableVersion("offer")
        let deviceID = try XCTUnwrap(
            DeviceID(
                rawValue: "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
            )
        )
        for kind in [CoreCommandKind.acceptFolder, .ignorePendingFolder] {
            let command = CoreCommand(
                kind: kind,
                folderID: try XCTUnwrap(FolderID(rawValue: "offered-folder")),
                arguments: [
                    "offeringDeviceID": deviceID.rawValue,
                    "offerVersion": offerVersion,
                    "observationProofID": proofID,
                ],
                commandConfigurationRevision: revision,
                trigger: .user
            )
            XCTAssertEqual(
                try CoreSessionBridgeContract.commandConfigurationRevision(
                    for: command,
                    binding: binding
                ),
                revision
            )
        }

        for kind in [CoreCommandKind.acceptFolder, .ignorePendingFolder] {
            let legacy = CoreCommand(
                kind: kind,
                folderID: try XCTUnwrap(FolderID(rawValue: "offered-folder")),
                commandConfigurationRevision: revision,
                trigger: .user
            )
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.commandConfigurationRevision(
                    for: legacy,
                    binding: binding
                )
            ) { error in
                XCTAssertEqual(
                    error as? CoreClientError,
                    .coreRejected("network_observation_required")
                )
            }
        }
    }

    func testNetworkPlanRejectsNoncanonicalConfigurationRevision() throws {
        let taskID = UUID()
        let folderID = try XCTUnwrap(FolderID(rawValue: "folder-alpha"))
        let invalidRevisions = [
            "",
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ]

        for revision in invalidRevisions {
            XCTAssertThrowsError(
                try CoreNetworkSessionPlan(
                    taskID: taskID,
                    folderID: folderID,
                    expectedConfigurationRevision: revision,
                    maximumNetworkBytes: .unlimited
                )
            ) { error in
                XCTAssertEqual(
                    error as? CoreNetworkSessionPlanError,
                    .invalidConfigurationRevision
                )
            }
        }
    }

    func testNetworkByteLimitHasOnlyCanonicalWireForms() throws {
        XCTAssertEqual(CoreNetworkByteLimit.unlimited.wireValue, "unlimited")
        XCTAssertEqual(try CoreNetworkByteLimit(byteCount: 0).wireValue, "0")
        XCTAssertEqual(
            try CoreNetworkByteLimit(byteCount: Int64.max).wireValue,
            "9223372036854775807"
        )
        XCTAssertThrowsError(try CoreNetworkByteLimit(byteCount: -1)) { error in
            XCTAssertEqual(error as? CoreNetworkByteLimitError, .negativeByteCount)
        }
    }

    func testBindingContainsOnlyFieldsAllowedByItsMode() throws {
        let sessionID = try XCTUnwrap(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let configuration = CoreExplicitSessionBinding.configuration(sessionID: sessionID)
        XCTAssertEqual(configuration.mode, .configuration)
        XCTAssertNil(configuration.folderID)
        XCTAssertNil(configuration.taskID)
        XCTAssertNil(configuration.planDigest)
        XCTAssertNil(configuration.expectedConfigurationRevision)
        XCTAssertNil(configuration.maximumNetworkBytes)

        let plan = try CoreNetworkSessionPlan(
            taskID: UUID(),
            folderID: try XCTUnwrap(FolderID(rawValue: "folder-alpha")),
            expectedConfigurationRevision: String(repeating: "a", count: 64),
            maximumNetworkBytes: .unlimited
        )
        let network = CoreExplicitSessionBinding.network(sessionID: sessionID, plan: plan)
        XCTAssertEqual(network.mode, .network)
        XCTAssertEqual(network.folderID, plan.folderID)
        XCTAssertEqual(network.taskID, plan.taskID)
        XCTAssertEqual(network.planDigest, plan.planDigest)
        XCTAssertEqual(
            network.expectedConfigurationRevision,
            plan.expectedConfigurationRevision
        )
        XCTAssertEqual(network.maximumNetworkBytes, "unlimited")
        XCTAssertEqual(network.networkOperation, .sync)
    }

    func testCoreClientDefaultsDoNotPretendLegacyStartIsAnExplicitSession() async throws {
        let client = LegacyOnlyCoreClient()
        let root = URL(fileURLWithPath: "/private/tmp/core-session-default-test")

        do {
            _ = try await client.openConfigurationSession(
                configurationDirectory: root.appendingPathComponent("Config"),
                dataDirectory: root.appendingPathComponent("Data"),
                sessionID: UUID()
            )
            XCTFail("default explicit-session adapter unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? CoreClientError, .bridgeUnavailable)
        }

        do {
            _ = try await client.closeExplicitSession()
            XCTFail("default explicit-session close unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? CoreClientError, .bridgeUnavailable)
        }

        let observationPlan = try PendingFolderObservationPlan(
            taskID: UUID(),
            folderID: XCTUnwrap(FolderID(rawValue: "offered-folder")),
            offeringDeviceID: XCTUnwrap(
                DeviceID(
                    rawValue:
                        "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
                )
            ),
            expectedConfigurationRevision: String(repeating: "a", count: 64),
            maximumNetworkBytes: 0
        )
        do {
            _ = try await client.openPendingFolderObservationSession(
                configurationDirectory: root.appendingPathComponent("Config"),
                dataDirectory: root.appendingPathComponent("Data"),
                sessionID: UUID(),
                plan: observationPlan
            )
            XCTFail("default observation-session adapter unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? CoreClientError, .bridgeUnavailable)
        }
        do {
            _ = try await client.capturePendingFolderObservation()
            XCTFail("default observation capture unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? CoreClientError, .bridgeUnavailable)
        }

        let discoveryPlan = try PendingFolderDiscoveryPlan(
            taskID: UUID(),
            offeringDeviceID: observationPlan.offeringDeviceID,
            expectedConfigurationRevision: observationPlan.expectedConfigurationRevision,
            maximumNetworkBytes: 0
        )
        do {
            _ = try await client.openPendingFolderDiscoverySession(
                configurationDirectory: root.appendingPathComponent("Config"),
                dataDirectory: root.appendingPathComponent("Data"),
                sessionID: UUID(),
                plan: discoveryPlan
            )
            XCTFail("default discovery-session adapter unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? CoreClientError, .bridgeUnavailable)
        }
        do {
            _ = try await client.capturePendingFolderDiscovery()
            XCTFail("default discovery capture unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? CoreClientError, .bridgeUnavailable)
        }
    }

    func testLifecycleValidatorAcceptsExactNetworkOpenAndClosePayloads() throws {
        let sessionID = try XCTUnwrap(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let plan = try CoreNetworkSessionPlan(
            taskID: try XCTUnwrap(
                UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
            ),
            folderID: try XCTUnwrap(FolderID(rawValue: "folder-alpha")),
            expectedConfigurationRevision: String(repeating: "a", count: 64),
            maximumNetworkBytes: try CoreNetworkByteLimit(byteCount: 0)
        )
        let binding = CoreExplicitSessionBinding.network(sessionID: sessionID, plan: plan)

        for (command, lifecycle, generation) in [
            ("openNetworkSession", CoreExplicitSessionLifecycle.running, 4),
            ("closeSession", CoreExplicitSessionLifecycle.stopped, 5),
        ] {
            let response = lifecycleEnvelope(
                requestID: "request-\(generation)",
                command: command,
                lifecycle: lifecycle.rawValue,
                generation: generation,
                binding: binding,
                configurationRevision: plan.expectedConfigurationRevision
            )
            let validated = try CoreSessionBridgeContract.validateLifecycleResponse(
                response,
                requestID: "request-\(generation)",
                command: command,
                lifecycle: lifecycle,
                binding: binding
            )
            XCTAssertEqual(validated.generation, UInt64(generation))
            XCTAssertEqual(
                validated.configurationRevision,
                plan.expectedConfigurationRevision
            )
        }
    }

    func testEveryBoundQueryAndReadRequiresExactNetworkByteLimit() throws {
        let binding = CoreExplicitSessionBinding.network(
            sessionID: UUID(),
            plan: try CoreNetworkSessionPlan(
                taskID: UUID(),
                folderID: try XCTUnwrap(FolderID(rawValue: "folder-alpha")),
                expectedConfigurationRevision: String(repeating: "a", count: 64),
                maximumNetworkBytes: try CoreNetworkByteLimit(byteCount: 4_096)
            )
        )
        let base: [String: Any] = [
            "schemaVersion": 1,
            "requestID": "request-1",
            "sessionID": binding.sessionIDString,
            "taskID": binding.taskIDString!,
            "planDigest": binding.planDigest!,
            "expectedConfigurationRevision": binding.expectedConfigurationRevision!,
            "maximumNetworkBytes": binding.maximumNetworkBytes!,
            "networkOperation": binding.networkOperation!.rawValue,
            "folderID": binding.folderID!.rawValue,
        ]
        var requests: [[String: Any]] = []
        var items = base
        items.merge([
            "query": "items", "scope": "global", "limit": 200,
            "includeDeleted": true,
        ]) { _, new in new }
        requests.append(items)
        var events = base
        events.merge(["query": "events", "limit": 10]) { _, new in new }
        requests.append(events)
        var read = base
        read.merge([
            "itemID": "item-1", "path": "a.txt", "contentVersion": "AA==",
            "offset": 0, "length": 1,
        ]) { _, new in new }
        requests.append(read)

        for request in requests {
            let valid = try jsonString(request)
            XCTAssertNoThrow(
                try CoreSessionBridgeContract.validateRequestBinding(
                    valid,
                    binding: binding,
                    folder: .exact(binding.folderID!)
                )
            )

            var missing = request
            missing.removeValue(forKey: "maximumNetworkBytes")
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.validateRequestBinding(
                    try jsonString(missing),
                    binding: binding,
                    folder: .exact(binding.folderID!)
                )
            )

            var substituted = request
            substituted["maximumNetworkBytes"] = "4097"
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.validateRequestBinding(
                    try jsonString(substituted),
                    binding: binding,
                    folder: .exact(binding.folderID!)
                )
            )

            var missingOperation = request
            missingOperation.removeValue(forKey: "networkOperation")
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.validateRequestBinding(
                    try jsonString(missingOperation),
                    binding: binding,
                    folder: .exact(binding.folderID!)
                )
            )

            var substitutedOperation = request
            substitutedOperation["networkOperation"] = "upload"
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.validateRequestBinding(
                    try jsonString(substitutedOperation),
                    binding: binding,
                    folder: .exact(binding.folderID!)
                )
            )
        }
    }

    func testConfigurationRequestOmitsEveryNetworkBindingField() throws {
        let binding = CoreExplicitSessionBinding.configuration(sessionID: UUID())
        let request: [String: Any] = [
            "schemaVersion": 1,
            "requestID": "request-1",
            "command": "removeFolder",
            "sessionID": binding.sessionIDString,
            "folderID": "folder-alpha",
            "arguments": [:] as [String: String],
        ]
        XCTAssertNoThrow(
            try CoreSessionBridgeContract.validateRequestBinding(
                try jsonString(request),
                binding: binding,
                folder: .unconstrained
            )
        )
        for forbidden in [
            "taskID", "planDigest", "expectedConfigurationRevision",
            "maximumNetworkBytes",
        ] {
            var invalid = request
            invalid[forbidden] = "unexpected"
            XCTAssertThrowsError(
                try CoreSessionBridgeContract.validateRequestBinding(
                    try jsonString(invalid),
                    binding: binding,
                    folder: .unconstrained
                )
            )
        }
    }

    func testConfigurationCommandUsesOnlyDurableEnqueueRevision() throws {
        let binding = CoreExplicitSessionBinding.configuration(sessionID: UUID())
        let revision = String(repeating: "a", count: 64)
        let command = CoreCommand(
            kind: .removeFolder,
            folderID: try XCTUnwrap(FolderID(rawValue: "folder-alpha")),
            commandConfigurationRevision: revision,
            trigger: .user
        )
        XCTAssertEqual(
            try CoreSessionBridgeContract.commandConfigurationRevision(
                for: command,
                binding: binding
            ),
            revision
        )

        let request: [String: Any] = [
            "schemaVersion": 1,
            "requestID": command.id.uuidString.lowercased(),
            "command": command.kind.rawValue,
            "sessionID": binding.sessionIDString,
            "commandConfigurationRevision": revision,
            "folderID": command.folderID!.rawValue,
            "arguments": [:] as [String: String],
        ]
        XCTAssertNoThrow(
            try CoreSessionBridgeContract.validateRequestBinding(
                try jsonString(request),
                binding: binding,
                folder: .unconstrained,
                commandConfigurationRevision: revision
            )
        )

        var substituted = request
        substituted["commandConfigurationRevision"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateRequestBinding(
                try jsonString(substituted),
                binding: binding,
                folder: .unconstrained,
                commandConfigurationRevision: revision
            )
        )

        let missing = CoreCommand(
            kind: .removeFolder,
            folderID: command.folderID,
            trigger: .user
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.commandConfigurationRevision(
                for: missing,
                binding: binding
            )
        )

        let suppression = CoreCommand(
            kind: .ignorePendingFolder,
            commandConfigurationRevision: revision,
            trigger: .user
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.commandConfigurationRevision(
                for: suppression,
                binding: binding
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreClientError,
                .coreRejected("network_observation_required")
            )
        }

        let networkBinding = CoreExplicitSessionBinding.network(
            sessionID: UUID(),
            plan: try CoreNetworkSessionPlan(
                taskID: UUID(),
                folderID: command.folderID!,
                expectedConfigurationRevision: String(repeating: "c", count: 64),
                maximumNetworkBytes: .unlimited
            )
        )
        XCTAssertNil(
            try CoreSessionBridgeContract.commandConfigurationRevision(
                for: command,
                binding: networkBinding
            )
        )
    }

    func testNetworkBudgetTotalsPreserveStickyExhaustionSemantics() {
        let baseline = CoreNetworkTransferTotals(receivedBytes: 100, sentBytes: 200)
        let current = CoreNetworkTransferTotals(
            receivedBytes: 103,
            sentBytes: 204,
            budgetLimited: true,
            budgetLimitBytes: 10,
            budgetUsedBytes: 7,
            budgetExhausted: true
        )
        let delta = current.delta(since: baseline)
        XCTAssertEqual(delta?.receivedBytes, 3)
        XCTAssertEqual(delta?.sentBytes, 4)
        XCTAssertEqual(delta?.budgetUsedBytes, 7)
        XCTAssertTrue(delta?.budgetExhausted == true)
        XCTAssertTrue(
            delta?.matchesNetworkSessionBudget(maximumNetworkBytes: "10") == true
        )

        XCTAssertTrue(
            CoreNetworkTransferTotals(
                receivedBytes: 0,
                sentBytes: 0,
                budgetLimited: true,
                budgetLimitBytes: 0,
                budgetUsedBytes: 0,
                budgetExhausted: true
            ).matchesNetworkSessionBudget(maximumNetworkBytes: "0")
        )
        XCTAssertTrue(
            CoreNetworkTransferTotals(
                receivedBytes: 3,
                sentBytes: 4,
                budgetLimited: false,
                budgetLimitBytes: 0,
                budgetUsedBytes: 7,
                budgetExhausted: false
            ).matchesNetworkSessionBudget(maximumNetworkBytes: "unlimited")
        )
        XCTAssertFalse(
            CoreNetworkTransferTotals(
                receivedBytes: 3,
                sentBytes: 4,
                budgetLimited: false,
                budgetLimitBytes: 0,
                budgetUsedBytes: 7,
                budgetExhausted: true
            ).hasCoherentBudgetState
        )
    }

    func testNetworkByteLimitCodeSurvivesCommandFailureClassification() {
        let code = CoreBridgeFailureClassifier.validatedOperationalCode(
            "network_byte_limit_reached",
            responseKind: "command"
        )
        XCTAssertEqual(code, "network_byte_limit_reached")
        XCTAssertEqual(
            CoreBridgeFailureClassifier.failure(
                code: code!,
                mutationPhase: nil,
                mutationAmbiguous: nil,
                expectsMutationMetadata: false
            ) as? CoreClientError,
            .coreRejected("network_byte_limit_reached")
        )
    }

    func testNetworkByteLimitCodeSurvivesReadRangeButNotQueryClassification() {
        let code = CoreBridgeFailureClassifier.validatedOperationalCode(
            "network_byte_limit_reached",
            responseKind: "readRange"
        )
        XCTAssertEqual(code, "network_byte_limit_reached")
        XCTAssertEqual(
            CoreBridgeFailureClassifier.failure(
                code: code!,
                mutationPhase: nil,
                mutationAmbiguous: nil,
                expectsMutationMetadata: false
            ) as? CoreClientError,
            .coreRejected("network_byte_limit_reached")
        )
        XCTAssertNil(
            CoreBridgeFailureClassifier.validatedOperationalCode(
                "network_byte_limit_reached",
                responseKind: "query"
            )
        )
    }

    func testLifecycleValidatorRejectsScopeSubstitutionAndUnexpectedFields() throws {
        let sessionID = UUID()
        let plan = try CoreNetworkSessionPlan(
            taskID: UUID(),
            folderID: try XCTUnwrap(FolderID(rawValue: "folder-alpha")),
            expectedConfigurationRevision: String(repeating: "a", count: 64),
            maximumNetworkBytes: .unlimited
        )
        let binding = CoreExplicitSessionBinding.network(sessionID: sessionID, plan: plan)
        let valid = try XCTUnwrap(
            lifecycleEnvelope(
                requestID: "request-1",
                command: "openNetworkSession",
                lifecycle: "running",
                generation: 1,
                binding: binding,
                configurationRevision: plan.expectedConfigurationRevision
            ).data(using: .utf8)
        )
        var payload = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: valid) as? [String: Any])
        )
        var body = try XCTUnwrap(payload["payload"] as? [String: Any])
        body["folderID"] = "folder-substituted"
        payload["payload"] = body
        let substituted = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateLifecycleResponse(
                substituted,
                requestID: "request-1",
                command: "openNetworkSession",
                lifecycle: .running,
                binding: binding
            )
        )

        body["folderID"] = plan.folderID.rawValue
        body["maximumNetworkBytes"] = "00"
        payload["payload"] = body
        let budgetSubstituted = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateLifecycleResponse(
                budgetSubstituted,
                requestID: "request-1",
                command: "openNetworkSession",
                lifecycle: .running,
                binding: binding
            )
        )

        body["maximumNetworkBytes"] = plan.maximumNetworkBytes.wireValue
        body["untrustedFutureField"] = "must-not-be-ignored"
        payload["payload"] = body
        let unexpected = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateLifecycleResponse(
                unexpected,
                requestID: "request-1",
                command: "openNetworkSession",
                lifecycle: .running,
                binding: binding
            )
        )
    }

    func testLifecycleValidatorRejectsNetworkRevisionDrift() throws {
        let binding = CoreExplicitSessionBinding.network(
            sessionID: UUID(),
            plan: try CoreNetworkSessionPlan(
                taskID: UUID(),
                folderID: try XCTUnwrap(FolderID(rawValue: "folder-alpha")),
                expectedConfigurationRevision: String(repeating: "a", count: 64),
                maximumNetworkBytes: .unlimited
            )
        )
        let response = lifecycleEnvelope(
            requestID: "request-1",
            command: "openNetworkSession",
            lifecycle: "running",
            generation: 1,
            binding: binding,
            configurationRevision: String(repeating: "b", count: 64)
        )

        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateLifecycleResponse(
                response,
                requestID: "request-1",
                command: "openNetworkSession",
                lifecycle: .running,
                binding: binding
            )
        )
    }

    func testLifecycleValidatorRejectsDuplicateKeysBeforeSemanticDecoding() throws {
        let binding = CoreExplicitSessionBinding.configuration(sessionID: UUID())
        let revision = String(repeating: "a", count: 64)
        let response = """
            {"schemaVersion":1,"requestID":"request-1","kind":"command","ok":true,
             "payload":{"command":"openConfiguration","command":"closeSession",
                        "lifecycle":"running","generation":1,
                        "sessionID":"\(binding.sessionIDString)",
                        "sessionMode":"configuration","configurationRevision":"\(revision)"}}
            """

        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateLifecycleResponse(
                response,
                requestID: "request-1",
                command: "openConfiguration",
                lifecycle: .running,
                binding: binding
            )
        ) { error in
            XCTAssertEqual(error as? CoreClientError, .invalidResponse("session_envelope"))
        }
    }

    func testLifecycleValidatorDoesNotPromoteUnknownErrorCodeToStableAPI() throws {
        let binding = CoreExplicitSessionBinding.configuration(sessionID: UUID())
        let response = """
            {"schemaVersion":1,"requestID":"request-1","kind":"command","ok":false,
             "error":{"code":"plausible_but_unknown","message":"untrusted"}}
            """

        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateLifecycleResponse(
                response,
                requestID: "request-1",
                command: "openConfiguration",
                lifecycle: .running,
                binding: binding
            )
        ) { error in
            XCTAssertEqual(
                error as? CoreClientError,
                .invalidResponse("session_error_envelope")
            )
        }
    }

    func testConfigurationSnapshotDoesNotQueryAnyFolderIndex() throws {
        let folders = try ["alpha", "beta"].map { try XCTUnwrap(FolderID(rawValue: $0)) }
        let binding = CoreExplicitSessionBinding.configuration(sessionID: UUID())

        XCTAssertEqual(
            try CoreSessionSnapshotScope.itemFolderIDs(
                configuredFolderIDs: folders,
                binding: binding
            ),
            []
        )
        XCTAssertFalse(
            CoreSessionSnapshotScope.hasRuntimeStatus(folderID: folders[0], binding: binding)
        )
        XCTAssertFalse(
            CoreSessionSnapshotScope.hasRuntimeStatus(folderID: folders[1], binding: binding)
        )
    }

    func testMultiFolderNetworkSnapshotQueriesOnlyExactTarget() throws {
        let folders = try ["alpha", "beta", "gamma"].map {
            try XCTUnwrap(FolderID(rawValue: $0))
        }
        let plan = try CoreNetworkSessionPlan(
            taskID: UUID(),
            folderID: folders[1],
            expectedConfigurationRevision: String(repeating: "a", count: 64),
            maximumNetworkBytes: .unlimited
        )
        let binding = CoreExplicitSessionBinding.network(sessionID: UUID(), plan: plan)

        XCTAssertEqual(
            try CoreSessionSnapshotScope.itemFolderIDs(
                configuredFolderIDs: folders,
                binding: binding
            ),
            [folders[1]]
        )
        XCTAssertFalse(
            CoreSessionSnapshotScope.hasRuntimeStatus(folderID: folders[0], binding: binding)
        )
        XCTAssertTrue(
            CoreSessionSnapshotScope.hasRuntimeStatus(folderID: folders[1], binding: binding)
        )
        XCTAssertFalse(
            CoreSessionSnapshotScope.hasRuntimeStatus(folderID: folders[2], binding: binding)
        )
    }

    func testPendingFolderObservationSnapshotHasNoFolderIndexAuthority() throws {
        let folders = try ["alpha", "beta"].map {
            try XCTUnwrap(FolderID(rawValue: $0))
        }
        let binding = CoreExplicitSessionBinding.pendingFolderObservation(
            sessionID: UUID(),
            plan: try observationPlan()
        )
        XCTAssertEqual(
            try CoreSessionSnapshotScope.itemFolderIDs(
                configuredFolderIDs: folders,
                binding: binding
            ),
            []
        )
        XCTAssertFalse(
            CoreSessionSnapshotScope.hasRuntimeStatus(
                folderID: folders[0],
                binding: binding
            )
        )

        let localDeviceID = try XCTUnwrap(
            DeviceID(
                rawValue: "IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN-OOOOOOO-PPPPPPP"
            )
        )
        XCTAssertNoThrow(
            try CoreSessionBridgeContract.validateSnapshotResponse(
                snapshotEnvelope(
                    requestID: "observation-snapshot",
                    deviceID: localDeviceID,
                    revision: binding.expectedConfigurationRevision!,
                    binding: binding,
                    folderIDs: []
                ),
                requestID: "observation-snapshot",
                binding: binding,
                expectedDeviceID: localDeviceID
            )
        )
    }

    func testPendingFolderDiscoverySnapshotHasNoFolderIndexAuthority() throws {
        let folders = try ["alpha", "beta"].map {
            try XCTUnwrap(FolderID(rawValue: $0))
        }
        let binding = CoreExplicitSessionBinding.pendingFolderDiscovery(
            sessionID: UUID(),
            plan: try discoveryPlan()
        )
        XCTAssertEqual(
            try CoreSessionSnapshotScope.itemFolderIDs(
                configuredFolderIDs: folders,
                binding: binding
            ),
            []
        )
        XCTAssertFalse(
            CoreSessionSnapshotScope.hasRuntimeStatus(
                folderID: folders[0],
                binding: binding
            )
        )

        let localDeviceID = try XCTUnwrap(
            DeviceID(
                rawValue: "IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN-OOOOOOO-PPPPPPP"
            )
        )
        XCTAssertNoThrow(
            try CoreSessionBridgeContract.validateSnapshotResponse(
                snapshotEnvelope(
                    requestID: "discovery-snapshot",
                    deviceID: localDeviceID,
                    revision: binding.expectedConfigurationRevision!,
                    binding: binding,
                    folderIDs: []
                ),
                requestID: "discovery-snapshot",
                binding: binding,
                expectedDeviceID: localDeviceID
            )
        )
    }

    func testSnapshotValidatorAcceptsConfigurationAndMultiFolderNetworkScopes() throws {
        let deviceID = try XCTUnwrap(
            DeviceID(
                rawValue: "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
            )
        )
        let revision = String(repeating: "a", count: 64)
        let configuration = CoreExplicitSessionBinding.configuration(sessionID: UUID())
        try CoreSessionBridgeContract.validateSnapshotResponse(
            snapshotEnvelope(
                requestID: "config-snapshot",
                deviceID: deviceID,
                revision: revision,
                binding: configuration,
                folderIDs: ["alpha", "beta"]
            ),
            requestID: "config-snapshot",
            binding: configuration,
            expectedDeviceID: deviceID
        )

        let network = CoreExplicitSessionBinding.network(
            sessionID: UUID(),
            plan: try CoreNetworkSessionPlan(
                taskID: UUID(),
                folderID: try XCTUnwrap(FolderID(rawValue: "beta")),
                expectedConfigurationRevision: revision,
                maximumNetworkBytes: .unlimited
            )
        )
        try CoreSessionBridgeContract.validateSnapshotResponse(
            snapshotEnvelope(
                requestID: "network-snapshot",
                deviceID: deviceID,
                revision: revision,
                binding: network,
                folderIDs: ["alpha", "beta", "gamma"]
            ),
            requestID: "network-snapshot",
            binding: network,
            expectedDeviceID: deviceID
        )
    }

    func testSnapshotValidatorRejectsDuplicateSessionFields() throws {
        let deviceID = try XCTUnwrap(
            DeviceID(
                rawValue: "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
            )
        )
        let binding = CoreExplicitSessionBinding.configuration(sessionID: UUID())
        let response = """
            {"schemaVersion":1,"requestID":"snapshot-1","kind":"snapshot","ok":true,
             "payload":{"deviceID":"\(deviceID.rawValue)","lifecycle":"running",
                        "running":true,"generation":1,
                        "configurationRevision":"\(String(repeating: "a", count: 64))",
                        "session":{"sessionID":"\(binding.sessionIDString)",
                                   "sessionID":"substituted","mode":"configuration"}}}
            """

        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateSnapshotResponse(
                response,
                requestID: "snapshot-1",
                binding: binding,
                expectedDeviceID: deviceID
            )
        )
    }

    func testLegacySnapshotMayOmitNewExplicitSessionFields() throws {
        let deviceID = try XCTUnwrap(
            DeviceID(
                rawValue: "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
            )
        )
        let response = """
            {"schemaVersion":1,"requestID":"legacy-snapshot","kind":"snapshot","ok":true,
             "payload":{"deviceID":"\(deviceID.rawValue)","lifecycle":"running",
                        "running":true,"generation":1}}
            """

        XCTAssertNoThrow(
            try CoreSessionBridgeContract.validateSnapshotResponse(
                response,
                requestID: "legacy-snapshot",
                binding: nil,
                expectedDeviceID: deviceID
            )
        )
    }

    func testCandidateDeviceIdentityRejectsInvalidAndChangedValues() throws {
        let original = try XCTUnwrap(
            DeviceID(
                rawValue: "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
            )
        )
        let changed = try XCTUnwrap(
            DeviceID(
                rawValue: "IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN-OOOOOOO-PPPPPPP"
            )
        )

        XCTAssertEqual(
            try CoreSessionBridgeContract.validateCandidateDeviceID(
                original.rawValue,
                expected: original
            ),
            original
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateCandidateDeviceID(
                "not-a-device-id",
                expected: original
            )
        )
        XCTAssertThrowsError(
            try CoreSessionBridgeContract.validateCandidateDeviceID(
                changed.rawValue,
                expected: original
            )
        )
    }

    func testSnapshotConfigurationRevisionRoundTripsAndLegacyDecodesNil() throws {
        let revision = String(repeating: "a", count: 64)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoded = try encoder.encode(
            CoreSnapshot(generation: 7, configurationRevision: revision)
        )
        XCTAssertEqual(
            try decoder.decode(CoreSnapshot.self, from: encoded).configurationRevision,
            revision
        )

        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacy.removeValue(forKey: "configurationRevision")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(
            try decoder.decode(CoreSnapshot.self, from: legacyData).configurationRevision
        )
    }

    func testSnapshotRejectsInvalidPersistedConfigurationRevision() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let valid = try encoder.encode(
            CoreSnapshot(
                generation: 1,
                configurationRevision: String(repeating: "a", count: 64)
            )
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["configurationRevision"] = "not-a-revision"
        let invalid = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(try decoder.decode(CoreSnapshot.self, from: invalid))
    }

    func testSnapshotStoreRejectsInvalidRevisionBeforeReplacingGoodState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-revision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedSnapshotStore(snapshotURL: root.appendingPathComponent("snapshot.json"))
        let validRevision = String(repeating: "a", count: 64)
        try store.write(
            CoreSnapshot(generation: 1, configurationRevision: validRevision)
        )

        XCTAssertThrowsError(
            try store.write(
                CoreSnapshot(generation: 2, configurationRevision: "not-a-revision")
            )
        ) { error in
            guard case SharedSnapshotError.invalidConfigurationRevision = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let persisted = try XCTUnwrap(store.read())
        XCTAssertEqual(persisted.generation, 1)
        XCTAssertEqual(persisted.configurationRevision, validRevision)
    }

    private func lifecycleEnvelope(
        requestID: String,
        command: String,
        lifecycle: String,
        generation: Int,
        binding: CoreExplicitSessionBinding,
        configurationRevision: String
    ) -> String {
        var payload: [String: Any] = [
            "command": command,
            "lifecycle": lifecycle,
            "generation": generation,
            "sessionID": binding.sessionIDString,
            "sessionMode": binding.mode.rawValue,
            "configurationRevision": configurationRevision,
        ]
        if binding.mode != .configuration {
            if binding.mode != .pendingFolderDiscovery {
                payload["folderID"] = binding.folderID?.rawValue
            }
            if binding.mode == .pendingFolderObservation
                || binding.mode == .pendingFolderDiscovery
            {
                payload["offeringDeviceID"] = binding.offeringDeviceID?.rawValue
            }
            payload["taskID"] = binding.taskIDString
            payload["planDigest"] = binding.planDigest
            payload["expectedConfigurationRevision"] = binding.expectedConfigurationRevision
            payload["maximumNetworkBytes"] = binding.maximumNetworkBytes
            if binding.mode == .network {
                payload["networkOperation"] = binding.networkOperation?.rawValue
            }
        }
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "requestID": requestID,
            "kind": "command",
            "ok": true,
            "payload": payload,
        ]
        let data = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func observationPlan() throws -> PendingFolderObservationPlan {
        try PendingFolderObservationPlan(
            taskID: XCTUnwrap(
                UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
            ),
            folderID: XCTUnwrap(FolderID(rawValue: "offered-folder")),
            offeringDeviceID: XCTUnwrap(
                DeviceID(
                    rawValue:
                        "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
                )
            ),
            expectedConfigurationRevision: String(repeating: "a", count: 64),
            maximumNetworkBytes: 8_388_608
        )
    }

    private func discoveryPlan(
        maximumNetworkBytes: Int64 = 8_388_608
    ) throws -> PendingFolderDiscoveryPlan {
        try PendingFolderDiscoveryPlan(
            taskID: XCTUnwrap(
                UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
            ),
            offeringDeviceID: XCTUnwrap(
                DeviceID(
                    rawValue:
                        "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
                )
            ),
            expectedConfigurationRevision: String(repeating: "a", count: 64),
            maximumNetworkBytes: maximumNetworkBytes
        )
    }

    private func captureEnvelope(
        requestID: String,
        binding: CoreExplicitSessionBinding,
        proof: [String: Any]
    ) -> String {
        var payload: [String: Any] = [
            "command": "capturePendingFolderObservation",
            "lifecycle": "running",
            "generation": 8,
            "configurationRevision": binding.expectedConfigurationRevision!,
            "sessionID": binding.sessionIDString,
            "sessionMode": binding.mode.rawValue,
            "folderID": binding.folderID!.rawValue,
            "offeringDeviceID": binding.offeringDeviceID!.rawValue,
            "taskID": binding.taskIDString!,
            "planDigest": binding.planDigest!,
            "expectedConfigurationRevision": binding.expectedConfigurationRevision!,
            "maximumNetworkBytes": binding.maximumNetworkBytes!,
            "pendingFolderObservation": proof,
        ]
        payload["configurationRevision"] = binding.expectedConfigurationRevision!
        return try! jsonString([
            "schemaVersion": 1,
            "requestID": requestID,
            "kind": "command",
            "ok": true,
            "payload": payload,
        ])
    }

    private func discoveryCaptureEnvelope(
        requestID: String,
        binding: CoreExplicitSessionBinding,
        batch: [String: Any]
    ) -> String {
        let payload: [String: Any] = [
            "command": "capturePendingFolderDiscovery",
            "lifecycle": "running",
            "generation": 8,
            "configurationRevision": binding.expectedConfigurationRevision!,
            "sessionID": binding.sessionIDString,
            "sessionMode": binding.mode.rawValue,
            "offeringDeviceID": binding.offeringDeviceID!.rawValue,
            "taskID": binding.taskIDString!,
            "planDigest": binding.planDigest!,
            "expectedConfigurationRevision": binding.expectedConfigurationRevision!,
            "maximumNetworkBytes": binding.maximumNetworkBytes!,
            "pendingFolderDiscovery": batch,
        ]
        return try! jsonString([
            "schemaVersion": 1,
            "requestID": requestID,
            "kind": "command",
            "ok": true,
            "payload": payload,
        ])
    }

    private func stableVersion(_ parts: String...) -> String {
        var material = Data()
        for part in parts {
            material.append(contentsOf: part.utf8)
            material.append(0)
        }
        return Data(SHA256.hash(data: material)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func canonicalDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func snapshotEnvelope(
        requestID: String,
        deviceID: DeviceID,
        revision: String,
        binding: CoreExplicitSessionBinding,
        folderIDs: [String]
    ) -> String {
        var session: [String: Any] = [
            "sessionID": binding.sessionIDString,
            "mode": binding.mode.rawValue,
        ]
        if binding.mode != .configuration {
            if binding.mode != .pendingFolderDiscovery {
                session["folderID"] = binding.folderID?.rawValue
            }
            if binding.mode == .pendingFolderObservation
                || binding.mode == .pendingFolderDiscovery
            {
                session["offeringDeviceID"] = binding.offeringDeviceID?.rawValue
            }
            session["taskID"] = binding.taskIDString
            session["planDigest"] = binding.planDigest
            session["expectedConfigurationRevision"] = binding.expectedConfigurationRevision
            session["maximumNetworkBytes"] = binding.maximumNetworkBytes
            if binding.mode == .network {
                session["networkOperation"] = binding.networkOperation?.rawValue
            }
        }
        let payload: [String: Any] = [
            "deviceID": deviceID.rawValue,
            "lifecycle": "running",
            "running": true,
            "generation": 1,
            "configurationRevision": revision,
            "session": session,
            "folders": folderIDs.map { ["folderID": $0] },
        ]
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "requestID": requestID,
            "kind": "snapshot",
            "ok": true,
            "payload": payload,
        ]
        let data = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}

private actor LegacyOnlyCoreClient: CoreClient {
    func start(configurationDirectory: URL, dataDirectory: URL) async throws -> DeviceID {
        guard
            let deviceID = DeviceID(
                rawValue: "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
            )
        else {
            throw CoreClientError.invalidResponse("test_device_id")
        }
        return deviceID
    }

    func stop() async throws {}

    func snapshot() async throws -> CoreSnapshot {
        throw CoreClientError.bridgeUnavailable
    }

    func execute(_ command: CoreCommand) async throws {}
}
