import CryptoKit
import Darwin
import Foundation

public struct CoreMutationReconciliationProof: Hashable, Sendable {
    public static let kind = "authoritative_snapshot_requested_state"

    public var snapshotGeneration: UInt64
    public var ownerEpoch: UInt64
    public var stateDigest: Data

    public init(snapshotGeneration: UInt64, ownerEpoch: UInt64, stateDigest: Data) {
        self.snapshotGeneration = snapshotGeneration
        self.ownerEpoch = ownerEpoch
        self.stateDigest = stateDigest
    }
}

/// Proves the final state of a File Provider mutation without replaying the
/// mutation's request UUID. A successful proof requires both the authoritative
/// bridge snapshot and, for uploaded content, the retained staging bytes.
struct MutationReconciler: Sendable {
    let paths: SharedContainerPaths

    func expectedIsDirectory(
        for command: CoreCommand,
        baseline: CoreSnapshot?
    ) -> Bool? {
        guard command.isFileProviderMutation else { return nil }
        switch command.kind {
        case .create:
            switch command.arguments["isDirectory"] {
            case "true": return true
            case "false": return false
            default: return nil
            }
        case .modify, .move:
            if command.arguments["stagedContentToken"] != nil { return false }
            guard let itemID = command.itemID else { return nil }
            let matches =
                baseline?.items.filter {
                    $0.id == itemID && $0.folderID == command.folderID
                } ?? []
            return matches.count == 1 ? matches[0].isDirectory : nil
        case .delete:
            return nil
        default:
            return nil
        }
    }

    func rescanCommand(for original: CoreCommand, ownerEpoch: UInt64) -> CoreCommand? {
        guard original.isFileProviderMutation, let folderID = original.folderID else { return nil }
        var input = Data("file-provider-mutation-reconciliation".utf8)
        input.append(0)
        input.append(Data(original.id.uuidString.lowercased().utf8))
        input.append(0)
        input.append(Data(String(ownerEpoch).utf8))
        let bytes = Array(SHA256.hash(data: input).prefix(16))
        let id = UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
        return CoreCommand(
            id: id,
            kind: .rescan,
            folderID: folderID,
            folderIncarnationDigest: original.folderIncarnationDigest,
            trigger: original.trigger
        )
    }

    func createTargetWasAbsent(
        for command: CoreCommand,
        baseline: CoreSnapshot?
    ) -> Bool? {
        guard command.kind == .create,
            let baseline,
            let folderID = command.folderID,
            let folder = baseline.folders.only(where: { $0.id == folderID }),
            let target = target(for: command, folderID: folderID, snapshot: baseline)
        else {
            return nil
        }
        let matches = baseline.items.filter {
            $0.folderID == folderID && $0.relativePath == target.relativePath
        }
        guard matches.count <= 1 else { return nil }
        guard matches.isEmpty else { return false }
        guard let folderRoot = safeFolderRoot(for: folder) else { return nil }
        return securelyObserveTargetAbsence(
            relativePath: target.relativePath,
            folderRoot: folderRoot
        )
    }

    func sourceRelativePath(
        for command: CoreCommand,
        baseline: CoreSnapshot?
    ) -> String? {
        guard command.kind == .move,
            let baseline,
            let folderID = command.folderID,
            let itemID = command.itemID,
            !itemID.isEmpty,
            let source = baseline.items.only(where: {
                $0.id == itemID && $0.folderID == folderID
            }),
            Self.isSafeRelativePath(source.relativePath)
        else {
            return nil
        }
        return source.relativePath
    }

    func provesRequestedState(
        of command: CoreCommand,
        expectedIsDirectory: Bool?,
        createTargetWasAbsent: Bool?,
        sourceRelativePath: String?,
        snapshot: CoreSnapshot
    ) -> Bool {
        guard command.isFileProviderMutation, let folderID = command.folderID else { return false }
        if command.kind == .delete {
            guard let itemID = command.itemID, !itemID.isEmpty else { return false }
            return snapshot.tombstones.contains { $0.itemID == itemID }
                && !snapshot.items.contains { $0.id == itemID }
        }

        if command.kind == .create, createTargetWasAbsent != true { return false }

        guard let expectedIsDirectory,
            let target = target(for: command, folderID: folderID, snapshot: snapshot),
            let authoritativeItem = authoritativeItem(
                for: command,
                folderID: folderID,
                target: target,
                expectedIsDirectory: expectedIsDirectory,
                snapshot: snapshot
            ),
            let folder = snapshot.folders.only(where: { $0.id == folderID }),
            let folderRoot = safeFolderRoot(for: folder),
            securelyValidateExistingTarget(
                relativePath: target.relativePath,
                isDirectory: expectedIsDirectory,
                folderRoot: folderRoot
            )
        else {
            return false
        }

        guard authoritativeItem.parentID == target.parentItemID else { return false }
        if command.kind == .move {
            guard let sourceRelativePath,
                sourceRelativePath != target.relativePath,
                Self.isSafeRelativePath(sourceRelativePath),
                !snapshot.items.contains(where: {
                    $0.folderID == folderID && $0.relativePath == sourceRelativePath
                }),
                securelyObserveTargetAbsence(
                    relativePath: sourceRelativePath,
                    folderRoot: folderRoot,
                    missingAncestorIsAbsence: true
                ) == true
            else {
                return false
            }
        }
        if let token = command.arguments["stagedContentToken"] {
            guard !expectedIsDirectory else { return false }
            do {
                return try FileProviderStagingStore(root: paths.fileProviderStaging)
                    .contentMatches(
                        token: token,
                        commandID: command.id,
                        targetRoot: folderRoot,
                        targetRelativePath: target.relativePath
                    )
            } catch {
                return false
            }
        }
        return true
    }

    func reconciliationProof(
        of command: CoreCommand,
        expectedIsDirectory: Bool?,
        createTargetWasAbsent: Bool?,
        sourceRelativePath: String?,
        snapshot: CoreSnapshot,
        ownerEpoch: UInt64
    ) -> CoreMutationReconciliationProof? {
        guard ownerEpoch > 0,
            snapshot.generation > 0,
            provesRequestedState(
                of: command,
                expectedIsDirectory: expectedIsDirectory,
                createTargetWasAbsent: createTargetWasAbsent,
                sourceRelativePath: sourceRelativePath,
                snapshot: snapshot
            )
        else {
            return nil
        }

        var evidence = Data("psy-mutation-requested-state-v1".utf8)
        func append(_ value: String) {
            evidence.append(0)
            evidence.append(Data(value.utf8))
        }
        append(command.id.uuidString.lowercased())
        append(command.kind.rawValue)
        append(command.folderID?.rawValue ?? "")
        append(command.itemID ?? "")
        append(expectedIsDirectory.map(String.init) ?? "")
        append(createTargetWasAbsent.map(String.init) ?? "")
        append(sourceRelativePath ?? "")
        append(String(snapshot.generation))
        if command.kind == .delete {
            append("stable-id-tombstone-and-no-live-item")
        } else if let folderID = command.folderID,
            let target = target(for: command, folderID: folderID, snapshot: snapshot)
        {
            append(target.relativePath)
            append(target.parentItemID ?? "")
            append(command.kind == .move ? "target-live-source-local-and-global-absent" : "target-live")
        }
        return CoreMutationReconciliationProof(
            snapshotGeneration: snapshot.generation,
            ownerEpoch: ownerEpoch,
            stateDigest: Data(SHA256.hash(data: evidence))
        )
    }
}

extension MutationReconciler {
    private struct Target {
        let relativePath: String
        let parentItemID: String?
    }

    private func target(
        for command: CoreCommand,
        folderID: FolderID,
        snapshot: CoreSnapshot
    ) -> Target? {
        guard let parentIdentifier = command.arguments["parentIdentifier"],
            let filename = command.arguments["filename"],
            Self.isSafeFilename(filename)
        else {
            return nil
        }

        let parentPath: String
        let parentItemID: String?
        if parentIdentifier == Self.folderProviderIdentifier(folderID) {
            parentPath = ""
            parentItemID = nil
        } else {
            let prefix = "item-"
            guard parentIdentifier.hasPrefix(prefix) else { return nil }
            let rawParentID = String(parentIdentifier.dropFirst(prefix.count))
            guard !rawParentID.isEmpty,
                let parent = snapshot.items.only(where: {
                    $0.id == rawParentID && $0.folderID == folderID && $0.isDirectory
                }),
                Self.isSafeRelativePath(parent.relativePath)
            else {
                return nil
            }
            parentPath = parent.relativePath
            parentItemID = rawParentID
        }
        let relativePath = parentPath.isEmpty ? filename : parentPath + "/" + filename
        guard Self.isSafeRelativePath(relativePath) else { return nil }
        return Target(relativePath: relativePath, parentItemID: parentItemID)
    }

    private func authoritativeItem(
        for command: CoreCommand,
        folderID: FolderID,
        target: Target,
        expectedIsDirectory: Bool,
        snapshot: CoreSnapshot
    ) -> IndexedItem? {
        switch command.kind {
        case .create:
            return snapshot.items.only {
                $0.folderID == folderID
                    && $0.relativePath == target.relativePath
                    && $0.isDirectory == expectedIsDirectory
            }
        case .modify, .move:
            guard let itemID = command.itemID, !itemID.isEmpty else { return nil }
            return snapshot.items.only {
                $0.id == itemID
                    && $0.folderID == folderID
                    && $0.relativePath == target.relativePath
                    && $0.isDirectory == expectedIsDirectory
            }
        default:
            return nil
        }
    }

    private func safeFolderRoot(for folder: FolderRecord) -> URL? {
        guard folder.localPath.hasPrefix("/") else { return nil }
        let advertised = URL(fileURLWithPath: folder.localPath, isDirectory: true)
            .standardizedFileURL

        if let managed = try? paths.validatedManagedFolder(for: folder.id),
            Self.sameResolvedPath(advertised, managed)
        {
            return managed
        }

        let externalParent = paths.externalManagedFoldersRoot.standardizedFileURL
        let candidateComponents = advertised.pathComponents
        let parentComponents = externalParent.pathComponents
        guard candidateComponents.count == parentComponents.count + 1,
            Array(candidateComponents.prefix(parentComponents.count)) == parentComponents,
            let token = candidateComponents.last,
            let id = UUID(uuidString: token),
            id.uuidString.lowercased() == token.lowercased(),
            let external = try? paths.validatedExternalManagedRoot(for: token),
            Self.sameResolvedPath(advertised, external)
        else {
            return nil
        }
        return external
    }

    private func securelyValidateExistingTarget(
        relativePath: String,
        isDirectory: Bool,
        folderRoot: URL
    ) -> Bool {
        guard Self.isSafeRelativePath(relativePath) else { return false }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let rootDescriptor = folderRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else { return false }
        defer { close(rootDescriptor) }

        var directoryDescriptor = rootDescriptor
        var ownedDirectoryDescriptor: Int32?
        defer {
            if let ownedDirectoryDescriptor {
                close(ownedDirectoryDescriptor)
            }
        }
        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else { return false }
            if let ownedDirectoryDescriptor {
                close(ownedDirectoryDescriptor)
            }
            ownedDirectoryDescriptor = nextDescriptor
            directoryDescriptor = nextDescriptor
        }

        var flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        if isDirectory { flags |= O_DIRECTORY }
        let targetDescriptor = components[components.count - 1].withCString {
            openat(directoryDescriptor, $0, flags)
        }
        guard targetDescriptor >= 0 else { return false }
        defer { close(targetDescriptor) }

        var status = stat()
        guard fstat(targetDescriptor, &status) == 0 else { return false }
        let itemType = status.st_mode & mode_t(S_IFMT)
        return itemType == (isDirectory ? mode_t(S_IFDIR) : mode_t(S_IFREG))
    }

    private func securelyObserveTargetAbsence(
        relativePath: String,
        folderRoot: URL,
        missingAncestorIsAbsence: Bool = false
    ) -> Bool? {
        guard Self.isSafeRelativePath(relativePath) else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let rootDescriptor = folderRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else { return nil }
        defer { close(rootDescriptor) }

        var directoryDescriptor = rootDescriptor
        var ownedDirectoryDescriptor: Int32?
        defer {
            if let ownedDirectoryDescriptor {
                close(ownedDirectoryDescriptor)
            }
        }
        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                return missingAncestorIsAbsence && errno == ENOENT ? true : nil
            }
            if let ownedDirectoryDescriptor {
                close(ownedDirectoryDescriptor)
            }
            ownedDirectoryDescriptor = nextDescriptor
            directoryDescriptor = nextDescriptor
        }

        var status = stat()
        let result = components[components.count - 1].withCString {
            fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return false }
        return errno == ENOENT ? true : nil
    }

    private static func folderProviderIdentifier(_ folderID: FolderID) -> String {
        let digest = SHA256.hash(data: Data(folderID.rawValue.utf8))
        return "folder-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        (1...255).contains(value.utf8.count)
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains(":")
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("\0")
            && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private static func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

extension Array {
    fileprivate func only(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        let matches = try filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }
}
