import PsySync
import UIKit

/// Commands reachable from the menu bar (Mac, Designed for iPad) and the iPad
/// keyboard shortcut overlay. Routed through `AppModel.pendingCommand`.
enum AppCommand: Equatable {
    case syncNow
    case addDevice
    case newFolder
}

enum AppMenu {
    static let identifier = UIMenu.Identifier("app.psynguechthyngue.menu.sync")

    /// Builds the "Sync" menu. On iOS 27 the item images are explicitly made
    /// visible (`preferredImageVisibility`), so Designed for iPad on macOS shows
    /// the same symbol-led menu items as native apps instead of text-only items.
    static func build(with builder: UIMenuBuilder) {
        guard builder.system == .main else { return }
        let items: [UIKeyCommand] = [
            command(String(localized: "Sync Now"), image: "arrow.clockwise", key: "r", modifiers: .command,
                    action: #selector(AppDelegate.menuSyncNow(_:))),
            command(String(localized: "Add Device…"), image: "plus.circle", key: "d", modifiers: [.command, .shift],
                    action: #selector(AppDelegate.menuAddDevice(_:))),
            command(String(localized: "New Folder…"), image: "folder.badge.plus", key: "n", modifiers: [.command, .shift],
                    action: #selector(AppDelegate.menuNewFolder(_:))),
        ]
        let menu = UIMenu(title: String(localized: "Sync"), identifier: identifier, children: items)
        builder.insertSibling(menu, afterMenu: .view)
    }

    private static func command(_ title: String, image: String, key: String, modifiers: UIKeyModifierFlags, action: Selector) -> UIKeyCommand {
        let cmd = UIKeyCommand(title: title, image: UIImage(systemName: image), action: action, input: key, modifierFlags: modifiers)
        if #available(iOS 27.0, *) {
            cmd.preferredImageVisibility = .visible
        }
        return cmd
    }
}

/// Mac only: closing the last window quits a Designed-for-iPad app and stops
/// syncing (Docs/REWRITE/MAC_SPIKE.md). While transfers are running, iOS 27's
/// `UISceneClosureConfirmation` asks before the window closes.
@MainActor
enum ClosureConfirmation {
    static func update(transfersActive: Bool, isOnMac: Bool) {
        guard isOnMac else { return }
        guard #available(iOS 27.0, *) else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let confirm = transfersActive && scenes.count == 1
        for scene in scenes {
            if confirm, scene.closureConfirmation == nil {
                scene.closureConfirmation = UISceneClosureConfirmation(
                    title: String(localized: "Stop syncing?"),
                    message: String(localized: "Closing the last window quits Psynguechthyngue and stops the transfers in progress. Minimize the window to keep syncing."),
                    actions: []   // system default Close / Cancel
                )
                LifecycleLog.shared.record("closure-confirmation", "installed")
            } else if !confirm, scene.closureConfirmation != nil {
                scene.closureConfirmation = nil
                LifecycleLog.shared.record("closure-confirmation", "removed")
            }
        }
    }
}

/// Default local device name. On Mac (Designed for iPad) `UIDevice.current.name`
/// is the generic "iPad", which is what peers would see; use "Mac" instead.
@MainActor
enum DefaultDeviceName {
    static var current: String {
        ProcessInfo.processInfo.isiOSAppOnMac ? "Mac" : UIDevice.current.name
    }
}
