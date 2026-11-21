import AppIntents
import Foundation

/// "Sync Now": opens the app (the engine only runs in the foreground or a BGTask)
/// and rescans every folder.
struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Now"
    static let description = IntentDescription("Open Psynguechthyngue and sync all folders.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let env = AppEnvironment.shared
        await env.host.handle(.didBecomeActive)
        await env.model.syncNow()
        return .result()
    }
}

struct PsyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncNowIntent(), phrases: ["Sync \(.applicationName)", "Sync now in \(.applicationName)"],
                    shortTitle: "Sync Now", systemImageName: "arrow.triangle.2.circlepath")
    }
}
