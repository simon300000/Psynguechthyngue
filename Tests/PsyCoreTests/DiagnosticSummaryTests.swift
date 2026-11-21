import Darwin
import Foundation
import XCTest

@testable import PsyCore

final class DiagnosticSummaryTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_786_176_000)
    private let fixedSalt = Data((0..<16).map(UInt8.init))

    func testSensitiveDurableStateIsReducedToAggregates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let deviceIDText = Array(repeating: "AAAAAAA", count: 8).joined(separator: "-")
        let compactDeviceIDText = String(repeating: "B", count: 56)
        let deviceID = try XCTUnwrap(DeviceID(rawValue: deviceIDText))
        let compactDeviceID = try XCTUnwrap(DeviceID(rawValue: compactDeviceIDText))
        let folderIDText = "private-folder-canary"
        let folderID = try XCTUnwrap(FolderID(rawValue: folderIDText))
        let itemID = "private-item-id-canary"
        let filename = "private-filename-canary.txt"
        let absolutePath = "/private/var/mobile/private-path-canary"
        let peerAddress = "tcp://private-peer-canary.example:22000"
        let rawError = "localized provider error private-error-canary"
        let requestID = UUID(uuidString: "12345678-1234-4234-8234-1234567890AB")!
        let identityBlob = Data("private-identity-blob-canary".utf8)
        let bookmark = Data("private-bookmark-canary".utf8)
        let stagedToken = requestID.uuidString.lowercased() + "/contents"

        let snapshot = CoreSnapshot(
            generation: 42,
            generatedAt: fixedDate,
            localDeviceID: deviceID,
            devices: [
                DeviceRecord(
                    id: deviceID,
                    name: "/Users/private-device-label-canary",
                    addresses: [peerAddress],
                    state: .connected,
                    pendingBytes: 99,
                    blockingReason: rawError
                ),
                DeviceRecord(
                    id: compactDeviceID,
                    name: "private-device-label-canary",
                    addresses: [peerAddress],
                    state: .disconnected
                ),
            ],
            folders: [
                FolderRecord(
                    id: folderID,
                    label: "private-folder-label-canary",
                    localPath: absolutePath,
                    selectionMode: .manual,
                    deviceIDs: [deviceID, compactDeviceID],
                    pendingUploadBytes: 7,
                    pendingDownloadBytes: 11,
                    error: rawError
                )
            ],
            items: [
                IndexedItem(
                    id: itemID,
                    folderID: folderID,
                    relativePath: filename,
                    isDirectory: false,
                    size: 17,
                    modifiedAt: fixedDate,
                    contentVersion: identityBlob,
                    metadataVersion: identityBlob,
                    availability: .remoteOnly,
                    isPinned: true,
                    remoteReplicaCount: 1,
                    generation: 42
                )
            ]
        )
        try write(snapshot, to: fixture.paths.snapshot, dates: true)

        let policy = SyncPolicy(
            automaticallyAllowedNetworks: [.ethernet, .wifi],
            cellularAccess: .smallFiles,
            allowExpensive: true,
            allowConstrained: false
        )
        try write(policy, to: fixture.paths.policy)

        try SyncRunHistory(url: fixture.paths.history).append(
            SyncRunRecord(
                id: requestID,
                trigger: .backgroundProcessing,
                startedAt: fixedDate,
                endedAt: fixedDate.addingTimeInterval(2.5),
                transferredBytes: 123,
                endReason: .failed,
                failureCode: rawError
            )
        )

        let command = CoreCommand(
            id: requestID,
            kind: .modify,
            folderID: folderID,
            itemID: itemID,
            arguments: [
                "path": absolutePath,
                "stagedToken": stagedToken,
                "identity": identityBlob.base64EncodedString(),
            ],
            trigger: .fileProvider,
            createdAt: fixedDate
        )
        try CoreCommandQueue(root: fixture.paths.commandQueue).enqueue(command)
        let rawResult = CoreCommandResult(
            commandID: requestID,
            status: .failed,
            errorCode: rawError,
            reconciliationSourceRelativePath: filename,
            reconciliationProofStateDigest: identityBlob
        )
        try CoreCommandQueue(root: fixture.paths.commandQueue).record(rawResult)
        for component in ["pending", "results"] {
            let directory = fixture.paths.commandQueue.appendingPathComponent(
                component,
                isDirectory: true
            )
            for entry in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) {
                XCTAssertEqual(chmod(entry.path, 0), 0)
            }
        }

        let capabilities = ExternalDirectoryCapabilities(
            canEnumerate: true,
            canRead: true,
            failures: [rawError]
        )
        let external = try ExternalDirectoryRecord(
            id: requestID,
            displayName: "private-external-label-canary",
            bookmark: bookmark,
            mode: .readOnly,
            capabilities: capabilities,
            managedRootToken: requestID.uuidString.lowercased(),
            syncBinding: ExternalDirectorySyncBinding(
                folderID: folderID,
                commandID: requestID,
                phase: .failed,
                failureCode: rawError,
                lastCheckedAt: fixedDate
            ),
            lastMirrorStatus: ExternalDirectoryMirrorStatus(
                phase: .retryableFailure,
                lastAttemptedAt: fixedDate,
                failureCode: .providerOffline
            ),
            lastProbedAt: fixedDate
        )
        try write([external], to: fixture.paths.externalDirectoryRecords, dates: true)

        let stagingDirectory = fixture.paths.fileProviderStaging
            .appendingPathComponent(requestID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagedData = Data((stagedToken + filename + absolutePath).utf8)
        try stagedData.write(to: stagingDirectory.appendingPathComponent("contents"))
        let reservationJSON = """
            {"entries":[{"commandID":"\(requestID.uuidString)","destinationBytes":17}],"schemaVersion":1}
            """
        try Data(reservationJSON.utf8).write(
            to: fixture.paths.fileProviderStaging.appendingPathComponent(".reservations-v1.json")
        )

        let ownerURL = CoreProcessCoordinator.ownerMetadataURL(for: fixture.paths.coreLock)
        try write(
            CoreOwnerLease(
                epoch: 9,
                instanceID: requestID,
                role: .fileProvider,
                acquiredAt: fixedDate
            ),
            to: ownerURL,
            secondsSince1970Dates: true
        )

        let data = try builder(for: fixture).makeJSON()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let forbidden = [
            deviceIDText,
            compactDeviceIDText,
            folderIDText,
            itemID,
            filename,
            absolutePath,
            peerAddress,
            rawError,
            requestID.uuidString,
            requestID.uuidString.lowercased(),
            identityBlob.base64EncodedString(),
            bookmark.base64EncodedString(),
            stagedToken,
            "private-device-label-canary",
            "private-folder-label-canary",
            "private-external-label-canary",
            "/Users/",
            "/private/",
        ]
        for canary in forbidden {
            XCTAssertFalse(text.contains(canary), "diagnostic JSON leaked \(canary)")
        }

        let json = try jsonObject(data)
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(value(at: ["snapshot", "generation"], in: json) as? Int, 42)
        XCTAssertEqual(value(at: ["snapshot", "deviceCount"], in: json) as? Int, 2)
        XCTAssertEqual(value(at: ["snapshot", "folderCount"], in: json) as? Int, 1)
        XCTAssertEqual(value(at: ["snapshot", "itemCount"], in: json) as? Int, 1)
        XCTAssertEqual(value(at: ["queue", "pendingCount"], in: json) as? Int, 1)
        XCTAssertEqual(value(at: ["queue", "resultCount"], in: json) as? Int, 1)
        XCTAssertEqual(value(at: ["externalDirectories", "recordCount"], in: json) as? Int, 1)
        XCTAssertEqual(
            value(at: ["staging", "regularContentBytes"], in: json) as? Int,
            stagedData.count
        )
        XCTAssertEqual(value(at: ["staging", "reservationCount"], in: json) as? Int, 1)
        XCTAssertEqual(
            value(at: ["staging", "reservedDestinationBytes"], in: json) as? Int,
            17
        )
        XCTAssertEqual(value(at: ["owner", "epoch"], in: json) as? Int, 9)
        XCTAssertEqual(
            value(at: ["runHistory", "records", "0", "failureCode"], in: json) as? String,
            "unrecognized"
        )
    }

    func testSymlinkWrongTypeAndOversizeInputsAreRejectedWithoutReadingTargets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let secret = fixture.root.appendingPathComponent("outside-secret.json")
        let canary = "symlink-target-private-canary"
        try Data(canary.utf8).write(to: secret)
        try FileManager.default.createDirectory(
            at: fixture.paths.snapshot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: fixture.paths.snapshot, withDestinationURL: secret)

        try FileManager.default.createDirectory(
            at: fixture.paths.policy,
            withIntermediateDirectories: true
        )
        let oversized = fixture.paths.history
        try FileManager.default.createDirectory(
            at: oversized.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: DiagnosticSummaryBuilder.maximumHistoryBytes + 1)
            .write(to: oversized)

        let data = try builder(for: fixture).makeJSON()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(canary))
        let json = try jsonObject(data)
        XCTAssertEqual(value(at: ["snapshot", "health"], in: json) as? String, "symbolicLink")
        XCTAssertEqual(value(at: ["policy", "health"], in: json) as? String, "wrongType")
        XCTAssertEqual(value(at: ["runHistory", "health"], in: json) as? String, "oversize")
    }

    func testCorruptAndTruncatedInputsFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try createParent(of: fixture.paths.snapshot)
        try Data("{not-json".utf8).write(to: fixture.paths.snapshot)
        try Data("{\"schemaVersion\":1}".utf8).write(to: fixture.paths.history)

        let json = try jsonObject(builder(for: fixture).makeJSON())
        XCTAssertEqual(value(at: ["snapshot", "health"], in: json) as? String, "corrupt")
        XCTAssertEqual(value(at: ["runHistory", "health"], in: json) as? String, "truncated")
        XCTAssertEqual((value(at: ["runHistory", "records"], in: json) as? [Any])?.count, 0)
    }

    func testUnreadableInputIsNotBypassed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try createParent(of: fixture.paths.snapshot)
        try Data("{}".utf8).write(to: fixture.paths.snapshot)
        XCTAssertEqual(chmod(fixture.paths.snapshot.path, 0), 0)
        defer { _ = chmod(fixture.paths.snapshot.path, mode_t(0o600)) }

        let json = try jsonObject(builder(for: fixture).makeJSON())
        XCTAssertEqual(value(at: ["snapshot", "health"], in: json) as? String, "unreadable")
    }

    func testSameInodeSameSizeMutationFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("same-inode.json")
        let original = Data("{\"value\":\"aaaaaaaa\"}".utf8)
        let replacement = Data("{\"value\":\"bbbbbbbb\"}".utf8)
        XCTAssertEqual(original.count, replacement.count)
        try original.write(to: url)

        let result = StrictDiagnosticFileReader.read(
            url,
            maximumBytes: 1_024,
            beforeFinalValidation: {
                try replacement.write(to: url, options: [])
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
                    ofItemAtPath: url.path
                )
            }
        )
        XCTAssertEqual(result.health, .changedDuringRead)
        XCTAssertNil(result.data)
    }

    func testEncodingIsDeterministicForFixedTimeAndSalt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try write(
            SyncPolicy(automaticallyAllowedNetworks: [.other, .wifi, .ethernet]),
            to: fixture.paths.policy
        )

        XCTAssertEqual(try builder(for: fixture).makeJSON(), try builder(for: fixture).makeJSON())
    }

    func testAtomicExportUsesExclusive0600FileAndCleansUp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outputDirectory = fixture.root.appendingPathComponent("Exports", isDirectory: true)
        let exporter = DiagnosticSummaryExporter(builder: builder(for: fixture))

        let url = try exporter.export(to: outputDirectory)
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o600))
        _ = try jsonObject(Data(contentsOf: url))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
                .contains(where: { $0.contains(".partial-") })
        )

        try exporter.removeExport(at: url, from: outputDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAtomicWriterRemovesPartialFileAfterInjectedFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outputDirectory = fixture.root.appendingPathComponent("Exports", isDirectory: true)
        enum Injected: Error { case stop }

        XCTAssertThrowsError(
            try DiagnosticAtomicFileWriter.write(
                Data("{}".utf8),
                to: outputDirectory,
                finalName: "diagnostic-summary.json",
                beforeCommit: { throw Injected.stop }
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path),
            []
        )
    }

    func testNextExportCleanupRemovesOnlyOwnedRegularArtifacts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outputDirectory = fixture.root.appendingPathComponent("Exports", isDirectory: true)
        let exporter = DiagnosticSummaryExporter(builder: builder(for: fixture))
        let first = try exporter.export(to: outputDirectory)
        let unrelated = outputDirectory.appendingPathComponent("keep-me.txt")
        try Data("keep".utf8).write(to: unrelated)
        let abandonedPartial = outputDirectory.appendingPathComponent(
            ".partial-0123456789abcdef01234567"
        )
        try Data("partial".utf8).write(to: abandonedPartial)

        try exporter.removeTemporaryExports(from: outputDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedPartial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCleanupRejectsSymlinkArtifactWithoutTouchingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outputDirectory = fixture.root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
        let target = fixture.root.appendingPathComponent("outside.json")
        try Data("outside-canary".utf8).write(to: target)
        let link = outputDirectory.appendingPathComponent(
            "diagnostic-summary-0123456789abcdef01234567.json"
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try DiagnosticSummaryExporter.removeTemporaryExports(from: outputDirectory)
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "outside-canary")
    }

    private func builder(for fixture: Fixture) -> DiagnosticSummaryBuilder {
        DiagnosticSummaryBuilder(
            paths: fixture.paths,
            build: DiagnosticBuildMetadata(
                appVersion: "1.2.3",
                appBuild: "456",
                coreRevision: "syncthing-v2.1.3@946e2b83a1f6"
            ),
            generatedAt: fixedDate,
            salt: fixedSalt
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func value(at path: [String], in root: Any) -> Any? {
        var current: Any = root
        for component in path {
            if let object = current as? [String: Any], let value = object[component] {
                current = value
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    private func write<T: Encodable>(
        _ value: T,
        to url: URL,
        dates: Bool = false,
        secondsSince1970Dates: Bool = false
    ) throws {
        try createParent(of: url)
        let encoder = JSONEncoder()
        if dates { encoder.dateEncodingStrategy = .iso8601 }
        if secondsSince1970Dates { encoder.dateEncodingStrategy = .secondsSince1970 }
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url)
    }

    private func createParent(of url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

private struct Fixture {
    let root: URL
    let paths: SharedContainerPaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticSummaryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        paths = SharedContainerPaths(root: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
