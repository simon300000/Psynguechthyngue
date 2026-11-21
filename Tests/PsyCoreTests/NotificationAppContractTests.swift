import Foundation
import XCTest

#if os(macOS)
    final class NotificationAppContractTests: XCTestCase {
        func testPlatformContentIsGenericAndPayloadIsCategoryOnly() throws {
            let root = repositoryRoot()
            let appModel = try source("App/AppModel.swift", root: root)
            let schedule = try XCTUnwrap(
                appModel.range(of: "func schedule(")
            )
            let delegate = try XCTUnwrap(
                appModel.range(
                    of: "nonisolated func userNotificationCenter",
                    range: schedule.upperBound..<appModel.endIndex
                )
            )
            let body = String(appModel[schedule.lowerBound..<delegate.lowerBound])

            XCTAssertTrue(body.contains("content.userInfo = request.deepLinkPayload"))
            XCTAssertTrue(body.contains("A device request needs review"))
            XCTAssertTrue(body.contains("A folder offer needs review"))
            XCTAssertTrue(body.contains("File conflicts need review"))
            XCTAssertTrue(body.contains("A recovery item needs review"))
            for forbidden in [
                "relativePath", "localPath", "deviceID", "folderID", "addresses",
                "recoveryID", "locator", "offer.label", "snapshot.", "summary.", "\\(",
            ] {
                XCTAssertFalse(body.contains(forbidden), "lock-screen content uses \(forbidden)")
            }
        }

        func testPermissionPromptIsExplicitAndDeepLinkRevalidatesBeforeOneShotNavigation() throws {
            let root = repositoryRoot()
            let appModel = try source("App/AppModel.swift", root: root)
            let settings = try source("App/SettingsView.swift", root: root)
            let rootView = try source("App/RootView.swift", root: root)
            let eventStore = try source(
                "Sources/PsyCore/Notifications/NotificationEventStore.swift",
                root: root
            )

            XCTAssertTrue(settings.contains("Review Notifications"))
            XCTAssertTrue(settings.contains("model.setNotificationsEnabled(enabled)"))
            XCTAssertTrue(eventStore.contains("if status == .notDetermined"))
            XCTAssertTrue(eventStore.contains("status: .dispatching"))
            XCTAssertTrue(eventStore.contains("claimToken == claim.token"))
            XCTAssertTrue(eventStore.contains("if platformAccepted"))
            XCTAssertTrue(appModel.contains("SharedSnapshotStore(snapshotURL: paths.snapshot).read()"))
            XCTAssertTrue(appModel.contains("NotificationDeepLinkValidator.isActionable"))
            XCTAssertTrue(appModel.contains("enqueueNotificationNavigationDestination(destination)"))
            XCTAssertTrue(appModel.contains("queuedNotificationNavigationDestinations.append(destination)"))
            XCTAssertTrue(
                appModel.contains(
                    "notificationNavigationDestination = queuedNotificationNavigationDestinations.removeFirst()"
                )
            )
            XCTAssertTrue(rootView.contains("consumeNotificationNavigationDestination(destination)"))
            XCTAssertTrue(appModel.contains("bufferedDestinations: [NotificationDestination]"))
            XCTAssertTrue(appModel.contains("pendingNotificationResponseDestinations"))
            XCTAssertTrue(appModel.contains("await drainPendingNotificationResponses()"))
            XCTAssertTrue(appModel.contains("func drainPendingNotificationResponses() async"))
            XCTAssertTrue(
                settings.contains("This is not real-time push delivery")
            )
        }

        func testBackgroundSchedulingRunsOnlyInsideAnActuallyLaunchedHandler() throws {
            let background = try source("App/BackgroundTaskManager.swift", root: repositoryRoot())
            let submitStart = try XCTUnwrap(
                background.range(of: "nonisolated private static func submitNextTasks")
            )
            let launchedHandler = String(background[..<submitStart.lowerBound])
            let requestScheduling = String(background[submitStart.lowerBound...])

            XCTAssertEqual(
                launchedHandler.components(separatedBy: "AppNotificationDelivery.deliver").count - 1,
                2
            )
            XCTAssertFalse(requestScheduling.contains("AppNotificationDelivery.deliver"))
            XCTAssertTrue(launchedHandler.contains("guard outcome.completedSuccessfully, !Task.isCancelled"))
            XCTAssertTrue(launchedHandler.contains("guard succeeded, !Task.isCancelled"))
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
