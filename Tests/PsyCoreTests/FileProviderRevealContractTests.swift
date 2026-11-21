import Foundation
import XCTest

#if os(macOS)
    final class FileProviderRevealContractTests: XCTestCase {
        func testAggregateFilesDomainEnumeratesEveryShareAsAnIsolatedFolderEntry() throws {
            let root = repositoryRoot()
            let domainManager = try source("App/FileProviderDomainManager.swift", root: root)
            let support = try source("FileProvider/ProviderSupport.swift", root: root)
            let enumerator = try source("FileProvider/ProviderEnumerator.swift", root: root)
            let fileProvider = try source("FileProvider/FileProviderExtension.swift", root: root)
            let app = try source("App/PsynguechthyngueApp.swift", root: root)
            let physicalUI = try source(
                "Tests/PsynguechthyngueUITests/PhysicalFilesUIE2ETests.swift",
                root: root
            )
            let directItem = try functionBody(
                "    static func item(\n",
                in: support,
                endingAt: "    static func resolvedIndexedItem("
            )
            let resolvedItem = try functionBody(
                "    static func resolvedItem(\n",
                in: support,
                endingAt: "    static func resolvedParentContext("
            )

            XCTAssertTrue(domainManager.contains("static func reconcileDomains(snapshot: CoreSnapshot)"))
            XCTAssertTrue(domainManager.contains("identifier: aggregateDomainIdentifier"))
            XCTAssertTrue(domainManager.contains("displayName: \"Psynguechthyngue\""))
            XCTAssertTrue(domainManager.contains("hasPrefix(FileProviderDomainIdentity.sharePrefix)"))
            XCTAssertTrue(domainManager.contains("NSFileProviderManager.remove(existing)"))
            XCTAssertTrue(domainManager.contains("guard snapshot.localDeviceID != nil else { return }"))
            XCTAssertFalse(domainManager.contains(".isHidden"))
            XCTAssertFalse(
                app.contains("FileProviderDomainManager.reconcileDomains(snapshot: model.snapshot)")
            )
            XCTAssertTrue(
                domainManager.contains(
                    "static func requestDownload(folderID: FolderID, itemID: String)"
                )
            )
            XCTAssertTrue(support.contains("enum ProviderDomainScope"))
            XCTAssertTrue(support.contains("case legacyAggregate"))
            XCTAssertTrue(support.contains("domainScope.contains(resolved.folderID)"))
            XCTAssertTrue(support.contains("rootFolderID: domainScope.rootFolderID"))
            XCTAssertTrue(support.contains("private static func rootMutationAccess("))
            XCTAssertTrue(directItem.contains("mutationAccess: rootMutationAccess("))
            XCTAssertTrue(resolvedItem.contains("mutationAccess: rootMutationAccess("))
            XCTAssertTrue(
                support.contains(
                    "if mutationAccess.allowsAddingSubItems { capabilities.insert(.allowsAddingSubItems) }"
                )
            )
            XCTAssertTrue(enumerator.contains("inFolder: domainScope.rootFolderID"))
            XCTAssertTrue(support.contains("IndexedMetadataContainerScope.folderWorkingSet"))
            XCTAssertTrue(enumerator.contains("UniqueFolderIdentityIndex(snapshot.folders)"))
            XCTAssertTrue(enumerator.contains("ProviderItem(\n                        folder: folder"))
            XCTAssertTrue(enumerator.contains("domainScope.contains(parent.folderID)"))
            XCTAssertTrue(fileProvider.contains("domainIdentifier = domain.identifier.rawValue"))
            XCTAssertTrue(fileProvider.contains("domainIdentifier: domainIdentifier"))
            let providerTap = try XCTUnwrap(
                physicalUI.range(of: "providerLocation.tap()")?.lowerBound
            )
            let shareLookup = try XCTUnwrap(
                physicalUI.range(of: "named: [shareFolderName]", range: providerTap..<physicalUI.endIndex)?
                    .lowerBound
            )
            XCTAssertLessThan(providerTap, shareLookup)
            XCTAssertFalse(physicalUI.contains("private let locationNames"))
        }

        func testAppUsesTheCurrentDomainAndStableItemIdentifierForFilesReveal() throws {
            let root = repositoryRoot()
            let domainManager = try source("App/FileProviderDomainManager.swift", root: root)
            let globalFiles = try source("App/GlobalFilesView.swift", root: root)
            let appModel = try source("App/AppModel.swift", root: root)
            let folders = try source("App/FoldersView.swift", root: root)

            XCTAssertTrue(
                domainManager.contains("func userVisibleURL(folderID: FolderID, itemID: String)")
            )
            XCTAssertTrue(domainManager.contains("manager.getUserVisibleURL("))
            XCTAssertTrue(domainManager.contains(#"NSFileProviderItemIdentifier("item-\(itemID)")"#))
            XCTAssertTrue(domainManager.contains("struct FileProviderRevealFence"))
            XCTAssertTrue(domainManager.contains("let relativePath: String"))
            XCTAssertTrue(domainManager.contains("let parentID: String?"))
            XCTAssertTrue(domainManager.contains("let contentVersion: Data"))
            XCTAssertTrue(domainManager.contains("let metadataVersion: Data"))
            XCTAssertTrue(domainManager.contains("let generation: UInt64"))
            XCTAssertTrue(domainManager.contains("FileProviderRevealFence(item: revalidated) == candidateFence"))
            XCTAssertTrue(domainManager.contains("func validateCurrent("))
            XCTAssertTrue(
                appModel.contains(
                    "expectedFence: FileProviderRevealFence(item: resolved.item)"
                )
            )
            XCTAssertTrue(globalFiles.contains("Button(\"Show in Files\""))
            XCTAssertTrue(appModel.contains("showIndexedItemInFiles"))
            XCTAssertFalse(appModel.contains("showFolderInFiles"))
            XCTAssertFalse(folders.contains("Open Share in Files"))
            XCTAssertTrue(appModel.contains("startAccessingSecurityScopedResource"))
            XCTAssertTrue(appModel.contains("stopAccessingSecurityScopedResource"))
            XCTAssertFalse(domainManager.contains("ManagedFolders"))
        }

        func testOpenIntentUsesTheForegroundSecurityScopedRevealFlow() throws {
            let root = repositoryRoot()
            let intents = try source("App/AppIntents.swift", root: root)

            XCTAssertTrue(intents.contains("struct OpenIndexedItemIntent: AppIntent"))
            XCTAssertTrue(intents.contains("static let openAppWhenRun = true"))
            XCTAssertTrue(intents.contains("FileProviderRevealService().userVisibleURL"))
            XCTAssertTrue(intents.contains("startAccessingSecurityScopedResource"))
            XCTAssertTrue(intents.contains("stopAccessingSecurityScopedResource"))
            XCTAssertTrue(intents.contains("FileProviderRevealService().validateCurrent"))
            XCTAssertTrue(intents.contains("expectedFence: FileProviderRevealFence(item: resolved.item)"))
            XCTAssertTrue(intents.contains("openFileProviderURL(resolved.url)"))
            XCTAssertFalse(intents.contains("OpenURLIntent(resolved.url)"))
            XCTAssertTrue(
                intents.contains(
                    "authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication"
                )
            )
            XCTAssertFalse(intents.contains("ManagedFolders"))
        }

        func testUnavailableIntentStubsAreAbsentFromTheV1ShortcutsSurface() throws {
            let root = repositoryRoot()
            let intents = try source("App/AppIntents.swift", root: root)
            let devices = try source("App/DevicesView.swift", root: root)
            let platform = try source("Platform/GoCoreClient.swift", root: root)

            for unavailableIntent in [
                "UploadFolderIntent",
                "DownloadFolderIntent",
                "ExchangeIndexIntent",
                "DownloadItemIntent",
                "PinItemIntent",
            ] {
                XCTAssertFalse(
                    intents.contains("struct \(unavailableIntent): AppIntent"),
                    "\(unavailableIntent) must not be discoverable when it can only report unavailable"
                )
            }

            for executableIntent in [
                "SyncAllIntent",
                "SyncFolderIntent",
                "TransferFolderIntent",
                "DeviceControlIntent",
                "OpenIndexedItemIntent",
                "EvictItemIntent",
                "DownloadIndexedItemIntent",
                "KeepIndexedItemDownloadedIntent",
                "DeleteIndexedItemEverywhereIntent",
            ] {
                XCTAssertTrue(intents.contains("struct \(executableIntent): AppIntent"))
            }
            XCTAssertTrue(intents.contains("case .uploadOnly: kind = .upload"))
            XCTAssertTrue(intents.contains("case .downloadOnly: kind = .download"))
            XCTAssertTrue(intents.contains("case .exchangeIndexOnly: kind = .exchangeIndex"))
            XCTAssertTrue(intents.contains("case .pause: kind = .pause"))
            XCTAssertTrue(intents.contains("case .resume: kind = .resume"))
            XCTAssertTrue(intents.contains("itemID: validatedDeviceID.rawValue"))
            XCTAssertTrue(intents.contains("DeviceID(syncthingString: deviceID)"))
            XCTAssertTrue(devices.contains("DeviceID(syncthingString: deviceID)"))
            XCTAssertTrue(devices.contains("DeviceID(syncthingString: value)"))
            XCTAssertTrue(platform.contains("var pendingBytes: Int64"))
            XCTAssertTrue(platform.contains("var uploadBytesPerSecond: Int64"))
            XCTAssertTrue(platform.contains("var downloadBytesPerSecond: Int64"))
            XCTAssertTrue(platform.contains("uploadBytesPerSecond: uploadBytesPerSecond"))
            XCTAssertTrue(platform.contains("downloadBytesPerSecond: downloadBytesPerSecond"))
            XCTAssertTrue(platform.contains("pendingBytes: pendingBytes"))
            XCTAssertTrue(devices.contains("device.uploadBytesPerSecond.formatted(.byteCount(style: .file))"))
            XCTAssertTrue(devices.contains("device.downloadBytesPerSecond.formatted(.byteCount(style: .file))"))
            XCTAssertTrue(devices.contains("device.pendingBytes.formatted(.byteCount(style: .file))"))
            XCTAssertTrue(intents.contains("device.uploadBytesPerSecond.formatted(.byteCount(style: .file))"))
            XCTAssertTrue(intents.contains("device.downloadBytesPerSecond.formatted(.byteCount(style: .file))"))
            XCTAssertTrue(intents.contains("device.pendingBytes.formatted(.byteCount(style: .file))"))
            XCTAssertFalse(devices.contains("Not reported"))
            XCTAssertFalse(intents.contains("Per-device transfer rates are not reported"))
        }

        func testOverviewDoesNotOfferAnInoperableIndexExchangeAction() throws {
            let root = repositoryRoot()
            let overview = try source("App/OverviewView.swift", root: root)
            let devices = try source("App/DevicesView.swift", root: root)
            let appModel = try source("App/AppModel.swift", root: root)
            let domainManager = try source("App/FileProviderDomainManager.swift", root: root)

            let details = try source("App/SyncDiagnosticsView.swift", root: root)
            XCTAssertTrue(overview.contains("await model.submit(kind: .sync"))
            XCTAssertFalse(overview.contains("model.submit(kind: .exchangeIndex)"))
            XCTAssertFalse(overview.contains("Exchange Index Only — Unavailable"))
            XCTAssertTrue(overview.contains("Copy Device ID"))
            XCTAssertTrue(overview.contains("UIPasteboard.general.string = model.localDeviceIDText"))
            XCTAssertTrue(devices.contains("UIPasteboard.general.string = device.id.rawValue"))
            XCTAssertTrue(domainManager.contains("guard domain.userEnabled else { return .disabled }"))
            XCTAssertTrue(appModel.contains("FileProviderDomainManager.status(snapshot: snapshot)"))
            XCTAssertTrue(overview.contains("Files Location"))
            XCTAssertTrue(overview.contains("enable Psynguechthyngue"))
            XCTAssertFalse(overview.contains("Each Syncthing share is available as its own location"))
            XCTAssertTrue(overview.contains("SyncDiagnosticsView()"))
            XCTAssertTrue(details.contains("RunHistoryView()"))

        }

        func testGlobalFilesAndIntentsExposeFourTruthfulStorageActions() throws {
            let root = repositoryRoot()
            let globalFiles = try source("App/GlobalFilesView.swift", root: root)
            let appModel = try source("App/AppModel.swift", root: root)
            let intents = try source("App/AppIntents.swift", root: root)
            let storageActions = try source("App/FileProviderDomainManager.swift", root: root)
            let selectionPlan = try source("Sources/PsyCore/Selection/SelectionPlan.swift", root: root)

            XCTAssertTrue(globalFiles.contains("Button(\"Show in Files\""))
            XCTAssertTrue(globalFiles.contains("await model.showIndexedItemInFiles(item)"))
            XCTAssertTrue(globalFiles.contains("Button(\"Download\""))
            XCTAssertTrue(globalFiles.contains("Button(\"Keep Downloaded\""))
            XCTAssertTrue(globalFiles.contains("Button(\"Remove Download\""))
            XCTAssertTrue(globalFiles.contains("Button(\"Delete Everywhere\""))
            XCTAssertTrue(appModel.contains("func downloadIndexedItem("))
            XCTAssertTrue(appModel.contains("func keepIndexedItemDownloaded("))
            XCTAssertTrue(appModel.contains("func evictFilesCache("))
            XCTAssertTrue(appModel.contains("func deleteIndexedItemFromSyncthing("))
            XCTAssertEqual(
                appModel.components(separatedBy: "await refreshContentRetentionProjection()").count - 1,
                2,
                "Keep Downloaded and Remove Download must immediately refresh the shared retention projection"
            )
            XCTAssertTrue(globalFiles.contains("model.contentRetentionStatuses[item.id]"))
            XCTAssertTrue(globalFiles.contains("Waiting for upload, then remove download"))
            XCTAssertTrue(intents.contains("FileProviderStorageActionService().download"))
            XCTAssertTrue(intents.contains("FileProviderStorageActionService().keepDownloaded"))
            XCTAssertTrue(intents.contains("FileProviderStorageActionService().evictItem"))
            XCTAssertTrue(intents.contains("\"propagatesToPeers\": \"true\""))
            XCTAssertTrue(storageActions.contains("ensureDownloadedForCurrentRetentionIntent("))
            XCTAssertTrue(storageActions.contains("recordExplicitPin: false"))
            XCTAssertTrue(storageActions.contains("if recordExplicitPin {"))
            XCTAssertFalse(selectionPlan.contains("SelectionPlanCommandEnvelope"))
            XCTAssertFalse(selectionPlan.contains("preparedCommandArguments"))
            XCTAssertFalse(selectionPlan.contains("selectionPlanState"))
            XCTAssertFalse(globalFiles.contains("Download on Demand — Use Files"))
            XCTAssertFalse(globalFiles.contains("Keep Offline — Unavailable on iOS"))
            XCTAssertFalse(globalFiles.contains("explainFilesDownloadLimitation"))
            XCTAssertFalse(globalFiles.contains("explainKeepOfflineLimitation"))
            XCTAssertFalse(appModel.contains("func explainFilesDownloadLimitation("))
            XCTAssertFalse(appModel.contains("func explainKeepOfflineLimitation("))
            XCTAssertTrue(storageActions.contains("enum CurrentIndexedItemLoader"))
            XCTAssertTrue(storageActions.contains("let matches = snapshot.items.filter { $0.id == itemID }"))
            XCTAssertTrue(storageActions.contains("guard matches.count == 1"))
            XCTAssertFalse(storageActions.contains("metadata.item(identifier: itemID)"))
            XCTAssertTrue(
                storageActions.contains(
                    "guard try SharedSnapshotStore(snapshotURL: paths.snapshot).read() == snapshot"
                )
            )
            XCTAssertTrue(
                storageActions.contains(
                    "ContentRetentionIntentResolver(\n                metadataDatabaseURL: paths.metadataIndex"
                )
            )
            XCTAssertGreaterThanOrEqual(
                storageActions.components(separatedBy: "CurrentIndexedItemLoader.load(").count - 1,
                4
            )
            XCTAssertTrue(intents.contains("CurrentIndexedItemLoader.load(itemID: identifier"))
            XCTAssertTrue(intents.contains("Self.pendingTransferBytes(in: snapshot)"))
            XCTAssertTrue(intents.contains("addingReportingOverflow(nonnegative)"))
            XCTAssertTrue(intents.contains("store.currentGeneration() == snapshot.generation"))
            XCTAssertTrue(intents.contains("Dictionary(grouping: snapshot.items, by: \\.id)"))
            XCTAssertTrue(intents.contains("canonicalMatches.count == 1"))
            XCTAssertTrue(intents.contains("canonicalMatches[0] == item"))
            XCTAssertTrue(intents.contains("sorted(by: IndexedMetadataStore.binaryItemOrderPrecedes)"))
            let start = try functionBody(
                "    func start() async {",
                in: appModel,
                endingAt: "    func refresh("
            )
            XCTAssertTrue(start.contains("FileProviderStorageActionService().reconcilePendingWork("))
            XCTAssertTrue(start.contains("trigger: .foreground"))
            XCTAssertTrue(start.contains("await repairDerivedMetadataIndexIfNeeded(paths: paths)"))
            XCTAssertLessThan(
                try XCTUnwrap(
                    start.range(of: "await repairDerivedMetadataIndexIfNeeded(paths: paths)")?
                        .lowerBound
                ),
                try XCTUnwrap(start.range(of: "reconcilePendingWork(")?.lowerBound)
            )
            XCTAssertLessThan(
                try XCTUnwrap(start.range(of: "reconcilePendingWork(")?.lowerBound),
                try XCTUnwrap(start.range(of: "await refresh(bootstrapConfigurationIfNeeded: false)")?.lowerBound)
            )
        }

        func testDirectoryRemovalPagesTheAuthoritativeIndexAndBackgroundWorkRotates() throws {
            let root = repositoryRoot()
            let manager = try source("App/FileProviderDomainManager.swift", root: root)
            let directoryEviction = try functionBody(
                "    private func evictDirectory(",
                in: manager,
                endingAt: "    private func evictRegularItem("
            )
            let traversal = try functionBody(
                "    private func processDirectoryEviction(",
                in: manager,
                endingAt: "    private func evictRegularItem("
            )
            let reconciliation = try functionBody(
                "    func reconcilePendingWork(",
                in: manager,
                endingAt: "    func evictItem("
            )

            XCTAssertTrue(directoryEviction.contains("beginDirectoryEviction("))
            XCTAssertTrue(directoryEviction.contains("processDirectoryEviction("))
            XCTAssertTrue(traversal.contains("metadata.items("))
            XCTAssertTrue(traversal.contains("IndexedMetadataStore.maximumPageSize"))
            XCTAssertTrue(traversal.contains("metadata.currentGeneration() == intent.indexGeneration"))
            XCTAssertTrue(traversal.contains("advanceDirectoryEviction("))
            XCTAssertFalse(directoryEviction.contains("snapshot.items"))
            XCTAssertLessThan(
                try XCTUnwrap(directoryEviction.range(of: "beginDirectoryEviction(")?.lowerBound),
                try XCTUnwrap(directoryEviction.range(of: "processDirectoryEviction(")?.lowerBound)
            )
            XCTAssertTrue(reconciliation.contains("backgroundScanCursor()"))
            XCTAssertTrue(reconciliation.contains("advanceBackgroundScanCursor"))
            XCTAssertTrue(reconciliation.contains("directoryEvictionIntents()"))
            XCTAssertTrue(reconciliation.contains("maximumPages: 1"))
            XCTAssertTrue(reconciliation.contains("materializedItemIdentifiers()"))
            XCTAssertEqual(
                reconciliation.components(separatedBy: "materializedItemIdentifiers()").count - 1,
                1
            )
            XCTAssertTrue(reconciliation.contains("to: .contentRemoved"))
            XCTAssertTrue(manager.contains("to: .systemAccepted"))
            XCTAssertTrue(manager.contains("ContentEvictionFinalization.command"))
        }

        func testRemovedV1SurfaceStringsStayOutOfBothLocalizations() throws {
            let root = repositoryRoot()
            let english = try source("App/Resources/en.lproj/Localizable.strings", root: root)
            let chinese = try source("App/Resources/zh-Hans.lproj/Localizable.strings", root: root)
            let removedKeys = [
                "Upload Folder Changes",
                "Download Folder Changes",
                "Exchange Syncthing Index",
                "Keep Indexed Item Offline",
                "Exchange Index Only — Unavailable",
                "Download on Demand — Use Files",
                "Keep Offline — Unavailable on iOS",
                "On iOS, open this item from the Psynguechthyngue location in Files to download it on demand. The app cannot start that system download itself.",
                "iOS does not expose the File Provider keep-downloaded policy used for a durable offline pin. No pin was saved or reported as complete.",
            ]

            for key in removedKeys {
                XCTAssertFalse(english.contains("\"\(key)\" ="))
                XCTAssertFalse(chinese.contains("\"\(key)\" ="))
            }
        }

        func testFileCopyGuidanceIsAvailableWithoutBlockingSetupAndRemainsInSettings() throws {
            let root = repositoryRoot()
            let rootView = try source("App/RootView.swift", root: root)
            let settings = try source("App/SettingsView.swift", root: root)
            let english = try source("App/Resources/en.lproj/Localizable.strings", root: root)
            let chinese = try source("App/Resources/zh-Hans.lproj/Localizable.strings", root: root)
            let generator = try source("Scripts/generate-xcodeproj.rb", root: root)
            let project = try source("Psynguechthyngue.xcodeproj/project.pbxproj", root: root)
            let warning =
                "This app has no permanent central cloud copy. Offline Uploaded status uses the last exact peer evidence."

            let overview = try source("App/OverviewView.swift", root: root)
            XCTAssertTrue(overview.contains("About your file copies"))
            XCTAssertTrue(overview.contains("Keep a complete copy on another device or in a backup."))
            XCTAssertFalse(rootView.contains("peerStorageRiskIsPresented"))
            XCTAssertTrue(rootView.contains("switch model.startupState"))
            XCTAssertFalse(rootView.contains("requiresPeerStorageRiskAcknowledgement"))
            XCTAssertTrue(rootView.contains("TabView(selection: $selection)"))
            XCTAssertEqual(
                rootView.components(separatedBy: ".tabItem {").count - 1,
                5
            )
            XCTAssertFalse(rootView.contains(".tabBarMinimizeBehavior(.onScrollDown)"))
            XCTAssertTrue(rootView.contains("NavigationStack(path: $overviewPath)"))
            XCTAssertTrue(rootView.contains("devicesPath = NavigationPath()"))
            XCTAssertTrue(rootView.contains("foldersPath = NavigationPath()"))
            XCTAssertTrue(rootView.contains("filesPath = NavigationPath()"))
            XCTAssertFalse(rootView.contains("ExternalDirectoriesView()"))
            XCTAssertFalse(rootView.contains("RunHistoryView()"))
            XCTAssertTrue(settings.contains(warning))
            XCTAssertTrue(english.contains(warning))
            XCTAssertTrue(chinese.contains(warning))
            XCTAssertTrue(chinese.contains("如果所有设备都移除了同一文件的下载"))
            for document in ["LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"] {
                XCTAssertTrue(generator.contains(document))
                XCTAssertTrue(project.contains("\(document) in Resources"))
            }
            XCTAssertTrue(settings.contains("LegalNoticesView()"))
            XCTAssertTrue(settings.contains("PlatformCoreBootstrap.coreRevision"))
            XCTAssertTrue(settings.contains("This development build does not claim that source offer is available."))
            XCTAssertTrue(settings.contains("Do not distribute it."))
        }

        func testRuleEditorSupportsScopedDragAndDropReordering() throws {
            let editor = try source("App/RuleEditorView.swift", root: repositoryRoot())
            let selection = try source("App/FolderSelectionView.swift", root: repositoryRoot())

            XCTAssertTrue(editor.contains(".draggable(ruleDragPayload(rule))"))
            XCTAssertTrue(editor.contains(".dropDestination("))
            XCTAssertTrue(editor.contains("for: String.self,"))
            XCTAssertTrue(editor.contains("action: { payloads, _ in"))
            XCTAssertTrue(editor.contains("psy-selection-rule-v1|"))
            XCTAssertTrue(editor.contains("components[1] == Substring(syntax.rawValue)"))
            XCTAssertTrue(editor.contains("payloads.count == 1"))
            XCTAssertTrue(editor.contains("plan.moveRule(id: sourceID, syntax: syntax, to: destination)"))
            XCTAssertTrue(selection.contains("SelectionFileTree(items: source)"))
            XCTAssertTrue(selection.contains("requestedPlan.manualSelectionProjection(items: source)"))
            XCTAssertTrue(selection.contains("tree.search(query)"))
            XCTAssertTrue(selection.contains("Task.detached(priority: .userInitiated)"))
            XCTAssertFalse(selection.contains("plan.manualDirectoryState(for:"))
            let selectionPlan = try source("Sources/PsyCore/Selection/SelectionPlan.swift", root: repositoryRoot())
            XCTAssertTrue(selectionPlan.contains("let directivesByPath = Dictionary("))
            XCTAssertTrue(selectionPlan.contains("for depth in 1...components.count"))
        }

        private func repositoryRoot() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }

        private func source(_ path: String, root: URL) throws -> String {
            if path == "App/AppModel.swift" { return try applicationModelSource(root: root) }
            return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
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
    }
#endif
