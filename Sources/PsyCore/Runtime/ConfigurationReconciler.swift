import CryptoKit
import Foundation

public struct CoreConfigurationReconciliationProof: Hashable, Sendable {
    public static let kind = "authoritative_snapshot_configuration_state"

    public var snapshotGeneration: UInt64
    public var ownerEpoch: UInt64
    public var stateDigest: Data

    public init(snapshotGeneration: UInt64, ownerEpoch: UInt64, stateDigest: Data) {
        self.snapshotGeneration = snapshotGeneration
        self.ownerEpoch = ownerEpoch
        self.stateDigest = stateDigest
    }
}

extension CoreCommand {
    public var isConfigurationReconciliationCommand: Bool {
        switch kind {
        case .addDevice, .editDevice, .removeDevice, .acceptDevice,
            .addFolder, .editFolder, .removeFolder, .acceptFolder,
            .pause, .resume:
            true
        default:
            false
        }
    }
}

/// Proves a non-replay-safe configuration command from a snapshot produced by
/// a later owner. Native independently requires that the ledger entry was
/// loaded as pending by NewCore, so a Save failure cannot be "proved" from the
/// same in-memory configuration wrapper that failed to persist it.
struct ConfigurationReconciler: Sendable {
    func reconciliationProof(
        of command: CoreCommand,
        failedResult: CoreCommandResult,
        snapshot: CoreSnapshot,
        ownerEpoch: UInt64
    ) -> CoreConfigurationReconciliationProof? {
        guard command.isConfigurationReconciliationCommand,
            failedResult.commandID == command.id,
            failedResult.status == .failed,
            let failedOwnerEpoch = failedResult.ownerEpoch,
            failedOwnerEpoch > 0,
            ownerEpoch > failedOwnerEpoch,
            snapshot.generation > 0,
            provesRequestedState(of: command, snapshot: snapshot)
        else {
            return nil
        }

        var evidence = Data("psy-configuration-requested-state-v1".utf8)
        func append(_ value: String) {
            evidence.append(0)
            evidence.append(Data(value.utf8))
        }
        append(command.id.uuidString.lowercased())
        append(command.kind.rawValue)
        append(command.folderID?.rawValue ?? "")
        append(command.itemID ?? "")
        for key in command.arguments.keys.sorted() {
            append(key)
            append(command.arguments[key] ?? "")
        }
        append(String(snapshot.generation))
        append(String(ownerEpoch))
        append(snapshot.localDeviceID?.rawValue ?? "")

        if let deviceID = deviceTarget(for: command) {
            let matches = snapshot.devices.filter { $0.id == deviceID }
            if let device = matches.count == 1 ? matches[0] : nil {
                append(device.id.rawValue)
                append(device.name)
                device.addresses.forEach(append)
                append(String(device.isPaused))
            } else {
                append("device-absent")
            }
            if command.kind == .acceptDevice {
                append(snapshot.pendingDeviceObservationScope.rawValue)
                append(String(snapshot.suppressedPendingStateAvailable))
                append(String(snapshot.suppressedPendingDevicesTruncated))
                append("accepted-device-pending-and-suppression-absent")
            } else if command.kind == .removeDevice {
                for folder in snapshot.folders.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
                    append(folder.id.rawValue)
                    (folder.deviceIDs ?? []).map(\.rawValue).sorted().forEach(append)
                }
                append("removed-device-absent-from-all-folder-device-sets")
            }
        } else if let folderID = folderTarget(for: command) {
            let matches = snapshot.folders.filter { $0.id == folderID }
            if let folder = matches.count == 1 ? matches[0] : nil {
                append(folder.id.rawValue)
                append(folder.label)
                append(folder.localPath)
                append(folder.type.rawValue)
                append(String(folder.isPaused))
                (folder.deviceIDs ?? []).map(\.rawValue).sorted().forEach(append)
                append(folder.rescanIntervalS.map(String.init) ?? "unknown")
            } else {
                append("folder-absent")
            }
            if command.kind == .acceptFolder {
                append(String(snapshot.pendingFoldersAvailable))
                append(String(snapshot.pendingFoldersTruncated))
                append(String(snapshot.suppressedPendingStateAvailable))
                append(String(snapshot.suppressedPendingFoldersTruncated))
                append("accepted-folder-pending-and-suppression-absent")
            }
        } else {
            return nil
        }

        return CoreConfigurationReconciliationProof(
            snapshotGeneration: snapshot.generation,
            ownerEpoch: ownerEpoch,
            stateDigest: Data(SHA256.hash(data: evidence))
        )
    }

    func provesRequestedState(of command: CoreCommand, snapshot: CoreSnapshot) -> Bool {
        guard command.isConfigurationReconciliationCommand else { return false }
        switch command.kind {
        case .addDevice, .editDevice:
            guard let target = deviceTarget(for: command),
                command.folderID == nil,
                hasOnlyArguments(command, allowed: ["deviceID", "name", "addresses", "paused"]),
                command.kind != .editDevice
                    || hasAnyArgument(command, keys: ["name", "addresses", "paused"]),
                let device = only(snapshot.devices, where: { $0.id == target })
            else {
                return false
            }
            return deviceMatchesSuppliedArguments(device, command: command)

        case .removeDevice:
            guard let target = deviceTarget(for: command),
                command.folderID == nil,
                hasOnlyArguments(command, allowed: ["deviceID"])
            else {
                return false
            }
            return !snapshot.devices.contains { $0.id == target }
                && snapshot.folders.allSatisfy { folder in
                    guard let deviceIDs = folder.deviceIDs else { return false }
                    return !deviceIDs.contains(target)
                }

        case .acceptDevice:
            guard let target = deviceTarget(for: command),
                command.folderID == nil,
                hasOnlyArguments(command, allowed: ["deviceID", "offerVersion", "name", "paused"]),
                command.arguments["offerVersion"].map(PendingDeviceOffer.isCanonicalOfferVersion) == true,
                command.arguments["name"] != nil,
                command.arguments["paused"] != nil,
                let device = only(snapshot.devices, where: { $0.id == target }),
                device.addresses == ["dynamic"],
                deviceMatchesSuppliedArguments(device, command: command),
                snapshot.pendingDeviceObservationScope == .bridgeEventsPersisted,
                !snapshot.pendingDevices.contains(where: { $0.deviceID == target }),
                snapshot.suppressedPendingStateAvailable,
                !snapshot.suppressedPendingDevicesTruncated,
                !snapshot.suppressedPendingDevices.contains(where: { $0.deviceID == target })
            else {
                return false
            }
            return true

        case .addFolder, .editFolder:
            guard let target = folderTarget(for: command),
                command.itemID == nil,
                hasOnlyArguments(
                    command,
                    allowed: ["folderID", "label", "path", "type", "paused", "deviceIDs", "rescanIntervalS"]
                ),
                command.kind != .addFolder || command.arguments["path"] != nil,
                command.kind != .editFolder
                    || hasAnyArgument(
                        command,
                        keys: ["label", "path", "type", "paused", "deviceIDs", "rescanIntervalS"]
                    ),
                let folder = only(snapshot.folders, where: { $0.id == target })
            else {
                return false
            }
            return folderMatchesSuppliedArguments(folder, command: command, snapshot: snapshot)

        case .removeFolder:
            guard let target = folderTarget(for: command),
                command.itemID == nil,
                hasOnlyArguments(command, allowed: ["folderID", "deleteData"]),
                command.arguments["deleteData"] == nil
                    || command.arguments["deleteData"].flatMap(parseBoolean) == false
            else {
                return false
            }
            return !snapshot.folders.contains { $0.id == target }

        case .acceptFolder:
            guard let target = folderTarget(for: command),
                command.itemID == nil,
                hasOnlyArguments(
                    command,
                    allowed: [
                        "folderID", "offeringDeviceID", "offerVersion", "label", "path", "type", "paused",
                        "deviceIDs", "rescanIntervalS",
                    ]
                ),
                ["offeringDeviceID", "offerVersion", "label", "path", "type", "paused", "deviceIDs", "rescanIntervalS"]
                    .allSatisfy({ command.arguments[$0] != nil }),
                command.arguments["offerVersion"].map(PendingDeviceOffer.isCanonicalOfferVersion) == true,
                let offeringDevice = command.arguments["offeringDeviceID"].flatMap({ DeviceID(rawValue: $0) }),
                snapshot.devices.contains(where: { $0.id == offeringDevice }),
                let folder = only(snapshot.folders, where: { $0.id == target }),
                folderMatchesSuppliedArguments(folder, command: command, snapshot: snapshot),
                folder.deviceIDs?.contains(offeringDevice) == true,
                snapshot.pendingFoldersAvailable,
                !snapshot.pendingFoldersTruncated,
                !snapshot.pendingFolders.contains(where: {
                    $0.folderID == target && $0.offeringDeviceID == offeringDevice
                }),
                snapshot.suppressedPendingStateAvailable,
                !snapshot.suppressedPendingFoldersTruncated,
                !snapshot.suppressedPendingFolders.contains(where: {
                    $0.folderID == target && $0.offeringDeviceID == offeringDevice
                })
            else {
                return false
            }
            return true

        case .pause, .resume:
            let requestedPause = command.kind == .pause
            guard hasOnlyArguments(command, allowed: ["folderID", "deviceID"]) else { return false }
            let folderID = folderTarget(for: command)
            let deviceID = deviceTarget(for: command)
            guard (folderID == nil) != (deviceID == nil) else { return false }
            if let folderID, command.itemID == nil, command.arguments["deviceID"] == nil {
                return only(snapshot.folders, where: { $0.id == folderID })?.isPaused == requestedPause
            }
            guard command.folderID == nil, command.arguments["folderID"] == nil, let deviceID else { return false }
            return only(snapshot.devices, where: { $0.id == deviceID })?.isPaused == requestedPause

        default:
            return false
        }
    }
}

extension ConfigurationReconciler {
    private func deviceMatchesSuppliedArguments(_ device: DeviceRecord, command: CoreCommand) -> Bool {
        if let rawName = command.arguments["name"] {
            guard let name = parseName(rawName), device.name == name else { return false }
        }
        if let rawAddresses = command.arguments["addresses"] {
            guard let addresses = parseStringList(rawAddresses, canonicalizeDynamic: true),
                device.addresses == addresses
            else {
                return false
            }
        }
        if let rawPaused = command.arguments["paused"] {
            guard let paused = parseBoolean(rawPaused), device.isPaused == paused else { return false }
        }
        return true
    }

    private func folderMatchesSuppliedArguments(
        _ folder: FolderRecord,
        command: CoreCommand,
        snapshot: CoreSnapshot
    ) -> Bool {
        if let rawLabel = command.arguments["label"] {
            guard let label = parseName(rawLabel), folder.label == label else { return false }
        }
        if let rawPath = command.arguments["path"] {
            guard let path = canonicalAbsolutePath(rawPath), folder.localPath == path else { return false }
        }
        if let rawType = command.arguments["type"] {
            guard let type = parseFolderType(rawType), folder.type == type else { return false }
        }
        if let rawPaused = command.arguments["paused"] {
            guard let paused = parseBoolean(rawPaused), folder.isPaused == paused else { return false }
        }
        if let rawDeviceIDs = command.arguments["deviceIDs"] {
            guard let configured = folder.deviceIDs,
                let requested = parseDeviceIDs(rawDeviceIDs, localDeviceID: snapshot.localDeviceID),
                Set(configured) == requested,
                configured.count == requested.count
            else {
                return false
            }
        }
        if let rawInterval = command.arguments["rescanIntervalS"] {
            guard let interval = Int(rawInterval.trimmingCharacters(in: .whitespacesAndNewlines)),
                (0...(365 * 24 * 60 * 60)).contains(interval),
                folder.rescanIntervalS == interval
            else {
                return false
            }
        }
        return true
    }

    private func deviceTarget(for command: CoreCommand) -> DeviceID? {
        let item = command.itemID.flatMap(DeviceID.init(rawValue:))
        let argument = command.arguments["deviceID"].flatMap(DeviceID.init(rawValue:))
        if command.itemID != nil, item == nil { return nil }
        if command.arguments["deviceID"] != nil, argument == nil { return nil }
        if let item, let argument, item != argument { return nil }
        return item ?? argument
    }

    private func folderTarget(for command: CoreCommand) -> FolderID? {
        let direct = command.folderID
        let argument = command.arguments["folderID"].flatMap(FolderID.init(rawValue:))
        if command.arguments["folderID"] != nil, argument == nil { return nil }
        if let direct, let argument, direct != argument { return nil }
        return direct ?? argument
    }

    private func hasOnlyArguments(_ command: CoreCommand, allowed: Set<String>) -> Bool {
        Set(command.arguments.keys).isSubset(of: allowed)
    }

    private func hasAnyArgument(_ command: CoreCommand, keys: Set<String>) -> Bool {
        !Set(command.arguments.keys).isDisjoint(with: keys)
    }

    private func parseName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 256,
            value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            return nil
        }
        return value
    }

    private func parseBoolean(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private func parseStringList(_ raw: String, canonicalizeDynamic: Bool = false) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let values: [String]
        if trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String].self, from: data)
            else {
                return nil
            }
            values = decoded
        } else if trimmed.isEmpty {
            values = []
        } else {
            values = trimmed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
        guard values.count <= 64 else { return nil }
        var seen: Set<String> = []
        var result: [String] = []
        for rawValue in values {
            var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if canonicalizeDynamic, value.lowercased() == "dynamic" { value = "dynamic" }
            if seen.insert(value).inserted { result.append(value) }
        }
        if canonicalizeDynamic, result.isEmpty { return ["dynamic"] }
        return result
    }

    private func parseDeviceIDs(_ raw: String, localDeviceID: DeviceID?) -> Set<DeviceID>? {
        guard let values = parseStringList(raw) else { return nil }
        var result: Set<DeviceID> = []
        for value in values {
            guard let id = DeviceID(rawValue: value) else { return nil }
            if id != localDeviceID { result.insert(id) }
        }
        return result
    }

    private func parseFolderType(_ raw: String) -> FolderType? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sendreceive": .sendReceive
        case "sendonly": .sendOnly
        case "receiveonly": .receiveOnly
        case "receiveencrypted": .receiveEncrypted
        default: nil
        }
    }

    private func canonicalAbsolutePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\0") else { return nil }
        return NSString(string: trimmed).standardizingPath
    }

    private func only<Element>(_ values: [Element], where predicate: (Element) -> Bool) -> Element? {
        let matches = values.filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }
}
