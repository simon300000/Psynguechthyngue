import Darwin
@preconcurrency import FileProvider
import Foundation
import PsyCore
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension,
    NSFileProviderCustomAction
{
    private static let keepDownloadedAction = NSFileProviderExtensionActionIdentifier(
        "moe.simon3k.Psynguechthyngue.keep-downloaded"
    )
    private static let removeDownloadAction = NSFileProviderExtensionActionIdentifier(
        "moe.simon3k.Psynguechthyngue.remove-download"
    )
    private static let materializedFilePrefix = "psy-fp-materialized-"
    private static let runtimeTemporaryFilePrefix = ".psy-materialize-"
    private static let staleTemporaryFileAge: TimeInterval = 24 * 60 * 60
    private static let bridgeMutationFields: NSFileProviderItemFields = [
        .contents, .filename, .parentItemIdentifier,
    ]

    private struct InvocationStaging {
        let token: String
        let createdByThisInvocation: Bool
    }

    private let domain: NSFileProviderDomain
    private let domainIdentifier: String
    private let manager: NSFileProviderManager?
    private let maintenanceTaskState = ProviderMaintenanceTaskState()

    required init(domain: NSFileProviderDomain) {
        let registeredDomainIdentifier = domain.identifier.rawValue
        self.domain = domain
        domainIdentifier = registeredDomainIdentifier
        manager = NSFileProviderManager(for: domain)
        super.init()
        if let manager { Self.removeStaleOwnedTemporaryFiles(using: manager) }
        if let manager { schedulePendingMaterializedSetReconciliation(using: manager) }
    }

    func invalidate() {
        maintenanceTaskState.cancel()
    }

    private func schedulePendingMaterializedSetReconciliation(
        using manager: NSFileProviderManager
    ) {
        let manager = ProviderManagerBox(manager)
        let identifier = domainIdentifier
        let taskID = UUID()
        let state = maintenanceTaskState
        let task = Task.detached(priority: .utility) { @Sendable in
            defer { state.clear(taskID: taskID) }
            do {
                guard
                    let paths = try? SharedContainerPaths.resolve(),
                    (try? ContentRetentionStore(url: paths.contentRetention)
                        .isMaterializedSetReconciliationPending(
                            domainIdentifier: identifier
                        )) == true
                else { return }
                try Task.checkCancellation()
                await Self.reconcileMaterializedSet(
                    using: manager.value,
                    domainIdentifier: identifier
                )
            } catch {
                // The durable marker remains set for a later extension/App/BG
                // opportunity. Cancellation must never be converted to success.
            }
        }
        state.install(task, taskID: taskID)
    }

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(max(1, itemIdentifiers.count)))
        let completion = ProviderActionCompletionBox(completionHandler)
        guard
            actionIdentifier == Self.keepDownloadedAction
                || actionIdentifier == Self.removeDownloadAction,
            !itemIdentifiers.isEmpty,
            itemIdentifiers.count <= 200
        else {
            completion.fail(CocoaError(.featureUnsupported))
            return progress
        }
        let progressBox = ProviderProgressBox(progress)
        let operation = ProviderAsyncOperation {
            [manager, domainIdentifier = domain.identifier.rawValue] in
            do {
                guard let manager else {
                    throw ProviderSupport.providerError(.serverUnreachable)
                }
                try await Self.performRetentionAction(
                    actionIdentifier,
                    itemIdentifiers: itemIdentifiers,
                    manager: manager,
                    domainIdentifier: domainIdentifier,
                    progress: progressBox
                )
                completion.succeed()
            } catch {
                completion.fail(Self.supported(error))
            }
        }
        let work = Task.detached(priority: .userInitiated) { await operation.run() }
        progress.cancellationHandler = {
            work.cancel()
            completion.cancel()
        }
        return progress
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = ItemCompletionBox(itemIdentifier: identifier, handler: completionHandler)
        let progressBox = ProviderProgressBox(progress)
        let operation = ProviderAsyncOperation {
            [domainIdentifier = domain.identifier.rawValue] in
            do {
                let paths = try SharedContainerPaths.resolve()
                let snapshot = try ProviderSupport.snapshot()
                guard
                    let item = try await ProviderSupport.resolvedItem(
                        for: identifier,
                        snapshot: snapshot,
                        paths: paths,
                        domainIdentifier: domainIdentifier
                    )
                else {
                    completion.fail(ProviderSupport.providerError(.noSuchItem, itemIdentifier: identifier))
                    return
                }
                progressBox.progress.completedUnitCount = 1
                completion.succeed(item)
            } catch {
                completion.fail(Self.supported(error))
            }
        }
        let work = Task.detached(priority: .userInitiated) { await operation.run() }
        progress.cancellationHandler = {
            work.cancel()
            completion.cancel()
        }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        guard let manager else {
            completionHandler(
                nil,
                nil,
                ProviderSupport.providerError(.serverUnreachable, itemIdentifier: itemIdentifier)
            )
            return progress
        }
        let completion = FetchCompletionBox(
            manager: manager,
            itemIdentifier: itemIdentifier,
            handler: completionHandler
        )
        let progressBox = ProviderProgressBox(progress)
        let operation = ProviderAsyncOperation {
            [domainIdentifier = domain.identifier.rawValue] in
            do {
                let paths = try SharedContainerPaths.resolve()
                let snapshot = try ProviderSupport.snapshot()
                guard
                    let indexed = try await ProviderSupport.resolvedIndexedItem(
                        for: itemIdentifier,
                        snapshot: snapshot,
                        paths: paths,
                        domainIdentifier: domainIdentifier
                    ),
                    !indexed.isDirectory,
                    UniqueFolderIdentityIndex(snapshot.folders).folder(indexed.folderID) != nil
                else {
                    completion.fail(ProviderSupport.providerError(.noSuchItem, itemIdentifier: itemIdentifier))
                    return
                }

                if let requestedVersion,
                    !indexed.contentVersion.isEmpty && requestedVersion.contentVersion != indexed.contentVersion
                {
                    completion.fail(ProviderSupport.providerError(.cannotSynchronize, itemIdentifier: itemIdentifier))
                    return
                }

                let destination = try completion.manager.temporaryDirectoryURL()
                    .appendingPathComponent(Self.materializedFilePrefix + UUID().uuidString.lowercased())
                await PlatformCoreBootstrap.install()
                let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                let outcome = await Self.materializeWhenAvailable(
                    indexed, destination: destination, paths: paths, environment: environment, progress: progressBox)
                guard outcome.completedSuccessfully else {
                    completion.fail(
                        Self.executionError(
                            materializationOutcome: outcome,
                            itemIdentifier: completion.itemIdentifier
                        )
                    )
                    return
                }
                let materializedSnapshot = try ProviderSupport.snapshot()
                guard
                    let materialized = try await ProviderSupport.resolvedIndexedItem(
                        for: itemIdentifier,
                        snapshot: materializedSnapshot, paths: paths, domainIdentifier: domainIdentifier),
                    FileProviderDeliveryFence(item: indexed).matches(materialized)
                else {
                    try? FileManager.default.removeItem(at: destination)
                    throw CocoaError(.fileReadUnknown)
                }
                progressBox.progress.completedUnitCount = 100
                if !completion.succeed(
                    destination,
                    item: try ProviderSupport.providerItem(
                        indexed: materialized,
                        snapshot: materializedSnapshot,
                        paths: paths,
                        domainIdentifier: domainIdentifier
                    )
                ) {
                    try? FileManager.default.removeItem(at: destination)
                }
            } catch {
                completion.fail(Self.supported(error))
            }
        }
        let work = Task.detached(priority: .userInitiated) { await operation.run() }
        progress.cancellationHandler = {
            work.cancel()
            completion.cancel()
        }
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let isDirectory = itemTemplate.contentType == .folder
        let mayAlreadyExist = options.contains(.mayAlreadyExist)
        do {
            // The SDK defines template properties absent from `fields` as
            // undefined. A durable create needs an explicit location, and a
            // supplied transfer URL is authoritative only for `.contents`.
            guard fields.contains(.filename),
                fields.contains(.parentItemIdentifier),
                url == nil || (!isDirectory && fields.contains(.contents)),
                !fields.contains(.contents) || url != nil || isDirectory || mayAlreadyExist
            else {
                throw ProviderSupport.providerError(
                    .cannotSynchronize,
                    itemIdentifier: itemTemplate.itemIdentifier
                )
            }
            try validateFilename(itemTemplate.filename)
            let stillPendingFields = fields.subtracting(Self.bridgeMutationFields)
            let commandID = ProviderSupport.commandUUID(
                operation: "create",
                components: (domainIdentifier == FileProviderDomainIdentity.legacyAggregateIdentifier
                    ? [] : [domainIdentifier])
                    + [
                        itemTemplate.itemIdentifier.rawValue,
                        itemTemplate.parentItemIdentifier.rawValue,
                        itemTemplate.filename,
                    ]
            )
            let pending = pendingItem(
                template: itemTemplate, identifier: ProviderSupport.itemIdentifier(commandID.uuidString.lowercased()))
            let completion = MutationCompletionBox(
                pendingItem: pending,
                requestedFields: fields,
                stillPendingFields: stillPendingFields,
                handler: completionHandler
            )
            let progressBox = ProviderProgressBox(progress)
            let enqueueGate = MutationEnqueueGate()
            let parentIdentifier = itemTemplate.parentItemIdentifier
            let filename = itemTemplate.filename
            let stagedContents = url
            let deletionConflicted = options.contains(.deletionConflicted)
            let templateIdentifier = itemTemplate.itemIdentifier
            let templateVersion = itemTemplate.itemVersion
            let operation = ProviderAsyncOperation {
                [domainIdentifier = domain.identifier.rawValue] in
                do {
                    try Task.checkCancellation()
                    let paths = try SharedContainerPaths.resolve()
                    let snapshot = try ProviderSupport.snapshot()
                    guard
                        let parent = try await ProviderSupport.resolvedParentContext(
                            for: parentIdentifier,
                            snapshot: snapshot,
                            paths: paths,
                            domainIdentifier: domainIdentifier
                        )
                    else {
                        completion.fail(
                            ProviderSupport.providerError(.noSuchItem, itemIdentifier: parentIdentifier)
                        )
                        return
                    }
                    try ProviderSupport.requireBridgeMutationAccess(
                        .create,
                        folderID: parent.folderID,
                        item: parent.indexedItem,
                        snapshot: snapshot,
                        paths: paths,
                        itemIdentifier: parentIdentifier
                    )
                    let precondition = try ProviderSupport.mutationPrecondition(
                        for: parent.folderID,
                        snapshot: snapshot,
                        paths: paths
                    )
                    let relativePath = ProviderSupport.childRelativePath(parent: parent, filename: filename)
                    let existing = try await ProviderSupport.resolvedIndexedItem(
                        inFolder: parent.folderID,
                        relativePath: relativePath,
                        snapshot: snapshot,
                        paths: paths
                    )
                    if mayAlreadyExist {
                        if let existing,
                            try Self.isSafeReimportMatch(
                                existing,
                                isDirectory: isDirectory,
                                templateVersion: templateVersion,
                                suppliedContents: stagedContents,
                                commandID: commandID,
                                paths: paths,
                                progress: progressBox
                            )
                        {
                            progressBox.progress.completedUnitCount = 100
                            completion.succeed(
                                try ProviderSupport.providerItem(
                                    indexed: existing,
                                    snapshot: snapshot,
                                    paths: paths,
                                    domainIdentifier: domainIdentifier
                                )
                            )
                            return
                        }
                        if stagedContents == nil, !isDirectory {
                            // A dataless file reimport that cannot be matched must
                            // be refused without creating an empty remote object.
                            // A directory has no contents URL even when it is new;
                            // create it so Files can subsequently import children
                            // instead of recursively deleting the local tree.
                            progressBox.progress.completedUnitCount = 100
                            completion.succeedWithoutItem()
                            return
                        }
                    }
                    if let existing {
                        completion.fail(
                            NSError.fileProviderErrorForCollision(
                                with: try ProviderSupport.providerItem(
                                    indexed: existing,
                                    snapshot: snapshot,
                                    paths: paths,
                                    domainIdentifier: domainIdentifier
                                )
                            )
                        )
                        return
                    }
                    if deletionConflicted {
                        guard ProviderSupport.rawItemID(templateIdentifier) != nil,
                            try await ProviderSupport.resolvedIndexedItem(
                                for: templateIdentifier,
                                snapshot: snapshot,
                                paths: paths,
                                domainIdentifier: domainIdentifier
                            ) == nil
                        else {
                            completion.fail(
                                ProviderSupport.providerError(
                                    .cannotSynchronize,
                                    itemIdentifier: templateIdentifier
                                )
                            )
                            return
                        }
                    }
                    guard isDirectory || stagedContents != nil else {
                        completion.fail(
                            ProviderSupport.providerError(
                                .cannotSynchronize,
                                itemIdentifier: completion.itemIdentifier
                            )
                        )
                        return
                    }
                    var arguments = [
                        "parentIdentifier": ProviderSupport.bridgeParentIdentifier(parent),
                        "filename": filename,
                        "isDirectory": String(isDirectory),
                        "fileProviderOperation": "createAndPropagate",
                    ]
                    if stagedContents != nil {
                        arguments["stagedContentToken"] = Self.stagedContentToken(id: commandID)
                    }
                    let command = try ScopedCoreCommandProducer(paths: paths).prepareCommands(
                        invocationID: commandID,
                        kind: .create,
                        folderID: parent.folderID,
                        arguments: arguments,
                        expectedFolderIncarnationDigest: precondition.folderIncarnationDigest,
                        expectedConfigurationRevision: precondition.configurationRevision,
                        trigger: .fileProvider
                    ).first
                    guard let command else {
                        throw ScopedCoreCommandProducerError.folderScopeRequired(.create)
                    }
                    try Self.stageIfNeededAndEnqueue(
                        stagedContents,
                        command: command,
                        paths: paths,
                        progress: progressBox,
                        enqueueGate: enqueueGate
                    )
                    await PlatformCoreBootstrap.install()
                    let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                    let execution = await CoreCommandExecutor().execute(
                        [command], trigger: .fileProvider,
                        paths: paths, environment: environment,
                        currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) },
                        maximumPasses: 8, timeout: .seconds(20))
                    let outcome = execution.outcome ?? .failed(code: "file_provider_queue_pending")
                    let queue = CoreCommandQueue(root: paths.commandQueue)
                    let result = try queue.result(for: commandID)
                    guard result?.status == .succeeded else {
                        let collisionItem = try? await Self.collisionItem(
                            errorCode: result?.errorCode,
                            folderID: parent.folderID,
                            relativePath: relativePath,
                            paths: paths,
                            domainIdentifier: domainIdentifier
                        )
                        completion.fail(
                            Self.executionError(
                                result: result,
                                outcome: outcome,
                                itemIdentifier: completion.itemIdentifier,
                                parentIdentifier: parentIdentifier,
                                collisionItem: collisionItem
                            )
                        )
                        return
                    }
                    let committedSnapshot = try ProviderSupport.snapshot()
                    guard
                        let committed = try await ProviderSupport.resolvedIndexedItem(
                            inFolder: parent.folderID,
                            relativePath: relativePath,
                            snapshot: committedSnapshot,
                            paths: paths
                        )
                    else {
                        completion.fail(
                            ProviderSupport.providerError(
                                .cannotSynchronize,
                                itemIdentifier: completion.itemIdentifier
                            )
                        )
                        return
                    }
                    let committedItem = try ProviderSupport.providerItem(
                        indexed: committed,
                        snapshot: committedSnapshot,
                        paths: paths,
                        domainIdentifier: domainIdentifier
                    )
                    try? FileProviderStagingStore(root: paths.fileProviderStaging)
                        .release(id: commandID)
                    progressBox.progress.completedUnitCount = 100
                    completion.succeed(committedItem)
                } catch {
                    completion.fail(Self.supported(error))
                }
            }
            let work = Task.detached(priority: .userInitiated) { await operation.run() }
            progress.cancellationHandler = {
                let cancellation = enqueueGate.cancel {
                    completion.reserveCancellation()
                }
                cancellation?()
                work.cancel()
            }
        } catch {
            completionHandler(nil, fields, false, Self.supported(error))
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        do {
            try validateFilename(item.filename)
            let actionableFields = changedFields.intersection(Self.bridgeMutationFields)
            let stillPendingFields = changedFields.subtracting(Self.bridgeMutationFields)
            let requestsContentsChange = changedFields.contains(.contents)
            let requestsFilenameChange = changedFields.contains(.filename)
            let requestsParentChange = changedFields.contains(.parentItemIdentifier)
            let requestsMove = requestsFilenameChange || requestsParentChange
            let commandID = ProviderSupport.commandUUID(
                operation: requestsMove ? "move" : "modify",
                components: [
                    item.itemIdentifier.rawValue,
                    item.parentItemIdentifier.rawValue,
                    item.filename,
                    version.contentVersion.base64EncodedString(),
                    version.metadataVersion.base64EncodedString(),
                ]
            )
            let pending = pendingItem(template: item, identifier: item.itemIdentifier)
            let completion = MutationCompletionBox(
                pendingItem: pending,
                requestedFields: changedFields,
                stillPendingFields: stillPendingFields,
                handler: completionHandler
            )
            let progressBox = ProviderProgressBox(progress)
            let enqueueGate = MutationEnqueueGate()
            let itemIdentifier = item.itemIdentifier
            let parentIdentifier = item.parentItemIdentifier
            let filename = item.filename
            let stagedContents = newContents
            let contentVersion = version.contentVersion
            let metadataVersion = version.metadataVersion
            let mayAlreadyExist = options.contains(.mayAlreadyExist)
            let failOnConflict: Bool
            if #available(iOS 26.0, *) {
                failOnConflict = options.contains(.failOnConflict)
            } else {
                failOnConflict = false
            }
            let operation = ProviderAsyncOperation {
                [domainIdentifier = domain.identifier.rawValue] in
                do {
                    try Task.checkCancellation()
                    let paths = try SharedContainerPaths.resolve()
                    let snapshot = try ProviderSupport.snapshot()
                    guard
                        let current = try await ProviderSupport.resolvedIndexedItem(
                            for: itemIdentifier,
                            snapshot: snapshot,
                            paths: paths,
                            domainIdentifier: domainIdentifier
                        )
                    else {
                        completion.fail(
                            ProviderSupport.providerError(.noSuchItem, itemIdentifier: itemIdentifier)
                        )
                        return
                    }
                    let stagingStore = FileProviderStagingStore(root: paths.fileProviderStaging)
                    let incomingDigest = try stagedContents.map { url in
                        try CoordinatedFileAccess().read(at: url) { source in
                            try stagingStore.sourceContentDigest(
                                source, cancellationCheck: { try Task<Never, Never>.checkCancellation() })
                        }
                    }
                    if ProviderSupport.itemVersion(for: current) != version {
                        if #available(iOS 26.0, *), failOnConflict {
                            completion.fail(
                                ProviderSupport.providerError(
                                    .localVersionConflictingWithServer, itemIdentifier: itemIdentifier))
                            return
                        }
                        if requestsContentsChange, let stagedContents, let incomingDigest, !current.isDirectory,
                            !failOnConflict
                        {
                            try await Self.preserveConflictedContents(
                                stagedContents, digest: incomingDigest,
                                current: current, baseContentVersion: contentVersion,
                                baseMetadataVersion: metadataVersion,
                                snapshot: snapshot, paths: paths, domainIdentifier: domainIdentifier,
                                progress: progressBox, enqueueGate: enqueueGate)
                            let latest = try ProviderSupport.snapshot()
                            guard
                                let resolved = try await ProviderSupport.resolvedItem(
                                    for: itemIdentifier, snapshot: latest, paths: paths,
                                    domainIdentifier: domainIdentifier)
                            else {
                                throw ProviderSupport.providerError(.serverUnreachable, itemIdentifier: itemIdentifier)
                            }
                            completion.succeed(resolved)
                        } else if !requestsContentsChange {
                            // Resolve concurrent metadata edits to the authoritative
                            // location. No content is discarded by this resolution.
                            completion.succeed(
                                try ProviderSupport.providerItem(
                                    indexed: current,
                                    snapshot: snapshot, paths: paths, domainIdentifier: domainIdentifier))
                        } else {
                            completion.fail(CocoaError(.fileWriteUnknown))
                        }
                        return
                    }
                    let operationCommandID =
                        incomingDigest.map { digest in
                            ProviderSupport.commandUUID(
                                operation: "content-bound-modify-v2",
                                components: [commandID.uuidString, digest.base64EncodedString()])
                        } ?? commandID
                    if actionableFields.isEmpty {
                        progressBox.progress.completedUnitCount = 100
                        completion.succeed(
                            try ProviderSupport.providerItem(
                                indexed: current,
                                snapshot: snapshot,
                                paths: paths,
                                domainIdentifier: domainIdentifier
                            )
                        )
                        return
                    }
                    guard stagedContents == nil || requestsContentsChange,
                        !requestsContentsChange || (!current.isDirectory && stagedContents != nil)
                    else {
                        completion.fail(
                            ProviderSupport.providerError(
                                .cannotSynchronize,
                                itemIdentifier: itemIdentifier
                            )
                        )
                        return
                    }
                    let currentParentIdentifier =
                        current.parentID.map(ProviderSupport.itemIdentifier)
                        ?? (ProviderSupport.domainScope(
                            identifier: domainIdentifier,
                            snapshot: snapshot
                        )?.rootFolderID == current.folderID
                            ? .rootContainer
                            : ProviderSupport.folderIdentifier(current.folderID))
                    let currentFilename = URL(fileURLWithPath: current.relativePath).lastPathComponent
                    let isRename = filename != currentFilename
                    let isReparent = parentIdentifier != currentParentIdentifier
                    let isMove = isRename || isReparent
                    guard !isRename || requestsFilenameChange,
                        !isReparent || requestsParentChange
                    else {
                        completion.fail(
                            ProviderSupport.providerError(.cannotSynchronize, itemIdentifier: itemIdentifier)
                        )
                        return
                    }
                    if !isMove, !requestsContentsChange {
                        progressBox.progress.completedUnitCount = 100
                        completion.succeed(
                            try ProviderSupport.providerItem(
                                indexed: current,
                                snapshot: snapshot,
                                paths: paths,
                                domainIdentifier: domainIdentifier
                            )
                        )
                        return
                    }
                    guard
                        let targetParent = try await ProviderSupport.resolvedParentContext(
                            for: parentIdentifier,
                            snapshot: snapshot,
                            paths: paths,
                            domainIdentifier: domainIdentifier
                        ), targetParent.folderID == current.folderID
                    else {
                        // Cross-folder moves require a transactional copy+delete protocol and
                        // are rejected until the bridge can prove both halves committed.
                        completion.fail(
                            ProviderSupport.providerError(.cannotSynchronize, itemIdentifier: itemIdentifier)
                        )
                        return
                    }
                    let relativePath = ProviderSupport.childRelativePath(
                        parent: targetParent,
                        filename: filename
                    )
                    let targetAtDestination =
                        isMove
                        ? try await ProviderSupport.resolvedIndexedItem(
                            inFolder: current.folderID,
                            relativePath: relativePath,
                            snapshot: snapshot,
                            paths: paths
                        )
                        : nil
                    let mergeTarget: IndexedItem?
                    if let targetAtDestination, targetAtDestination.id != current.id {
                        if mayAlreadyExist,
                            await Self.canMergeExistingItem(
                                current,
                                with: targetAtDestination,
                                requestsContentsChange: requestsContentsChange,
                                suppliedContents: stagedContents,
                                baseVersion: version,
                                snapshot: snapshot,
                                paths: paths
                            )
                        {
                            mergeTarget = targetAtDestination
                        } else {
                            completion.fail(
                                NSError.fileProviderErrorForCollision(
                                    with: try ProviderSupport.providerItem(
                                        indexed: targetAtDestination,
                                        snapshot: snapshot,
                                        paths: paths,
                                        domainIdentifier: domainIdentifier
                                    )
                                )
                            )
                            return
                        }
                    } else {
                        mergeTarget = nil
                    }
                    if mergeTarget != nil {
                        try ProviderSupport.requireBridgeMutationAccess(
                            .delete,
                            folderID: current.folderID,
                            item: current,
                            snapshot: snapshot,
                            paths: paths,
                            itemIdentifier: itemIdentifier
                        )
                    } else if isRename {
                        try ProviderSupport.requireBridgeMutationAccess(
                            .rename,
                            folderID: current.folderID,
                            item: current,
                            snapshot: snapshot,
                            paths: paths,
                            itemIdentifier: itemIdentifier
                        )
                    }
                    if mergeTarget == nil, isReparent {
                        try ProviderSupport.requireBridgeMutationAccess(
                            .reparent,
                            folderID: current.folderID,
                            item: current,
                            snapshot: snapshot,
                            paths: paths,
                            itemIdentifier: itemIdentifier
                        )
                        try ProviderSupport.requireBridgeMutationAccess(
                            .create,
                            folderID: targetParent.folderID,
                            item: targetParent.indexedItem,
                            snapshot: snapshot,
                            paths: paths,
                            itemIdentifier: parentIdentifier
                        )
                    }
                    if mergeTarget == nil, !isMove {
                        try ProviderSupport.requireBridgeMutationAccess(
                            .modify,
                            folderID: current.folderID,
                            item: current,
                            snapshot: snapshot,
                            paths: paths,
                            itemIdentifier: itemIdentifier
                        )
                    }
                    let precondition = try ProviderSupport.mutationPrecondition(
                        for: current.folderID,
                        snapshot: snapshot,
                        paths: paths
                    )
                    var arguments: [String: String]
                    let commandKind: CoreCommandKind
                    let effectiveCommandID: UUID
                    if let mergeTarget {
                        commandKind = .delete
                        effectiveCommandID = ProviderSupport.commandUUID(
                            operation: "merge-delete",
                            components: [
                                current.id,
                                mergeTarget.id,
                                contentVersion.base64EncodedString(),
                                metadataVersion.base64EncodedString(),
                            ]
                        )
                        arguments = [
                            "baseContentVersion": contentVersion.base64EncodedString(),
                            "baseMetadataVersion": metadataVersion.base64EncodedString(),
                            "propagatesToPeers": "true",
                            "recursive": "false",
                        ]
                    } else {
                        commandKind = isMove ? .move : .modify
                        effectiveCommandID = operationCommandID
                        arguments = [
                            "filename": filename,
                            "parentIdentifier": ProviderSupport.bridgeParentIdentifier(
                                targetParent
                            ),
                            "baseContentVersion": contentVersion.base64EncodedString(),
                            "baseMetadataVersion": metadataVersion.base64EncodedString(),
                            "fileProviderOperation": "modifyAndPropagate",
                        ]
                    }
                    if mergeTarget == nil, stagedContents != nil {
                        arguments["stagedContentToken"] = Self.stagedContentToken(
                            id: effectiveCommandID
                        )
                    }
                    let command = try ScopedCoreCommandProducer(paths: paths).prepareCommands(
                        invocationID: effectiveCommandID,
                        kind: commandKind,
                        folderID: current.folderID,
                        itemID: current.id,
                        arguments: arguments,
                        expectedFolderIncarnationDigest: precondition.folderIncarnationDigest,
                        expectedConfigurationRevision: precondition.configurationRevision,
                        trigger: .fileProvider
                    ).first
                    guard let command else {
                        throw ScopedCoreCommandProducerError.folderScopeRequired(
                            commandKind
                        )
                    }
                    try Self.stageIfNeededAndEnqueue(
                        mergeTarget == nil ? stagedContents : nil,
                        command: command,
                        expectedDigest: mergeTarget == nil ? incomingDigest : nil,
                        paths: paths,
                        progress: progressBox,
                        enqueueGate: enqueueGate
                    )
                    await PlatformCoreBootstrap.install()
                    let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                    let execution = await CoreCommandExecutor().execute(
                        [command], trigger: .fileProvider,
                        paths: paths, environment: environment,
                        currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) },
                        maximumPasses: 8, timeout: .seconds(20))
                    let outcome = execution.outcome ?? .failed(code: "file_provider_queue_pending")
                    let queue = CoreCommandQueue(root: paths.commandQueue)
                    let result = try queue.result(for: effectiveCommandID)
                    guard result?.status == .succeeded else {
                        let collisionItem = try? await Self.collisionItem(
                            errorCode: result?.errorCode,
                            folderID: current.folderID,
                            relativePath: relativePath,
                            paths: paths,
                            domainIdentifier: domainIdentifier
                        )
                        completion.fail(
                            Self.executionError(
                                result: result,
                                outcome: outcome,
                                itemIdentifier: completion.itemIdentifier,
                                parentIdentifier: parentIdentifier,
                                collisionItem: collisionItem
                            )
                        )
                        return
                    }
                    let committedSnapshot = try ProviderSupport.snapshot()
                    if let mergeTarget {
                        guard
                            let committedTarget = try await ProviderSupport.resolvedIndexedItem(
                                for: ProviderSupport.itemIdentifier(mergeTarget.id),
                                snapshot: committedSnapshot,
                                paths: paths,
                                domainIdentifier: domainIdentifier
                            )
                        else {
                            completion.fail(
                                ProviderSupport.providerError(
                                    .cannotSynchronize,
                                    itemIdentifier: itemIdentifier
                                )
                            )
                            return
                        }
                        progressBox.progress.completedUnitCount = 100
                        completion.succeed(
                            try ProviderSupport.providerItem(
                                indexed: committedTarget,
                                snapshot: committedSnapshot,
                                paths: paths,
                                domainIdentifier: domainIdentifier
                            )
                        )
                        return
                    }
                    let sameIdentifier = try await ProviderSupport.resolvedIndexedItem(
                        for: itemIdentifier,
                        snapshot: committedSnapshot,
                        paths: paths,
                        domainIdentifier: domainIdentifier
                    )
                    let committed: IndexedItem?
                    if sameIdentifier?.relativePath == relativePath {
                        committed = sameIdentifier
                    } else {
                        committed = try await ProviderSupport.resolvedIndexedItem(
                            inFolder: current.folderID,
                            relativePath: relativePath,
                            snapshot: committedSnapshot,
                            paths: paths
                        )
                    }
                    guard let committed else {
                        completion.fail(
                            ProviderSupport.providerError(.cannotSynchronize, itemIdentifier: itemIdentifier)
                        )
                        return
                    }
                    let committedItem = try ProviderSupport.providerItem(
                        indexed: committed,
                        snapshot: committedSnapshot,
                        paths: paths,
                        domainIdentifier: domainIdentifier
                    )
                    try? FileProviderStagingStore(root: paths.fileProviderStaging)
                        .release(id: effectiveCommandID)
                    progressBox.progress.completedUnitCount = 100
                    completion.succeed(committedItem)
                } catch {
                    completion.fail(Self.supported(error))
                }
            }
            let work = Task.detached(priority: .userInitiated) { await operation.run() }
            progress.cancellationHandler = {
                let cancellation = enqueueGate.cancel {
                    completion.reserveCancellation()
                }
                cancellation?()
                work.cancel()
            }
        } catch {
            completionHandler(nil, changedFields, false, Self.supported(error))
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completion = DeleteCompletionBox(itemIdentifier: identifier, handler: completionHandler)
        let progressBox = ProviderProgressBox(progress)
        let enqueueGate = MutationEnqueueGate()
        let recursive = options.contains(.recursive)
        let contentVersion = version.contentVersion
        let metadataVersion = version.metadataVersion
        let operation = ProviderAsyncOperation {
            [domainIdentifier = domain.identifier.rawValue] in
            do {
                try Task.checkCancellation()
                let paths = try SharedContainerPaths.resolve()
                let snapshot = try ProviderSupport.snapshot()
                guard let rawItemID = ProviderSupport.rawItemID(identifier) else {
                    completion.fail(ProviderSupport.providerError(.noSuchItem, itemIdentifier: identifier))
                    return
                }
                guard
                    let indexed = try await ProviderSupport.resolvedIndexedItem(
                        for: identifier,
                        snapshot: snapshot,
                        paths: paths,
                        domainIdentifier: domainIdentifier
                    )
                else {
                    // Idempotent retry: an item already absent from the authoritative
                    // projection has already reached the requested delete state.
                    progressBox.progress.completedUnitCount = 1
                    completion.succeed()
                    return
                }
                guard ProviderSupport.itemVersion(for: indexed) == version else {
                    completion.fail(
                        NSError.fileProviderErrorForRejectedDeletion(
                            of: try ProviderSupport.providerItem(
                                indexed: indexed,
                                snapshot: snapshot,
                                paths: paths,
                                domainIdentifier: domainIdentifier
                            )
                        )
                    )
                    return
                }
                try ProviderSupport.requireBridgeMutationAccess(
                    .delete,
                    folderID: indexed.folderID,
                    item: indexed,
                    snapshot: snapshot,
                    paths: paths,
                    itemIdentifier: identifier
                )
                let precondition = try ProviderSupport.mutationPrecondition(
                    for: indexed.folderID,
                    snapshot: snapshot,
                    paths: paths
                )
                let commandID = ProviderSupport.commandUUID(
                    operation: "delete",
                    components: [
                        identifier.rawValue,
                        contentVersion.base64EncodedString(),
                        metadataVersion.base64EncodedString(),
                        String(recursive),
                    ]
                )
                let command = try ScopedCoreCommandProducer(paths: paths).prepareCommands(
                    invocationID: commandID,
                    kind: .delete,
                    folderID: indexed.folderID,
                    itemID: rawItemID,
                    arguments: [
                        "baseContentVersion": contentVersion.base64EncodedString(),
                        "baseMetadataVersion": metadataVersion.base64EncodedString(),
                        "propagatesToPeers": "true",
                        "recursive": String(recursive),
                    ],
                    expectedFolderIncarnationDigest: precondition.folderIncarnationDigest,
                    expectedConfigurationRevision: precondition.configurationRevision,
                    trigger: .fileProvider
                ).first
                guard let command else {
                    throw ScopedCoreCommandProducerError.folderScopeRequired(.delete)
                }
                try enqueueGate.enqueue {
                    try Self.enqueueMutationAndPropagation(command, paths: paths)
                }
                await PlatformCoreBootstrap.install()
                let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
                let execution = await CoreCommandExecutor().execute(
                    [command], trigger: .fileProvider,
                    paths: paths, environment: environment,
                    currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) },
                    maximumPasses: 8, timeout: .seconds(20))
                let outcome = execution.outcome ?? .failed(code: "file_provider_queue_pending")
                let queue = CoreCommandQueue(root: paths.commandQueue)
                let result = try queue.result(for: commandID)
                guard result?.status == .succeeded else {
                    completion.fail(
                        Self.executionError(
                            result: result,
                            outcome: outcome,
                            itemIdentifier: completion.itemIdentifier,
                            deletionItem: try ProviderSupport.providerItem(
                                indexed: indexed,
                                snapshot: snapshot,
                                paths: paths,
                                domainIdentifier: domainIdentifier
                            )
                        )
                    )
                    return
                }
                progressBox.progress.completedUnitCount = 1
                completion.succeed()
            } catch {
                completion.fail(Self.supported(error))
            }
        }
        let work = Task.detached(priority: .userInitiated) { await operation.run() }
        progress.cancellationHandler = {
            let cancellation = enqueueGate.cancel {
                completion.reserveCancellation()
            }
            cancellation?()
            work.cancel()
        }
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        let snapshot = try ProviderSupport.snapshot()
        guard
            ProviderSupport.domainScope(
                identifier: domainIdentifier,
                snapshot: snapshot
            ) != nil
        else {
            throw ProviderSupport.providerError(.noSuchItem, itemIdentifier: containerItemIdentifier)
        }
        if containerItemIdentifier != .rootContainer,
            containerItemIdentifier != .workingSet,
            ProviderSupport.folder(for: containerItemIdentifier, snapshot: snapshot) == nil,
            ProviderSupport.rawItemID(containerItemIdentifier) == nil
        {
            throw ProviderSupport.providerError(.noSuchItem, itemIdentifier: containerItemIdentifier)
        }
        return ProviderEnumerator(
            container: containerItemIdentifier,
            domainIdentifier: domainIdentifier
        )
    }

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        let completion = ProviderVoidCompletionBox(completionHandler)
        guard let manager else {
            completion.call()
            return
        }
        let managerBox = ProviderManagerBox(manager)
        let domainIdentifier = domainIdentifier
        let taskID = UUID()
        let state = maintenanceTaskState
        let task = Task.detached(priority: .utility) { @Sendable in
            defer { state.clear(taskID: taskID) }
            if let paths = try? SharedContainerPaths.resolve() {
                try? ContentRetentionStore(url: paths.contentRetention)
                    .markMaterializedSetReconciliationPending(
                        domainIdentifier: domainIdentifier
                    )
            }
            // Apple expects this callback to finish within a few seconds. The
            // durable marker above makes the longer reconciliation restartable.
            completion.call()
            guard !Task.isCancelled else { return }
            await Self.reconcileMaterializedSet(
                using: managerBox.value,
                domainIdentifier: domainIdentifier
            )
        }
        state.install(task, taskID: taskID)
    }

    func pendingItemsDidChange(completionHandler: @escaping () -> Void) {
        let completion = ProviderVoidCompletionBox(completionHandler)
        guard let manager else {
            completion.call()
            return
        }
        // The system pending set is deliberately supplementary status, never
        // upload/download authority. Ask Files to re-enumerate our truthful
        // item flags and return immediately.
        manager.signalEnumerator(for: .workingSet) { _ in completion.call() }
    }

    private static func reconcileMaterializedSet(
        using manager: NSFileProviderManager,
        domainIdentifier: String
    ) async {
        guard let paths = try? SharedContainerPaths.resolve() else { return }
        let retentionStore = ContentRetentionStore(url: paths.contentRetention)
        do {
            let materialized = try await MaterializedItemSetCollector.collect(
                from: manager.enumeratorForMaterializedItems()
            )
            try Task.checkCancellation()
            let snapshot = try ProviderSupport.snapshot()
            guard
                let domainScope = ProviderSupport.domainScope(
                    identifier: domainIdentifier,
                    snapshot: snapshot
                )
            else { return }
            guard let revision = snapshot.configurationRevision,
                revision.count == 64,
                revision.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else { return }
            let uniqueFolders = UniqueFolderIdentityIndex(snapshot.folders)
            let incarnations = Dictionary(
                uniqueKeysWithValues: try FolderIncarnationStore(
                    url: paths.folderIncarnations
                ).snapshot().records.map { ($0.folderID, $0.folderIncarnationDigest) }
            )
            let metadata = try IndexedMetadataStore(
                databaseURL: paths.metadataIndex,
                accessMode: .readOnly,
                recoveryPolicy: .fail
            )
            guard try await metadata.currentGeneration() == snapshot.generation else { return }

            var cursor: IndexedItemPageCursor?
            var pinnedItems: [String] = []
            try FileProviderReplicaStore(url: paths.fileProviderReplicaState).replaceObservedIdentifiers(
                Set(materialized.map(\.rawValue)))
            repeat {
                try Task.checkCancellation()
                let page = try await metadata.allItems(after: cursor, limit: 500)
                for item in page.items where !item.isDirectory && domainScope.contains(item.folderID) {
                    guard !materialized.contains(ProviderSupport.itemIdentifier(item.id)),
                        uniqueFolders.folder(item.folderID) != nil,
                        let incarnation = incarnations[item.folderID]
                    else { continue }
                    if try retentionStore.status(for: item, folderIncarnationDigest: incarnation).isPinned {
                        pinnedItems.append(item.id)
                    }
                }
                cursor = page.nextCursor
            } while cursor != nil
            // A system cache observation never creates a core eviction command.
            // Syncthing may still hold the only complete local copy.
            try Task.checkCancellation()
            try retentionStore.completeMaterializedSetReconciliation(
                domainIdentifier: domainIdentifier
            )
            if case .legacyAggregate = domainScope {
                try retentionStore.completeMaterializedSetReconciliation()
            }
            for itemID in pinnedItems {
                try Task.checkCancellation()
                try? await manager.requestDownloadForItem(
                    withIdentifier: ProviderSupport.itemIdentifier(itemID)
                )
            }
            try? await manager.signalEnumerator(for: .workingSet)
        } catch {
            // Leave the durable marker set. Extension recreation, a later
            // system callback, or a background opportunity will retry.
        }
    }

    private static func materializeWhenAvailable(
        _ item: IndexedItem, destination: URL, paths: SharedContainerPaths,
        environment: SyncEnvironmentSnapshot, progress: ProviderProgressBox
    ) async -> CoreMaterializationOutcome {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !Task.isCancelled {
            let outcome = await CoreRuntime.shared.materialize(
                item, to: destination, trigger: .fileProvider,
                paths: paths, environment: environment,
                currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) },
                progress: { completed, total in
                    if total > 0 { progress.progress.completedUnitCount = min(99, completed * 99 / total) }
                })
            guard case .coreBusy = outcome, ContinuousClock.now < deadline else { return outcome }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
        }
        return .failed(code: "cancelled")
    }

    private static func preserveConflictedContents(
        _ contents: URL, digest: Data, current: IndexedItem,
        baseContentVersion: Data, baseMetadataVersion: Data,
        snapshot: CoreSnapshot, paths: SharedContainerPaths, domainIdentifier: String,
        progress: ProviderProgressBox, enqueueGate: MutationEnqueueGate
    ) async throws {
        let precondition = try ProviderSupport.mutationPrecondition(
            for: current.folderID, snapshot: snapshot, paths: paths)
        let parentID =
            current.parentID.map(ProviderSupport.itemIdentifier)
            ?? (ProviderSupport.domainScope(identifier: domainIdentifier, snapshot: snapshot)?.rootFolderID
                == current.folderID
                ? .rootContainer : ProviderSupport.folderIdentifier(current.folderID))
        guard
            let parent = try await ProviderSupport.resolvedParentContext(
                for: parentID, snapshot: snapshot, paths: paths, domainIdentifier: domainIdentifier)
        else {
            throw ProviderSupport.providerError(.serverUnreachable, itemIdentifier: parentID)
        }
        try ProviderSupport.requireBridgeMutationAccess(
            .create, folderID: current.folderID, item: parent.indexedItem,
            snapshot: snapshot, paths: paths, itemIdentifier: parentID)
        let plan = FileProviderConflictPlan(
            item: current, baseContentVersion: baseContentVersion,
            baseMetadataVersion: baseMetadataVersion, contentDigest: digest,
            incarnation: precondition.folderIncarnationDigest)
        let relativePath = ProviderSupport.childRelativePath(parent: parent, filename: plan.filename)
        let staging = FileProviderStagingStore(root: paths.fileProviderStaging)
        if let existing = try await ProviderSupport.resolvedIndexedItem(
            inFolder: current.folderID, relativePath: relativePath, snapshot: snapshot, paths: paths)
        {
            guard !existing.isDirectory,
                try staging.managedContentDigest(
                    root: paths.validatedManagedFolder(for: current.folderID), relativePath: existing.relativePath,
                    cancellationCheck: { try Task<Never, Never>.checkCancellation() }) == digest
            else { throw CocoaError(.fileWriteUnknown) }
            return
        }
        guard
            let command = try ScopedCoreCommandProducer(paths: paths).prepareCommands(
                invocationID: plan.commandID,
                kind: .create, folderID: current.folderID,
                arguments: [
                    "parentIdentifier": ProviderSupport.bridgeParentIdentifier(parent), "filename": plan.filename,
                    "isDirectory": "false", "fileProviderOperation": "createAndPropagate",
                    "stagedContentToken": stagedContentToken(id: plan.commandID),
                ],
                expectedFolderIncarnationDigest: precondition.folderIncarnationDigest,
                expectedConfigurationRevision: precondition.configurationRevision, trigger: .fileProvider
            ).first
        else { throw CocoaError(.fileWriteUnknown) }
        try stageIfNeededAndEnqueue(
            contents, command: command, expectedDigest: digest, paths: paths, progress: progress,
            enqueueGate: enqueueGate)
        await PlatformCoreBootstrap.install()
        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        let execution = await CoreCommandExecutor().execute(
            [command], trigger: .fileProvider, paths: paths,
            environment: environment,
            currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) },
            maximumPasses: 8, timeout: .seconds(20))
        guard execution.succeeded else { throw CocoaError(.fileWriteUnknown) }
        // Re-read and verify the actual committed payload before acknowledging
        // an edit that the system is then allowed to replace with remote data.
        let latest = try ProviderSupport.snapshot()
        guard
            let retained = try await ProviderSupport.resolvedIndexedItem(
                inFolder: current.folderID, relativePath: relativePath, snapshot: latest, paths: paths),
            try staging.managedContentDigest(
                root: paths.validatedManagedFolder(for: current.folderID), relativePath: retained.relativePath)
                == digest
        else { throw CocoaError(.fileWriteUnknown) }
        try? staging.release(id: command.id)
        if let manager = NSFileProviderManager(
            for: NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(domainIdentifier), displayName: "Psynguechthyngue"))
        {
            try? await manager.signalEnumerator(for: .workingSet)
        }
    }

    private static func stagedContentToken(id: UUID) -> String {
        id.uuidString + "/contents"
    }

    private static func stageIfNeededAndEnqueue(
        _ url: URL?,
        command: CoreCommand,
        expectedDigest: Data? = nil,
        paths: SharedContainerPaths,
        progress: ProviderProgressBox,
        enqueueGate: MutationEnqueueGate
    ) throws {
        var staging: InvocationStaging?
        do {
            if let url {
                guard command.arguments["stagedContentToken"] == stagedContentToken(id: command.id) else {
                    throw FileProviderStagingError.invalidStagedContentToken
                }
                let prepared = try CoordinatedFileAccess().read(at: url) { source in
                    let result = try FileProviderStagingStore(
                        root: paths.fileProviderStaging
                    ).stageAndCommit(
                        source,
                        id: command.id,
                        cancellationCheck: {
                            try Task<Never, Never>.checkCancellation()
                        },
                        progress: { completedBytes, totalBytes in
                            guard totalBytes > 0 else { return }
                            progress.progress.completedUnitCount = min(
                                24,
                                max(1, completedBytes * 24 / totalBytes)
                            )
                        },
                        expectedDigest: expectedDigest,
                        commit: {
                            try enqueueGate.enqueue {
                                try enqueueMutationAndPropagation(command, paths: paths)
                            }
                        }
                    )
                    return InvocationStaging(
                        token: result.token,
                        createdByThisInvocation: result.createdByThisInvocation
                    )
                }
                staging = prepared
            } else if command.arguments["stagedContentToken"] != nil {
                throw FileProviderStagingError.invalidStagedContentToken
            } else {
                try enqueueGate.enqueue {
                    try enqueueMutationAndPropagation(command, paths: paths)
                }
            }
            progress.progress.completedUnitCount = max(
                progress.progress.completedUnitCount,
                25
            )
        } catch {
            releasePreEnqueueStagingIfNeeded(
                staging,
                commandID: command.id,
                paths: paths
            )
            throw error
        }
    }

    /// Commits the local File Provider mutation and its eventual upload intent
    /// as one queue document. The mutation has the higher scheduling class and
    /// therefore runs first in a zero-network local session. The upload remains
    /// durable when offline or policy-blocked and is retried by later App/BG
    /// opportunities without holding the system File Provider callback open.
    private static func enqueueMutationAndPropagation(
        _ command: CoreCommand,
        paths: SharedContainerPaths
    ) throws {
        guard command.isFileProviderMutation,
            let folderID = command.folderID,
            let folderIncarnationDigest = command.folderIncarnationDigest
        else {
            throw ProviderMutationBatchError.invalidMutationCommand
        }
        let mutationID = command.id.uuidString.lowercased()
        let propagation = CoreCommand(
            id: ProviderSupport.commandUUID(
                operation: "file-provider-propagation",
                components: [mutationID]
            ),
            kind: .upload,
            folderID: folderID,
            folderIncarnationDigest: folderIncarnationDigest,
            trigger: .backgroundProcessing,
            createdAt: command.createdAt
        )
        let batchID = ProviderSupport.commandUUID(
            operation: "file-provider-mutation-batch",
            components: [mutationID]
        )
        try CoreCommandQueue(root: paths.commandQueue).enqueueAtomically(
            [command, propagation],
            batchID: batchID
        )
    }

    private static func releasePreEnqueueStagingIfNeeded(
        _ staging: InvocationStaging?,
        commandID: UUID,
        paths: SharedContainerPaths
    ) {
        guard staging?.createdByThisInvocation == true else { return }
        try? FileProviderStagingStore(root: paths.fileProviderStaging)
            .release(id: commandID)
    }

    private func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty,
            filename != ".",
            filename != "..",
            !filename.contains("/"),
            !filename.contains(":")
        else { throw CocoaError(.fileWriteInvalidFileName) }
    }

    private func pendingItem(
        template: NSFileProviderItem,
        identifier: NSFileProviderItemIdentifier
    ) -> ProviderItem {
        let version = ProviderSupport.versionData(UInt64(Date.now.timeIntervalSince1970 * 1_000_000))
        return ProviderItem(
            identifier: identifier,
            parentIdentifier: template.parentItemIdentifier,
            filename: template.filename,
            typeIdentifier: template.contentType?.identifier ?? UTType.data.identifier,
            capabilities: template.capabilities ?? [.allowsReading, .allowsWriting],
            size: (template.documentSize ?? nil)?.int64Value,
            modifiedAt: template.contentModificationDate ?? .now,
            contentVersion: version,
            metadataVersion: version,
            downloaded: true,
            downloading: false,
            uploaded: false,
            uploading: true
        )
    }

    private static func isSafeReimportMatch(
        _ existing: IndexedItem,
        isDirectory: Bool,
        templateVersion: NSFileProviderItemVersion?,
        suppliedContents: URL?,
        commandID: UUID,
        paths: SharedContainerPaths,
        progress: ProviderProgressBox
    ) throws -> Bool {
        guard existing.isDirectory == isDirectory else { return false }
        // A directory at the same authoritative path is a safe merge target;
        // Files will recursively reimport its children.
        guard !isDirectory else { return true }
        guard let suppliedContents else {
            // A dataless disk item has no local bytes to discard; exact version
            // identity is sufficient to recover its stable provider ID.
            return templateVersion.map { ProviderSupport.itemVersion(for: existing) == $0 } == true
        }

        // A materialized reimport may contain a local edit while retaining the
        // last provider version. Match only after byte-for-byte comparison with
        // the authoritative managed copy, and never retain these probe bytes.
        let store = FileProviderStagingStore(root: paths.fileProviderStaging)
        do {
            return try CoordinatedFileAccess().read(at: suppliedContents) { source in
                try store.stageAndCompareContent(
                    source,
                    id: commandID,
                    targetRoot: paths.validatedManagedFolder(for: existing.folderID),
                    targetRelativePath: existing.relativePath,
                    cancellationCheck: {
                        try Task<Never, Never>.checkCancellation()
                    },
                    progress: { completedBytes, totalBytes in
                        guard totalBytes > 0 else { return }
                        progress.progress.completedUnitCount = min(
                            24,
                            max(1, completedBytes * 24 / totalBytes)
                        )
                    }
                )
            }
        } catch let error as FileProviderStagingError {
            guard error == .targetNotRegularFile || error == .contentChangedDuringValidation else {
                throw error
            }
            // A remote-only or otherwise unavailable managed copy cannot prove
            // that supplied disk bytes are safe to discard. A path replacement
            // during comparison has the same fail-closed result. Let the caller
            // surface the existing provider item as a filename collision.
            return false
        }
    }

    private static func canMergeExistingItem(
        _ source: IndexedItem,
        with target: IndexedItem,
        requestsContentsChange: Bool,
        suppliedContents: URL?,
        baseVersion: NSFileProviderItemVersion,
        snapshot: CoreSnapshot,
        paths: SharedContainerPaths
    ) async -> Bool {
        guard source.isDirectory == target.isDirectory,
            !requestsContentsChange, suppliedContents == nil,
            ProviderSupport.itemVersion(for: source) == baseVersion
        else { return false }
        if !source.isDirectory {
            return ProviderSupport.itemVersion(for: target) == baseVersion
        }
        // The bridge has no transactional recursive-directory merge. Deleting
        // only an authoritatively empty source is safe; a nonempty directory is
        // returned as a collision so Files can bounce it without data loss.
        do {
            let store = try IndexedMetadataStore(
                databaseURL: paths.metadataIndex,
                accessMode: .readOnly,
                recoveryPolicy: .fail
            )
            guard try await store.currentGeneration() == snapshot.generation else {
                return false
            }
            return try await store.children(
                inFolder: source.folderID,
                parentID: source.id,
                limit: 1
            ).items.isEmpty
        } catch {
            return false
        }
    }

    private static func collisionItem(
        errorCode: String?,
        folderID: FolderID,
        relativePath: String,
        paths: SharedContainerPaths,
        domainIdentifier: String
    ) async throws -> NSFileProviderItem? {
        guard ["destination_exists", "path_conflict", "path_identity_conflict"].contains(errorCode) else {
            return nil
        }
        let snapshot = try ProviderSupport.snapshot()
        guard
            let indexed = try await ProviderSupport.resolvedIndexedItem(
                inFolder: folderID,
                relativePath: relativePath,
                snapshot: snapshot,
                paths: paths
            )
        else { return nil }
        return try ProviderSupport.providerItem(
            indexed: indexed,
            snapshot: snapshot,
            paths: paths,
            domainIdentifier: domainIdentifier
        )
    }

    private static func executionError(
        result: CoreCommandResult?,
        outcome: CoreRunOutcome,
        itemIdentifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier? = nil,
        collisionItem: NSFileProviderItem? = nil,
        deletionItem: NSFileProviderItem? = nil
    ) -> Error {
        if let code = result?.errorCode {
            switch code {
            case "cancelled", "sync_cancelled":
                return CocoaError(.userCancelled)
            case "destination_exists", "path_conflict", "path_identity_conflict":
                if let collisionItem {
                    return NSError.fileProviderErrorForCollision(with: collisionItem)
                }
                return ProviderSupport.providerError(
                    .filenameCollision,
                    itemIdentifier: itemIdentifier
                )
            case "item_not_found":
                return ProviderSupport.providerError(.noSuchItem, itemIdentifier: itemIdentifier)
            case "invalid_parent", "folder_not_found":
                return ProviderSupport.providerError(
                    .noSuchItem,
                    itemIdentifier: parentIdentifier ?? itemIdentifier
                )
            case "directory_not_empty":
                return ProviderSupport.providerError(
                    .directoryNotEmpty,
                    itemIdentifier: itemIdentifier
                )
            case "version_conflict", "invalid_base_version", "item_type_changed":
                if let deletionItem {
                    return NSError.fileProviderErrorForRejectedDeletion(of: deletionItem)
                }
                return CocoaError(.fileWriteUnknown)
            case "device_offline", "network_unavailable", "remote_read_unavailable",
                "core_not_running", "core_unavailable", "core_closed", "core_busy",
                "database_busy", "request_cache_full", "query_failed",
                "coreBridgeUnavailable", "coreBusy", "coreLockUnavailable",
                "protected_data_unavailable":
                return ProviderSupport.providerError(
                    .serverUnreachable,
                    itemIdentifier: itemIdentifier
                )
            case "folder_paused", "folder_not_writable", "configuration_revision_mismatch",
                "folder_incarnation_mismatch", "staged_content_invalid",
                "propagation_not_indexed", "rescan_failed":
                return ProviderSupport.providerError(
                    .cannotSynchronize,
                    itemIdentifier: itemIdentifier
                )
            default:
                break
            }
        }
        switch outcome {
        case .configurationUnavailable, .coreBusy:
            return ProviderSupport.providerError(.serverUnreachable, itemIdentifier: itemIdentifier)
        case .policyDenied(let reasons):
            if reasons.contains(.insufficientDisk) {
                return ProviderSupport.providerError(
                    .insufficientQuota,
                    itemIdentifier: itemIdentifier
                )
            }
            if reasons.contains(.unuploadedChanges) || reasons.contains(.unresolvedConflict) {
                return ProviderSupport.providerError(
                    .cannotSynchronize,
                    itemIdentifier: itemIdentifier
                )
            }
            return ProviderSupport.providerError(.serverUnreachable, itemIdentifier: itemIdentifier)
        case .completed, .failed:
            return CocoaError(.fileWriteUnknown)
        }
    }

    private static func executionError(
        materializationOutcome outcome: CoreMaterializationOutcome,
        itemIdentifier: NSFileProviderItemIdentifier
    ) -> Error {
        switch outcome {
        case .configurationUnavailable, .coreBusy:
            ProviderSupport.providerError(.serverUnreachable, itemIdentifier: itemIdentifier)
        case .policyDenied(let reasons):
            if reasons.contains(.insufficientDisk) {
                ProviderSupport.providerError(.insufficientQuota, itemIdentifier: itemIdentifier)
            } else if reasons.contains(.unuploadedChanges) || reasons.contains(.unresolvedConflict) {
                ProviderSupport.providerError(.cannotSynchronize, itemIdentifier: itemIdentifier)
            } else {
                ProviderSupport.providerError(.serverUnreachable, itemIdentifier: itemIdentifier)
            }
        case .completed:
            ProviderSupport.providerError(.cannotSynchronize, itemIdentifier: itemIdentifier)
        case .failed(let code):
            switch code {
            case "cancelled":
                CocoaError(.userCancelled)
            case "item_not_found":
                ProviderSupport.providerError(.noSuchItem, itemIdentifier: itemIdentifier)
            case "remote_read_unavailable", "device_offline", "network_unavailable",
                "core_not_running", "core_unavailable", "core_closed", "core_busy",
                "database_busy", "request_cache_full", "query_failed",
                "coreBridgeUnavailable", "coreBusy", "coreLockUnavailable",
                "protected_data_unavailable":
                ProviderSupport.providerError(.serverUnreachable, itemIdentifier: itemIdentifier)
            case "materialization_protection_failed":
                CocoaError(.fileWriteNoPermission)
            default:
                ProviderSupport.providerError(.cannotSynchronize, itemIdentifier: itemIdentifier)
            }
        }
    }

    private static func supported(_ error: Error) -> Error {
        if case FileProviderStagingError.insufficientCapacity = error {
            return ProviderSupport.providerError(.insufficientQuota)
        }
        let value = error as NSError
        if value.domain == NSFileProviderErrorDomain || value.domain == NSCocoaErrorDomain { return error }
        return NSError(
            domain: NSCocoaErrorDomain,
            code: NSXPCConnectionReplyInvalid,
            userInfo: [NSUnderlyingErrorKey: value]
        )
    }

    private static func removeStaleOwnedTemporaryFiles(
        using manager: NSFileProviderManager,
        now: Date = .now
    ) {
        guard let directory = try? manager.temporaryDirectoryURL(),
            let candidates = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: []
            )
        else { return }
        for candidate in candidates {
            let name = candidate.lastPathComponent
            guard
                name.hasPrefix(materializedFilePrefix)
                    || name.hasPrefix(runtimeTemporaryFilePrefix)
            else { continue }
            guard
                let values = try? candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey]
                ),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate,
                now.timeIntervalSince(modifiedAt) >= staleTemporaryFileAge
            else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private static func performRetentionAction(
        _ actionIdentifier: NSFileProviderExtensionActionIdentifier,
        itemIdentifiers: [NSFileProviderItemIdentifier],
        manager: NSFileProviderManager,
        domainIdentifier: String,
        progress: ProviderProgressBox
    ) async throws {
        let paths = try SharedContainerPaths.resolve()
        let snapshot = try ProviderSupport.snapshot()
        guard
            let domainScope = ProviderSupport.domainScope(
                identifier: domainIdentifier,
                snapshot: snapshot
            )
        else {
            throw ProviderSupport.providerError(.serverUnreachable)
        }
        guard let revision = snapshot.configurationRevision,
            revision.utf8.count == 64,
            revision.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            throw ProviderSupport.providerError(.syncAnchorExpired)
        }
        let uniqueFolders = UniqueFolderIdentityIndex(snapshot.folders)
        let incarnations = Dictionary(
            uniqueKeysWithValues: try FolderIncarnationStore(
                url: paths.folderIncarnations
            ).snapshot().records.map { ($0.folderID, $0.folderIncarnationDigest) }
        )
        let metadata = try IndexedMetadataStore(
            databaseURL: paths.metadataIndex,
            accessMode: .readOnly,
            recoveryPolicy: .fail
        )
        guard try await metadata.currentGeneration() == snapshot.generation else {
            throw ProviderSupport.providerError(.syncAnchorExpired)
        }
        let retention = ContentRetentionStore(url: paths.contentRetention)

        for identifier in itemIdentifiers {
            try Task.checkCancellation()
            let rootFolder: FolderRecord? = {
                if identifier == .rootContainer,
                    let folderID = domainScope.rootFolderID
                {
                    return uniqueFolders.folder(folderID)
                }
                guard case .legacyAggregate = domainScope else { return nil }
                return ProviderSupport.folder(for: identifier, snapshot: snapshot)
            }()
            if let folder = rootFolder,
                let incarnation = incarnations[folder.id]
            {
                let rootScopeID = ContentRetentionStore.folderRootScopeItemID(folder.id)
                if actionIdentifier == keepDownloadedAction {
                    try retention.keepDownloaded(
                        itemID: rootScopeID,
                        folderID: folder.id,
                        relativePath: "",
                        isDirectory: true,
                        folderIncarnationDigest: incarnation
                    )
                    try? await manager.requestDownloadForItem(withIdentifier: identifier)
                } else {
                    try await removeDirectoryDownload(
                        itemID: rootScopeID,
                        folderID: folder.id,
                        relativePath: "",
                        incarnation: incarnation,
                        revision: revision,
                        metadata: metadata,
                        retention: retention,
                        manager: manager,
                        paths: paths
                    )
                }
                progress.advance()
                continue
            }
            guard let itemID = ProviderSupport.rawItemID(identifier),
                let item = try await metadata.item(identifier: itemID),
                domainScope.contains(item.folderID),
                uniqueFolders.folder(item.folderID) != nil,
                let incarnation = incarnations[item.folderID]
            else {
                throw ProviderSupport.providerError(.noSuchItem, itemIdentifier: identifier)
            }
            if actionIdentifier == keepDownloadedAction {
                try retention.keepDownloaded(
                    itemID: item.id,
                    folderID: item.folderID,
                    relativePath: item.relativePath,
                    isDirectory: item.isDirectory,
                    folderIncarnationDigest: incarnation
                )
                if !item.isDirectory, item.availability != .local, item.availability != .uploading {
                    try await enqueuePinnedMaterialization(
                        item,
                        incarnation: incarnation,
                        revision: revision,
                        paths: paths
                    )
                }
                // The durable pin is accepted even if the provider is offline.
                // A later App/BG/extension opportunity retries the request.
                try? await manager.requestDownloadForItem(withIdentifier: identifier)
            } else if item.isDirectory {
                try await removeDirectoryDownload(
                    itemID: item.id,
                    folderID: item.folderID,
                    relativePath: item.relativePath,
                    incarnation: incarnation,
                    revision: revision,
                    metadata: metadata,
                    retention: retention,
                    manager: manager,
                    paths: paths
                )
            } else {
                try await removeFileDownload(
                    item,
                    incarnation: incarnation,
                    revision: revision,
                    retention: retention,
                    manager: manager,
                    paths: paths
                )
            }
            progress.advance()
        }
        guard try await metadata.currentGeneration() == snapshot.generation else {
            throw ProviderSupport.providerError(.syncAnchorExpired)
        }
        try? await manager.signalEnumerator(for: .workingSet)
    }

    private static func removeDirectoryDownload(
        itemID: String,
        folderID: FolderID,
        relativePath: String,
        incarnation: String,
        revision: String,
        metadata: IndexedMetadataStore,
        retention: ContentRetentionStore,
        manager: NSFileProviderManager,
        paths: SharedContainerPaths
    ) async throws {
        guard var generation = try await metadata.currentGeneration() else {
            throw ProviderSupport.providerError(.syncAnchorExpired)
        }
        var intent = try retention.beginDirectoryEviction(
            itemID: itemID,
            folderID: folderID,
            relativePath: relativePath,
            folderIncarnationDigest: incarnation,
            configurationRevision: revision,
            indexGeneration: generation
        )
        let normalized = normalizedSelectionPath(relativePath)
        while true {
            try Task.checkCancellation()
            guard let currentGeneration = try await metadata.currentGeneration() else {
                throw ProviderSupport.providerError(.syncAnchorExpired)
            }
            if currentGeneration != generation {
                generation = currentGeneration
                guard
                    let restarted = try retention.restartDirectoryEviction(
                        intentID: intent.id,
                        indexGeneration: generation
                    )
                else { return }
                intent = restarted
            }
            let page = try await metadata.items(
                inFolder: folderID,
                after: intent.cursor,
                limit: IndexedMetadataStore.maximumPageSize
            )
            for child in page.items
            where !child.isDirectory
                && selectionPath(
                    normalizedSelectionPath(child.relativePath),
                    isDescendantOf: normalized
                )
                && (child.availability == .local || child.availability == .uploading)
            {
                try Task.checkCancellation()
                try await removeFileDownload(
                    child,
                    incarnation: incarnation,
                    revision: revision,
                    retention: retention,
                    manager: manager,
                    paths: paths,
                    preservingCurrentPin: true
                )
            }
            guard try await metadata.currentGeneration() == generation else {
                continue
            }
            try retention.advanceDirectoryEviction(
                intentID: intent.id,
                indexGeneration: generation,
                nextCursor: page.nextCursor
            )
            guard let nextCursor = page.nextCursor else { return }
            intent.cursor = nextCursor
        }
    }

    private static func removeFileDownload(
        _ item: IndexedItem,
        incarnation: String,
        revision: String,
        retention: ContentRetentionStore,
        manager: NSFileProviderManager,
        paths: SharedContainerPaths,
        preservingCurrentPin: Bool = false
    ) async throws {
        let disposition = try retention.requestEviction(
            of: item,
            folderIncarnationDigest: incarnation,
            configurationRevision: revision,
            preservingCurrentPin: preservingCurrentPin
        )
        guard case .ready(let transaction) = disposition else { return }
        var systemEvictionCompleted = false
        do {
            try await manager.evictItem(identifier: ProviderSupport.itemIdentifier(item.id))
            systemEvictionCompleted = true
            try retention.advanceEviction(transactionID: transaction.id, to: .systemAccepted)
            try retention.advanceEviction(transactionID: transaction.id, to: .contentRemoved)
            try await finalizeEviction(transaction, paths: paths)
        } catch {
            if !systemEvictionCompleted {
                try? retention.failEviction(transactionID: transaction.id)
            }
            throw error
        }
    }

    private static func enqueuePinnedMaterialization(
        _ item: IndexedItem,
        incarnation: String,
        revision: String,
        paths: SharedContainerPaths
    ) async throws {
        let queue = CoreCommandQueue(root: paths.commandQueue)
        let encodedVersion = item.contentVersion.base64EncodedString()
        let alreadyPending = try queue.pending(limit: .max).contains {
            $0.kind == .pin && $0.folderID == item.folderID && $0.itemID == item.id
                && $0.folderIncarnationDigest == incarnation
                && $0.arguments["contentVersion"] == encodedVersion
        }
        if !alreadyPending {
            try queue.enqueue(
                CoreCommand(
                    kind: .pin,
                    folderID: item.folderID,
                    itemID: item.id,
                    arguments: ["contentVersion": encodedVersion],
                    folderIncarnationDigest: incarnation,
                    commandConfigurationRevision: revision,
                    trigger: .fileProvider
                )
            )
        }
        await PlatformCoreBootstrap.install()
        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        _ = await CoreRuntime.shared.processPending(
            trigger: .fileProvider,
            paths: paths,
            environment: environment,
            currentEnvironment: {
                await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
            }
        )
    }

    private static func finalizeEviction(
        _ transaction: ContentEvictionTransaction,
        paths: SharedContainerPaths
    ) async throws {
        let retention = ContentRetentionStore(url: paths.contentRetention)
        if !(try retention.coreEvictionIsRequested(transactionID: transaction.id)) {
            if try retention.pendingTransactions().contains(where: { $0.id == transaction.id }) {
                try retention.completeEviction(transactionID: transaction.id)
            }
            return
        }
        let queue = CoreCommandQueue(root: paths.commandQueue)
        let command = ContentEvictionFinalization.command(for: transaction, trigger: .fileProvider)
        if try queue.result(for: command.id) == nil,
            !(try queue.pending(limit: .max)).contains(where: { $0.id == command.id })
        {
            try queue.enqueue(command)
        }
        await PlatformCoreBootstrap.install()
        let environment = await SyncEnvironmentSnapshot.captureSystemState(paths: paths)
        _ = await CoreCommandExecutor().execute(
            [command], trigger: .fileProvider, paths: paths, environment: environment,
            currentEnvironment: { await SyncEnvironmentSnapshot.captureSystemState(paths: paths) },
            maximumPasses: 8, timeout: .seconds(20))
        guard try queue.result(for: command.id)?.status == .succeeded else {
            throw ProviderSupport.providerError(
                .serverUnreachable, itemIdentifier: ProviderSupport.itemIdentifier(transaction.itemID))
        }
        try ContentRetentionStore(url: paths.contentRetention)
            .completeEviction(transactionID: transaction.id)
    }
}

private final class ProviderVoidCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        let action = lock.withLock { () -> (() -> Void)? in
            defer { handler = nil }
            return handler
        }
        action?()
    }
}

private final class ProviderManagerBox: @unchecked Sendable {
    let value: NSFileProviderManager

    init(_ value: NSFileProviderManager) {
        self.value = value
    }
}

private final class ProviderMaintenanceTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: (id: UUID, value: Task<Void, Never>)?
    private var invalidated = false

    func install(_ value: Task<Void, Never>, taskID: UUID) {
        let installation = lock.withLock { () -> (previous: Task<Void, Never>?, accepted: Bool) in
            guard !invalidated else { return (nil, false) }
            let previous = task?.value
            task = (taskID, value)
            return (previous, true)
        }
        installation.previous?.cancel()
        if !installation.accepted { value.cancel() }
    }

    func clear(taskID: UUID) {
        lock.withLock {
            guard task?.id == taskID else { return }
            task = nil
        }
    }

    func cancel() {
        let current = lock.withLock { () -> Task<Void, Never>? in
            invalidated = true
            defer { task = nil }
            return task?.value
        }
        current?.cancel()
    }
}

private final class MaterializedItemSetCollector: NSObject, NSFileProviderEnumerationObserver,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let enumerator: NSFileProviderEnumerator
    private var identifiers: Set<NSFileProviderItemIdentifier> = []
    private var continuation: CheckedContinuation<Set<NSFileProviderItemIdentifier>, Error>?
    private var keepAlive: MaterializedItemSetCollector?

    private init(enumerator: NSFileProviderEnumerator) {
        self.enumerator = enumerator
    }

    static func collect(
        from enumerator: NSFileProviderEnumerator
    ) async throws -> Set<NSFileProviderItemIdentifier> {
        let collector = MaterializedItemSetCollector(enumerator: enumerator)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.lock.withLock {
                    collector.continuation = continuation
                    collector.keepAlive = collector
                }
                enumerator.enumerateItems(
                    for: collector,
                    startingAt: NSFileProviderPage(Data())
                )
            }
        } onCancel: {
            collector.cancel()
        }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        lock.withLock {
            identifiers.formUnion(updatedItems.map(\.itemIdentifier))
        }
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        if let nextPage {
            enumerator.enumerateItems(for: self, startingAt: nextPage)
            return
        }
        finish(.success(lock.withLock { identifiers }))
    }

    func finishEnumeratingWithError(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Set<NSFileProviderItemIdentifier>, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Set<NSFileProviderItemIdentifier>, Error>? in
            defer {
                self.continuation = nil
                keepAlive = nil
            }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    private func cancel() {
        finish(.failure(CocoaError(.userCancelled)))
        enumerator.invalidate()
    }
}

private final class ProviderProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    let progress: Progress

    init(_ progress: Progress) {
        self.progress = progress
    }

    func advance() {
        lock.withLock {
            progress.completedUnitCount += 1
        }
    }
}

private final class ProviderActionCompletionBox: @unchecked Sendable {
    private let gate = ProviderCompletionGate()
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func succeed() {
        gate.finish { handler(nil) }
    }

    func fail(_ error: Error) {
        gate.finish { handler(error) }
    }

    func cancel() {
        fail(CocoaError(.userCancelled))
    }
}

private enum ProviderMutationBatchError: Error {
    case invalidMutationCommand
}

private final class ProviderAsyncOperation: @unchecked Sendable {
    private let body: () async -> Void

    init(body: @escaping () async -> Void) {
        self.body = body
    }

    func run() async {
        await body()
    }
}

private final class ProviderCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    @discardableResult
    func finish(_ body: () -> Void) -> Bool {
        guard claim() else { return false }
        body()
        return true
    }
}

private final class MutationEnqueueGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel<T>(_ reserveCompletion: () -> T) -> T {
        lock.withLock {
            cancelled = true
            return reserveCompletion()
        }
    }

    func enqueue(_ body: () throws -> Void) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try Task<Never, Never>.checkCancellation()
            try body()
        }
    }
}

private final class FetchCompletionBox: @unchecked Sendable {
    let manager: NSFileProviderManager
    let itemIdentifier: NSFileProviderItemIdentifier
    private let gate = ProviderCompletionGate()
    private let handler: (URL?, NSFileProviderItem?, Error?) -> Void

    init(
        manager: NSFileProviderManager,
        itemIdentifier: NSFileProviderItemIdentifier,
        handler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) {
        self.manager = manager
        self.itemIdentifier = itemIdentifier
        self.handler = handler
    }

    @discardableResult
    func succeed(_ url: URL, item: NSFileProviderItem) -> Bool {
        gate.finish { handler(url, item, nil) }
    }

    func fail(_ error: Error) {
        gate.finish { handler(nil, nil, error) }
    }

    func cancel() {
        fail(CocoaError(.userCancelled))
    }
}

private final class ItemCompletionBox: @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    private let gate = ProviderCompletionGate()
    private let handler: (NSFileProviderItem?, Error?) -> Void

    init(
        itemIdentifier: NSFileProviderItemIdentifier,
        handler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        self.itemIdentifier = itemIdentifier
        self.handler = handler
    }

    func succeed(_ item: NSFileProviderItem) {
        gate.finish { handler(item, nil) }
    }

    func fail(_ error: Error) {
        gate.finish { handler(nil, error) }
    }

    func cancel() {
        fail(CocoaError(.userCancelled))
    }
}

private final class MutationCompletionBox: @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    private let gate = ProviderCompletionGate()
    private let pendingItem: NSFileProviderItem
    private let requestedFields: NSFileProviderItemFields
    private let stillPendingFields: NSFileProviderItemFields
    private let handler: (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void

    init(
        pendingItem: NSFileProviderItem,
        requestedFields: NSFileProviderItemFields,
        stillPendingFields: NSFileProviderItemFields,
        handler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) {
        itemIdentifier = pendingItem.itemIdentifier
        self.pendingItem = pendingItem
        self.requestedFields = requestedFields
        self.stillPendingFields = stillPendingFields
        self.handler = handler
    }

    func succeed(_ committedItem: NSFileProviderItem?) {
        gate.finish {
            handler(committedItem ?? pendingItem, stillPendingFields, false, nil)
        }
    }

    func succeedWithoutItem() {
        gate.finish { handler(nil, [], false, nil) }
    }

    func fail(_ error: Error) {
        gate.finish { handler(nil, requestedFields, false, error) }
    }

    func reserveCancellation() -> (() -> Void)? {
        guard gate.claim() else { return nil }
        return { self.handler(nil, [], false, CocoaError(.userCancelled)) }
    }
}

private final class DeleteCompletionBox: @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    private let gate = ProviderCompletionGate()
    private let handler: (Error?) -> Void

    init(itemIdentifier: NSFileProviderItemIdentifier, handler: @escaping (Error?) -> Void) {
        self.itemIdentifier = itemIdentifier
        self.handler = handler
    }

    func succeed() {
        gate.finish { handler(nil) }
    }

    func fail(_ error: Error) {
        gate.finish { handler(error) }
    }

    func reserveCancellation() -> (() -> Void)? {
        guard gate.claim() else { return nil }
        return { self.handler(CocoaError(.userCancelled)) }
    }
}
