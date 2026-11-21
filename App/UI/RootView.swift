import PsySync
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var selection: Tab = .home

    enum Tab: Hashable { case home, devices, folders, settings }

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .badge(model.pendingCount)
                .tag(Tab.home)
            DevicesView()
                .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                .tag(Tab.devices)
            FoldersView()
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag(Tab.folders)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay(alignment: .top) { BannerView() }
        .overlay(alignment: .bottomLeading) {
            if model.isFixture {
                // Invisible probe for UI tests: engine transitions seen by the UI.
                Text("starts=\(model.engineStarts) stops=\(model.engineStops)")
                    .font(.system(size: 1)).opacity(0.01)
                    .accessibilityIdentifier("debug.engine")
                    .allowsHitTesting(false)
            }
        }
        .animation(.default, value: model.banner)
        .fullScreenCover(isPresented: onboardingBinding) { OnboardingView() }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !settings.onboardingDone },
            set: { if !$0 { settings.onboardingDone = true } }
        )
    }
}

/// Global error / info overlay: visible on every tab, dismisses itself.
struct BannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let banner = model.banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: banner.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(banner.kind == .error ? .red : .blue)
                Text(banner.message)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.dismissBanner() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 6, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: 600)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("error-banner")
        }
    }
}
