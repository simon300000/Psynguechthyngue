import PsyCore
import SwiftUI
import UIKit
import VisionKit

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAddDevice = false
    @State private var selectedPendingDevice: PendingDeviceOffer?
    @State private var selectedIgnoredDevice: SuppressedPendingDevice?

    var body: some View {
        Group {
            if model.snapshot.remoteDevices.isEmpty,
                model.snapshot.pendingDevices.isEmpty,
                model.snapshot.suppressedPendingDevices.isEmpty,
                model.snapshot.pendingDeviceObservationScope == .bridgeEventsPersisted,
                model.snapshot.suppressedPendingStateAvailable,
                !model.snapshot.suppressedPendingDevicesTruncated
            {
                ContentUnavailableView(
                    "No Devices",
                    systemImage: "desktopcomputer",
                    description: Text("Add a standard Syncthing device by device ID or QR code.")
                )
            } else {
                List {
                    if !model.snapshot.remoteDevices.isEmpty {
                        Section("Configured Devices") {
                            ForEach(model.snapshot.remoteDevices) { device in
                                NavigationLink {
                                    DeviceDetailView(device: device)
                                } label: {
                                    DeviceRow(device: device)
                                }
                                .contextMenu {
                                    Button(device.isPaused ? "Resume" : "Pause") {
                                        Task {
                                            await model.submit(
                                                kind: device.isPaused ? .resume : .pause,
                                                itemID: device.id.rawValue
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !model.snapshot.pendingDevices.isEmpty {
                        Section {
                            ForEach(model.snapshot.pendingDevices) { offer in
                                Button {
                                    selectedPendingDevice = offer
                                } label: {
                                    PendingDeviceRow(
                                        offer: offer,
                                        source: model.snapshot.pendingDeviceObservationScope
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the unverified device request for review.")
                            }
                        } header: {
                            Text("Pending Device Requests")
                        } footer: {
                            Text(
                                "A pending device ID and advertised label are untrusted until you verify the ID with its owner through another channel. Network addresses from unknown peers are not retained."
                            )
                        }
                    }

                    if !model.snapshot.suppressedPendingDevices.isEmpty {
                        Section {
                            ForEach(model.snapshot.suppressedPendingDevices) { record in
                                Button {
                                    selectedIgnoredDevice = record
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Allow Future Requests")
                                        Text(record.deviceID.rawValue)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .accessibilityHint(
                                    "Opens a confirmation to allow future requests from this device ID."
                                )
                            }
                        } header: {
                            Text("Ignored Device Requests")
                        } footer: {
                            Text(
                                "Ignored records contain only a device ID and version proof. Allowing future requests does not restore the previous request; the peer must announce it again."
                            )
                        }
                    }

                    if model.snapshot.pendingDeviceObservationScope != .bridgeEventsPersisted {
                        Section("Pending Request Source") {
                            Label {
                                Text(pendingDeviceSourceDescription(model.snapshot.pendingDeviceObservationScope))
                            } icon: {
                                Image(
                                    systemName: model.snapshot.pendingDeviceObservationScope == .unavailable
                                        ? "exclamationmark.triangle.fill"
                                        : "memorychip"
                                )
                            }
                            .foregroundStyle(.orange)
                        }
                    }

                    if !model.snapshot.suppressedPendingStateAvailable
                        || model.snapshot.suppressedPendingDevicesTruncated
                    {
                        Section("Ignored Request Status") {
                            if !model.snapshot.suppressedPendingStateAvailable {
                                Label(
                                    "The core cannot currently provide an authoritative ignored-request list. Ignore and Allow Future Requests are disabled.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.orange)
                            }
                            if model.snapshot.suppressedPendingDevicesTruncated {
                                Label(
                                    "Only the first 512 ignored device requests are shown.",
                                    systemImage: "list.bullet.clipboard"
                                )
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Device", systemImage: "plus") { showingAddDevice = true }
            }
        }
        .sheet(isPresented: $showingAddDevice) { AddDeviceView() }
        .sheet(item: $selectedPendingDevice) { offer in
            PendingDeviceAcceptanceView(
                offer: offer,
                observationScope: model.snapshot.pendingDeviceObservationScope
            )
        }
        .confirmationDialog(
            "Allow future requests from this device ID?",
            isPresented: Binding(
                get: { selectedIgnoredDevice != nil },
                set: { if !$0 { selectedIgnoredDevice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let record = selectedIgnoredDevice {
                Button("Allow Future Requests") {
                    selectedIgnoredDevice = nil
                    Task { await model.allowFutureDeviceRequests(record) }
                }
            }
        } message: {
            Text(
                "The previous request will not be restored. A new request appears only if this peer announces it again."
            )
        }
        .refreshable { await model.refresh() }
    }
}

private struct PendingDeviceRow: View {
    let offer: PendingDeviceOffer
    let source: PendingDeviceObservationScope

    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(offer.label.isEmpty ? String(localized: "No advertised label") : offer.label)
                Text(offer.deviceID.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("Unverified identity · \(pendingDeviceSourceTitle(source))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                String(
                    localized:
                        "Pending unverified device \(offer.label.isEmpty ? offer.deviceID.rawValue : offer.label)"
                )
            )
        )
        .accessibilityValue(Text(pendingDeviceSourceDescription(source)))
    }
}

private struct PendingDeviceAcceptanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let offer: PendingDeviceOffer
    let observationScope: PendingDeviceObservationScope
    @State private var name: String
    @State private var paused = false
    @State private var identityConfirmed = false
    @State private var showingConfirmation = false
    @State private var showingIgnoreConfirmation = false
    @State private var isSubmitting = false

    init(offer: PendingDeviceOffer, observationScope: PendingDeviceObservationScope) {
        self.offer = offer
        self.observationScope = observationScope
        _name = State(initialValue: offer.label)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Unverified Identity") {
                    LabeledContent(
                        "Advertised Name",
                        value: offer.label.isEmpty ? String(localized: "None") : offer.label
                    )
                    Text(offer.deviceID.rawValue)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    LabeledContent("Observed") {
                        Text(offer.lastSeen, style: .relative)
                    }
                    LabeledContent("Offer Source", value: pendingDeviceSourceTitle(observationScope))
                }

                Section("Risk Review") {
                    Label(
                        "The advertised name and device ID came from an unknown peer and do not prove who controls it.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(.orange)
                    Text(pendingDeviceSourceDescription(observationScope))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(
                        "Compare the complete device ID with the owner through a trusted channel. This flow never accepts an address advertised by the unknown peer."
                    )
                    .font(.footnote)
                    Toggle("I verified this complete device ID with its owner", isOn: $identityConfirmed)
                }

                Section("Local Configuration") {
                    TextField("Name", text: $name)
                    Toggle("Add Paused", isOn: $paused)
                    Text("No folders are shared automatically when this device is accepted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("Cannot accept device: \(validationMessage)"))
                    }
                }
            }
            .navigationTitle("Review Device Request")
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Accept Device") { showingConfirmation = true }
                        .disabled(validationMessage != nil || isSubmitting)
                        .keyboardShortcut(.defaultAction)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Ignore Request", role: .destructive) {
                        showingIgnoreConfirmation = true
                    }
                    .disabled(!canIgnore || isSubmitting)
                }
            }
            .confirmationDialog(
                "Accept this unverified device?",
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Accept Unverified Device", role: .destructive) {
                    acceptDevice()
                }
            } message: {
                Text(
                    "Only the verified device ID, your local name, and paused setting will be submitted. No observed network address or folder permission is accepted."
                )
            }
            .confirmationDialog(
                "Ignore future repeats of this device request?",
                isPresented: $showingIgnoreConfirmation,
                titleVisibility: .visible
            ) {
                Button("Ignore Device Request", role: .destructive) {
                    ignoreDevice()
                }
            } message: {
                Text(
                    "Only the device ID and exact offer version are submitted. The advertised name and network addresses are not stored. You can allow future requests later."
                )
            }
        }
    }

    private var canIgnore: Bool {
        model.snapshot.suppressedPendingStateAvailable
            && model.snapshot.pendingDeviceObservationScope == observationScope
            && model.snapshot.pendingDevices.first(where: { $0.deviceID == offer.deviceID }) == offer
    }

    private var validationMessage: String? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= 256,
            normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            return String(localized: "Enter a name no longer than 256 UTF-8 bytes and without control characters.")
        }
        guard identityConfirmed else {
            return String(localized: "Verify the complete device ID and confirm the identity check.")
        }
        return nil
    }

    private func acceptDevice() {
        guard validationMessage == nil else { return }
        isSubmitting = true
        Task {
            let accepted = await model.acceptPendingDevice(
                offer,
                observationScope: observationScope,
                name: name,
                paused: paused,
                confirmedUnverifiedIdentity: identityConfirmed
            )
            isSubmitting = false
            if accepted { dismiss() }
        }
    }

    private func ignoreDevice() {
        guard canIgnore else { return }
        isSubmitting = true
        Task {
            let ignored = await model.ignorePendingDevice(
                offer,
                observationScope: observationScope
            )
            isSubmitting = false
            if ignored { dismiss() }
        }
    }
}

private func pendingDeviceSourceTitle(_ scope: PendingDeviceObservationScope) -> String {
    switch scope {
    case .bridgeEventsPersisted:
        String(localized: "Persisted bridge events")
    case .bridgeEventsMemoryOnly:
        String(localized: "Memory-only bridge events")
    case .unavailable:
        String(localized: "Unavailable")
    }
}

private func pendingDeviceSourceDescription(_ scope: PendingDeviceObservationScope) -> String {
    switch scope {
    case .bridgeEventsPersisted:
        String(localized: "The minimal offer was observed from bridge events and saved across app restarts.")
    case .bridgeEventsMemoryOnly:
        String(
            localized:
                "The minimal offer currently exists only in bridge memory and may disappear after the core restarts. Acceptance still rechecks its exact version."
        )
    case .unavailable:
        String(
            localized:
                "The core cannot currently provide a trustworthy pending-device view. No device request can be accepted until it becomes available."
        )
    }
}

private struct DeviceRow: View {
    let device: DeviceRecord

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(device.name.isEmpty ? device.id.rawValue : device.name)
                Text("Last check: \(deviceStateTitle(device.state))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(device.name.isEmpty ? device.id.rawValue : device.name))
        .accessibilityValue(Text(deviceStateTitle(device.state)))
        .accessibilityHint("Opens device details and controls.")
    }

    private var icon: String { device.state == .connected ? "checkmark.circle.fill" : "circle.dashed" }
    private var color: Color { device.state == .connected ? .green : .secondary }
}

private struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    private let initialDevice: DeviceRecord
    @State private var editing = false
    @State private var confirmingRemoval = false

    init(device: DeviceRecord) { initialDevice = device }

    private var device: DeviceRecord {
        model.snapshot.devices.first { $0.id == initialDevice.id } ?? initialDevice
    }

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Name", value: device.name)
                Text(device.id.rawValue).font(.caption.monospaced()).textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = device.id.rawValue
                } label: {
                    Label("Copy Device ID", systemImage: "doc.on.doc")
                }
                .accessibilityHint("Copies the full Syncthing device ID to the system clipboard.")
                ShareLink(item: device.id.rawValue)
                    .accessibilityLabel("Share Device ID")
                    .accessibilityHint("Shares the full Syncthing device ID.")
            }
            Section("Connection") {
                LabeledContent("State", value: deviceStateTitle(device.state))
                LabeledContent("Last Online") {
                    if let lastSeen = device.lastSeen { Text(lastSeen, style: .relative) } else { Text("Never") }
                }
                ForEach(device.addresses, id: \.self) { Text($0).textSelection(.enabled) }
            }
            Section {
                LabeledContent(
                    "Upload",
                    value: "\(device.uploadBytesPerSecond.formatted(.byteCount(style: .file)))/s"
                )
                LabeledContent(
                    "Download",
                    value: "\(device.downloadBytesPerSecond.formatted(.byteCount(style: .file)))/s"
                )
                LabeledContent(
                    "Pending Upload",
                    value: device.pendingBytes.formatted(.byteCount(style: .file))
                )
            } header: {
                Text("Transfer")
            } footer: {
                Text("Rates are sampled when the embedded core publishes a network snapshot.")
            }
            if let reason = device.blockingReason {
                Section("Blocked") { Text(reason).foregroundStyle(.orange) }
            }
            Section {
                Button(device.isPaused ? "Resume Device" : "Pause Device") {
                    Task {
                        await model.submit(
                            kind: device.isPaused ? .resume : .pause,
                            itemID: device.id.rawValue
                        )
                    }
                }
                Button("Edit Device") { editing = true }
                Button("Remove Device", role: .destructive) { confirmingRemoval = true }
                    .accessibilityHint("Opens a confirmation before removing the peer configuration.")
            }
        }
        .disabled(!model.snapshot.devices.contains { $0.id == initialDevice.id })
        .navigationTitle(device.name)
        .sheet(isPresented: $editing) {
            EditDeviceView(device: device)
        }
        .confirmationDialog(
            "Remove this device configuration?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Device", role: .destructive) {
                Task { await model.submit(kind: .removeDevice, itemID: device.id.rawValue) }
            }
        } message: {
            Text("This removes the peer configuration. It does not delete synchronized files.")
        }
    }
}

struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var deviceID = ""
    @State private var name = ""
    @State private var addresses = "dynamic"
    @State private var paused = false
    @State private var scanning = false
    @State private var isSubmitting = false
    @State private var submissionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Name", text: $name)
                    TextField("Device ID", text: $deviceID, axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                    Button("Scan QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
                        .disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)
                        .accessibilityHint("Opens the camera to scan a Syncthing device ID.")
                    DisclosureGroup("Advanced Settings") {
                        TextField("Addresses (one per line)", text: $addresses, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Add Paused", isOn: $paused)
                    }
                }
                if !deviceID.isEmpty, DeviceID(syncthingString: deviceID) == nil {
                    Text("Enter a complete, valid Syncthing device ID.").foregroundStyle(.red)
                }
                if let submissionError {
                    Text(submissionError).foregroundStyle(.red)
                }
                Section {
                    Text("Verify the device owner and shared-folder permissions before accepting unexpected requests.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Add Device")
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let id = DeviceID(syncthingString: deviceID) else { return }
                        isSubmitting = true
                        submissionError = nil
                        Task {
                            let didSubmit = await model.addDevice(
                                id: id,
                                name: name,
                                addresses: parsedDeviceAddresses(addresses),
                                paused: paused
                            )
                            isSubmitting = false
                            if didSubmit {
                                dismiss()
                            } else {
                                submissionError = model.errorMessage ?? model.statusMessage
                            }
                        }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("Add") }
                    }
                    .disabled(DeviceID(syncthingString: deviceID) == nil || isSubmitting)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    DeviceIDScanner { value in
                        deviceID = value
                        scanning = false
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityLabel("QR code scanner")
                    .accessibilityHint("Point the camera at a Syncthing device ID QR code.")
                    .navigationTitle("Scan QR Code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { scanning = false }
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                }
            }
        }
    }
}

private struct EditDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let device: DeviceRecord
    @State private var name: String
    @State private var addresses: String
    @State private var paused: Bool
    @State private var isSubmitting = false
    @State private var submissionError: String?

    init(device: DeviceRecord) {
        self.device = device
        _name = State(initialValue: device.name)
        _addresses = State(initialValue: device.addresses.joined(separator: "\n"))
        _paused = State(initialValue: device.isPaused)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("ID", value: device.id.rawValue)
                    TextField("Name", text: $name)
                    TextField("Addresses (one per line)", text: $addresses, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Paused", isOn: $paused)
                }
                if let submissionError {
                    Text(submissionError).foregroundStyle(.red)
                }
            }
            .navigationTitle("Edit Device")
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isSubmitting = true
                        submissionError = nil
                        Task {
                            let didSubmit = await model.editDevice(
                                id: device.id,
                                name: name,
                                addresses: parsedDeviceAddresses(addresses),
                                paused: paused
                            )
                            isSubmitting = false
                            if didSubmit {
                                dismiss()
                            } else {
                                submissionError = model.errorMessage ?? model.statusMessage
                            }
                        }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("Save") }
                    }
                    .disabled(isSubmitting)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

private func deviceStateTitle(_ state: DeviceConnectionState) -> String {
    switch state {
    case .disconnected: String(localized: "Disconnected")
    case .connecting: String(localized: "Connecting")
    case .connected: String(localized: "Connected")
    case .paused: String(localized: "Paused")
    case .blocked: String(localized: "Blocked")
    case .error: String(localized: "Error")
    }
}

private func parsedDeviceAddresses(_ value: String) -> [String] {
    value
        .split(whereSeparator: { $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private struct DeviceIDScanner: UIViewControllerRepresentable {
    let onValue: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onValue: onValue) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onValue: (String) -> Void
        init(onValue: @escaping (String) -> Void) { self.onValue = onValue }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            guard case .barcode(let barcode) = item,
                let value = barcode.payloadStringValue,
                let deviceID = DeviceID(syncthingString: value)
            else { return }
            onValue(deviceID.rawValue)
        }
    }
}
