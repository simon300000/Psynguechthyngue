import Foundation
import XCTest

@testable import PsyCore

final class PendingFolderObservationCommandTests: XCTestCase {
    private let revision = String(repeating: "a", count: 64)
    private let now = Date.now

    func testProofMatchesEveryReviewedOfferFieldExactly() throws {
        let offer = try makeOffer()
        let proof = makeProof(for: offer)

        XCTAssertTrue(proof.exactlyMatchesReviewedOffer(offer))
        XCTAssertTrue(
            makeProof(
                for: offer,
                lastSeen: Date(
                    timeIntervalSince1970: offer.lastSeen.timeIntervalSince1970.rounded(.down)
                        + 0.999
                )
            ).exactlyMatchesReviewedOffer(offer)
        )
        for mismatchedProof in [
            makeProof(for: offer, folderID: try folderID("other-folder")),
            makeProof(for: offer, offeringDeviceID: try deviceID("C")),
            makeProof(for: offer, offerVersion: stableVersion(2)),
            makeProof(for: offer, label: "Changed label"),
            makeProof(for: offer, lastSeen: offer.lastSeen.addingTimeInterval(1)),
            makeProof(for: offer, receiveEncrypted: true),
            makeProof(for: offer, remoteEncrypted: true),
        ] {
            XCTAssertFalse(mismatchedProof.exactlyMatchesReviewedOffer(offer))
        }
    }

    func testAcceptAndIgnoreWireAreProofBackedAndExcludeAdvertisedInputs() throws {
        let offer = try makeOffer()
        let proof = makeProof(for: offer)
        let accept = try PendingAcceptanceCommandBuilder.folder(
            offer: offer,
            observationProof: proof,
            label: "Local label",
            managedPath: "/private/tmp/AppGroup/ManagedFolders/Folders/folder-local",
            type: .sendReceive,
            paused: false,
            deviceIDs: [offer.offeringDeviceID],
            rescanIntervalS: 3600
        )

        XCTAssertEqual(accept.arguments["observationProofID"], proof.proofID)
        XCTAssertEqual(accept.arguments["offeringDeviceID"], offer.offeringDeviceID.rawValue)
        XCTAssertEqual(accept.arguments["offerVersion"], offer.offerVersion)
        XCTAssertNil(accept.arguments["advertisedPath"])
        XCTAssertNil(accept.arguments["address"])
        XCTAssertNil(accept.arguments["receiveEncrypted"])
        XCTAssertNil(accept.arguments["remoteEncrypted"])

        let encryptedOffer = try makeOffer(receiveEncrypted: true, remoteEncrypted: false)
        let encryptedProof = makeProof(for: encryptedOffer)
        let encryptedAccept = try PendingAcceptanceCommandBuilder.folder(
            offer: encryptedOffer,
            observationProof: encryptedProof,
            label: "Encrypted local copy",
            managedPath: "/private/tmp/managed-encrypted",
            type: .receiveEncrypted,
            paused: false,
            deviceIDs: [encryptedOffer.offeringDeviceID],
            rescanIntervalS: 86_400
        )
        XCTAssertEqual(encryptedAccept.arguments["type"], FolderType.receiveEncrypted.rawValue)
        XCTAssertEqual(encryptedAccept.arguments["rescanIntervalS"], "86400")
        XCTAssertNil(encryptedAccept.arguments["encryptionPassword"])

        XCTAssertThrowsError(
            try PendingAcceptanceCommandBuilder.folder(
                offer: encryptedOffer,
                observationProof: encryptedProof,
                label: "Too many peers",
                managedPath: "/private/tmp/managed-encrypted",
                type: .receiveEncrypted,
                paused: false,
                deviceIDs: [encryptedOffer.offeringDeviceID, deviceID("C")],
                rescanIntervalS: 86_400
            )
        ) { error in
            XCTAssertEqual(error as? PendingAcceptanceCommandError, .invalidDeviceSelection)
        }

        XCTAssertThrowsError(
            try PendingAcceptanceCommandBuilder.folder(
                offer: encryptedOffer,
                observationProof: encryptedProof,
                label: "Wrong type",
                managedPath: "/private/tmp/managed-encrypted",
                type: .sendReceive,
                paused: false,
                deviceIDs: [encryptedOffer.offeringDeviceID],
                rescanIntervalS: 86_400
            )
        ) { error in
            XCTAssertEqual(error as? PendingAcceptanceCommandError, .encryptedFolderTypeMismatch)
        }
        XCTAssertThrowsError(
            try PendingAcceptanceCommandBuilder.folder(
                offer: encryptedOffer,
                observationProof: encryptedProof,
                label: "Too frequent",
                managedPath: "/private/tmp/managed-encrypted",
                type: .receiveEncrypted,
                paused: false,
                deviceIDs: [encryptedOffer.offeringDeviceID],
                rescanIntervalS: 3_600
            )
        ) { error in
            XCTAssertEqual(error as? PendingAcceptanceCommandError, .invalidRescanInterval)
        }
        let invalidEncryptedOffer = try makeOffer(receiveEncrypted: true, remoteEncrypted: true)
        XCTAssertThrowsError(
            try PendingAcceptanceCommandBuilder.folder(
                offer: invalidEncryptedOffer,
                observationProof: makeProof(for: invalidEncryptedOffer),
                label: "Invalid encrypted contract",
                managedPath: "/private/tmp/managed-encrypted",
                type: .receiveEncrypted,
                paused: false,
                deviceIDs: [invalidEncryptedOffer.offeringDeviceID],
                rescanIntervalS: 86_400
            )
        ) { error in
            XCTAssertEqual(error as? PendingAcceptanceCommandError, .invalidEncryptedFolderOffer)
        }
        XCTAssertThrowsError(
            try PendingAcceptanceCommandBuilder.folder(
                offer: offer,
                observationProof: proof,
                label: "Plain offer",
                managedPath: "/private/tmp/managed",
                type: .receiveEncrypted,
                paused: false,
                deviceIDs: [offer.offeringDeviceID],
                rescanIntervalS: 86_400
            )
        ) { error in
            XCTAssertEqual(error as? PendingAcceptanceCommandError, .encryptedFolderTypeMismatch)
        }

        let ignore = try PendingSuppressionCommandBuilder.ignoreFolder(
            encryptedOffer,
            observationProof: encryptedProof
        )
        XCTAssertEqual(
            ignore.arguments,
            [
                "observationProofID": encryptedProof.proofID,
                "offeringDeviceID": encryptedOffer.offeringDeviceID.rawValue,
                "offerVersion": encryptedOffer.offerVersion,
            ]
        )
    }

    func testBuildersRejectMismatchedAndExpiredProofs() throws {
        let offer = try makeOffer()
        let mismatched = makeProof(for: offer, label: "Changed label")
        XCTAssertThrowsError(
            try PendingSuppressionCommandBuilder.ignoreFolder(
                offer,
                observationProof: mismatched
            )
        ) { error in
            XCTAssertEqual(
                error as? PendingAcceptanceCommandError,
                .observationProofMismatch
            )
        }

        let expired = makeProof(for: offer, expiresAt: now)
        XCTAssertThrowsError(
            try PendingSuppressionCommandBuilder.ignoreFolder(
                offer,
                observationProof: expired
            )
        ) { error in
            XCTAssertEqual(
                error as? PendingAcceptanceCommandError,
                .observationProofExpired
            )
        }
    }

    func testProducerAtomicallyEnqueuesExactProofRevisionForCrashRecovery() throws {
        let fixture = try Fixture(revision: revision)
        defer { fixture.cleanup() }
        let offer = try makeOffer()
        let proof = makeProof(for: offer)
        let configuration = try PendingSuppressionCommandBuilder.ignoreFolder(
            offer,
            observationProof: proof
        )
        let commandID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

        let command = try ScopedCoreCommandProducer(paths: fixture.paths)
            .enqueueProofBackedPendingFolderCommand(
                invocationID: commandID,
                configuration: configuration,
                observationProof: proof,
                expectedConfigurationRevision: proof.configurationRevision,
                trigger: .user,
                createdAt: now
            )

        XCTAssertEqual(command.commandConfigurationRevision, revision)
        XCTAssertEqual(command.arguments, configuration.arguments)
        let recovered = try XCTUnwrap(
            CoreCommandQueue(root: fixture.paths.commandQueue).pending().first
        )
        XCTAssertEqual(recovered.id, command.id)
        XCTAssertEqual(recovered.kind, command.kind)
        XCTAssertEqual(recovered.folderID, command.folderID)
        XCTAssertEqual(recovered.arguments, command.arguments)
        XCTAssertEqual(
            recovered.commandConfigurationRevision,
            command.commandConfigurationRevision
        )
    }

    func testRevisionDriftAndUnexpectedWireFieldsEnqueueNothing() throws {
        let driftedRevision = String(repeating: "b", count: 64)
        let fixture = try Fixture(revision: driftedRevision)
        defer { fixture.cleanup() }
        let offer = try makeOffer()
        let proof = makeProof(for: offer)
        let valid = try PendingSuppressionCommandBuilder.ignoreFolder(
            offer,
            observationProof: proof
        )
        let producer = ScopedCoreCommandProducer(paths: fixture.paths)

        XCTAssertThrowsError(
            try producer.enqueueProofBackedPendingFolderCommand(
                configuration: valid,
                observationProof: proof,
                expectedConfigurationRevision: revision,
                trigger: .user
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .configurationRevisionMismatch(
                    expected: self.revision,
                    actual: driftedRevision
                )
            )
        }
        XCTAssertEqual(try CoreCommandQueue(root: fixture.paths.commandQueue).pending(), [])

        let wrongScopeProof = makeProof(
            for: offer,
            folderID: try folderID("wrong-scope")
        )
        XCTAssertThrowsError(
            try producer.enqueueProofBackedPendingFolderCommand(
                configuration: valid,
                observationProof: wrongScopeProof,
                expectedConfigurationRevision: revision,
                trigger: .user
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .invalidProofBackedPendingFolderCommand
            )
        }
        XCTAssertEqual(try CoreCommandQueue(root: fixture.paths.commandQueue).pending(), [])

        var unexpectedArguments = valid.arguments
        unexpectedArguments["address"] = "tcp://untrusted.example:22000"
        let unexpected = PendingAcceptanceCommandConfiguration(
            kind: valid.kind,
            folderID: valid.folderID,
            itemID: valid.itemID,
            arguments: unexpectedArguments
        )
        XCTAssertThrowsError(
            try producer.enqueueProofBackedPendingFolderCommand(
                configuration: unexpected,
                observationProof: proof,
                expectedConfigurationRevision: driftedRevision,
                trigger: .user
            )
        ) { error in
            XCTAssertEqual(
                error as? ScopedCoreCommandProducerError,
                .invalidProofBackedPendingFolderCommand
            )
        }
        XCTAssertEqual(try CoreCommandQueue(root: fixture.paths.commandQueue).pending(), [])

        let exactFixture = try Fixture(revision: revision)
        defer { exactFixture.cleanup() }
        let encryptedOffer = try makeOffer(receiveEncrypted: true)
        let encryptedProof = makeProof(for: encryptedOffer)
        let encryptedConfiguration = try PendingAcceptanceCommandBuilder.folder(
            offer: encryptedOffer,
            observationProof: encryptedProof,
            label: "Encrypted local copy",
            managedPath: "/private/tmp/managed-encrypted",
            type: .receiveEncrypted,
            paused: false,
            deviceIDs: [encryptedOffer.offeringDeviceID],
            rescanIntervalS: 86_400
        )
        let extraDeviceIDs = try XCTUnwrap(
            String(
                data: JSONEncoder().encode(
                    [encryptedOffer.offeringDeviceID.rawValue, try deviceID("C").rawValue]
                ),
                encoding: .utf8
            )
        )
        let invalidEncryptedArguments: [[String: String]] = [
            encryptedConfiguration.arguments.merging(["type": FolderType.sendReceive.rawValue]) {
                _, replacement in replacement
            },
            encryptedConfiguration.arguments.merging(["rescanIntervalS": "3600"]) {
                _, replacement in replacement
            },
            encryptedConfiguration.arguments.merging(["deviceIDs": extraDeviceIDs]) {
                _, replacement in replacement
            },
        ]
        let exactProducer = ScopedCoreCommandProducer(paths: exactFixture.paths)
        for arguments in invalidEncryptedArguments {
            let invalidConfiguration = PendingAcceptanceCommandConfiguration(
                kind: .acceptFolder,
                folderID: encryptedOffer.folderID,
                itemID: nil,
                arguments: arguments
            )
            XCTAssertThrowsError(
                try exactProducer.enqueueProofBackedPendingFolderCommand(
                    configuration: invalidConfiguration,
                    observationProof: encryptedProof,
                    expectedConfigurationRevision: revision,
                    trigger: .user
                )
            ) { error in
                XCTAssertEqual(
                    error as? ScopedCoreCommandProducerError,
                    .invalidProofBackedPendingFolderCommand
                )
            }
        }
        XCTAssertEqual(
            try CoreCommandQueue(root: exactFixture.paths.commandQueue).pending(),
            []
        )
    }

    #if os(macOS)
        func testAppFlowRequiresObservationAndFinalSnapshotConfirmation() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appModel = try applicationModelSource(root: repositoryRoot)
            let foldersView = try String(
                contentsOf: repositoryRoot.appendingPathComponent("App/FoldersView.swift"),
                encoding: .utf8
            )

            for required in [
                "observePendingFolderOffer(",
                "exactlyMatchesReviewedOffer",
                "enqueueProofBackedPendingFolderCommand",
                "snapshot.folders.contains(where: { $0.id == offer.folderID })",
                "snapshot.confirmsSuppression(of: offer)",
            ] {
                XCTAssertTrue(appModel.contains(required), "Missing App flow fence: \(required)")
            }
            XCTAssertTrue(foldersView.contains("Revalidating this offer with the offering device"))
            XCTAssertTrue(foldersView.contains("No acceptance or ignore request is queued"))
            XCTAssertTrue(foldersView.contains("up to five minutes"))
            XCTAssertTrue(foldersView.contains("The durable ignore record retains only"))
            XCTAssertTrue(foldersView.contains("Remote paths and addresses are never retained or accepted"))
            XCTAssertTrue(foldersView.contains("local folder type is fixed to Receive Encrypted"))
            XCTAssertTrue(foldersView.contains("offer.hasInvalidEncryptionContract"))
            XCTAssertTrue(foldersView.contains("offer.advertisesEncryption"))
            XCTAssertFalse(appModel.contains("encryptionPassword"))
        }
    #endif

    private func makeOffer(
        receiveEncrypted: Bool = false,
        remoteEncrypted: Bool = false
    ) throws -> PendingFolderOffer {
        try PendingFolderOffer(
            folderID: folderID("reviewed-folder"),
            label: "Reviewed label",
            offeringDeviceID: deviceID("B"),
            lastSeen: now.addingTimeInterval(-10),
            offerVersion: stableVersion(1),
            receiveEncrypted: receiveEncrypted,
            remoteEncrypted: remoteEncrypted,
            requiresManagedLocalPath: true,
            requiresExplicitDeviceSelection: true
        )
    }

    private func makeProof(
        for offer: PendingFolderOffer,
        folderID: FolderID? = nil,
        offeringDeviceID: DeviceID? = nil,
        offerVersion: String? = nil,
        label: String? = nil,
        lastSeen: Date? = nil,
        receiveEncrypted: Bool? = nil,
        remoteEncrypted: Bool? = nil,
        expiresAt: Date? = nil
    ) -> PendingFolderObservationProof {
        PendingFolderObservationProof(
            proofID: stableVersion(90),
            folderID: folderID ?? offer.folderID,
            offeringDeviceID: offeringDeviceID ?? offer.offeringDeviceID,
            offerVersion: offerVersion ?? offer.offerVersion,
            label: label ?? offer.label,
            lastSeen: lastSeen ?? offer.lastSeen,
            lastSeenWireValue: "2023-11-14T22:13:10Z",
            receiveEncrypted: receiveEncrypted ?? offer.receiveEncrypted,
            remoteEncrypted: remoteEncrypted ?? offer.remoteEncrypted,
            configurationRevision: revision,
            observationSessionID: "10000000-0000-0000-0000-000000000001",
            connectionEpoch: stableVersion(91),
            observedAt: now,
            observedAtWireValue: "2023-11-14T22:13:20Z",
            expiresAt: expiresAt ?? now.addingTimeInterval(PendingFolderObservationProof.timeToLive),
            expiresAtWireValue: "2023-11-14T22:18:20Z"
        )
    }

    private func stableVersion(_ byte: UInt8) -> String {
        Data(repeating: byte, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func deviceID(_ character: Character) throws -> DeviceID {
        try XCTUnwrap(DeviceID(rawValue: String(repeating: character, count: 56)))
    }

    private func folderID(_ value: String) throws -> FolderID {
        try XCTUnwrap(FolderID(rawValue: value))
    }

    private struct Fixture {
        let root: URL
        let paths: SharedContainerPaths

        init(revision: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PendingFolderObservationCommandTests-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            paths = SharedContainerPaths(root: root)
            try SharedSnapshotStore(snapshotURL: paths.snapshot).write(
                CoreSnapshot(generation: 1, configurationRevision: revision)
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
