import PsyCore
import SwiftUI

private enum MainTab: String, Hashable {
    case overview
    case devices
    case folders
    case files
    case settings

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .devices: "Devices"
        case .folders: "Folders"
        case .files: "Files"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .devices: "desktopcomputer"
        case .folders: "folder"
        case .files: "doc.text.magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MainTab = .overview
    @State private var overviewPath = NavigationPath()
    @State private var devicesPath = NavigationPath()
    @State private var foldersPath = NavigationPath()
    @State private var filesPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    var body: some View {
        Group {
            switch model.startupState {
            case .loading:
                ProgressView("Starting sync engine…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Unable to start sync", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.retryStartup() } }
                        .buttonStyle(.borderedProminent)
                }
            case .ready:
                adaptiveTabView
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection == .devices || selection == .folders || selection == .settings,
                let message = model.errorMessage ?? model.statusMessage
            {
                HStack(alignment: .top) {
                    Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.errorMessage = nil
                        model.statusMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Dismiss message")
                }
                .padding()
                .background(.regularMaterial)
            }
        }
        .onChange(of: model.notificationNavigationDestination, initial: true) { _, destination in
            guard let destination else { return }
            switch destination {
            case .devices:
                devicesPath = NavigationPath()
                selection = .devices
            case .folders:
                foldersPath = NavigationPath()
                selection = .folders
            case .globalFiles:
                filesPath = NavigationPath()
                selection = .files
            }
            model.consumeNotificationNavigationDestination(destination)
        }
    }

    @ViewBuilder
    private var adaptiveTabView: some View {
        if #available(iOS 26.0, *) {
            tabView
                .tabViewStyle(.tabBarOnly)
        } else if #available(iOS 18.0, *) {
            tabView
                .tabViewStyle(.tabBarOnly)
        } else {
            tabView
        }
    }

    private var tabView: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $overviewPath) {
                OverviewView(
                    openDevices: { selection = .devices },
                    openFolders: { selection = .folders },
                    openFiles: { selection = .files },
                    openSettings: { selection = .settings }
                )
            }
            .tabItem { Label(MainTab.overview.title, systemImage: MainTab.overview.icon) }
            .tag(MainTab.overview)

            NavigationStack(path: $devicesPath) {
                DevicesView()
            }
            .tabItem { Label(MainTab.devices.title, systemImage: MainTab.devices.icon) }
            .tag(MainTab.devices)

            NavigationStack(path: $foldersPath) {
                FoldersView()
            }
            .tabItem { Label(MainTab.folders.title, systemImage: MainTab.folders.icon) }
            .tag(MainTab.folders)

            NavigationStack(path: $filesPath) {
                GlobalFilesView()
            }
            .tabItem { Label(MainTab.files.title, systemImage: MainTab.files.icon) }
            .tag(MainTab.files)

            NavigationStack(path: $settingsPath) {
                SettingsView()
            }
            .tabItem { Label(MainTab.settings.title, systemImage: MainTab.settings.icon) }
            .tag(MainTab.settings)
        }
    }

}
