import SwiftUI

@main
struct PsynguechthyngueApp: App {
    @State private var model = AppModel()

    init() {
        BackgroundTaskManager.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            AppSceneView()
                .environment(model)
        }
    }
}

private struct AppSceneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var sceneID = UUID()

    var body: some View {
        RootView()
            .task { await model.start() }
            .onChange(of: phase, initial: true) { _, phase in
                model.setScene(sceneID, active: phase == .active)
                if phase == .background {
                    model.syncController.cancelUserOperationsIfInactive()
                    BackgroundTaskManager.shared.scheduleNextTasks()
                }
            }
            .onDisappear { model.setScene(sceneID, active: false) }
    }
}
