import Foundation
import XCTest

#if os(macOS)
    final class FileProviderMutationContractTests: XCTestCase {
        func testEveryMutationPassesBothObservedFencesBeforeStaging() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let create = try functionBody("func createItem(", in: source, endingAt: "    func modifyItem(")
            let modify = try functionBody("    func modifyItem(", in: source, endingAt: "    func deleteItem(")
            let delete = try functionBody("    func deleteItem(", in: source, endingAt: "    func enumerator(")

            for body in [create, modify, delete] {
                XCTAssertTrue(body.contains("expectedFolderIncarnationDigest:"))
                XCTAssertTrue(body.contains("expectedConfigurationRevision:"))
            }
            XCTAssertLessThan(
                try XCTUnwrap(create.range(of: ".prepareCommands(")?.lowerBound),
                try XCTUnwrap(create.range(of: "Self.stageIfNeededAndEnqueue(")?.lowerBound)
            )
            XCTAssertLessThan(
                try XCTUnwrap(modify.range(of: ".prepareCommands(")?.lowerBound),
                try XCTUnwrap(modify.range(of: "Self.stageIfNeededAndEnqueue(")?.lowerBound)
            )
            XCTAssertLessThan(
                try XCTUnwrap(delete.range(of: ".prepareCommands(")?.lowerBound),
                try XCTUnwrap(
                    delete.range(of: "enqueueMutationAndPropagation(command")?.lowerBound
                )
            )
        }

        func testCrossFolderMoveIsRejectedBeforeSideEffectsWhileIntraFolderReparentIsAdvertised() throws {
            let extensionSource = try repositorySource("FileProvider/FileProviderExtension.swift")
            let supportSource = try repositorySource("FileProvider/ProviderSupport.swift")
            let modify = try functionBody(
                "    func modifyItem(",
                in: extensionSource,
                endingAt: "    func deleteItem("
            )

            XCTAssertTrue(modify.contains("targetParent.folderID == current.folderID"))
            XCTAssertTrue(modify.contains("Cross-folder moves require a transactional copy+delete protocol"))
            let crossFolderGuard = try XCTUnwrap(
                modify.range(of: "targetParent.folderID == current.folderID")?.lowerBound
            )
            for sideEffect in [
                ".prepareCommands(", "stageIfNeededAndEnqueue", ".enqueue(command)",
            ] {
                if let sideEffectIndex = modify.range(of: sideEffect)?.lowerBound {
                    XCTAssertLessThan(crossFolderGuard, sideEffectIndex)
                }
            }
            XCTAssertTrue(supportSource.contains("capabilities.insert(.allowsReparenting)"))
            XCTAssertTrue(supportSource.contains(".allowsRenaming"))
            XCTAssertTrue(supportSource.contains(".allowsAddingSubItems"))
        }

        func testModifyPreflightDistinguishesFilenameRenameFromParentReparent() throws {
            let extensionSource = try repositorySource("FileProvider/FileProviderExtension.swift")
            let modify = try functionBody(
                "    func modifyItem(",
                in: extensionSource,
                endingAt: "    func deleteItem("
            )

            XCTAssertTrue(modify.contains("let requestsFilenameChange"))
            XCTAssertTrue(modify.contains("let requestsParentChange"))
            XCTAssertTrue(modify.contains("let isRename = filename != currentFilename"))
            XCTAssertTrue(modify.contains("let isReparent = parentIdentifier != currentParentIdentifier"))
            XCTAssertTrue(modify.contains("!isRename || requestsFilenameChange"))
            XCTAssertTrue(modify.contains("!isReparent || requestsParentChange"))
            XCTAssertTrue(modify.contains(".rename"))
            XCTAssertTrue(modify.contains(".reparent"))
            XCTAssertTrue(modify.contains("isReparent {"))
        }

        func testResolvedParentsAreNormalizedToBridgeIdentifiersBeforeEnqueue() throws {
            let extensionSource = try repositorySource("FileProvider/FileProviderExtension.swift")
            let supportSource = try repositorySource("FileProvider/ProviderSupport.swift")
            let create = try functionBody(
                "func createItem(",
                in: extensionSource,
                endingAt: "    func modifyItem("
            )
            let modify = try functionBody(
                "    func modifyItem(",
                in: extensionSource,
                endingAt: "    func deleteItem("
            )

            XCTAssertTrue(create.contains("ProviderSupport.bridgeParentIdentifier(parent)"))
            XCTAssertTrue(modify.contains("ProviderSupport.bridgeParentIdentifier("))
            XCTAssertTrue(modify.contains("targetParent"))
            XCTAssertFalse(create.contains(#""parentIdentifier": parentIdentifier.rawValue"#))
            XCTAssertFalse(modify.contains(#""parentIdentifier": parentIdentifier.rawValue"#))
            XCTAssertTrue(
                supportSource.contains("parent.itemID.map { itemIdentifier($0).rawValue }")
            )
            XCTAssertTrue(
                supportSource.contains(
                    "FileProviderDomainIdentity.folderItemIdentifier(for: parent.folderID)"
                )
            )
        }

        func testFetchRejectsDuplicateFolderIdentityBeforeCoreOrMaterializationIO() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let fetch = try functionBody(
                "    func fetchContents(",
                in: source,
                endingAt: "    func createItem("
            )
            let duplicateGate = try XCTUnwrap(
                fetch.range(of: "UniqueFolderIdentityIndex")?.lowerBound
            )

            XCTAssertLessThan(
                duplicateGate,
                try XCTUnwrap(fetch.range(of: "PlatformCoreBootstrap.install")?.lowerBound)
            )
            XCTAssertLessThan(
                duplicateGate,
                try XCTUnwrap(fetch.range(of: "Self.materializeWhenAvailable(")?.lowerBound)
            )
        }

        func testOnlyNewPreEnqueueStagingIsReleasedOnFailure() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")

            XCTAssertTrue(source.contains("createdByThisInvocation"))
            XCTAssertTrue(source.contains("releasePreEnqueueStagingIfNeeded"))
            XCTAssertTrue(source.contains("enqueueMutationAndPropagation(command"))
            XCTAssertTrue(source.contains(".enqueueAtomically("))
        }

        func testMutationAndDeferredPropagationPublishAsOneOrderedBatch() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let helper = try functionBody(
                "    private static func enqueueMutationAndPropagation(",
                in: source,
                endingAt: "    private static func releasePreEnqueueStagingIfNeeded("
            )

            XCTAssertTrue(helper.contains("command.isFileProviderMutation"))
            XCTAssertTrue(helper.contains("kind: .upload"))
            XCTAssertTrue(helper.contains("trigger: .backgroundProcessing"))
            XCTAssertTrue(helper.contains("[command, propagation]"))
            XCTAssertTrue(helper.contains("batchID: batchID"))
        }

        func testSuccessfulMutationReleasesStagingBeforeCallingTheCompletionHandler() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let create = try functionBody("func createItem(", in: source, endingAt: "    func modifyItem(")
            let modify = try functionBody(
                "    func modifyItem(",
                in: source,
                endingAt: "    func deleteItem("
            )

            for (body, releaseMarker) in [
                (create, ".release(id: commandID)"),
                (modify, ".release(id: effectiveCommandID)"),
            ] {
                let release = try XCTUnwrap(body.range(of: releaseMarker)?.lowerBound)
                let completion = try XCTUnwrap(
                    body.range(
                        of: "completion.succeed(committedItem)",
                        range: release..<body.endIndex
                    )?.lowerBound
                )
                XCTAssertLessThan(release, completion)
            }
        }

        func testMutationCancellationOwnsStagingProgressAndSerializesEnqueue() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let staging = try repositorySource(
                "Sources/PsyCore/Storage/FileProviderStagingStore.swift"
            )
            let helper = try functionBody(
                "    private static func stageIfNeededAndEnqueue(",
                in: source,
                endingAt: "    private static func releasePreEnqueueStagingIfNeeded("
            )

            XCTAssertTrue(source.contains("let enqueueGate = MutationEnqueueGate()"))
            XCTAssertTrue(source.contains("completion.reserveCancellation()"))
            XCTAssertTrue(helper.contains("enqueueGate.enqueue"))
            XCTAssertTrue(helper.contains("stageAndCommit("))
            XCTAssertTrue(source.contains("Task<Never, Never>.checkCancellation()"))
            XCTAssertTrue(source.contains("completedBytes * 24 / totalBytes"))
            XCTAssertTrue(staging.contains("stageWithDisposition"))
            XCTAssertTrue(staging.contains("stageAndCommit"))
            XCTAssertTrue(staging.contains("createdByThisInvocation"))
            XCTAssertTrue(staging.contains("try cancellationCheck()"))
            for body in [
                try functionBody("func createItem(", in: source, endingAt: "    func modifyItem("),
                try functionBody("    func modifyItem(", in: source, endingAt: "    func deleteItem("),
                try functionBody("    func deleteItem(", in: source, endingAt: "    func enumerator("),
            ] {
                let start = try XCTUnwrap(
                    body.range(of: "progress.cancellationHandler = {")?.lowerBound
                )
                let cancellation = body[start...]
                XCTAssertLessThan(
                    try XCTUnwrap(cancellation.range(of: "cancellation?()")?.lowerBound),
                    try XCTUnwrap(cancellation.range(of: "work.cancel()")?.lowerBound)
                )
            }
        }

        func testCreateAndModifyHandleReimportAndMergeOptionsBeforeEnqueue() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let create = try functionBody("func createItem(", in: source, endingAt: "    func modifyItem(")
            let modify = try functionBody(
                "    func modifyItem(",
                in: source,
                endingAt: "    func deleteItem("
            )

            XCTAssertTrue(create.contains("options.contains(.mayAlreadyExist)"))
            XCTAssertTrue(create.contains("options.contains(.deletionConflicted)"))
            XCTAssertTrue(create.contains("fields.contains(.filename)"))
            XCTAssertTrue(create.contains("fields.contains(.parentItemIdentifier)"))
            XCTAssertTrue(create.contains("!isDirectory && fields.contains(.contents)"))
            XCTAssertTrue(create.contains("isSafeReimportMatch"))
            XCTAssertTrue(create.contains("if stagedContents == nil, !isDirectory"))
            XCTAssertTrue(create.contains("completion.succeedWithoutItem()"))
            XCTAssertLessThan(
                try XCTUnwrap(create.range(of: "isSafeReimportMatch")?.lowerBound),
                try XCTUnwrap(create.range(of: "stageIfNeededAndEnqueue")?.lowerBound)
            )
            XCTAssertTrue(modify.contains("options.contains(.mayAlreadyExist)"))
            XCTAssertTrue(modify.contains("canMergeExistingItem"))
            XCTAssertTrue(modify.contains("operation: \"merge-delete\""))
            XCTAssertTrue(modify.contains("ProviderSupport.itemIdentifier(mergeTarget.id)"))
            let reimportAssessment = try functionBody(
                "    private static func isSafeReimportMatch(",
                in: source,
                endingAt: "    private static func canMergeExistingItem("
            )
            XCTAssertTrue(reimportAssessment.contains("guard let suppliedContents"))
            XCTAssertTrue(reimportAssessment.contains("stageAndCompareContent"))
            XCTAssertTrue(reimportAssessment.contains("paths.validatedManagedFolder"))
            XCTAssertTrue(reimportAssessment.contains("targetNotRegularFile"))
            XCTAssertTrue(reimportAssessment.contains("contentChangedDuringValidation"))
            let mergeAssessment = try functionBody(
                "    private static func canMergeExistingItem(",
                in: source,
                endingAt: "    private static func collisionItem("
            )
            XCTAssertTrue(mergeAssessment.contains("currentGeneration() == snapshot.generation"))
            XCTAssertTrue(mergeAssessment.contains("parentID: source.id"))
            XCTAssertTrue(mergeAssessment.contains("limit: 1"))
            XCTAssertTrue(mergeAssessment.contains("return false"))
        }

        func testStillPendingFieldsAndNoOpMetadataChangesDoNotCreateInvalidCommands() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let modify = try functionBody(
                "    func modifyItem(",
                in: source,
                endingAt: "    func deleteItem("
            )
            let completion = try functionBody(
                "private final class MutationCompletionBox:",
                in: source,
                endingAt: "private final class DeleteCompletionBox:"
            )

            XCTAssertTrue(source.contains("fields.subtracting(Self.bridgeMutationFields)"))
            XCTAssertTrue(source.contains("changedFields.subtracting(Self.bridgeMutationFields)"))
            XCTAssertTrue(modify.contains("if actionableFields.isEmpty"))
            XCTAssertTrue(modify.contains("if !isMove, !requestsContentsChange"))
            XCTAssertTrue(completion.contains("stillPendingFields"))
            XCTAssertTrue(completion.contains("handler(nil, [], false, nil)"))
            XCTAssertTrue(completion.contains("handler(nil, [], false, CocoaError(.userCancelled))"))
        }

        func testCommandErrorCodesMapBeforeRunOutcomeFallbackWithItemContext() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let mapping = try functionBody(
                "    private static func executionError(\n        result:",
                in: source,
                endingAt: "    private static func executionError(\n        materializationOutcome"
            )

            for code in [
                "destination_exists", "path_conflict", "path_identity_conflict", "item_not_found",
                "invalid_parent", "folder_not_found", "directory_not_empty",
                "version_conflict", "invalid_base_version", "item_type_changed",
                "cancelled", "device_offline", "network_unavailable",
                "core_not_running", "core_unavailable", "core_closed", "core_busy",
                "database_busy", "request_cache_full", "query_failed",
            ] {
                XCTAssertTrue(mapping.contains("\"\(code)\""), "missing mapping for \(code)")
            }
            XCTAssertTrue(mapping.contains("fileProviderErrorForCollision"))
            XCTAssertTrue(mapping.contains("fileProviderErrorForRejectedDeletion"))
            XCTAssertTrue(mapping.contains("parentIdentifier ?? itemIdentifier"))
            XCTAssertTrue(mapping.contains("reasons.contains(.insufficientDisk)"))
            let supported = try functionBody(
                "    private static func supported(",
                in: source,
                endingAt: "    private static func removeStaleOwnedTemporaryFiles("
            )
            XCTAssertTrue(supported.contains("FileProviderStagingError.insufficientCapacity"))
            XCTAssertTrue(supported.contains(".insufficientQuota"))
        }

        func testExtensionInvalidationDoesNotStartLockedMaintenance() throws {
            let extensionSource = try repositorySource("FileProvider/FileProviderExtension.swift")
            let invalidate = try functionBody(
                "    func invalidate() {",
                in: extensionSource,
                endingAt: "    private func schedulePendingMaterializedSetReconciliation("
            )
            let appSource = try repositorySource("App/AppModel.swift")

            XCTAssertFalse(invalidate.contains("Task.detached"))
            XCTAssertFalse(invalidate.contains("removeStaleOwnedTemporaryFiles"))
            XCTAssertFalse(invalidate.contains("CoreCommandQueue"))
            XCTAssertTrue(invalidate.contains("maintenanceTaskState.cancel()"))
            XCTAssertTrue(extensionSource.contains("private final class ProviderMaintenanceTaskState"))
            XCTAssertTrue(extensionSource.contains("invalidated = true"))
            XCTAssertFalse(extensionSource.contains("reclaimStaleStagedContent"))
            XCTAssertTrue(appSource.contains("reclaimStaleFileProviderStaging(paths: paths)"))
            XCTAssertTrue(appSource.contains("retainedFileProviderStagingCommandIDs()"))
            XCTAssertTrue(appSource.contains("reclaimStaleDirectories(retaining: retained)"))
        }

        func testCallbackPreflightDoesNotConsultRetentionOrStignore() throws {
            let extensionSource = try repositorySource("FileProvider/FileProviderExtension.swift")
            let supportSource = try repositorySource("FileProvider/ProviderSupport.swift")
            let bridgePreflight = try functionBody(
                "    static func requireBridgeMutationAccess(",
                in: supportSource,
                endingAt: "    static func resolvedIndexedItem("
            )

            XCTAssertFalse(extensionSource.contains("prepareSelectionForLocalEdit"))
            XCTAssertFalse(extensionSource.contains(".stignore"))
            XCTAssertFalse(bridgePreflight.contains("ContentRetentionIntentResolver"))
            XCTAssertFalse(bridgePreflight.contains("selectionMode"))
        }

        func testDuplicateFolderIDsCannotAdvertiseOrPassCallbackPreflight() throws {
            let supportSource = try repositorySource("FileProvider/ProviderSupport.swift")
            let enumeratorSource = try repositorySource("FileProvider/ProviderEnumerator.swift")
            let folderLookup = try functionBody(
                "    static func folder(for identifier:",
                in: supportSource,
                endingAt: "    static func metadataScope("
            )
            let bridgePreflight = try functionBody(
                "    static func requireBridgeMutationAccess(",
                in: supportSource,
                endingAt: "    static func resolvedIndexedItem("
            )
            let mutationPrecondition = try functionBody(
                "    static func mutationPrecondition(",
                in: supportSource,
                endingAt: "    static func parentFolderID("
            )
            let rootEnumeration = try functionBody(
                "    private func enumerateRoot(",
                in: enumeratorSource,
                endingAt: "    private static func cursor("
            )

            XCTAssertTrue(folderLookup.contains("UniqueFolderIdentityIndex"))
            XCTAssertFalse(folderLookup.contains(".first"))
            XCTAssertTrue(rootEnumeration.contains("UniqueFolderIdentityIndex"))
            XCTAssertTrue(bridgePreflight.contains("uniqueFolder"))
            XCTAssertTrue(mutationPrecondition.contains("matches == 1"))
        }

        func testSystemMaterializedAndPendingCallbacksKeepAuthoritySeparated() throws {
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let materialized = try functionBody(
                "    func materializedItemsDidChange(",
                in: source,
                endingAt: "    func pendingItemsDidChange("
            )
            let pending = try functionBody(
                "    func pendingItemsDidChange(",
                in: source,
                endingAt: "    private static func reconcileMaterializedSet("
            )
            let reconciliation = try functionBody(
                "    private static func reconcileMaterializedSet(",
                in: source,
                endingAt: "    private static func stagedContentToken("
            )

            XCTAssertTrue(materialized.contains("markMaterializedSetReconciliationPending"))
            XCTAssertTrue(materialized.contains("completion.call()"))
            XCTAssertTrue(pending.contains("signalEnumerator(for: .workingSet)"))
            XCTAssertFalse(pending.contains("ContentRetentionStore"))
            XCTAssertTrue(reconciliation.contains("enumeratorForMaterializedItems()"))
            XCTAssertFalse(reconciliation.contains("\"systemEvictionObserved\": \"true\""))
            XCTAssertTrue(reconciliation.contains("FileProviderReplicaStore"))
            XCTAssertTrue(reconciliation.contains(".isPinned"))
            XCTAssertTrue(reconciliation.contains("requestDownloadForItem"))
            XCTAssertFalse(reconciliation.contains("var pendingCommandIDs = Set("))
            XCTAssertFalse(reconciliation.contains("for _ in commands.indices"))
            XCTAssertTrue(reconciliation.contains("completeMaterializedSetReconciliation"))
        }

        func testFilesCustomActionsUseTheDurableRetentionAndPerFileEvictionPaths() throws {
            let root = repositoryRoot()
            let source = try repositorySource("FileProvider/FileProviderExtension.swift")
            let infoData = try Data(
                contentsOf: root.appendingPathComponent("FileProvider/Info.plist")
            )
            let info = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: infoData, format: nil)
                    as? [String: Any]
            )
            let extensionInfo = try XCTUnwrap(info["NSExtension"] as? [String: Any])
            let actions = try XCTUnwrap(
                extensionInfo["NSExtensionFileProviderActions"] as? [[String: String]]
            )

            XCTAssertTrue(source.contains("NSFileProviderCustomAction"))
            XCTAssertTrue(source.contains("func performAction("))
            XCTAssertTrue(source.contains("retention.keepDownloaded("))
            XCTAssertTrue(source.contains("retention.requestEviction("))
            XCTAssertTrue(source.contains("manager.evictItem(identifier:"))
            let finalization = try functionBody(
                "    private static func finalizeEviction(",
                in: source,
                endingAt: "\n}\n\nprivate final class ProviderVoidCompletionBox"
            )
            XCTAssertTrue(finalization.contains("ContentEvictionFinalization.command"))
            XCTAssertTrue(source.contains("preservingCurrentPin: true"))
            XCTAssertTrue(source.contains("IndexedMetadataStore.maximumPageSize"))
            XCTAssertFalse(
                source.contains("manager.evictItem(identifier: ProviderSupport.itemIdentifier(directory.id))"))
            XCTAssertFalse(source.contains(".stignore"))

            XCTAssertEqual(actions.count, 2)
            XCTAssertEqual(
                Set(actions.compactMap { $0["NSExtensionFileProviderActionIdentifier"] }),
                [
                    "moe.simon3k.Psynguechthyngue.keep-downloaded",
                    "moe.simon3k.Psynguechthyngue.remove-download",
                ]
            )
            XCTAssertTrue(
                actions.allSatisfy {
                    $0["NSExtensionFileProviderActionActivationRule"] == "TRUEPREDICATE"
                }
            )
            let english = try repositorySource(
                "FileProvider/Resources/en.lproj/Localizable.strings"
            )
            let chinese = try repositorySource(
                "FileProvider/Resources/zh-Hans.lproj/Localizable.strings"
            )
            XCTAssertTrue(english.contains("Keep Downloaded"))
            XCTAssertTrue(english.contains("Remove Download"))
            XCTAssertTrue(chinese.contains("保留下载"))
            XCTAssertTrue(chinese.contains("移除下载"))
        }

        private func repositorySource(_ path: String) throws -> String {
            if path == "App/AppModel.swift" { return try applicationModelSource(root: repositoryRoot()) }
            return try String(
                contentsOf: repositoryRoot().appendingPathComponent(path),
                encoding: .utf8
            )
        }

        private func functionBody(
            _ start: String,
            in source: String,
            endingAt end: String
        ) throws -> String {
            let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
            let endIndex = try XCTUnwrap(
                source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound
            )
            return String(source[startIndex..<endIndex])
        }

        private func repositoryRoot() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
    }
#endif
