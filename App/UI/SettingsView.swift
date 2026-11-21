import PsySync
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
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
                         ? "On Mac, syncing continues while the app is open."
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

                Section("About") {
                    LabeledContent("Version") { Text("\(AppInfo.version) (\(AppInfo.build))") }
                    LabeledContent("Syncthing") { Text(AppInfo.syncthingVersion) }
                    NavigationLink("Licenses") { LicensesView() }
                }

                Section {
                    DisclosureGroup("Advanced") {
                        TextField("Device name", text: $settings.deviceName, prompt: Text(UIDevice.current.name))
                            .accessibilityIdentifier("settings.devicename")
                        Toggle("Global discovery", isOn: $settings.globalDiscovery)
                            .accessibilityIdentifier("settings.globaldiscovery")
                        Toggle("Relays", isOn: $settings.relaysEnabled)
                            .accessibilityIdentifier("settings.relays")
                        Text("Global discovery and relays help devices find each other over the internet. They share this device’s ID and IP address with the public Syncthing servers.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ShareLink(item: model.diagnosticsText()) { Label("Export Diagnostics", systemImage: "stethoscope") }
                        Button("Reset Devices and Folders", role: .destructive) { confirmReset = true }
                            .accessibilityIdentifier("settings.reset")
                    }
                }
            }
            .navigationTitle("Settings")
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
        .navigationTitle("Licenses")
    }
}
