import Foundation
import PsyCore
import UIKit
import UserNotifications

extension AppModel {
    func setNotificationsEnabled(_ enabled: Bool) async {
        guard let notificationCoordinator, !isUpdatingNotificationSettings else { return }
        isUpdatingNotificationSettings = true
        defer { isUpdatingNotificationSettings = false }
        do {
            let result = try await notificationCoordinator.setNotificationsEnabled(enabled)
            switch result {
            case .enabled(let status):
                notificationsEnabled = true
                notificationAuthorizationStatus = status
                notificationStateUnavailable = false
                statusMessage = String(
                    localized:
                        "Review notifications are enabled. iOS may deliver them after a foreground refresh or an opportunistic background run."
                )
                await deliverNotifications(
                    snapshot: snapshot,
                    mutationRecoveries: coreMutationRecoveries
                )
            case .disabled:
                notificationsEnabled = false
                notificationStateUnavailable = false
                statusMessage = String(localized: "Review notifications are disabled.")
            case .permissionDenied:
                notificationsEnabled = false
                notificationAuthorizationStatus = .denied
                notificationStateUnavailable = false
                statusMessage = String(
                    localized:
                        "Notification permission is denied. You can allow it in iOS Settings."
                )
            case .authorizationUnavailable:
                notificationsEnabled = false
                notificationAuthorizationStatus = .notDetermined
                notificationStateUnavailable = false
                statusMessage = String(
                    localized:
                        "iOS did not grant notification permission, so review notifications remain disabled."
                )
            }
        } catch {
            notificationStateUnavailable = true
            statusMessage = String(
                localized:
                    "Notification settings could not be updated safely. No notification was scheduled."
            )
            await reloadNotificationConfiguration()
        }
    }

    func openSystemNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func consumeNotificationNavigationDestination(_ destination: NotificationDestination) {
        guard notificationNavigationDestination == destination else { return }
        if queuedNotificationNavigationDestinations.isEmpty {
            notificationNavigationDestination = nil
        } else {
            notificationNavigationDestination = queuedNotificationNavigationDestinations.removeFirst()
        }
    }

    func reloadNotificationConfiguration() async {
        guard let notificationCoordinator else { return }
        notificationAuthorizationStatus = await notificationCoordinator.authorizationStatus()
        do {
            notificationsEnabled = try await notificationCoordinator.configuration().isEnabled
            notificationStateUnavailable = false
        } catch {
            notificationsEnabled = false
            notificationStateUnavailable = true
        }
    }

    func deliverNotifications(
        snapshot: CoreSnapshot,
        mutationRecoveries: [CoreMutationRecoverySummary] = []
    ) async {
        guard let notificationCoordinator else { return }
        let report = await notificationCoordinator.deliverNewEvents(
            snapshot: snapshot,
            mutationRecoveries: mutationRecoveries
        )
        notificationAuthorizationStatus = await notificationCoordinator.authorizationStatus()
        switch report.outcome {
        case .storeUnavailable:
            notificationStateUnavailable = true
        case .disabled, .authorizationRequired, .permissionDenied, .noNewEvents,
            .scheduled, .partiallyScheduled, .schedulingFailed, .cancelled:
            notificationStateUnavailable = false
        }
    }

    /// A notification supplies only a broad destination. This method re-reads
    /// authoritative state after the App opens, then emits a one-shot route
    /// only if that category still contains work requiring review.
    func handleNotificationResponse(_ destination: NotificationDestination) async {
        guard let paths else {
            if !pendingNotificationResponseDestinations.contains(destination) {
                pendingNotificationResponseDestinations.append(destination)
            }
            return
        }
        let authoritativeSnapshot: CoreSnapshot
        do {
            let latest = try await Task.detached(priority: .userInitiated) {
                try SharedSnapshotStore(snapshotURL: paths.snapshot).read()
            }.value
            guard let loaded = latest else {
                throw NotificationDeepLinkError.snapshotUnavailable
            }
            authoritativeSnapshot = loaded
            snapshot = loaded
        } catch {
            statusMessage = String(
                localized:
                    "This notification could not be revalidated against the latest authoritative state. No destination was opened."
            )
            return
        }
        let isStillActionable: Bool
        switch destination {
        case .devices, .folders:
            isStillActionable = NotificationDeepLinkValidator.isActionable(
                destination,
                snapshot: authoritativeSnapshot
            )
        case .globalFiles:
            if NotificationDeepLinkValidator.isActionable(
                destination,
                snapshot: authoritativeSnapshot
            ) {
                isStillActionable = true
            } else if isCoreMutationRecoveryLoading {
                isStillActionable = false
            } else {
                await refreshCoreMutationRecoveries(reset: true)
                isStillActionable = NotificationDeepLinkValidator.isActionable(
                    destination,
                    snapshot: authoritativeSnapshot,
                    mutationRecoveries: coreMutationRecoveries,
                    mutationRecoveryStateAvailable: coreMutationRecoveryFailureCode == nil
                )
            }
        }
        guard isStillActionable else {
            statusMessage = String(
                localized:
                    "This notification is no longer current. The latest authoritative state has no matching item to review."
            )
            return
        }
        enqueueNotificationNavigationDestination(destination)
    }

    func drainPendingNotificationResponses() async {
        let pendingDestinations = pendingNotificationResponseDestinations
        pendingNotificationResponseDestinations.removeAll(keepingCapacity: true)
        for destination in pendingDestinations {
            await handleNotificationResponse(destination)
        }
    }

    func enqueueNotificationNavigationDestination(
        _ destination: NotificationDestination
    ) {
        guard notificationNavigationDestination != destination,
            !queuedNotificationNavigationDestinations.contains(destination)
        else {
            return
        }
        if notificationNavigationDestination == nil {
            notificationNavigationDestination = destination
        } else {
            queuedNotificationNavigationDestinations.append(destination)
        }
    }

    /// Loads policy state only for the current durable folder incarnation.
    /// Both incarnation reads must agree so a concurrent remove-and-readd is
    /// surfaced to the editor instead of inheriting authority by folder ID.
}
