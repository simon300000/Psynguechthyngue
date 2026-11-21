import Darwin
import Foundation
import PsyCore
import UIKit
import XCTest

@testable import Psynguechthyngue

/// A manually selected signed-device gate, excluded from the ordinary unit suite.
/// Run it concurrently on one iPad and one iPhone that share exactly one enabled folder.
@MainActor
final class PhysicalFileProviderE2ETests: XCTestCase {
    private static let sourceDirectoryName = "Psy-v1-e2e-4fbe0c9d-source"
    private static let finalDirectoryName = "Psy-v1-e2e-4fbe0c9d-final"
    private static let folderID = FolderID(rawValue: "psy-v1-e2e-4fbe0c9d")!
    private static let convergenceTimeout: TimeInterval = 300

    func testReportPhysicalPeerIdentityAndLANAddress() async throws {
        #if targetEnvironment(simulator)
            throw PhysicalFileProviderE2EError.physicalDeviceRequired
        #else
            let model = AppModel()
            await model.start()
            guard let deviceID = model.snapshot.localDeviceID,
                let address = Self.lanIPv4Address()
            else {
                throw PhysicalFileProviderE2EError.identityOrAddressUnavailable
            }
            print(
                "PSY_PHYSICAL_E2E_DISCOVERY device=\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") deviceID=\(deviceID.rawValue) address=tcp://\(address):22000 folders=\(model.snapshot.folders.count)"
            )
        #endif
    }

    func testConfigureTemporaryPeerAndShare() async throws {
        #if targetEnvironment(simulator)
            throw PhysicalFileProviderE2EError.physicalDeviceRequired
        #else
            let model = AppModel()
            await model.start()
            try require(
                model.snapshot.folders.isEmpty,
                "The setup phase refuses to overwrite an existing share configuration."
            )
            try await configureFixtureIfNeeded(model)
            await model.refresh()
            try require(
                model.snapshot.folders.map(\.id) == [Self.folderID],
                "The setup phase did not publish exactly the reserved temporary share."
            )
            try require(
                model.fileProviderDomainStatus == .enabled,
                "The temporary per-share Files location is not enabled."
            )
        #endif
    }

    func testWaitForFilesUIRenamedDirectory() async throws {
        #if targetEnvironment(simulator)
            throw PhysicalFileProviderE2EError.physicalDeviceRequired
        #else
            let model = AppModel()
            await model.start()
            guard
                try await waitForIndexedItem(
                    model,
                    relativePath: Self.finalDirectoryName,
                    timeout: Self.convergenceTimeout,
                    beforeEachAttempt: {
                        try await self.synchronize(model)
                    },
                    matching: { $0.isDirectory }
                ) != nil
            else {
                throw PhysicalFileProviderE2EError.assertion(
                    "The Files UI directory create/rename did not reach the peer global index."
                )
            }
            try require(
                !model.indexedItems.contains {
                    $0.folderID == Self.folderID && $0.relativePath == Self.sourceDirectoryName
                },
                "The pre-rename Files UI directory remained in the peer index."
            )
        #endif
    }

    func testWaitForFilesUIDeletionAndCleanup() async throws {
        #if targetEnvironment(simulator)
            throw PhysicalFileProviderE2EError.physicalDeviceRequired
        #else
            let model = AppModel()
            await model.start()
            let deleted = try await waitUntil(timeout: Self.convergenceTimeout) {
                try await self.synchronize(model)
                await model.refresh()
                return !model.indexedItems.contains {
                    $0.folderID == Self.folderID
                        && ($0.relativePath == Self.sourceDirectoryName
                            || $0.relativePath == Self.finalDirectoryName)
                }
            }
            await cleanupReservedConfiguration(model)
            try require(deleted, "The Files UI directory deletion did not propagate to this peer.")
            try require(model.snapshot.folders.isEmpty, "The temporary share was not removed.")
        #endif
    }

    func testCleanupTemporaryPeerAndShare() async throws {
        let model = AppModel()
        await model.start()
        await cleanupReservedConfiguration(model)
        try require(
            !model.snapshot.folders.contains(where: { $0.id == Self.folderID }),
            "The reserved temporary share could not be cleaned up."
        )
    }

    private func configureFixtureIfNeeded(_ model: AppModel) async throws {
        if model.snapshot.folders.count == 1 {
            return
        }
        try require(
            model.snapshot.folders.isEmpty,
            "The physical gate refuses to mutate a device with an unexpected share set."
        )
        let environment = ProcessInfo.processInfo.environment
        guard
            let peerText = environment["PSY_PHYSICAL_E2E_PEER_ID"],
            let peerID = DeviceID(syncthingString: peerText),
            let peerAddress = environment["PSY_PHYSICAL_E2E_PEER_ADDRESS"],
            !peerAddress.isEmpty
        else {
            throw PhysicalFileProviderE2EError.peerConfigurationUnavailable
        }

        var addedPeerID: DeviceID?
        if !model.snapshot.devices.contains(where: { $0.id == peerID }) {
            guard
                await model.addDevice(
                    id: peerID,
                    name: "Psy v1 E2E peer",
                    addresses: [peerAddress],
                    paused: false
                )
            else {
                throw PhysicalFileProviderE2EError.configurationFailed("add_device")
            }
            addedPeerID = peerID
        }
        guard
            await model.addManagedFolder(
                id: Self.folderID,
                label: "Psy v1 E2E",
                type: .sendReceive,
                paused: false,
                deviceIDs: [peerID],
                rescanIntervalS: 3600
            )
        else {
            if let addedPeerID {
                _ = await model.submit(kind: .removeDevice, itemID: addedPeerID.rawValue)
            }
            throw PhysicalFileProviderE2EError.configurationFailed("add_folder")
        }
        await model.refresh()
    }

    private func cleanupReservedConfiguration(_ model: AppModel) async {
        await model.refresh()
        if model.snapshot.folders.contains(where: { $0.id == Self.folderID }),
            let digest = model.folderIncarnationDigests[Self.folderID]
        {
            _ = await model.submit(
                kind: .removeFolder,
                folderID: Self.folderID,
                arguments: ["deleteData": "false"],
                expectedFolderIncarnationDigest: digest
            )
        }
        if let peerText = ProcessInfo.processInfo.environment["PSY_PHYSICAL_E2E_PEER_ID"],
            let peerID = DeviceID(syncthingString: peerText),
            model.snapshot.devices.contains(where: { $0.id == peerID })
        {
            _ = await model.submit(kind: .removeDevice, itemID: peerID.rawValue)
        }
        await model.refresh()
        guard !model.snapshot.folders.contains(where: { $0.id == Self.folderID }),
            let paths = try? SharedContainerPaths.resolve(),
            let root = try? paths.managedFolder(for: Self.folderID)
        else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PhysicalFileProviderE2EError.assertion(message) }
    }

    private func synchronize(_ model: AppModel) async throws {
        _ = await model.submit(kind: .sync)
        if let error = model.errorMessage {
            throw PhysicalFileProviderE2EError.syncFailed(error)
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        operation: () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try await operation() { return true }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        return try await operation()
    }

    private func waitForIndexedItem(
        _ model: AppModel,
        relativePath: String,
        timeout: TimeInterval,
        beforeEachAttempt: (() async throws -> Void)? = nil,
        matching: (IndexedItem) -> Bool = { _ in true }
    ) async throws -> IndexedItem? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try await beforeEachAttempt?()
            await model.refresh()
            if let item = model.indexedItems.first(where: {
                $0.folderID == Self.folderID
                    && $0.relativePath == relativePath
                    && matching($0)
            }) {
                return item
            }
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        try await beforeEachAttempt?()
        await model.refresh()
        return model.indexedItems.first {
            $0.folderID == Self.folderID
                && $0.relativePath == relativePath
                && matching($0)
        }
    }

    private nonisolated static func lanIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(priority: Int, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET),
                current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard
                getnameinfo(
                    address,
                    length,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0
            else { continue }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            candidates.append((name == "en0" ? 0 : 1, String(decoding: bytes, as: UTF8.self)))
        }
        return candidates.sorted {
            $0.priority == $1.priority ? $0.address < $1.address : $0.priority < $1.priority
        }.first?.address
    }

}

private enum PhysicalFileProviderE2EError: LocalizedError {
    case physicalDeviceRequired
    case identityOrAddressUnavailable
    case peerConfigurationUnavailable
    case configurationFailed(String)
    case assertion(String)
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .physicalDeviceRequired:
            "The paired Files E2E gate must run on signed physical devices."
        case .identityOrAddressUnavailable:
            "The physical device identity or LAN IPv4 address is unavailable."
        case .peerConfigurationUnavailable:
            "The physical E2E peer identity or address was not supplied."
        case .configurationFailed(let step):
            "The physical E2E configuration step failed: \(step)."
        case .assertion(let message): message
        case .syncFailed(let code): "The product sync path failed: \(code)"
        }
    }
}
