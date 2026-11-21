import CryptoKit
import FileProvider
import Foundation
import PsyCore
import UniformTypeIdentifiers

enum ProviderDomainScope: Hashable, Sendable {
    case legacyAggregate
    case folder(FolderID)

    func contains(_ folderID: FolderID) -> Bool {
        switch self {
        case .legacyAggregate: true
        case .folder(let scopedFolderID): scopedFolderID == folderID
        }
    }

    var rootFolderID: FolderID? {
        guard case .folder(let folderID) = self else { return nil }
        return folderID
    }
}

enum ProviderSupport {
    static func providerError(_ code: NSFileProviderError.Code, itemIdentifier: NSFileProviderItemIdentifier? = nil)
        -> NSError
    {
        var info: [String: Any] = [:]
        if let itemIdentifier { info[NSFileProviderErrorItemKey] = itemIdentifier }
        return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue, userInfo: info)
    }

    static func folderIdentifier(_ folderID: FolderID) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(FileProviderDomainIdentity.folderItemIdentifier(for: folderID))
    }

    static func itemIdentifier(_ id: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier("item-\(id)")
    }

    static func commandUUID(operation: String, components: [String]) -> UUID {
        var input = Data(operation.utf8)
        for component in components {
            input.append(0)
            input.append(Data(component.utf8))
        }
        let bytes = Array(SHA256.hash(data: input).prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    static func rawItemID(_ identifier: NSFileProviderItemIdentifier) -> String? {
        let prefix = "item-"
        guard identifier.rawValue.hasPrefix(prefix) else { return nil }
        return String(identifier.rawValue.dropFirst(prefix.count))
    }

    static func versionData(_ generation: UInt64, suffix: Data = Data()) -> Data {
        var value = generation.bigEndian
        var data = Data(bytes: &value, count: MemoryLayout<UInt64>.size)
        data.append(suffix.prefix(120))
        return data.prefix(128)
    }

    static func anchor(
        _ generation: UInt64,
        cursor: IndexedMetadataChangeCursor? = nil,
        shareRevision: Data? = nil
    ) -> NSFileProviderSyncAnchor {
        var data = Data([0xA1])
        data.append(bigEndianData(generation))
        if let cursor {
            data.append(2)
            data.append(bigEndianData(cursor.generation))
            data.append(bigEndianData(UInt64(bitPattern: cursor.sequence)))
            data.append(bigEndianData(cursor.rowOffset))
        } else {
            data.append(0)
        }
        if let shareRevision, shareRevision.count == 32 {
            data[0] = 0xA2
            data.append(shareRevision)
        }
        return NSFileProviderSyncAnchor(data)
    }

    static func anchorValues(_ anchor: NSFileProviderSyncAnchor) -> ProviderAnchorValues? {
        let data = anchor.rawValue
        if data.first == 0xA2, data.count >= 42 {
            var legacy = Data(data.dropLast(32))
            legacy[0] = 0xA1
            guard var result = anchorValues(NSFileProviderSyncAnchor(legacy)) else { return nil }
            result.shareRevision = Data(data.suffix(32))
            return result
        }
        // Accept the first-generation eight-byte anchor so existing domains can migrate.
        if data.count == 8 {
            return ProviderAnchorValues(
                generation: readBigEndianUInt64(data, offset: 0),
                cursor: nil
            )
        }
        guard data.count >= 10, data[0] == 0xA1 else { return nil }
        let generation = readBigEndianUInt64(data, offset: 1)
        switch data[9] {
        case 0 where data.count == 10:
            return ProviderAnchorValues(generation: generation, cursor: nil)
        case 1 where data.count == 26:
            // Version-one continuation anchors did not bind the cursor to its
            // lower-bound enumeration. Expire them instead of accepting a token
            // that cannot be proven to represent a complete page boundary.
            return nil
        case 2 where data.count == 34:
            let cursorGeneration = readBigEndianUInt64(data, offset: 10)
            let rowOffset = readBigEndianUInt64(data, offset: 26)
            guard cursorGeneration > generation, rowOffset > 0 else { return nil }
            return ProviderAnchorValues(
                generation: generation,
                cursor: IndexedMetadataChangeCursor(
                    generation: cursorGeneration,
                    sequence: Int64(bitPattern: readBigEndianUInt64(data, offset: 18)),
                    rowOffset: rowOffset
                )
            )
        default:
            return nil
        }
    }

    static func page(generation: UInt64, offset: UInt64) -> NSFileProviderPage {
        var data = Data([0xB1, 0])
        data.append(bigEndianData(generation))
        data.append(bigEndianData(offset))
        return NSFileProviderPage(data)
    }

    static func sharePage(generation: UInt64, offset: UInt64) -> NSFileProviderPage {
        var data = Data([0xB1, 2])
        data.append(bigEndianData(generation))
        data.append(bigEndianData(offset))
        return NSFileProviderPage(data)
    }

    static func itemPage(generation: UInt64, lastItemID: String) -> NSFileProviderPage? {
        let identifier = Data(lastItemID.utf8)
        guard !identifier.isEmpty, identifier.count <= 470 else { return nil }
        var data = Data([0xB1, 1])
        data.append(bigEndianData(generation))
        data.append(identifier)
        guard data.count <= 500 else { return nil }
        return NSFileProviderPage(data)
    }

    static func pageValues(_ page: NSFileProviderPage) -> ProviderPageValues? {
        let data = page.rawValue
        // Migrate the original generation+offset token emitted by early builds.
        if data.count == 16 {
            return ProviderPageValues(
                generation: readBigEndianUInt64(data, offset: 0),
                position: .offset(readBigEndianUInt64(data, offset: 8))
            )
        }
        guard data.count >= 10, data[0] == 0xB1 else { return nil }
        let generation = readBigEndianUInt64(data, offset: 2)
        switch data[1] {
        case 0 where data.count == 18:
            return ProviderPageValues(
                generation: generation,
                position: .offset(readBigEndianUInt64(data, offset: 10))
            )
        case 2 where data.count == 18:
            return ProviderPageValues(
                generation: generation, position: .shareOffset(readBigEndianUInt64(data, offset: 10)))
        case 1:
            let identifierData = data.subdata(in: 10..<data.count)
            guard let identifier = String(data: identifierData, encoding: .utf8), !identifier.isEmpty else {
                return nil
            }
            return ProviderPageValues(generation: generation, position: .itemID(identifier))
        default:
            return nil
        }
    }

    private static func bigEndianData(_ value: UInt64) -> Data {
        var value = value.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt64>.size)
    }

    private static func readBigEndianUInt64(_ data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
    }

    static func snapshot(paths suppliedPaths: SharedContainerPaths? = nil) throws -> CoreSnapshot {
        let paths = try suppliedPaths ?? SharedContainerPaths.resolve()
        return try SharedSnapshotStore(snapshotURL: paths.snapshot).readProviderMetadata() ?? CoreSnapshot()
    }

    static func fullSnapshot(matching snapshot: CoreSnapshot, paths: SharedContainerPaths) throws -> CoreSnapshot {
        if snapshot.providerMetadataGeneration == nil { return snapshot }
        guard var full = try SharedSnapshotStore(snapshotURL: paths.snapshot).read(),
            full.generation == snapshot.generation,
            full.configurationRevision == snapshot.configurationRevision
        else { throw providerError(.syncAnchorExpired) }
        full.providerMetadataGeneration = snapshot.providerMetadataGeneration
        return full
    }

    static func metadataGeneration(_ snapshot: CoreSnapshot) -> UInt64 {
        snapshot.providerMetadataGeneration ?? snapshot.generation
    }

    static func domainScope(
        identifier: String,
        snapshot: CoreSnapshot
    ) -> ProviderDomainScope? {
        if identifier == FileProviderDomainIdentity.legacyAggregateIdentifier {
            return .legacyAggregate
        }
        guard
            let folder = FileProviderDomainIdentity.folder(
                in: snapshot,
                matching: identifier
            )
        else { return nil }
        return .folder(folder.id)
    }

    static func rootDisplayName(
        scope: ProviderDomainScope,
        snapshot: CoreSnapshot
    ) -> String {
        guard case .folder(let folderID) = scope,
            let folder = uniqueFolder(folderID, snapshot: snapshot)
        else { return "Psynguechthyngue" }
        return folder.label.isEmpty ? folder.id.rawValue : folder.label
    }

    static func folder(for identifier: NSFileProviderItemIdentifier, snapshot: CoreSnapshot) -> FolderRecord? {
        let matches = UniqueFolderIdentityIndex(snapshot.folders).uniqueFolders.filter {
            folderIdentifier($0.id) == identifier
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func metadataScope(
        for container: NSFileProviderItemIdentifier,
        snapshot: CoreSnapshot,
        paths suppliedPaths: SharedContainerPaths? = nil,
        domainIdentifier: String
    ) async throws -> IndexedMetadataContainerScope? {
        guard let domainScope = domainScope(identifier: domainIdentifier, snapshot: snapshot) else {
            return nil
        }
        if container == .workingSet {
            return domainScope.rootFolderID.map(IndexedMetadataContainerScope.folderWorkingSet)
                ?? .workingSet
        }
        if container == .rootContainer, let folderID = domainScope.rootFolderID {
            return .folderRoot(folderID)
        }
        if case .legacyAggregate = domainScope,
            let folder = folder(for: container, snapshot: snapshot)
        {
            return .folderRoot(folder.id)
        }
        if let itemID = rawItemID(container),
            let item = try await resolvedIndexedItem(
                for: container, snapshot: snapshot, paths: suppliedPaths ?? SharedContainerPaths.resolve(),
                domainIdentifier: domainIdentifier),
            domainScope.contains(item.folderID)
        {
            return .directory(itemID: itemID)
        }
        return nil
    }

    static func item(
        for identifier: NSFileProviderItemIdentifier,
        snapshot: CoreSnapshot,
        domainIdentifier: String
    ) -> ProviderItem? {
        guard let domainScope = domainScope(identifier: domainIdentifier, snapshot: snapshot) else {
            return nil
        }
        if identifier == .rootContainer {
            return ProviderItem.root(
                displayName: rootDisplayName(scope: domainScope, snapshot: snapshot),
                generation: snapshot.generation,
                mutationAccess: rootMutationAccess(
                    scope: domainScope,
                    snapshot: snapshot
                )
            )
        }
        if case .legacyAggregate = domainScope,
            let folder = folder(for: identifier, snapshot: snapshot)
        {
            return ProviderItem(
                folder: folder, generation: metadataGeneration(snapshot),
                displayName: FileProviderShareCatalog.names(for: snapshot.folders)[folder.id])
        }
        guard let id = rawItemID(identifier),
            let item = snapshot.items.first(where: { $0.id == id }),
            domainScope.contains(item.folderID),
            uniqueFolder(item.folderID, snapshot: snapshot) != nil
        else {
            return nil
        }
        return ProviderItem(indexed: item, rootFolderID: domainScope.rootFolderID)
    }

    static func resolvedIndexedItem(
        for identifier: NSFileProviderItemIdentifier,
        snapshot: CoreSnapshot,
        paths: SharedContainerPaths,
        domainIdentifier: String
    ) async throws -> IndexedItem? {
        guard let id = rawItemID(identifier) else { return nil }
        guard let domainScope = domainScope(identifier: domainIdentifier, snapshot: snapshot) else {
            return nil
        }
        var resolved: IndexedItem? = nil
        do {
            let store = try IndexedMetadataStore(
                databaseURL: paths.metadataIndex,
                accessMode: .readOnly,
                recoveryPolicy: .fail
            )
            guard try await store.currentGeneration() == snapshot.generation else {
                resolved = try fullSnapshot(matching: snapshot, paths: paths).items.first { $0.id == id }
                if let resolved, domainScope.contains(resolved.folderID) {
                    return try ContentRetentionIntentResolver(
                        metadataDatabaseURL: paths.metadataIndex
                    ).applying(to: resolved)
                }
                return nil
            }
            resolved = try await store.item(identifier: id, expectedGeneration: snapshot.generation)
        } catch {
            resolved = try fullSnapshot(matching: snapshot, paths: paths).items.first { $0.id == id }
        }
        guard let resolved, domainScope.contains(resolved.folderID) else { return nil }
        return try ContentRetentionIntentResolver(
            metadataDatabaseURL: paths.metadataIndex
        ).applying(to: resolved)
    }

    static func resolvedItem(
        for identifier: NSFileProviderItemIdentifier,
        snapshot: CoreSnapshot,
        paths: SharedContainerPaths,
        domainIdentifier: String
    ) async throws -> ProviderItem? {
        guard let domainScope = domainScope(identifier: domainIdentifier, snapshot: snapshot) else {
            return nil
        }
        if identifier == .rootContainer {
            return ProviderItem.root(
                displayName: rootDisplayName(scope: domainScope, snapshot: snapshot),
                generation: snapshot.generation,
                mutationAccess: rootMutationAccess(
                    scope: domainScope,
                    snapshot: snapshot
                )
            )
        }
        if case .legacyAggregate = domainScope,
            let folder = folder(for: identifier, snapshot: snapshot)
        {
            return ProviderItem(
                folder: folder,
                generation: metadataGeneration(snapshot),
                displayName: FileProviderShareCatalog.names(for: snapshot.folders)[folder.id],
                mutationAccess: FileProviderMutationAccess.evaluate(
                    folder: folder,
                    item: nil
                )
            )
        }
        guard
            let item = try await resolvedIndexedItem(
                for: identifier,
                snapshot: snapshot,
                paths: paths,
                domainIdentifier: domainIdentifier
            )
        else {
            return nil
        }
        return try providerItem(
            indexed: item,
            snapshot: snapshot,
            paths: paths,
            domainIdentifier: domainIdentifier
        )
    }

    static func resolvedParentContext(
        for identifier: NSFileProviderItemIdentifier,
        snapshot: CoreSnapshot,
        paths: SharedContainerPaths,
        domainIdentifier: String
    ) async throws -> ProviderParentContext? {
        guard let domainScope = domainScope(identifier: domainIdentifier, snapshot: snapshot) else {
            return nil
        }
        if identifier == .rootContainer, let folderID = domainScope.rootFolderID {
            return ProviderParentContext(
                folderID: folderID,
                itemID: nil,
                relativePath: "",
                indexedItem: nil
            )
        }
        if case .legacyAggregate = domainScope,
            let folder = folder(for: identifier, snapshot: snapshot)
        {
            return ProviderParentContext(
                folderID: folder.id,
                itemID: nil,
                relativePath: "",
                indexedItem: nil
            )
        }
        guard
            let item = try await resolvedIndexedItem(
                for: identifier,
                snapshot: snapshot,
                paths: paths,
                domainIdentifier: domainIdentifier
            ), item.isDirectory
        else {
            return nil
        }
        return ProviderParentContext(
            folderID: item.folderID,
            itemID: item.id,
            relativePath: item.relativePath,
            indexedItem: item
        )
    }

    static func providerItem(
        indexed item: IndexedItem,
        snapshot: CoreSnapshot,
        paths: SharedContainerPaths,
        domainIdentifier: String
    ) throws -> ProviderItem {
        guard let domainScope = domainScope(identifier: domainIdentifier, snapshot: snapshot),
            domainScope.contains(item.folderID)
        else {
            throw providerError(.noSuchItem, itemIdentifier: itemIdentifier(item.id))
        }
        guard let folder = uniqueFolder(item.folderID, snapshot: snapshot) else {
            throw ScopedCoreCommandProducerError.folderUnavailable(item.folderID.rawValue)
        }
        return ProviderItem(
            indexed: item,
            mutationAccess: FileProviderMutationAccess.evaluate(
                folder: folder,
                item: item
            ),
            rootFolderID: domainScope.rootFolderID
        )
    }

    private static func rootMutationAccess(
        scope: ProviderDomainScope,
        snapshot: CoreSnapshot
    ) -> FileProviderMutationAccess {
        guard let folderID = scope.rootFolderID,
            let folder = uniqueFolder(folderID, snapshot: snapshot)
        else {
            return .readOnly
        }
        return FileProviderMutationAccess.evaluate(folder: folder, item: nil)
    }

    static func requireBridgeMutationAccess(
        _ kind: ProviderMutationKind,
        folderID: FolderID,
        item: IndexedItem?,
        snapshot: CoreSnapshot,
        paths: SharedContainerPaths,
        itemIdentifier: NSFileProviderItemIdentifier
    ) throws {
        guard let folder = uniqueFolder(folderID, snapshot: snapshot) else {
            throw providerError(.cannotSynchronize, itemIdentifier: itemIdentifier)
        }
        let access = FileProviderMutationAccess.evaluate(
            folder: folder,
            item: item
        )
        guard access.allows(kind) else {
            throw providerError(.cannotSynchronize, itemIdentifier: itemIdentifier)
        }
    }

    static func resolvedIndexedItem(
        inFolder folderID: FolderID,
        relativePath: String,
        snapshot: CoreSnapshot,
        paths: SharedContainerPaths
    ) async throws -> IndexedItem? {
        var resolved: IndexedItem? = nil
        do {
            let store = try IndexedMetadataStore(
                databaseURL: paths.metadataIndex,
                accessMode: .readOnly,
                recoveryPolicy: .fail
            )
            guard try await store.currentGeneration() == snapshot.generation else {
                resolved = try fullSnapshot(matching: snapshot, paths: paths).items.first {
                    $0.folderID == folderID && $0.relativePath == relativePath
                }
                if let resolved {
                    return try ContentRetentionIntentResolver(
                        metadataDatabaseURL: paths.metadataIndex
                    ).applying(to: resolved)
                }
                return nil
            }
            resolved = try await store.item(
                inFolder: folderID, relativePath: relativePath, expectedGeneration: snapshot.generation)
        } catch {
            resolved = try fullSnapshot(matching: snapshot, paths: paths).items.first {
                $0.folderID == folderID && $0.relativePath == relativePath
            }
        }
        guard let resolved else { return nil }
        return try ContentRetentionIntentResolver(
            metadataDatabaseURL: paths.metadataIndex
        ).applying(to: resolved)
    }

    static func childRelativePath(parent: ProviderParentContext, filename: String) -> String {
        parent.relativePath.isEmpty ? filename : parent.relativePath + "/" + filename
    }

    /// File Provider container identifiers are presentation-scoped. The Go
    /// bridge accepts only its canonical folder-root identifier or a stable
    /// bridge item identifier, so normalize after resolving the parent and
    /// before persisting a mutation command.
    static func bridgeParentIdentifier(_ parent: ProviderParentContext) -> String {
        parent.itemID.map { itemIdentifier($0).rawValue }
            ?? FileProviderDomainIdentity.folderItemIdentifier(for: parent.folderID)
    }

    static func itemVersion(for item: IndexedItem) -> NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: (item.contentVersion.isEmpty
                ? versionData(item.generation) : item.contentVersion).prefix(128),
            metadataVersion: (item.metadataVersion.isEmpty
                ? versionData(item.generation) : item.metadataVersion).prefix(128)
        )
    }

    static func mutationPrecondition(
        for folderID: FolderID,
        snapshot: CoreSnapshot,
        paths: SharedContainerPaths
    ) throws -> ProviderMutationPrecondition {
        let matches = snapshot.folders.lazy.filter { $0.id == folderID }.count
        guard matches == 1 else {
            if matches > 1 {
                throw ScopedCoreCommandProducerError.duplicateFolder(folderID.rawValue)
            }
            throw ScopedCoreCommandProducerError.folderUnavailable(folderID.rawValue)
        }
        guard let configurationRevision = snapshot.configurationRevision else {
            throw ScopedCoreCommandProducerError.configurationRevisionUnavailable
        }
        let context: FolderPolicyContext
        do {
            context = try FolderIncarnationStore(url: paths.folderIncarnations)
                .policyContext(for: folderID)
        } catch {
            throw ScopedCoreCommandProducerError.folderIncarnationUnavailable(
                folderID.rawValue
            )
        }
        return ProviderMutationPrecondition(
            configurationRevision: configurationRevision,
            folderIncarnationDigest: context.folderIncarnationDigest
        )
    }

    static func parentFolderID(
        for identifier: NSFileProviderItemIdentifier,
        snapshot: CoreSnapshot,
        domainIdentifier: String
    ) -> FolderID? {
        guard let domainScope = domainScope(identifier: domainIdentifier, snapshot: snapshot) else {
            return nil
        }
        if identifier == .rootContainer, let folderID = domainScope.rootFolderID {
            return folderID
        }
        if case .legacyAggregate = domainScope,
            let folder = folder(for: identifier, snapshot: snapshot)
        {
            return folder.id
        }
        guard let id = rawItemID(identifier), let item = snapshot.items.first(where: { $0.id == id }) else {
            return nil
        }
        guard domainScope.contains(item.folderID),
            uniqueFolder(item.folderID, snapshot: snapshot) != nil
        else { return nil }
        return item.folderID
    }

    private static func uniqueFolder(
        _ folderID: FolderID,
        snapshot: CoreSnapshot
    ) -> FolderRecord? {
        UniqueFolderIdentityIndex(snapshot.folders).folder(folderID)
    }
}

struct ProviderAnchorValues {
    var generation: UInt64
    var cursor: IndexedMetadataChangeCursor?
    var shareRevision: Data? = nil
}

struct ProviderParentContext: Hashable, Sendable {
    var folderID: FolderID
    var itemID: String?
    var relativePath: String
    var indexedItem: IndexedItem?
}

enum ProviderMutationKind: Hashable, Sendable {
    case create
    case modify
    case rename
    case reparent
    case delete
}

extension FileProviderMutationAccess {
    fileprivate func allows(_ kind: ProviderMutationKind) -> Bool {
        switch kind {
        case .create: allowsAddingSubItems
        case .modify: allowsWriting
        case .rename: allowsRenaming
        case .reparent: allowsReparenting
        case .delete: allowsDeleting
        }
    }
}

struct ProviderMutationPrecondition: Hashable, Sendable {
    var configurationRevision: String
    var folderIncarnationDigest: String
}

enum ProviderPagePosition {
    case shareOffset(UInt64)
    case offset(UInt64)
    case itemID(String)
}

struct ProviderPageValues {
    var generation: UInt64
    var position: ProviderPagePosition
}

final class ProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let typeIdentifier: String
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    let isDownloaded: Bool
    let isDownloading: Bool
    let isUploaded: Bool
    let isUploading: Bool
    let contentPolicy: NSFileProviderContentPolicy
    let downloadingError: Error?
    let uploadingError: Error?

    init(
        identifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        typeIdentifier: String,
        capabilities: NSFileProviderItemCapabilities,
        size: Int64?,
        modifiedAt: Date?,
        contentVersion: Data,
        metadataVersion: Data,
        downloaded: Bool,
        downloading: Bool,
        uploaded: Bool,
        uploading: Bool,
        contentPolicy: NSFileProviderContentPolicy = .inherited,
        downloadingError: Error? = nil,
        uploadingError: Error? = nil
    ) {
        itemIdentifier = identifier
        parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.typeIdentifier = typeIdentifier
        self.capabilities = capabilities
        documentSize = size.map(NSNumber.init(value:))
        contentModificationDate = modifiedAt
        itemVersion = NSFileProviderItemVersion(
            contentVersion: contentVersion.prefix(128),
            metadataVersion: metadataVersion.prefix(128)
        )
        isDownloaded = downloaded
        isDownloading = downloading
        isUploaded = uploaded
        isUploading = uploading
        self.contentPolicy = contentPolicy
        self.downloadingError = downloadingError
        self.uploadingError = uploadingError
    }

    static func root(
        displayName: String,
        generation: UInt64,
        mutationAccess: FileProviderMutationAccess = .readOnly
    ) -> ProviderItem {
        var capabilities: NSFileProviderItemCapabilities = [
            .allowsReading, .allowsContentEnumerating,
        ]
        if mutationAccess.allowsAddingSubItems { capabilities.insert(.allowsAddingSubItems) }
        return ProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: displayName,
            typeIdentifier: UTType.folder.identifier,
            capabilities: capabilities,
            size: nil,
            modifiedAt: nil,
            contentVersion: ProviderSupport.versionData(generation),
            metadataVersion: ProviderSupport.versionData(generation),
            downloaded: true,
            downloading: false,
            uploaded: true,
            uploading: false,
            contentPolicy: .downloadLazilyAndEvictOnRemoteUpdate
        )
    }

    convenience init(
        folder: FolderRecord,
        generation: UInt64,
        displayName: String? = nil,
        mutationAccess: FileProviderMutationAccess = .readOnly
    ) {
        var capabilities: NSFileProviderItemCapabilities = [
            .allowsReading, .allowsContentEnumerating,
        ]
        if mutationAccess.allowsAddingSubItems { capabilities.insert(.allowsAddingSubItems) }
        self.init(
            identifier: ProviderSupport.folderIdentifier(folder.id),
            parentIdentifier: .rootContainer,
            filename: displayName
                ?? FileProviderShareCatalog.safeComponent(folder.label.isEmpty ? folder.id.rawValue : folder.label),
            typeIdentifier: UTType.folder.identifier,
            capabilities: capabilities,
            size: nil,
            modifiedAt: nil,
            contentVersion: ProviderSupport.versionData(generation),
            metadataVersion: ProviderSupport.versionData(generation),
            downloaded: true,
            downloading: false,
            uploaded: folder.pendingUploadBytes == 0,
            uploading: folder.pendingUploadBytes > 0,
            contentPolicy: .inherited,
            uploadingError: folder.error.map {
                NSError(
                    domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: $0]
                )
            }
        )
    }

    convenience init(
        indexed item: IndexedItem,
        mutationAccess: FileProviderMutationAccess = .readOnly,
        rootFolderID: FolderID? = nil
    ) {
        let parent =
            item.parentID.map(ProviderSupport.itemIdentifier)
            ?? (rootFolderID == item.folderID
                ? .rootContainer
                : ProviderSupport.folderIdentifier(item.folderID))
        let filename = URL(fileURLWithPath: item.relativePath).lastPathComponent
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading]
        if mutationAccess.allowsWriting { capabilities.insert(.allowsWriting) }
        if mutationAccess.allowsRenaming { capabilities.insert(.allowsRenaming) }
        if mutationAccess.allowsReparenting { capabilities.insert(.allowsReparenting) }
        if mutationAccess.allowsDeleting { capabilities.insert(.allowsDeleting) }
        if item.isDirectory {
            capabilities.insert(.allowsContentEnumerating)
            if mutationAccess.allowsAddingSubItems { capabilities.insert(.allowsAddingSubItems) }
        }
        // Directory removal is coordinated item-by-item by the App because a
        // recursive system eviction may partially succeed. For a regular file
        // the replicated File Provider consumes the exact-version isUploaded
        // status and independently rejects unsynced edits.
        if !item.isDirectory, item.isUploaded {
            capabilities.insert(.allowsEvicting)
        }
        let type =
            item.isDirectory
            ? UTType.folder.identifier
            : (UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension)?.identifier
                ?? UTType.data.identifier)
        let error =
            item.availability == .error
            ? NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
            : nil
        self.init(
            identifier: ProviderSupport.itemIdentifier(item.id),
            parentIdentifier: parent,
            filename: filename,
            typeIdentifier: type,
            capabilities: capabilities,
            size: item.isDirectory ? nil : item.size,
            modifiedAt: item.modifiedAt,
            contentVersion: item.contentVersion.isEmpty
                ? ProviderSupport.versionData(item.generation) : item.contentVersion,
            metadataVersion: item.metadataVersion.isEmpty
                ? ProviderSupport.versionData(item.generation) : item.metadataVersion,
            downloaded: item.availability == .local || item.availability == .uploading,
            downloading: item.availability == .downloading,
            uploaded: item.isUploaded,
            uploading: item.isUploading,
            // iOS does not expose downloadEagerlyAndKeepDownloaded (that
            // enum case is macOS-only in the current SDK). Retention is a
            // durable App intent: pinned items are proactively requested and
            // re-requested after cache loss, while the replicated provider
            // truthfully reports the iOS lazy/evictable cache policy.
            contentPolicy: .downloadLazilyAndEvictOnRemoteUpdate,
            downloadingError: error,
            uploadingError: error
        )
    }
}
