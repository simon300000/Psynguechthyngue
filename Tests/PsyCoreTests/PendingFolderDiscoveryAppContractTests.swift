import Foundation
import XCTest

#if os(macOS)
    final class PendingFolderDiscoveryAppContractTests: XCTestCase {
        func testCoreCreationUsesStructuredAllowlistedFailureCodes() throws {
            let platform = try source("Platform/GoCoreClient.swift", root: repositoryRoot())
            let prepared = try functionBody(
                named: "private func preparedCore(",
                next: "private func openExplicitSession(",
                in: platform
            )

            XCTAssertTrue(prepared.contains("MobilebridgeNewCoreCreation("))
            XCTAssertTrue(prepared.contains("let creationFailureCode = creation.failureCode()"))
            XCTAssertTrue(prepared.contains("guard let candidate = creation.createdCore()"))
            XCTAssertTrue(prepared.contains("Self.sanitizedCoreCreationFailureCode(creationFailureCode)"))
            XCTAssertFalse(prepared.contains("localizedDescription"))
            XCTAssertFalse(prepared.contains("MobilebridgeNewCore("))

            let classifier = try functionBody(
                named: "private static func sanitizedCoreCreationFailureCode(",
                next: "private func openExplicitSession(",
                in: platform
            )
            for code in [
                "core_in_use",
                "identity_rejected",
                "invalid_core_directories",
                "core_state_unavailable",
            ] {
                XCTAssertTrue(classifier.contains("\"\(code)\""))
            }
            XCTAssertTrue(classifier.contains("\"core_creation_failed\""))
        }

        func testSuccessfulExplicitSessionCloseReleasesTheProcessCore() throws {
            let platform = try source("Platform/GoCoreClient.swift", root: repositoryRoot())
            let close = try functionBody(
                named: "func closeExplicitSession() async throws",
                next: "func stop() async throws",
                in: platform
            )

            XCTAssertTrue(close.contains("let cleanup = terminalDrainAndClose("))
            XCTAssertTrue(close.contains("guard !cleanup.closeFailed"))
            let cleanupCall = try XCTUnwrap(close.range(of: "let cleanup = terminalDrainAndClose("))
            let returnReceipt = try XCTUnwrap(close.range(of: "return receipt"))
            XCTAssertLessThan(cleanupCall.lowerBound, returnReceipt.lowerBound)
            XCTAssertTrue(
                close.contains(
                    "networkBinding: binding.mode != .configuration ? binding : nil"
                )
            )
            XCTAssertTrue(
                close.contains(
                    "networkBaseline: binding.mode != .configuration\n                        ? networkTransferBaseline : nil"
                )
            )
        }

        func testCleanInstallBootstrapsCanonicalConfigurationAndBusyCanRetry() throws {
            let model = try source("App/AppModel.swift", root: repositoryRoot())
            let start = try functionBody(named: "func start() async", next: "func refresh(", in: model)
            let refresh = try functionBody(
                named: "func refresh(",
                next: "func ensureCanonicalConfigurationAvailable(",
                in: model
            )
            let ensure = try functionBody(
                named: "func ensureCanonicalConfigurationAvailable(",
                next: "func reloadIndex(",
                in: model
            )
            let submit = try functionBody(
                named: "func submit(",
                next: "func showIndexedItemInFiles(",
                in: model
            )

            let startEnsure = try XCTUnwrap(start.range(of: "ensureCanonicalConfigurationAvailable"))
            let startRefresh = try XCTUnwrap(start.range(of: "await refresh("))
            XCTAssertLessThan(startEnsure.lowerBound, startRefresh.lowerBound)
            XCTAssertTrue(start.contains("await refresh(bootstrapConfigurationIfNeeded: false)"))
            XCTAssertTrue(refresh.contains("bootstrapConfigurationIfNeeded"))
            XCTAssertEqual(
                refresh.components(separatedBy: "ensureCanonicalConfigurationAvailable").count - 1,
                1,
                "A refresh opportunity may retry bootstrap once, but must not loop"
            )
            XCTAssertGreaterThanOrEqual(
                ensure.components(
                    separatedBy: "SharedSnapshotStore(snapshotURL: paths.snapshot).read()"
                ).count - 1,
                2,
                "Bootstrap must read before opening the core and verify persisted output afterward"
            )
            let existingRevision = try XCTUnwrap(
                ensure.range(of: "persistedSnapshot.configurationRevision != nil")
            )
            let runtimeRefresh = try XCTUnwrap(
                ensure.range(of: "CoreRuntime.shared.refreshConfigurationSnapshot(")
            )
            XCTAssertLessThan(existingRevision.lowerBound, runtimeRefresh.lowerBound)
            XCTAssertTrue(ensure.contains("refreshedSnapshot.configurationRevision != nil"))
            XCTAssertTrue(ensure.contains("case .completed"))
            XCTAssertTrue(ensure.contains("case .coreBusy"))
            XCTAssertTrue(ensure.contains("case .configurationUnavailable"))
            XCTAssertTrue(ensure.contains("case .failed"))
            XCTAssertTrue(submit.contains("Self.requiresCanonicalConfiguration(kind)"))
            let ensureBeforeProducer = try XCTUnwrap(
                submit.range(of: "ensureCanonicalConfigurationAvailable")
            )
            let producer = try XCTUnwrap(submit.range(of: "ScopedCoreCommandProducer"))
            XCTAssertLessThan(ensureBeforeProducer.lowerBound, producer.lowerBound)
            XCTAssertTrue(model.contains("case .addDevice, .editDevice, .removeDevice"))
            XCTAssertTrue(model.contains(".addFolder, .editFolder, .removeFolder"))
            XCTAssertTrue(model.contains("func addDevice("))
            XCTAssertTrue(model.contains("func editDevice("))
            XCTAssertTrue(model.contains("configured.addresses == expectedAddresses"))
            let devices = try source("App/DevicesView.swift", root: repositoryRoot())
            XCTAssertGreaterThanOrEqual(
                devices.components(separatedBy: "if didSubmit {\n                                dismiss()").count - 1,
                2
            )
            XCTAssertTrue(devices.contains("submissionError = model.errorMessage ?? model.statusMessage"))
        }

        func testManagedFolderFormsWaitForExactAuthoritativeConfiguration() throws {
            let root = repositoryRoot()
            let model = try source("App/AppModel.swift", root: root)
            let folders = try source("App/FoldersView.swift", root: root)
            let add = try functionBody(
                named: "func addManagedFolder(",
                next: "func acceptPendingDevice(",
                in: model
            )
            let edit = try functionBody(
                named: "func editManagedFolder(",
                next: "func isInternallyManagedFolder(",
                in: model
            )

            for body in [add, edit] {
                XCTAssertTrue(body.contains("confirmsManagedFolderConfiguration("))
                XCTAssertTrue(body.contains("preserveFolderConfigurationFailure()"))
            }
            XCTAssertTrue(edit.contains("deviceIDs: Set<DeviceID>"))
            XCTAssertTrue(edit.contains("\"deviceIDs\": deviceList"))
            XCTAssertTrue(edit.contains("sharedDeviceIDs.isSubset(of: configuredPeerIDs)"))
            XCTAssertTrue(folders.contains("_selectedDeviceIDs = State(initialValue: Set(folder.deviceIDs ?? []))"))
            XCTAssertGreaterThanOrEqual(
                folders.components(separatedBy: "Text(\"Share with Devices\")").count - 1,
                2
            )
            XCTAssertTrue(folders.contains("deviceIDs: selectedDeviceIDs"))
            for requiredFence in [
                "matchingFolders.count == 1",
                "configured.label == label",
                "configured.localPath",
                "configured.type == type",
                "configured.isPaused == paused",
                "Set(configuredDeviceIDs) == deviceIDs",
                "configuredDeviceIDs.count == deviceIDs.count",
                "configured.rescanIntervalS == rescanIntervalS",
            ] {
                XCTAssertTrue(model.contains(requiredFence), "Missing folder confirmation fence: \(requiredFence)")
            }
            XCTAssertGreaterThanOrEqual(
                folders.components(separatedBy: "submissionError = model.errorMessage ?? model.statusMessage").count
                    - 1,
                2
            )
            XCTAssertGreaterThanOrEqual(
                folders.components(separatedBy: "if didSubmit {\n                dismiss()").count - 1,
                2
            )
            for path in [
                "App/Resources/en.lproj/Localizable.strings",
                "App/Resources/zh-Hans.lproj/Localizable.strings",
            ] {
                let strings = try source(path, root: root)
                XCTAssertTrue(strings.contains("\"Request Result\" ="))
                XCTAssertTrue(
                    strings.contains(
                        "\"The core did not confirm this folder configuration in the latest snapshot. Keep the form open, review the request result, and try again.\" ="
                    )
                )
            }
        }

        func testFolderActionsCaptureAndRequireTheExactIncarnation() throws {
            let root = repositoryRoot()
            let model = try source("App/AppModel.swift", root: root)
            let folders = try source("App/FoldersView.swift", root: root)

            XCTAssertEqual(
                folders.components(separatedBy: "model.folderIncarnationDigests[folder.id]").count - 1,
                1,
                "The live digest may be read only when constructing the row"
            )
            XCTAssertTrue(folders.contains("private struct ConfiguredFolderListRow: View"))
            XCTAssertTrue(
                folders.contains(
                    "EditManagedFolderView(\n                folder: folder,\n                expectedFolderIncarnationDigest: expectedFolderIncarnationDigest"
                )
            )
            XCTAssertGreaterThanOrEqual(
                folders.components(separatedBy: ".disabled(folderActionsDisabled)").count - 1,
                5
            )
            let detailStart = try XCTUnwrap(folders.range(of: "private struct FolderDetailView: View"))
            let detailEnd = try XCTUnwrap(
                folders.range(
                    of: "private enum FolderPolicyByteField",
                    range: detailStart.upperBound..<folders.endIndex
                )
            )
            let detail = String(folders[detailStart.lowerBound..<detailEnd.lowerBound])
            XCTAssertTrue(detail.contains("kind: .removeFolder"))
            XCTAssertTrue(detail.contains("kind: folder.isPaused ? .resume : .pause"))
            XCTAssertTrue(detail.contains("kind: .sync"))
            XCTAssertTrue(detail.contains("kind: .rescan"))
            XCTAssertTrue(detail.contains("arguments: [\"deleteData\": \"false\"]"))
            XCTAssertTrue(
                detail.contains(
                    "expectedFolderIncarnationDigest: expectedFolderIncarnationDigest"
                )
            )
            XCTAssertTrue(
                folders.contains(
                    "expectedFolderIncarnationDigest: expectedFolderIncarnationDigest\n            )"
                )
            )

            XCTAssertTrue(model.contains("Self.requiresExactFolderIncarnation(kind)"))
            XCTAssertTrue(
                model.contains("case .editFolder, .removeFolder, .sync, .pause, .resume, .rescan:")
            )
            XCTAssertTrue(
                model.contains(
                    "folderIncarnationDigests[folderID] == expectedFolderIncarnationDigest"
                )
            )
            XCTAssertTrue(
                model.contains(
                    "expectedFolderIncarnationDigest: String\n    ) async -> Bool"
                )
            )
            XCTAssertTrue(
                model.contains(
                    "expectedFolderIncarnationDigest: expectedFolderIncarnationDigest"
                )
            )
        }

        func testManualDiscoveryIsAvailableWithoutConfiguredFoldersAndUsesBoundedRotation() throws {
            let root = repositoryRoot()
            let model = try source("App/AppModel.swift", root: root)
            let folders = try source("App/FoldersView.swift", root: root)
            let background = try source("App/BackgroundTaskManager.swift", root: root)

            XCTAssertTrue(model.contains("func discoverPendingFolderOffers() async"))
            XCTAssertTrue(model.contains("PendingFolderDiscoveryOpportunity.run("))
            XCTAssertTrue(folders.contains("Button(\"Check for Folder Offers\""))
            XCTAssertTrue(folders.contains("model.startPendingFolderDiscovery()"))
            XCTAssertTrue(background.contains("maximumDevicesPerOpportunity = 2"))
            XCTAssertTrue(background.contains("claimEligibleDeviceIDs"))
            XCTAssertTrue(background.contains("nextOffset"))
            XCTAssertFalse(background.contains("guard !snapshot.folders.isEmpty"))
        }

        func testBackgroundDiscoveryRunsOnlyInsideGrantedProcessingHandler() throws {
            let root = repositoryRoot()
            let background = try source("App/BackgroundTaskManager.swift", root: root)
            let settings = try source("App/SettingsView.swift", root: root)
            let model = try source("App/AppModel.swift", root: root)
            let handlerStart = try XCTUnwrap(
                background.range(of: "nonisolated private static func handle")
            )
            let schedulerStart = try XCTUnwrap(
                background.range(of: "nonisolated private static func submitNextTasks")
            )
            let schedulerEnd = try XCTUnwrap(
                background.range(
                    of: "nonisolated private static func submit(",
                    range: schedulerStart.upperBound..<background.endIndex
                )
            )
            let handler = String(background[handlerStart.lowerBound..<schedulerStart.lowerBound])
            let scheduler = String(background[schedulerStart.lowerBound..<schedulerEnd.lowerBound])

            XCTAssertTrue(handler.contains("PendingFolderDiscoveryOpportunity.run("))
            XCTAssertFalse(scheduler.contains("PendingFolderDiscoveryOpportunity.run("))
            XCTAssertFalse(scheduler.contains("discoverPendingFolderOffers("))
            XCTAssertTrue(handler.contains("trigger: .backgroundProcessing"))
            XCTAssertTrue(handler.contains("guard scheduling.mode == .refreshAndProcessing"))
            XCTAssertTrue(scheduler.contains("if !plan.refreshEnabled"))
            XCTAssertTrue(scheduler.contains("if !plan.processingEnabled"))
            XCTAssertTrue(
                scheduler.components(separatedBy: "cancel(taskRequestWithIdentifier:").count >= 3
            )
            XCTAssertTrue(settings.contains("Picker(\"Automatic Background Work\""))
            XCTAssertTrue(settings.contains("Toggle(\"Background Upload\""))
            XCTAssertTrue(settings.contains("Toggle(\"Background Download\""))
            XCTAssertTrue(settings.contains("Toggle(\"Background Scan\""))
            XCTAssertFalse(settings.contains("isOn: fullBackgroundSyncEnabled"))
            XCTAssertTrue(model.contains("BackgroundTaskManager.shared.scheduleNextTasks()"))
        }

        func testBGTaskLaunchClosuresAreDefinedOutsideMainActorIsolation() throws {
            let background = try source("App/BackgroundTaskManager.swift", root: repositoryRoot())

            XCTAssertTrue(
                background.contains(
                    "nonisolated private static func registerRefreshHandler(identifier: String) -> Bool"
                )
            )
            XCTAssertTrue(
                background.contains(
                    "nonisolated private static func registerProcessingHandler(identifier: String) -> Bool"
                )
            )
            XCTAssertTrue(background.contains("Self.registerRefreshHandler(identifier: refreshIdentifier)"))
            XCTAssertTrue(
                background.contains("Self.registerProcessingHandler(identifier: processingIdentifier)")
            )
        }

        func testDurableSummaryRemainsDisplayEvidenceAndEveryDecisionReobservesExactOffer() throws {
            let root = repositoryRoot()
            let model = try source("App/AppModel.swift", root: root)
            let folders = try source("App/FoldersView.swift", root: root)
            let accept = try functionBody(
                named: "func acceptPendingFolder(",
                next: "func ignorePendingFolder(",
                in: model
            )
            let ignore = try functionBody(
                named: "func ignorePendingFolder(",
                next: "func allowFutureFolderRequests(",
                in: model
            )

            for body in [accept, ignore] {
                let observe = try XCTUnwrap(body.range(of: "revalidatePendingFolderOffer("))
                let enqueue = try XCTUnwrap(
                    body.range(of: "submitProofBackedPendingFolderCommand(")
                )
                XCTAssertLessThan(observe.lowerBound, enqueue.lowerBound)
            }
            XCTAssertTrue(folders.contains("offer.evidenceSource == .durableSummary"))
            XCTAssertTrue(folders.contains("offer.requiresNetworkRevalidation"))
            XCTAssertTrue(folders.contains("Saved summary · network revalidation required"))
            XCTAssertTrue(folders.contains("Revalidate and Accept"))
            XCTAssertTrue(folders.contains("Revalidate and Ignore"))
        }

        func testDiscoveryStatusIsTruthfulAndDoesNotExposeConnectionMetadata() throws {
            let root = repositoryRoot()
            let model = try source("App/AppModel.swift", root: root)
            let background = try source("App/BackgroundTaskManager.swift", root: root)
            let opportunityStart = try XCTUnwrap(
                background.range(of: "enum PendingFolderDiscoveryOpportunity")
            )
            let opportunity = String(background[opportunityStart.lowerBound...])

            for state in [
                "case cancelled", "case configurationChanged", "case environmentChanged",
                "case policyDenied",
                "case coreBusy", "case configurationUnavailable", "case failed",
            ] {
                XCTAssertTrue(background.contains(state), "Missing truthful state: \(state)")
            }
            XCTAssertTrue(model.contains("case .cancelled:"))
            XCTAssertTrue(model.contains("case .configurationChanged:"))
            XCTAssertTrue(model.contains("case .environmentChanged:"))
            XCTAssertTrue(model.contains("case .policyDenied:"))
            for forbidden in [".addresses", "connectionEpoch", "localPath", "remotePath"] {
                XCTAssertFalse(opportunity.contains(forbidden), "Discovery wiring uses \(forbidden)")
            }
        }

        func testDiscoveryCopyIsLocalizedInEnglishAndSimplifiedChinese() throws {
            let root = repositoryRoot()
            let english = try source("App/Resources/en.lproj/Localizable.strings", root: root)
            let chinese = try source("App/Resources/zh-Hans.lproj/Localizable.strings", root: root)
            let keys = [
                "Check for Folder Offers",
                "Cancel Offer Check",
                "Checking configured devices for folder offers…",
                "Saved summary · network revalidation required",
                "Revalidate and Accept",
                "Revalidate and Ignore",
                "No eligible unpaused configured devices are available.",
                "The folder-offer check was cancelled.",
                "Folder-offer discovery stopped because configuration changed. Refresh and try again.",
                "Folder-offer discovery stopped because its transfer-budget window changed. No stale result was assumed. Try again.",
                "Current sync policy does not allow folder-offer discovery.",
                "Configuration is ready.",
                "The core is busy, so configuration was not initialized. Refresh to try again.",
                "Configuration storage is unavailable. Restore access, then refresh to try again.",
                "Configuration initialization failed safely. Refresh to try again.",
            ]

            for key in keys {
                XCTAssertTrue(english.contains("\"\(key)\" ="), "Missing English key: \(key)")
                XCTAssertTrue(chinese.contains("\"\(key)\" ="), "Missing Chinese key: \(key)")
            }
        }

        private func functionBody(named name: String, next: String, in source: String) throws -> String {
            let start = try XCTUnwrap(source.range(of: name))
            let end = try XCTUnwrap(source.range(of: next, range: start.upperBound..<source.endIndex))
            return String(source[start.lowerBound..<end.lowerBound])
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
    }
#endif
