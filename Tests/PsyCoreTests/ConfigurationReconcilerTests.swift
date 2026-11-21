import XCTest

@testable import PsyCore

final class ConfigurationReconcilerTests: XCTestCase {
    func testDeviceProofRequiresEverySuppliedFieldAndNewOwnerEpoch() throws {
        let local = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let remote = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let command = CoreCommand(
            kind: .addDevice,
            itemID: remote.rawValue,
            arguments: [
                "name": "Requested Peer",
                "addresses": #"["dynamic","tcp://127.0.0.1:22000"]"#,
                "paused": "true",
            ],
            trigger: .user
        )
        let failed = CoreCommandResult(
            commandID: command.id,
            status: .failed,
            ownerEpoch: 3,
            errorCode: "internal_error"
        )
        let requested = DeviceRecord(
            id: remote,
            name: "Requested Peer",
            addresses: ["dynamic", "tcp://127.0.0.1:22000"],
            isPaused: true
        )
        let snapshot = CoreSnapshot(
            generation: 9,
            localDeviceID: local,
            devices: [DeviceRecord(id: local, name: "Local"), requested]
        )
        let reconciler = ConfigurationReconciler()

        XCTAssertNotNil(
            reconciler.reconciliationProof(
                of: command,
                failedResult: failed,
                snapshot: snapshot,
                ownerEpoch: 4
            )
        )
        XCTAssertNil(
            reconciler.reconciliationProof(
                of: command,
                failedResult: failed,
                snapshot: snapshot,
                ownerEpoch: 3
            )
        )
        var conflicting = snapshot
        conflicting.devices[1].addresses = ["dynamic"]
        XCTAssertNil(
            reconciler.reconciliationProof(
                of: command,
                failedResult: failed,
                snapshot: conflicting,
                ownerEpoch: 4
            )
        )
    }

    func testFolderProofCoversLabelPathTypePauseDevicesAndRescanInterval() throws {
        let local = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let remote = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let folderID = try XCTUnwrap(FolderID(rawValue: "proof-folder"))
        let command = CoreCommand(
            kind: .editFolder,
            folderID: folderID,
            arguments: [
                "label": "Requested Folder",
                "path": "/tmp/requested-folder",
                "type": "sendOnly",
                "paused": "true",
                "deviceIDs": "[\"\(remote.rawValue)\"]",
                "rescanIntervalS": "120",
            ],
            trigger: .user
        )
        let failed = CoreCommandResult(
            commandID: command.id,
            status: .failed,
            ownerEpoch: 6,
            errorCode: "internal_error"
        )
        let requested = FolderRecord(
            id: folderID,
            label: "Requested Folder",
            localPath: "/tmp/requested-folder",
            type: .sendOnly,
            isPaused: true,
            deviceIDs: [remote],
            rescanIntervalS: 120
        )
        let snapshot = CoreSnapshot(
            generation: 12,
            localDeviceID: local,
            devices: [DeviceRecord(id: local, name: "Local"), DeviceRecord(id: remote, name: "Peer")],
            folders: [requested]
        )
        let reconciler = ConfigurationReconciler()

        XCTAssertNotNil(
            reconciler.reconciliationProof(
                of: command,
                failedResult: failed,
                snapshot: snapshot,
                ownerEpoch: 7
            )
        )
        var missingInterval = snapshot
        missingInterval.folders[0].rescanIntervalS = nil
        XCTAssertNil(
            reconciler.reconciliationProof(
                of: command,
                failedResult: failed,
                snapshot: missingInterval,
                ownerEpoch: 7
            )
        )
    }

    func testAcceptanceProofRequiresAuthoritativePendingAndSuppressionAbsence() throws {
        let local = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let remote = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let command = CoreCommand(
            kind: .acceptDevice,
            itemID: remote.rawValue,
            arguments: [
                "offerVersion": canonicalOfferVersion(repeating: 0x61),
                "name": "Accepted Peer",
                "paused": "false",
            ],
            trigger: .user
        )
        let failed = CoreCommandResult(
            commandID: command.id,
            status: .failed,
            ownerEpoch: 1,
            errorCode: "internal_error"
        )
        var snapshot = CoreSnapshot(
            generation: 2,
            localDeviceID: local,
            devices: [
                DeviceRecord(id: local, name: "Local"),
                DeviceRecord(id: remote, name: "Accepted Peer", addresses: ["dynamic"]),
            ],
            pendingDeviceObservationScope: .bridgeEventsPersisted,
            suppressedPendingStateAvailable: true
        )
        let reconciler = ConfigurationReconciler()

        XCTAssertNotNil(
            reconciler.reconciliationProof(
                of: command,
                failedResult: failed,
                snapshot: snapshot,
                ownerEpoch: 2
            )
        )
        var legacyHexCommand = command
        legacyHexCommand.arguments["offerVersion"] = String(repeating: "a", count: 64)
        XCTAssertFalse(reconciler.provesRequestedState(of: legacyHexCommand, snapshot: snapshot))

        snapshot.pendingDeviceObservationScope = .unavailable
        XCTAssertNil(
            reconciler.reconciliationProof(
                of: command,
                failedResult: failed,
                snapshot: snapshot,
                ownerEpoch: 2
            )
        )
    }

    func testRemovePauseResumeAndAddPostconditionsAreStrictlyProved() throws {
        let local = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let remote = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let folderID = try XCTUnwrap(FolderID(rawValue: "command-matrix-folder"))
        let reconciler = ConfigurationReconciler()
        func failed(_ command: CoreCommand) -> CoreCommandResult {
            CoreCommandResult(
                commandID: command.id,
                status: .failed,
                ownerEpoch: 4,
                errorCode: "internal_error"
            )
        }
        let pauseDevice = CoreCommand(
            kind: .pause,
            itemID: remote.rawValue,
            trigger: .user
        )
        let pausedDeviceSnapshot = CoreSnapshot(
            generation: 5,
            localDeviceID: local,
            devices: [
                DeviceRecord(id: local, name: "Local"),
                DeviceRecord(id: remote, name: "Peer", isPaused: true),
            ]
        )
        XCTAssertNotNil(
            reconciler.reconciliationProof(
                of: pauseDevice,
                failedResult: failed(pauseDevice),
                snapshot: pausedDeviceSnapshot,
                ownerEpoch: 5
            )
        )

        let resumeFolder = CoreCommand(
            kind: .resume,
            folderID: folderID,
            trigger: .user
        )
        let resumedFolderSnapshot = CoreSnapshot(
            generation: 5,
            localDeviceID: local,
            devices: [DeviceRecord(id: local, name: "Local")],
            folders: [
                FolderRecord(
                    id: folderID,
                    label: "Folder",
                    localPath: "/tmp/command-matrix-folder",
                    isPaused: false,
                    deviceIDs: []
                )
            ]
        )
        XCTAssertNotNil(
            reconciler.reconciliationProof(
                of: resumeFolder,
                failedResult: failed(resumeFolder),
                snapshot: resumedFolderSnapshot,
                ownerEpoch: 5
            )
        )

        let removeDevice = CoreCommand(
            kind: .removeDevice,
            itemID: remote.rawValue,
            trigger: .user
        )
        let removeFolder = CoreCommand(
            kind: .removeFolder,
            folderID: folderID,
            arguments: ["deleteData": "false"],
            trigger: .user
        )
        let absentSnapshot = CoreSnapshot(
            generation: 5,
            localDeviceID: local,
            devices: [DeviceRecord(id: local, name: "Local")]
        )
        XCTAssertNotNil(
            reconciler.reconciliationProof(
                of: removeDevice,
                failedResult: failed(removeDevice),
                snapshot: absentSnapshot,
                ownerEpoch: 5
            )
        )
        var incompleteRemovalSnapshot = absentSnapshot
        incompleteRemovalSnapshot.folders = [
            FolderRecord(
                id: folderID,
                label: "Legacy projection",
                localPath: "/tmp/legacy-projection",
                deviceIDs: nil
            )
        ]
        XCTAssertNil(
            reconciler.reconciliationProof(
                of: removeDevice,
                failedResult: failed(removeDevice),
                snapshot: incompleteRemovalSnapshot,
                ownerEpoch: 5
            )
        )
        incompleteRemovalSnapshot.folders[0].deviceIDs = [remote]
        XCTAssertNil(
            reconciler.reconciliationProof(
                of: removeDevice,
                failedResult: failed(removeDevice),
                snapshot: incompleteRemovalSnapshot,
                ownerEpoch: 5
            )
        )
        XCTAssertNotNil(
            reconciler.reconciliationProof(
                of: removeFolder,
                failedResult: failed(removeFolder),
                snapshot: absentSnapshot,
                ownerEpoch: 5
            )
        )

        let addFolder = CoreCommand(
            kind: .addFolder,
            folderID: folderID,
            arguments: [
                "label": "Added Folder",
                "path": "/tmp/command-matrix-folder",
                "type": "sendReceive",
                "paused": "false",
                "deviceIDs": remote.rawValue,
                "rescanIntervalS": "3600",
            ],
            trigger: .user
        )
        let addedSnapshot = CoreSnapshot(
            generation: 5,
            localDeviceID: local,
            devices: [DeviceRecord(id: local, name: "Local"), DeviceRecord(id: remote, name: "Peer")],
            folders: [
                FolderRecord(
                    id: folderID,
                    label: "Added Folder",
                    localPath: "/tmp/command-matrix-folder",
                    type: .sendReceive,
                    deviceIDs: [remote],
                    rescanIntervalS: 3600
                )
            ]
        )
        XCTAssertNotNil(
            reconciler.reconciliationProof(
                of: addFolder,
                failedResult: failed(addFolder),
                snapshot: addedSnapshot,
                ownerEpoch: 5
            )
        )
    }

    func testFolderAcceptanceRequiresExactConfigurationAndConsumedOfferState() throws {
        let local = try XCTUnwrap(DeviceID(rawValue: String(repeating: "A", count: 56)))
        let offering = try XCTUnwrap(DeviceID(rawValue: String(repeating: "B", count: 56)))
        let folderID = try XCTUnwrap(FolderID(rawValue: "accepted-proof-folder"))
        let command = CoreCommand(
            kind: .acceptFolder,
            folderID: folderID,
            arguments: [
                "offeringDeviceID": offering.rawValue,
                "offerVersion": canonicalOfferVersion(repeating: 0x62),
                "label": "Accepted Folder",
                "path": "/tmp/accepted-proof-folder",
                "type": "sendReceive",
                "paused": "false",
                "deviceIDs": offering.rawValue,
                "rescanIntervalS": "600",
            ],
            trigger: .user
        )
        let failed = CoreCommandResult(
            commandID: command.id,
            status: .failed,
            ownerEpoch: 8,
            errorCode: "internal_error"
        )
        var snapshot = CoreSnapshot(
            generation: 9,
            localDeviceID: local,
            devices: [DeviceRecord(id: local, name: "Local"), DeviceRecord(id: offering, name: "Peer")],
            folders: [
                FolderRecord(
                    id: folderID,
                    label: "Accepted Folder",
                    localPath: "/tmp/accepted-proof-folder",
                    type: .sendReceive,
                    deviceIDs: [offering],
                    rescanIntervalS: 600
                )
            ],
            pendingFoldersAvailable: true,
            suppressedPendingStateAvailable: true
        )
        let reconciler = ConfigurationReconciler()

        XCTAssertNotNil(
            reconciler.reconciliationProof(
                of: command,
                failedResult: failed,
                snapshot: snapshot,
                ownerEpoch: 9
            )
        )
        var legacyHexCommand = command
        legacyHexCommand.arguments["offerVersion"] = String(repeating: "b", count: 64)
        XCTAssertFalse(reconciler.provesRequestedState(of: legacyHexCommand, snapshot: snapshot))

        snapshot.pendingFoldersTruncated = true
        XCTAssertNil(
            reconciler.reconciliationProof(
                of: command,
                failedResult: failed,
                snapshot: snapshot,
                ownerEpoch: 9
            )
        )
    }

    private func canonicalOfferVersion(repeating byte: UInt8) -> String {
        Data(repeating: byte, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
