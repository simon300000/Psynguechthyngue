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
                    Toggle("Sync over cellular", isOn: $settings.syncOnCellular)
                        .accessibilityIdentifier("settings.cellular")
                    Toggle("Respect Low Data Mode", isOn: $settings.respectLowDataMode)
                        .accessibilityIdentifier("settings.lowdata")
                    if settings.syncOnCellular {
                        limitPicker("Cellular upload limit", value: $settings.cellularSendLimit)
                        limitPicker("Cellular download limit", value: $settings.cellularReceiveLimit)
                    }
                } header: { Text("Network") }

                Section {
                    Toggle("Pause in Low Power Mode", isOn: $settings.pauseInLowPowerMode)
                        .accessibilityIdentifier("settings.lowpower")
                } header: { Text("Power") }

                Section {
                    Toggle("Background sync", isOn: $settings.backgroundSync)
                        .accessibilityIdentifier("settings.background")
                    LabeledContent("Last background sync") {
                        if let d = settings.lastBackgroundRun { Text(Format.relative(d)) } else { Text("Never") }
                    }
                } header: { Text("Background") } footer: {
                    Text(model.isOnMac
                         ? "On Mac, syncing continues while the window is open or minimized. Closing the window quits the app and stops syncing."
                         : "iOS decides when background syncing runs, usually a few times a day. Syncing is continuous while the app is open.")
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

    var body: some View {
        if let options = model.engineOptions {
            Group {
                TextField("Device name", text: $name, prompt: Text(UIDevice.current.name))
                    .submitLabel(.done)
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

    private func load(_ options: EngineOptions) {
        guard options != loadedFrom else { return }
        loadedFrom = options
        name = options.deviceName
        listen = options.listenAddresses.joined(separator: ", ")
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
