import PsySync
import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        let _ = perfProbe("DevicesView")
        NavigationStack {
            Group {
                if model.devices.isEmpty {
                    ContentUnavailableView {
                        Label("No devices yet", systemImage: "laptopcomputer.and.iphone")
                    } description: {
                        Text("Add the computer or phone you want to sync with.")
                    } actions: {
                        Button("Add Device") { adding = true }
                            .buttonStyle(.glassProminent)
                            .accessibilityIdentifier("devices.empty.add")
                    }
                } else {
                    ScrollView {
                        GlassEffectContainer(spacing: 4) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                                ForEach(model.devices) { device in
                                    NavigationLink(value: device.id) {
                                        DeviceRow(device: device)
                                            .padding(.horizontal, 18).padding(.vertical, 14)
                                            .glassCard(cornerRadius: GlassMetrics.row, interactive: true)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("device.row.\(device.id.short)")
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 96)   // room for the floating button
                    }
                    .task { await model.metrics.watchTraffic() }
                }
            }
            .glassScreen()
            .navigationTitle("Devices")
            .navigationDestination(for: DeviceID.self) { DeviceDetailView(deviceID: $0) }
            .overlay(alignment: .bottomTrailing) {
                if !model.devices.isEmpty {
                    FloatingActionButton(title: "Add Device", systemImage: "plus", identifier: "devices.add") { adding = true }
                }
            }
            .toolbar {
                if model.devices.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { adding = true } label: { Label("Add Device", systemImage: "plus") }
                            .accessibilityIdentifier("devices.add")
                    }
                }
            }
            .sheet(isPresented: $adding) { AddDeviceView().bannerOverlay().environment(model) }
            .onChange(of: model.pendingCommand, initial: true) { _, command in
                if command == .addDevice { model.pendingCommand = nil; adding = true }
            }
        }
    }
}

struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: Device

    var body: some View {
        let _ = perfProbe("DeviceRow")
        let conn = model.connections[device.id]
        HStack(spacing: 14) {
            Image(systemName: icon(conn))
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color(conn))
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.nilIfEmpty ?? device.id.short).font(.headline)
                subtitle(conn).font(.subheadline).foregroundStyle(.secondary)
                if !device.paused && conn?.state == .connected {
                    RatePair(rate: model.metrics.deviceRates[device.id] ?? .zero)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("device.row.rates")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func icon(_ conn: DeviceConnection?) -> String {
        if device.paused { return "pause.circle.fill" }
        return conn?.state == .connected ? "checkmark.circle.fill" : "moon.zzz.fill"
    }

    private func color(_ conn: DeviceConnection?) -> Color {
        if device.paused { return .secondary }
        return conn?.state == .connected ? .green : .orange
    }

    @ViewBuilder private func subtitle(_ conn: DeviceConnection?) -> some View {
        if device.paused {
            Text("Paused")
        } else if conn?.state == .connected {
            Text(Format.connectionLabel(conn))
        } else if let seen = conn?.lastSeen {
            Text("Last seen \(Format.relative(seen))")
        } else {
            Text("Offline")
        }
    }
}

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deviceID: DeviceID
    @State private var name = ""
    @State private var loaded = false
    @State private var confirmRemove = false
    /// Set when Remove was confirmed: the view then disappears and its
    /// onDisappear must not PATCH the deleted device.
    @State private var removed = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let _ = perfProbe("DeviceDetailView")
        if let device = model.devices.first(where: { $0.id == deviceID }) {
            Form {
                Section("Name") {
                    TextField("Device name", text: $name)
                        .plainNameInput()
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { commitName() }
                        .accessibilityIdentifier("device.name")
                }
                Section {
                    Toggle("Pause syncing with this device", isOn: Binding(
                        get: { device.paused },
                        set: { v in Task { await model.updateDevice(id: deviceID) { $0.paused = v } } }
                    ))
                    .accessibilityIdentifier("device.pause")
                }
                DeviceConnectionSection(device: device)
                Section("Shared folders") {
                    let shared = model.folders.filter { $0.devices.contains(deviceID) }
                    if shared.isEmpty {
                        Text("No folders are shared with this device.").foregroundStyle(.secondary)
                    }
                    ForEach(shared) { f in
                        NavigationLink(f.label, value: f.id)
                    }
                }
                Section {
                    DisclosureGroup("Technical details") {
                        Text(device.id.rawValue).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section {
                    Button("Remove Device", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("device.remove")
                }
            }
            .glassScreen()
            .navigationTitle(device.name.nilIfEmpty ?? device.id.short)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FolderID.self) { FolderDetailView(folderID: $0) }
            .onAppear { if !loaded { name = device.name; loaded = true } }
            .onDisappear { commitName() }
            .confirmationDialog("Remove this device?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    removed = true
                    Task {
                        if await model.remove(device) { dismiss() } else { removed = false }
                    }
                }
                .accessibilityIdentifier("device.remove.confirm")
            } message: {
                Text("Files that were already synced stay on this device. You can add the device again later.")
            }
        } else {
            ContentUnavailableView("Device removed", systemImage: "trash")
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // The latest device, not the render-time copy; gone after Remove.
        guard loaded, !removed, !trimmed.isEmpty,
              let current = model.devices.first(where: { $0.id == deviceID }), trimmed != current.name else { return }
        Task { await model.updateDevice(id: deviceID) { $0.name = trimmed } }
    }
}
