import PsySync
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var selection: AppTab = RootView.initialTab

    enum AppTab: String, Hashable { case home, devices, folders, settings }

    /// `-PsyUITestInitialTab <name>` (fixtures only) for screenshots.
    private static var initialTab: AppTab {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-PsyUITestFixture"), let i = args.firstIndex(of: "-PsyUITestInitialTab"), i + 1 < args.count else { return .home }
        return AppTab(rawValue: args[i + 1]) ?? .home
    }

    var body: some View {
        let _ = perfProbe("RootView")
        TabView(selection: $selection) {
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath", value: AppTab.home) {
                HomeView()
            }
            .badge(model.pendingCount)
            Tab("Devices", systemImage: "laptopcomputer.and.iphone", value: AppTab.devices) {
                DevicesView()
            }
            Tab("Folders", systemImage: "folder", value: AppTab.folders) {
                FoldersView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        // iPad: floating top tab bar that can become a sidebar; iPhone: bottom bar.
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        // The Sync tab already shows transfers; show the accessory elsewhere.
        // Reads of per-event state (statuses, transfers) live in the modifier,
        // so a progress tick re-evaluates it, not this body and the TabView.
        .modifier(SyncAccessoryModifier(onHome: selection == .home, model: model))
        .overlay(alignment: .top) { BannerView() }
        .animation(.smooth, value: model.banner)
        .overlay(alignment: .bottomLeading) {
            if model.isFixture {
                // Invisible probe for UI tests: engine transitions seen by the UI.
                Text(verbatim: "starts=\(model.engineStarts) stops=\(model.engineStops)")
                    .font(.system(size: 1)).opacity(0.01)
                    .accessibilityIdentifier("debug.engine")
                    .allowsHitTesting(false)
            }
        }
        // Presented content on Mac (Designed for iPad) is hosted outside this view's
        // environment, so pass the observable models explicitly.
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView().environment(model).environment(settings)
        }
        .onChange(of: model.pendingCommand) { _, command in
            switch command {
            case .syncNow:
                model.pendingCommand = nil
                Task { await model.syncNow() }
            case .addDevice: selection = .devices    // DevicesView presents the sheet
            case .newFolder: selection = .folders    // FoldersView presents the sheet
            case nil: break
            }
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !settings.onboardingDone },
            set: { if !$0 { settings.onboardingDone = true } }
        )
    }
}

/// The dynamic bottom accessory needs iOS 26.1 (deployment target is 26.0);
/// on 26.0 progress is still shown on the Sync tab.
private struct SyncAccessoryModifier: ViewModifier {
    let onHome: Bool
    let model: AppModel

    func body(content: Content) -> some View {
        let enabled = !onHome && !model.syncingFolders.isEmpty
        Group {
            if #available(iOS 26.1, *) {
                content.tabViewBottomAccessory(isEnabled: enabled) { SyncProgressAccessory().environment(model) }
            } else {
                content
            }
        }
        .onChange(of: model.hasActiveTransfers, initial: true) { _, active in
            ClosureConfirmation.update(transfersActive: active, isOnMac: model.isOnMac)
        }
    }
}

/// Compact progress shown above (or inline with) the tab bar while syncing.
struct SyncProgressAccessory: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = perfProbe("SyncProgressAccessory")
        let folders = model.syncingFolders
        let statuses = folders.map { model.status(of: $0).progress }
        let total = statuses.reduce(Int64(0)) { $0 + $1.globalBytes }
        let need = statuses.reduce(Int64(0)) { $0 + $1.needBytes }
        let fraction = total > 0 ? Double(total - need) / Double(total) : 0
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeating)
                .foregroundStyle(.tint)
            Text(folders.count == 1 ? folders[0].label : String(localized: "\(folders.count) folders"))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("accessory.progress")
    }
}

extension View {
    /// Sheets cover RootView's banner, so errors from a sheet's own action
    /// (add device, new/accept folder) were invisible: repeat it on top.
    func bannerOverlay() -> some View { overlay(alignment: .top) { BannerView() } }

    /// Names and labels (device names, folder labels) are identifiers people
    /// type exactly: no automatic capitalization or autocorrection.
    func plainNameInput() -> some View {
        textInputAutocapitalization(.never).autocorrectionDisabled()
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
            .padding(14)
            .glassCard(cornerRadius: GlassMetrics.row, tint: banner.kind == .error ? .red : .blue)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: 600)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("error-banner")
        }
    }
}
