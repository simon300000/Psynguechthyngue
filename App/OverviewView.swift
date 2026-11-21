import PsyCore
import SwiftUI
import UIKit

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    var openDevices: () -> Void = {}
    var openFolders: () -> Void = {}
    var openFiles: () -> Void = {}
    var openSettings: () -> Void = {}
    @State private var showingAddDevice = false
    @State private var showingAddFolder = false
    @State private var showingIdentity = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    if model.syncController.activity == .running || model.isSubmittingCommand {
                        ProgressView()
                    } else {
                        Image(systemName: statusIcon).font(.title2).foregroundStyle(statusColor)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(statusTitle).font(.headline).accessibilityIdentifier("sync.status")
                        Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                Button {
                    Task {
                        await model.submit(kind: .sync, arguments: ["timeoutMS": "15000", "settleMS": "500"])
                    }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isSubmittingCommand)
                .keyboardShortcut("r", modifiers: [.command])
                Toggle(
                    "Sync while app is open",
                    isOn: Binding(
                        get: { model.foregroundSyncEnabled },
                        set: { model.setForegroundSyncEnabled($0) }
                    ))
                if let message = model.statusMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Sync Status")
            } footer: {
                Text("Keep the app open for ongoing transfers. Background sync runs when iOS grants time.")
            }

            if let error = model.errorMessage {
                Section("Needs Attention") {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try Again") { Task { await model.refresh() } }
                }
            }

            if model.snapshot.remoteDevices.isEmpty || model.snapshot.folders.isEmpty {
                Section("Get Started") {
                    if model.snapshot.remoteDevices.isEmpty {
                        Button {
                            showingAddDevice = true
                        } label: {
                            Label("Connect your first device", systemImage: "desktopcomputer")
                        }
                        Text("Add the other device here, then add this iPhone or iPad on that device using its ID.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Button(action: openDevices) {
                            Label("Devices connected for sharing", systemImage: "checkmark.circle")
                        }
                    }
                    Button {
                        showingAddFolder = true
                    } label: {
                        Label("Create a shared folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(model.snapshot.remoteDevices.isEmpty)
                    if !model.snapshot.remoteDevices.isEmpty {
                        Button(action: openFolders) {
                            Label("Find a folder shared with you", systemImage: "tray.and.arrow.down")
                        }
                    }
                    Button {
                        showingIdentity = true
                    } label: {
                        Label("Share Device ID", systemImage: "qrcode")
                    }
                }
            }

            if !model.snapshot.pendingDevices.isEmpty || !model.snapshot.pendingFolders.isEmpty {
                Section("Sharing Requests") {
                    if !model.snapshot.pendingDevices.isEmpty {
                        Button(action: openDevices) {
                            Label("Review device requests", systemImage: "person.badge.plus")
                            Spacer()
                            Text("\(model.snapshot.pendingDevices.count)").foregroundStyle(.secondary)
                        }
                    }
                    if !model.snapshot.pendingFolders.isEmpty {
                        Button(action: openFolders) {
                            Label("Review folder offers", systemImage: "folder.badge.plus")
                            Spacer()
                            Text("\(model.snapshot.pendingFolders.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !model.snapshot.folders.isEmpty {
                Section("Your Folders") {
                    ForEach(model.snapshot.folders) { folder in
                        Button(action: openFolders) {
                            HStack {
                                Label(folder.label, systemImage: folder.isPaused ? "pause.circle" : "folder")
                                Spacer()
                                if let error = folder.error, !error.isEmpty {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                        .accessibilityLabel(Text(error))
                                } else if folder.isPaused {
                                    Text("Paused").foregroundStyle(.secondary)
                                } else {
                                    Text(
                                        folder.pendingDownloadBytes + folder.pendingUploadBytes,
                                        format: .byteCount(style: .file)
                                    )
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                    Button(action: openFiles) { Label("Browse Files", systemImage: "doc.text.magnifyingglass") }
                }
            }

            Section("Files Location") {
                Label(
                    filesLocationTitle,
                    systemImage: model.fileProviderDomainStatus == .enabled
                        ? "checkmark.circle" : "folder.badge.questionmark")
                Text(
                    "In Files, open Browse, edit Locations, then enable Psynguechthyngue. Open this location to find your shared folders."
                )
                .font(.subheadline).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showingIdentity = true
                } label: {
                    Label("This Device", systemImage: "iphone")
                }
                NavigationLink {
                    SyncDiagnosticsView()
                } label: {
                    Label("Sync Details", systemImage: "waveform.path.ecg")
                }
                if case .blocked = model.syncController.activity {
                    Button(action: openSettings) { Label("Review Sync Settings", systemImage: "slider.horizontal.3") }
                }
                DisclosureGroup("About your file copies") {
                    Text(
                        "Keep a complete copy on another device or in a backup. Remove Download frees local space; Delete Everywhere also deletes the shared file on other devices."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Overview")
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showingAddDevice) { AddDeviceView() }
        .sheet(isPresented: $showingAddFolder) { AddManagedFolderView() }
        .sheet(isPresented: $showingIdentity) { ThisDeviceView() }
    }

    private var statusTitle: String {
        if model.isSubmittingCommand { return String(localized: "Applying your action") }
        if model.snapshot.remoteDevices.isEmpty { return String(localized: "Connect a device to begin") }
        if model.snapshot.folders.isEmpty { return String(localized: "Choose a folder to share") }
        switch model.syncController.activity {
        case .running: return String(localized: "Checking for changes")
        case .paused: return String(localized: "Automatic sync paused")
        case .stopped: return String(localized: "Sync stopped")
        case .waiting: return String(localized: "Waiting for next check")
        case .blocked: return String(localized: "Waiting for allowed conditions")
        case .failed: return String(localized: "Sync needs attention")
        }
    }

    private var statusDetail: String {
        switch model.syncController.activity {
        case .blocked(let reasons):
            return reasons.first.map(syncBlockDescription) ?? String(localized: "Review Sync Settings")
        case .failed(let code):
            return String(localized: "Open Sync Details to review the last attempt. Code: \(code)")
        case .paused:
            return String(localized: "Use Sync Now for a manual check, or turn automatic sync back on.")
        default:
            return String(localized: "A saved status is not proof that every device is up to date.")
        }
    }

    private var statusIcon: String {
        switch model.syncController.activity {
        case .failed: "exclamationmark.triangle"
        case .blocked, .paused: "pause.circle"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch model.syncController.activity {
        case .failed: .red
        case .blocked: .orange
        default: .accentColor
        }
    }

    private var filesLocationTitle: String {
        switch model.fileProviderDomainStatus {
        case .enabled: String(localized: "Files location enabled")
        case .checking: String(localized: "Checking Files location")
        case .noShares: String(localized: "Create a shared folder to use Files")
        case .disabled: String(localized: "Files location disabled")
        case .notInstalled: String(localized: "Files location not installed")
        case .unavailable: String(localized: "Files location unavailable")
        }
    }
}

struct ThisDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let id = model.snapshot.localDeviceID {
                        QRCodeView(value: id.rawValue, accessibilityTitle: "Local device ID QR code")
                            .frame(maxWidth: .infinity).frame(height: 200)
                            .accessibilityLabel("Local device ID QR code")
                    }
                    Text(model.localDeviceIDText).font(.callout.monospaced()).textSelection(.enabled)
                    Button("Copy Device ID", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = model.localDeviceIDText
                    }
                    ShareLink(item: model.localDeviceIDText) {
                        Label("Share Device ID", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("On your other device, add this ID and share the folders you want to sync.")
                }
            }
            .navigationTitle("This Device")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private func syncBlockDescription(_ reason: PolicyBlockReason) -> String {
    switch reason {
    case .networkUnavailable: String(localized: "Connect to Wi-Fi or another allowed network.")
    case .networkTypeDenied, .cellularDirectionDenied, .cellularFileTooLarge:
        String(localized: "This network is restricted by your sync settings. Connect to Wi-Fi or review the settings.")
    case .expensiveNetworkDenied: String(localized: "Sync is waiting for a network without a metered connection.")
    case .constrainedNetworkDenied:
        String(localized: "Low Data Mode is on. Change networks or review your sync settings.")
    case .externalPowerRequired, .batteryTooLow: String(localized: "Connect this device to power to continue syncing.")
    case .lowPowerMode: String(localized: "Turn off Low Power Mode or change your sync settings.")
    case .thermalPressure: String(localized: "This device needs to cool down before transfers continue.")
    case .insufficientDisk: String(localized: "Free some storage space before downloading more files.")
    case .outsideTimeWindow: String(localized: "Automatic sync is waiting for your scheduled time window.")
    case .runTransferLimit, .dailyTransferLimit, .dailyTransferAccountingUnavailable:
        String(localized: "A transfer limit is preventing sync. Review limits in Settings.")
    case .coreBusy, .databaseMaintenance: String(localized: "Another file operation is finishing. Sync will retry.")
    case .unresolvedConflict, .unuploadedChanges: String(localized: "Review pending changes before continuing.")
    case .backgroundActionDisabled, .noRequestedAction: String(localized: "Review Sync Settings")
    }
}
