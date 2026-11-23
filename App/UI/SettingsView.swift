import PsySync
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppSettings.self) private var settings
    @State private var confirmReset = false

    private static let limits = [0, 128, 256, 512, 1024, 2048, 5120]

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    NavigationLink { StorageView() } label: { Label("Storage", systemImage: "internaldrive") }
                        .accessibilityIdentifier("settings.storage")
                }

                // Mac (Designed for iPad): no cellular and no BGTaskScheduler, so the
                // cellular and background-sync options would have no effect there.
                if !model.isOnMac {
                    Section {
                        Toggle("Sync over cellular", isOn: $settings.syncOnCellular)
                            .accessibilityIdentifier("settings.cellular")
                        Toggle("Respect Low Data Mode", isOn: $settings.respectLowDataMode)
                            .accessibilityIdentifier("settings.lowdata")
                        if settings.syncOnCellular {
                            limitPicker("Cellular upload limit", value: $settings.cellularSendLimit)
                            limitPicker("Cellular download limit", value: $settings.cellularReceiveLimit)
                        }
                    } header: { Text("Network") }
                }

                Section {
                    Toggle("Pause in Low Power Mode", isOn: $settings.pauseInLowPowerMode)
                        .accessibilityIdentifier("settings.lowpower")
                    Toggle("Pause while the device is hot", isOn: $settings.pauseWhenHot)
                        .accessibilityIdentifier("settings.thermal")
                } header: { Text("Power") } footer: {
                    Text("When the device gets very hot, syncing pauses until it cools down. Turning this off lets syncing continue, but the system may still slow the device down.")
                }

                if model.isOnMac {
                    Section {
                        Text("On Mac, syncing continues while the window is open or minimized. Closing the window quits the app and stops syncing.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.machint")
                    } header: { Text("Background") }
                } else {
                    Section {
                        Toggle("Background sync", isOn: $settings.backgroundSync)
                            .accessibilityIdentifier("settings.background")
                        Toggle("Keep syncing in background automatically", isOn: $settings.autoContinueInBackground)
                            .accessibilityIdentifier("settings.autocontinue")
                        LabeledContent("Last background sync") {
                            if let d = settings.lastBackgroundRun { Text(Format.relative(d)) } else { Text("Never") }
                        }
                    } header: { Text("Background") } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("iOS decides when background syncing runs, usually a few times a day. Syncing is continuous while the app is open.")
                            Text("When transfers start, keep them going after you leave the app, with the system’s progress indicator.")
                        }
                    }
                }

                Section {
                    Toggle("Notifications", isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { on in
                            settings.notificationsEnabled = on
                            if on { Task { if !(await model.notifier.requestAuthorization()) && !model.isFixture { settings.notificationsEnabled = false } } }
                        }
                    ))
                    .accessibilityIdentifier("settings.notifications")
                } footer: { Text("Get notified about new device requests, folder invitations and sync problems.") }

                Section {
                    LabeledContent("Files location") {
                        switch model.filesLocation {
                        case .enabled: Text("On")
                        case .disabled: Text("Off").foregroundStyle(.orange)
                        case .unknown: Text("—")
                        }
                    }
                    .accessibilityIdentifier("settings.fileslocation")
                    if model.filesLocation == .disabled { FilesDisabledCard() }
                } header: { Text("Files") }

                Section("About") {
                    LabeledContent("Version") { Text("\(AppInfo.version) (\(AppInfo.build))") }
                    LabeledContent("Syncthing") { Text(model.syncthingVersion.isEmpty ? "—" : model.syncthingVersion) }
                        .accessibilityIdentifier("settings.syncthingversion")
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                        .accessibilityIdentifier("settings.diagnostics")
                    NavigationLink("Licenses") { LicensesView() }
                }

                Section {
                    DisclosureGroup("Advanced") {
                        EngineOptionsSection()
                        ShareLink(item: model.diagnosticsText()) { Label("Export Diagnostics", systemImage: "stethoscope") }
                        Button("Reset Devices and Folders", role: .destructive) { confirmReset = true }
                            .accessibilityIdentifier("settings.reset")
                    }
                }
            }
            .contentMargins(.horizontal, sizeClass == .regular ? 80 : nil, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 48)
            .glassScreen()
            .navigationTitle("Settings")
            .task { await model.refreshFilesLocation() }
            .confirmationDialog("Reset devices and folders?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { Task { await model.resetConfiguration() } }
            } message: {
                Text("All devices and folders are removed from this app. Files already on this device are kept.")
            }
        }
    }

    private func limitPicker(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
        Picker(title, selection: value) {
            ForEach(Self.limits, id: \.self) { v in
                if v == 0 { Text("Unlimited").tag(0) } else { Text("\(v) KB/s").tag(v) }
            }
        }
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section {
                Text("Psynguechthyngue uses Syncthing, which is licensed under the Mozilla Public License 2.0. The source code of the exact Syncthing release used is available at github.com/syncthing/syncthing.")
            }
            if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                Section { Text(text).font(.caption.monospaced()) }
            }
        }
        .glassScreen()
        .navigationTitle("Licenses")
    }
}

/// Engine-owned options (device name, discovery, relays, listen addresses).
/// Read from and written straight to the engine; changes apply immediately.
struct EngineOptionsSection: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var listen = ""
    @State private var loadedFrom: EngineOptions?
    private enum Field { case name, listen }
    @FocusState private var focused: Field?

    var body: some View {
        if let options = model.engineOptions {
            Group {
                TextField("Device name", text: $name, prompt: Text(DefaultDeviceName.current))
                    .plainNameInput()
                    .submitLabel(.done)
                    .focused($focused, equals: .name)
                    .onSubmit { commitName() }
                    .accessibilityIdentifier("settings.devicename")
                Toggle("Global discovery", isOn: Binding(
                    get: { options.globalDiscovery },
                    set: { v in Task { await model.updateOptions { $0.globalDiscovery = v } } }
                ))
                .accessibilityIdentifier("settings.globaldiscovery")
                Toggle("Relays", isOn: Binding(
                    get: { options.relays },
                    set: { v in Task { await model.updateOptions { $0.relays = v } } }
                ))
                .accessibilityIdentifier("settings.relays")
                Text("Global discovery and relays help devices find each other over the internet. They share this device’s ID and IP address with the public Syncthing servers.")
                    .font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Listen addresses").font(.subheadline)
                    TextField("default", text: $listen)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focused, equals: .listen)
                        .onSubmit { commitListen() }
                        .accessibilityIdentifier("settings.listen")
                    Text("Separate several addresses with commas, e.g. tcp://:22000. “default” lets Syncthing choose.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear { load(options) }
            .onChange(of: options) { _, new in load(new) }
            .onDisappear { commitName(); commitListen() }
        } else {
            Text("Advanced options are available while syncing is running.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Takes the engine's values, except for a field the user is editing
    /// (focused and changed since the last load): toggling an option reloads
    /// `options` and must not discard unsaved typing.
    private func load(_ options: EngineOptions) {
        guard options != loadedFrom else { return }
        let previous = loadedFrom
        loadedFrom = options
        let shownListen = previous?.listenAddresses.joined(separator: ", ")
        if focused != .name || previous == nil || name == previous?.deviceName {
            name = options.deviceName
        }
        if focused != .listen || previous == nil || listen == shownListen {
            listen = options.listenAddresses.joined(separator: ", ")
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != model.engineOptions?.deviceName else { return }
        Task { await model.updateOptions { $0.deviceName = trimmed } }
    }

    private func commitListen() {
        let list = listen.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !list.isEmpty, list != model.engineOptions?.listenAddresses else { return }
        Task { await model.updateOptions { $0.listenAddresses = list } }
    }
}
