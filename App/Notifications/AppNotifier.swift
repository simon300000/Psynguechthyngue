import Foundation
import PsySync
import UserNotifications

/// Local notifications for things that need the user (new device request,
/// folder invitation, errors). Source is `EngineEvent` (DESIGN.md §8.2);
/// delivery only happens while the app is not active (BGTask runs).
@MainActor
final class AppNotifier {
    private let center: UNUserNotificationCenter?
    private var seenDevices = Set<DeviceID>()
    private var seenFolders = Set<String>()
    private var seenIssues = Set<String>()

    init(center: UNUserNotificationCenter? = nil, enabled: Bool = true) {
        self.center = enabled ? (center ?? UNUserNotificationCenter.current()) : nil
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func handle(_ event: EngineEvent, isActive: Bool, enabled: Bool) {
        // Always track what has been seen so we never re-notify; only post when allowed.
        switch event {
        case let .pendingDevicesChanged(list):
            let fresh = list.filter { seenDevices.insert($0.id).inserted }
            guard enabled, !isActive, let first = fresh.first else { return }
            post(id: "pending-device-\(first.id.short)",
                 title: String(localized: "New device request"),
                 body: String(localized: "\(first.name.isEmpty ? first.id.short : first.name) wants to connect."))
        case let .pendingFoldersChanged(list):
            let fresh = list.filter { seenFolders.insert($0.id).inserted }
            guard enabled, !isActive, let first = fresh.first else { return }
            post(id: "pending-folder-\(first.id)",
                 title: String(localized: "Folder invitation"),
                 body: String(localized: "A device wants to share “\(first.label)” with you."))
        case let .folderStatusChanged(status):
            let fresh = status.issues.filter { seenIssues.insert($0.id).inserted }
            guard enabled, !isActive, let first = fresh.first else { return }
            post(id: "issue-\(first.id)",
                 title: String(localized: "Sync problem"),
                 body: first.kind == .conflict
                    ? String(localized: "A file conflict needs your attention.")
                    : String(localized: "A folder could not be synced. Open the app for details."))
        default:
            break
        }
    }

    private func post(id: String, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
