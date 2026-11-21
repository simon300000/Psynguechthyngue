import Foundation
import PsyCore
import SwiftUI

struct FoldersView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAddManagedFolder = false
    @State private var selectedPendingFolder: PendingFolderOffer?
    @State private var selectedIgnoredFolder: SuppressedPendingFolder?

    var body: some View {
        Group {
            if model.snapshot.folders.isEmpty,
                model.snapshot.pendingFolders.isEmpty,
                model.snapshot.suppressedPendingFolders.isEmpty,
                model.snapshot.pendingFoldersAvailable,
                !model.snapshot.pendingFoldersTruncated,
                model.snapshot.suppressedPendingStateAvailable,
                !model.snapshot.suppressedPendingFoldersTruncated
            {
                VStack(spacing: 18) {
                    ContentUnavailableView(
                        "No Syncthing Folders",
                        systemImage: "folder.badge.plus",
                        description: Text(
                            "Create an internal managed Syncthing folder or check configured devices for folder offers."
                        )
                    )
                    PendingFolderDiscoveryControl()
                        .padding(.horizontal)
                }
            } else {
                List {
                    Section {
                        PendingFolderDiscoveryControl()
                    } header: {
                        Text("Find Folder Offers")
                    } footer: {
                        Text(
                            "Each check contacts a rotating batch of at most two configured, unpaused devices. Saved summaries remain review-only until the exact offer is revalidated over the network."
                        )
                    }

                    if !model.snapshot.folders.isEmpty {
                        Section {
                            ForEach(model.snapshot.folders) { folder in
                                ConfiguredFolderListRow(
                                    folder: folder,
                                    expectedFolderIncarnationDigest:
                                        model.folderIncarnationDigests[folder.id]
                                )
                            }
                        } footer: {
                            Text(
                                "Each configured share uses App-owned storage and appears as its own folder in the Psynguechthyngue location in Files."
                            )
                        }
                    }

                    if !model.snapshot.pendingFolders.isEmpty {
                        Section {
                            ForEach(model.snapshot.pendingFolders) { offer in
                                Button {
                                    selectedPendingFolder = offer
                                } label: {
                                    PendingFolderRow(
                                        offer: offer,
                                        offeringDevice: model.snapshot.devices.first(where: {
                                            $0.id == offer.offeringDeviceID
                                        })
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the pending folder offer for risk review.")
                            }
                        } header: {
                            Text("Pending Folder Offers")
                        } footer: {
                            Text(
                                "Accepting an offer creates a new App-owned managed folder. A path advertised by a remote peer is never used."
                            )
                        }
                    }

                    if !model.snapshot.suppressedPendingFolders.isEmpty {
                        Section {
                            ForEach(model.snapshot.suppressedPendingFolders) { record in
                                Button {
                                    selectedIgnoredFolder = record
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Allow Future Requests")
                                        Text("Folder ID: \(record.folderID.rawValue)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Text("Device ID: \(record.offeringDeviceID.rawValue)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .accessibilityHint(
                                    "Opens a confirmation to allow future offers from this device for this folder ID."
                                )
                            }
                        } header: {
                            Text("Ignored Folder Offers")
                        } footer: {
                            Text(
                                "Ignored records contain only folder and device IDs plus a version proof. Allowing future requests does not restore the previous offer; the peer must announce it again."
                            )
                        }
                    }

                    if !model.snapshot.pendingFoldersAvailable || model.snapshot.pendingFoldersTruncated {
                        Section("Pending Offer Status") {
                            if !model.snapshot.pendingFoldersAvailable {
                                Label(
                                    "The core cannot currently provide an authoritative pending-folder list. Acceptance is disabled.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.orange)
                            }
                            if model.snapshot.pendingFoldersTruncated {
                                Label(
                                    "Only the first 512 pending folder offers are shown. Refresh after handling visible offers to review the rest.",
                                    systemImage: "list.bullet.clipboard"
                                )
                                .foregroundStyle(.orange)
                            }
                        }
                    }

                    if !model.snapshot.suppressedPendingStateAvailable
                        || model.snapshot.suppressedPendingFoldersTruncated
                    {
                        Section("Ignored Offer Status") {
                            if !model.snapshot.suppressedPendingStateAvailable {
                                Label(
                                    "The core cannot currently provide an authoritative ignored-offer list. Ignore and Allow Future Requests are disabled.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.orange)
                            }
                            if model.snapshot.suppressedPendingFoldersTruncated {
                                Label(
                                    "Only the first 512 ignored folder offers are shown.",
                                    systemImage: "list.bullet.clipboard"
                                )
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Folders")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Folder", systemImage: "plus") {
                    showingAddManagedFolder = true
                }
                .accessibilityHint("Creates an App-managed Syncthing share.")
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
        .sheet(isPresented: $showingAddManagedFolder) {
            AddManagedFolderView()
        }
        .sheet(item: $selectedPendingFolder) { offer in
            PendingFolderAcceptanceView(offer: offer)
        }
        .confirmationDialog(
            "Allow future offers from this device for this folder ID?",
            isPresented: Binding(
                get: { selectedIgnoredFolder != nil },
                set: { if !$0 { selectedIgnoredFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let record = selectedIgnoredFolder {
                Button("Allow Future Requests") {
                    selectedIgnoredFolder = nil
                    Task { await model.allowFutureFolderRequests(record) }
                }
            }
        } message: {
            Text(
                "The previous offer will not be restored. A new offer appears only if this peer announces it again."
            )
        }
        .refreshable { await model.refresh() }
    }
}

private struct ConfiguredFolderListRow: View {
    @Environment(AppModel.self) private var model
    let folder: FolderRecord
    let expectedFolderIncarnationDigest: String?

    var body: some View {
        NavigationLink {
            FolderDetailView(
                folder: folder,
                expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
            )
        } label: {
            FolderRow(
                folder: folder,
                isInternallyManaged: model.isInternallyManagedFolder(folder)
            )
        }
        .contextMenu {
            Button(folder.isPaused ? "Resume" : "Pause") {
                Task {
                    await model.submit(
                        kind: folder.isPaused ? .resume : .pause,
                        folderID: folder.id,
                        expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
                    )
                }
            }
            .disabled(expectedFolderIncarnationDigest == nil)
            Button("Rescan") {
                Task {
                    await model.submit(
                        kind: .rescan,
                        folderID: folder.id,
                        expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
                    )
                }
            }
            .disabled(expectedFolderIncarnationDigest == nil)
        }
    }
}

private struct PendingFolderDiscoveryControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isDiscoveringPendingFolderOffers {
                Label(
                    "Checking configured devices for folder offers…",
                    systemImage: "network"
                )
                Button("Cancel Offer Check", role: .cancel) {
                    model.cancelPendingFolderDiscovery()
                }
            } else {
                Button("Check for Folder Offers", systemImage: "arrow.triangle.2.circlepath") {
                    model.startPendingFolderDiscovery()
                }
                .disabled(!model.canDiscoverPendingFolderOffers)
            }

            if let message = model.pendingFolderDiscoveryStatusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.canDiscoverPendingFolderOffers,
                !model.isDiscoveringPendingFolderOffers
            {
                Text("No eligible unpaused configured devices are available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PendingFolderRow: View {
    let offer: PendingFolderOffer
    let offeringDevice: DeviceRecord?

    var body: some View {
        HStack {
            Image(systemName: pendingOfferIcon)
                .foregroundStyle(pendingOfferColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(offer.label.isEmpty ? offer.folderID.rawValue : offer.label)
                Text("Folder ID: \(offer.folderID.rawValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(
                    "Offered by \(offeringDevice?.name.isEmpty == false ? offeringDevice?.name ?? offer.offeringDeviceID.rawValue : offer.offeringDeviceID.rawValue)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if offer.supportsReceiveEncryptedAcceptance {
                    Text("Receive Encrypted offer · explicit review required")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if offer.hasInvalidEncryptionContract {
                    Text("Invalid encrypted offer · cannot accept")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if offer.evidenceSource == .durableSummary,
                    offer.requiresNetworkRevalidation
                {
                    Text("Saved summary · network revalidation required")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
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
                        "Pending folder \(offer.label.isEmpty ? offer.folderID.rawValue : offer.label) from \(offeringDevice?.name.isEmpty == false ? offeringDevice?.name ?? offer.offeringDeviceID.rawValue : offer.offeringDeviceID.rawValue)"
                )
            )
        )
        .accessibilityValue(
            Text(
                offer.hasInvalidEncryptionContract
                    ? String(localized: "Invalid encrypted offer; acceptance unavailable")
                    : offer.supportsReceiveEncryptedAcceptance
                        ? String(localized: "Receive Encrypted offer; requires explicit review")
                        : String(localized: "Unencrypted offer; requires explicit review")
            )
        )
    }

    private var pendingOfferIcon: String {
        offer.hasInvalidEncryptionContract
            ? "folder.badge.minus"
            : offer.supportsReceiveEncryptedAcceptance ? "lock.shield" : "folder.badge.questionmark"
    }

    private var pendingOfferColor: Color {
        offer.hasInvalidEncryptionContract ? .red : .orange
    }
}

private struct PendingFolderAcceptanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let offer: PendingFolderOffer
    @State private var label: String
    @State private var folderTypeRawValue: String
    @State private var rescanIntervalText: String
    @State private var paused = false
    @State private var selectedDeviceIDs: Set<DeviceID>
    @State private var storageAndDevicesConfirmed = false
    @State private var showingConfirmation = false
    @State private var showingIgnoreConfirmation = false
    @State private var isSubmitting = false

    init(offer: PendingFolderOffer) {
        self.offer = offer
        _label = State(initialValue: offer.label.isEmpty ? offer.folderID.rawValue : offer.label)
        _folderTypeRawValue = State(
            initialValue: offer.advertisesEncryption
                ? FolderType.receiveEncrypted.rawValue : FolderType.sendReceive.rawValue
        )
        _rescanIntervalText = State(initialValue: offer.advertisesEncryption ? "86400" : "3600")
        _selectedDeviceIDs = State(initialValue: [offer.offeringDeviceID])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote Offer") {
                    LabeledContent("Folder ID", value: offer.folderID.rawValue)
                    LabeledContent(
                        "Advertised Label",
                        value: offer.label.isEmpty ? String(localized: "None") : offer.label
                    )
                    LabeledContent("Offering Device") {
                        VStack(alignment: .trailing) {
                            Text(offeringDevice?.name.isEmpty == false ? offeringDevice?.name ?? "" : "")
                            Text(offer.offeringDeviceID.rawValue)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    LabeledContent("Observed") {
                        Text(offer.lastSeen, style: .relative)
                    }
                }

                if offer.evidenceSource == .durableSummary,
                    offer.requiresNetworkRevalidation
                {
                    Section("Saved Discovery Summary") {
                        Label(
                            "Saved summary · network revalidation required",
                            systemImage: "network.badge.shield.half.filled"
                        )
                        .foregroundStyle(.orange)
                        Text(
                            "This summary is display evidence only. Accepting or ignoring first performs a separate bounded observation and requires an exact proof of the offer you reviewed."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Encryption Risk") {
                    if offer.hasInvalidEncryptionContract {
                        Label(
                            "Both encrypted-direction tokens are present. Syncthing treats this as an invalid encrypted-folder contract, so it will not be accepted or queued.",
                            systemImage: "lock.trianglebadge.exclamationmark.fill"
                        )
                        .foregroundStyle(.red)
                        LabeledContent(
                            "Receive Encrypted",
                            value: offer.receiveEncrypted
                                ? String(localized: "Yes") : String(localized: "No")
                        )
                        LabeledContent(
                            "Remote Encrypted",
                            value: offer.remoteEncrypted
                                ? String(localized: "Yes") : String(localized: "No")
                        )
                    } else if offer.supportsReceiveEncryptedAcceptance {
                        Label(
                            "This peer offers an encrypted replica. The app will store opaque encrypted names and content as Receive Encrypted; it cannot browse or edit the plaintext.",
                            systemImage: "lock.shield.fill"
                        )
                        .foregroundStyle(.orange)
                        Text(
                            "No sender password is requested or stored on this receiving device. The verified Syncthing connection supplies the encryption token, and the local folder type is fixed to Receive Encrypted."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        Label("The offer does not advertise encrypted-folder semantics.", systemImage: "lock.open")
                            .foregroundStyle(.secondary)
                    }
                }

                if model.isRevalidatingPendingFolderOffer(offer) {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Revalidating this offer with the offering device…")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Revalidating this pending folder offer")
                    } footer: {
                        Text(
                            "No acceptance or ignore request is queued until this bounded revalidation succeeds."
                        )
                    }
                }

                Section {
                    TextField("Label", text: $label)
                    Picker("Folder Type", selection: $folderTypeRawValue) {
                        ForEach(supportedFolderTypes, id: \.rawValue) { type in
                            Text(folderTypeTitle(type)).tag(type.rawValue)
                        }
                    }
                    .disabled(offer.advertisesEncryption)
                    TextField("Rescan Interval (Seconds)", text: $rescanIntervalText)
                        .keyboardType(.numberPad)
                    Toggle("Add Paused", isOn: $paused)
                } header: {
                    Text("Local Managed Folder")
                } footer: {
                    Text(
                        "The share appears as its own folder in the Psynguechthyngue location in Files. No path supplied by the remote peer is accepted."
                    )
                }

                Section {
                    ForEach(peerDevices) { device in
                        Toggle(isOn: deviceSelectionBinding(device.id)) {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(device.name.isEmpty ? device.id.rawValue : device.name)
                                    if device.id == offer.offeringDeviceID {
                                        Text("Offering Device")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .background(.orange.opacity(0.2), in: Capsule())
                                    }
                                }
                                Text(device.id.rawValue)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Explicit Device Selection")
                } footer: {
                    Text(
                        "The offering device must be selected explicitly. No other configured peer receives this folder unless you select it here."
                    )
                }

                Section("Final Review") {
                    Toggle(
                        "I confirm the App-owned storage and selected device list",
                        isOn: $storageAndDevicesConfirmed
                    )
                    Text(
                        "Accepting adds a local Syncthing folder configuration. It does not import a remote path or share with unselected devices."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("Cannot accept folder: \(validationMessage)"))
                    }
                }
            }
            .navigationTitle("Review Folder Offer")
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(acceptButtonTitle) { showingConfirmation = true }
                        .disabled(validationMessage != nil || isSubmitting)
                        .keyboardShortcut(.defaultAction)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(ignoreButtonTitle, role: .destructive) {
                        showingIgnoreConfirmation = true
                    }
                    .disabled(!canIgnore || isSubmitting)
                }
            }
            .confirmationDialog(
                "Accept this folder into App-owned storage?",
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Create Managed Folder and Accept") {
                    acceptFolder()
                }
            } message: {
                Text(
                    "The app will first revalidate this exact offer. Only then can a durable acceptance request name \(selectedDeviceIDs.count) explicitly selected remote device(s), including the offering device."
                )
            }
            .confirmationDialog(
                "Ignore future repeats of this folder offer?",
                isPresented: $showingIgnoreConfirmation,
                titleVisibility: .visible
            ) {
                Button("Ignore Folder Offer", role: .destructive) {
                    ignoreFolder()
                }
            } message: {
                Text(
                    "The app will first revalidate this exact offer. A redacted proof temporarily retains the reviewed label, last-seen time, and encryption flags for up to five minutes and is consumed by this decision. The durable ignore record retains only the folder ID, offering device ID, and exact offer version. No folder is created when ignoring. Remote paths and addresses are never retained or accepted."
                )
            }
        }
    }

    private var canIgnore: Bool {
        model.snapshot.pendingFoldersAvailable
            && model.snapshot.suppressedPendingStateAvailable
            && model.snapshot.pendingFolders.first(where: { $0.id == offer.id }) == offer
            && hasSafeEvidenceContract
    }

    private var acceptButtonTitle: String {
        offer.evidenceSource == .durableSummary && offer.requiresNetworkRevalidation
            ? String(localized: "Revalidate and Accept")
            : String(localized: "Accept Folder")
    }

    private var ignoreButtonTitle: String {
        offer.evidenceSource == .durableSummary && offer.requiresNetworkRevalidation
            ? String(localized: "Revalidate and Ignore")
            : String(localized: "Ignore Offer")
    }

    private var hasSafeEvidenceContract: Bool {
        switch offer.evidenceSource {
        case .live:
            !offer.requiresNetworkRevalidation
        case .durableSummary:
            offer.requiresNetworkRevalidation
        }
    }

    private var offeringDevice: DeviceRecord? {
        model.snapshot.devices.first(where: { $0.id == offer.offeringDeviceID })
    }

    private var peerDevices: [DeviceRecord] {
        model.snapshot.devices.filter {
            $0.id != model.snapshot.localDeviceID
                && (!offer.advertisesEncryption || $0.id == offer.offeringDeviceID)
        }
    }

    private var supportedFolderTypes: [FolderType] {
        offer.advertisesEncryption
            ? [.receiveEncrypted]
            : [.sendReceive, .sendOnly, .receiveOnly]
    }

    private var parsedRescanInterval: Int? {
        strictNonnegativeInteger(rescanIntervalText)
    }

    private var validationMessage: String? {
        guard model.snapshot.pendingFoldersAvailable else {
            return String(localized: "The core cannot currently verify this pending folder offer.")
        }
        guard model.snapshot.pendingFolders.first(where: { $0.id == offer.id }) == offer else {
            return String(localized: "This offer changed or expired. Refresh and review the current version.")
        }
        guard hasSafeEvidenceContract else {
            return String(
                localized:
                    "This saved offer summary no longer has its required revalidation marker. Refresh before making a decision."
            )
        }
        guard !offer.hasInvalidEncryptionContract else {
            return String(
                localized: "The offer advertises an invalid encrypted-folder contract and cannot be accepted.")
        }
        guard offer.advertisesEncryption == (folderTypeRawValue == FolderType.receiveEncrypted.rawValue) else {
            return String(
                localized: "Encrypted offers must use Receive Encrypted; unencrypted offers cannot use that type.")
        }
        guard !model.snapshot.folders.contains(where: { $0.id == offer.folderID }) else {
            return String(localized: "A folder with this ID is already configured.")
        }
        guard isValidManagedFolderLabel(label) else {
            return String(localized: "Enter a label containing 1 to 256 UTF-8 bytes and no control characters.")
        }
        guard let parsedRescanInterval,
            (0...managedFolderMaximumRescanIntervalS).contains(parsedRescanInterval)
        else {
            return String(localized: "Enter a rescan interval from 0 to 31,536,000 seconds.")
        }
        guard
            folderTypeRawValue != FolderType.receiveEncrypted.rawValue
                || parsedRescanInterval == 0
                || parsedRescanInterval >= 86_400
        else {
            return String(localized: "Receive Encrypted rescans must be disabled or at least 86,400 seconds apart.")
        }
        guard offeringDevice != nil else {
            return String(localized: "The offering device is no longer configured.")
        }
        guard selectedDeviceIDs.contains(offer.offeringDeviceID) else {
            return String(localized: "Explicitly select the device that offered this folder.")
        }
        let peerIDs = Set(peerDevices.map(\.id))
        guard !selectedDeviceIDs.isEmpty, selectedDeviceIDs.isSubset(of: peerIDs) else {
            return String(localized: "Every selected device must still be a configured remote peer.")
        }
        guard !offer.advertisesEncryption || selectedDeviceIDs == [offer.offeringDeviceID] else {
            return String(
                localized: "A Receive Encrypted offer can be accepted only from its verified offering device.")
        }
        guard storageAndDevicesConfirmed else {
            return String(localized: "Confirm the App-owned storage and explicit device selection.")
        }
        return nil
    }

    private func deviceSelectionBinding(_ id: DeviceID) -> Binding<Bool> {
        Binding(
            get: { selectedDeviceIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedDeviceIDs.insert(id)
                } else {
                    selectedDeviceIDs.remove(id)
                }
            }
        )
    }

    private func acceptFolder() {
        guard let type = FolderType(rawValue: folderTypeRawValue),
            let rescanIntervalS = parsedRescanInterval,
            validationMessage == nil
        else {
            return
        }
        isSubmitting = true
        Task {
            let accepted = await model.acceptPendingFolder(
                offer,
                label: label,
                type: type,
                paused: paused,
                deviceIDs: selectedDeviceIDs,
                rescanIntervalS: rescanIntervalS,
                confirmedManagedStorageAndDevices: storageAndDevicesConfirmed
            )
            isSubmitting = false
            if accepted { dismiss() }
        }
    }

    private func ignoreFolder() {
        guard canIgnore else { return }
        isSubmitting = true
        Task {
            let ignored = await model.ignorePendingFolder(offer)
            isSubmitting = false
            if ignored { dismiss() }
        }
    }
}

private struct FolderRow: View {
    let folder: FolderRecord
    let isInternallyManaged: Bool

    var body: some View {
        HStack {
            Image(systemName: folder.error == nil ? "folder" : "folder.badge.questionmark")
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(folder.label)
                Text("\(storageKindTitle), \(folderTypeTitle(folder.type))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(folder.pendingDownloadBytes + folder.pendingUploadBytes, format: .byteCount(style: .file))
                .font(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(folder.label))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint("Opens folder details and selection controls.")
    }

    private var storageKindTitle: String {
        isInternallyManaged
            ? String(localized: "Internal Managed Folder")
            : String(localized: "Syncthing Folder")
    }

    private var accessibilityValue: String {
        String(
            localized:
                "\(storageKindTitle), \(folderTypeTitle(folder.type)), \((folder.pendingDownloadBytes + folder.pendingUploadBytes).formatted(.byteCount(style: .file))) pending"
        )
    }
}

private struct FolderDetailView: View {
    @Environment(AppModel.self) private var model
    private let initialFolder: FolderRecord
    let expectedFolderIncarnationDigest: String?
    @State private var editingConfiguration = false
    @State private var confirmingRemoval = false

    init(folder: FolderRecord, expectedFolderIncarnationDigest: String?) {
        initialFolder = folder
        self.expectedFolderIncarnationDigest = expectedFolderIncarnationDigest
    }

    private var folder: FolderRecord {
        model.snapshot.folders.first { $0.id == initialFolder.id } ?? initialFolder
    }

    var body: some View {
        Form {
            Section("Folder") {
                LabeledContent("ID", value: folder.id.rawValue)
                LabeledContent(
                    "Storage",
                    value: model.isInternallyManagedFolder(folder)
                        ? String(localized: "Internal Managed Folder")
                        : String(localized: "Syncthing Folder")
                )
                LabeledContent("Type", value: folderTypeTitle(folder.type))
                LabeledContent("Selection", value: contentSelectionTitle(folder.selectionMode))
                LabeledContent("Files Location", value: "Psynguechthyngue")
                Text(
                    "The share appears as its own folder in this Files location. Its App-managed storage path cannot be changed after creation."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Section("Pending") {
                LabeledContent("Upload", value: folder.pendingUploadBytes, format: .byteCount(style: .file))
                LabeledContent("Download", value: folder.pendingDownloadBytes, format: .byteCount(style: .file))
            }
            Section("Content Selection") {
                NavigationLink {
                    FolderSelectionView(
                        folder: folder,
                        items: model.snapshot.items.filter { $0.folderID == folder.id },
                        baselineGeneration: model.snapshot.generation
                    )
                } label: {
                    Label("Edit Content Selection", systemImage: "checklist")
                }
                Text(
                    "Full Sync, Manual Selection, Glob, and Regex define which global-index items this device keeps downloaded. Syncthing alone interprets the user's .stignore file."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Text(
                    "Keep Downloaded or Remove Download in Files overrides this folder plan for that item until the item choice changes again."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Section("Sync Policy") {
                NavigationLink {
                    FolderPolicyEditorView(folder: folder)
                } label: {
                    Label("Policy & Queue Priority", systemImage: "speedometer")
                }
                Text(
                    "Folder settings can only tighten the global policy and are bound to this exact folder incarnation."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Section("Actions") {
                Button("Edit Folder Configuration", systemImage: "slider.horizontal.3") {
                    editingConfiguration = true
                }
                .disabled(folderActionsDisabled)
                .accessibilityHint("Edits the Syncthing label, folder type, and optional rescan interval.")
                Button(folder.isPaused ? "Resume" : "Pause") {
                    Task {
                        await model.submit(
                            kind: folder.isPaused ? .resume : .pause,
                            folderID: folder.id,
                            expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
                        )
                    }
                }
                .disabled(folderActionsDisabled)
                Button("Sync Folder Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        await model.submit(
                            kind: .sync,
                            folderID: folder.id,
                            arguments: [
                                "timeoutMS": "10000",
                                "settleMS": "500",
                            ],
                            expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
                        )
                    }
                }
                .disabled(folder.isPaused || expectedFolderIncarnationDigest == nil)
                .accessibilityHint(
                    folder.isPaused
                        ? "Resume this folder before requesting synchronization."
                        : "Requests a policy-checked synchronization."
                )
                Menu("Sync Folder with Temporary Profile", systemImage: "timer") {
                    ForEach(model.temporaryPolicyProfiles) { profile in
                        Button(profile.name) {
                            Task {
                                await model.submit(
                                    kind: .sync,
                                    folderID: folder.id,
                                    arguments: [
                                        "timeoutMS": "10000",
                                        "settleMS": "500",
                                    ],
                                    expectedFolderIncarnationDigest: expectedFolderIncarnationDigest,
                                    temporaryPolicyProfileID: profile.id
                                )
                            }
                        }
                    }
                }
                .disabled(
                    folder.isPaused || expectedFolderIncarnationDigest == nil
                        || model.temporaryPolicyProfiles.isEmpty
                )
                .accessibilityHint(
                    "Runs this folder once with the saved profile's finite byte limit and expiry without changing persistent policy."
                )
                Button("Rescan") {
                    Task {
                        await model.submit(
                            kind: .rescan,
                            folderID: folder.id,
                            expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
                        )
                    }
                }
                .disabled(folderActionsDisabled)
            }
            Section("Danger Zone") {
                Button("Remove Folder Configuration", role: .destructive) { confirmingRemoval = true }
                    .disabled(folderActionsDisabled)
                    .accessibilityHint("Opens a confirmation before removing only the folder configuration.")
                Text(
                    "This removes the local folder configuration. It does not silently delete synchronized files from peers."
                )
                .font(.footnote)
            }
        }
        .disabled(folderActionsDisabled)
        .overlay {
            if folderActionsDisabled {
                ContentUnavailableView(
                    "Folder changed", systemImage: "folder.badge.questionmark",
                    description: Text("Return to the folder list and open the current folder again.")
                )
                .background(.background)
            }
        }
        .navigationTitle(folder.label)
        .sheet(isPresented: $editingConfiguration) {
            EditManagedFolderView(
                folder: folder,
                expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
            )
        }
        .confirmationDialog(
            "Remove this folder configuration?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Configuration Only", role: .destructive) {
                Task {
                    await model.submit(
                        kind: .removeFolder,
                        folderID: folder.id,
                        arguments: ["deleteData": "false"],
                        expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
                    )
                }
            }
            .disabled(folderActionsDisabled)
        } message: {
            Text(
                "No remote deletion is requested. Local files are preserved unless a separate, explicit action is confirmed."
            )
        }
    }

    private var folderActionsDisabled: Bool {
        expectedFolderIncarnationDigest == nil
            || model.folderIncarnationDigests[initialFolder.id] != expectedFolderIncarnationDigest
            || !model.snapshot.folders.contains { $0.id == initialFolder.id }
    }
}

private enum FolderPolicyByteField: Hashable {
    case cellularFile
    case expensiveRun
    case dailyExpensive
    case powerTransfer
    case minimumFreeDisk
}

private struct FolderPolicyEditorView: View {
    @Environment(AppModel.self) private var model
    let folder: FolderRecord

    @State private var configuration: FolderPolicyConfiguration?
    @State private var draft = FolderPolicyDraft()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?
    @State private var byteValidationErrors: [FolderPolicyByteField: String] = [:]

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading Folder Policy")
                    }
                }
            } else if configuration == nil {
                Section {
                    Label(
                        errorMessage ?? String(localized: "Folder policy is unavailable."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                }
            } else {
                scopeSection
                if draft.usesFolderOverride {
                    networkSection
                    powerSection
                    scheduleSection
                    backgroundSection
                    safetySection
                }
                effectiveSection
                whyNotSyncingSection
                saveSection
            }
        }
        .navigationTitle("Policy & Priority")
        .task { await load() }
    }

    private var scopeSection: some View {
        Section {
            Picker("Folder Policy", selection: $draft.usesFolderOverride) {
                Text("Use Global Policy").tag(false)
                Text("Customize for This Folder").tag(true)
            }
            Picker("Queue Priority", selection: $draft.queuePriority) {
                ForEach(FolderQueuePriority.allCases, id: \.self) { priority in
                    Text(folderQueuePriorityTitle(priority)).tag(priority)
                }
            }
            Text(
                "Queue priority orders eligible folder work; it never bypasses policy, safety checks, or another scheduling class."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Scope & Priority")
        } footer: {
            Text(
                "Use Global Policy removes all folder policy fields. A non-normal queue priority remains stored with this folder incarnation."
            )
        }
    }

    private var networkSection: some View {
        Section {
            FolderAllowedNetworksEditor(
                value: $draft.policy.automaticallyAllowedNetworks,
                inherited: configuration?.globalPolicy.automaticallyAllowedNetworks ?? []
            )
            Picker("Cellular", selection: $draft.policy.cellularAccess) {
                Text("Inherit Global").tag(nil as CellularAccess?)
                ForEach(CellularAccess.allCases, id: \.self) { access in
                    Text(folderCellularAccessTitle(access)).tag(Optional(access))
                }
            }
            FolderOptionalBoolPicker(
                title: "Expensive Networks",
                value: $draft.policy.allowExpensive,
                inherited: configuration?.globalPolicy.allowExpensive ?? false
            )
            FolderOptionalBoolPicker(
                title: "Low Data Mode",
                value: $draft.policy.allowConstrained,
                inherited: configuration?.globalPolicy.allowConstrained ?? false
            )
            FolderPolicyLimitEditor(
                title: "Cellular File Limit",
                value: $draft.policy.maxCellularFileBytes,
                inherited: configuration?.globalPolicy.maxCellularFileBytes,
                validationError: byteValidationBinding(for: .cellularFile)
            )
            FolderPolicyLimitEditor(
                title: "Expensive Run Limit",
                value: $draft.policy.maxExpensiveRunBytes,
                inherited: configuration?.globalPolicy.maxExpensiveRunBytes,
                validationError: byteValidationBinding(for: .expensiveRun)
            )
            FolderPolicyLimitEditor(
                title: "Daily Expensive Limit",
                value: $draft.policy.dailyExpensiveBytes,
                inherited: configuration?.globalPolicy.dailyExpensiveBytes,
                validationError: byteValidationBinding(for: .dailyExpensive)
            )
        } header: {
            Text("Network")
        } footer: {
            Text(
                "Allow or Unlimited choices cannot widen a denied global setting or raise a global byte ceiling. The effective preview shows the enforced result."
            )
        }
    }

    private var powerSection: some View {
        Section("Power & Device State") {
            FolderOptionalBoolPicker(
                title: "Require Power for Automatic Work",
                value: $draft.policy.requirePowerForAllAutomaticWork,
                inherited: configuration?.globalPolicy.requirePowerForAllAutomaticWork ?? false,
                enabledTitle: String(localized: "Required"),
                disabledTitle: String(localized: "Not Required")
            )
            FolderPolicyLimitEditor(
                title: "Require Power Above Transfer Size",
                value: $draft.policy.requirePowerForLargeTransferBytes,
                inherited: configuration?.globalPolicy.requirePowerForLargeTransferBytes,
                validationError: byteValidationBinding(for: .powerTransfer)
            )
            FolderOptionalBoolPicker(
                title: "Require Power for Maintenance",
                value: $draft.policy.requirePowerForMaintenance,
                inherited: configuration?.globalPolicy.requirePowerForMaintenance ?? false,
                enabledTitle: String(localized: "Required"),
                disabledTitle: String(localized: "Not Required")
            )
            FolderBatteryThresholdEditor(
                value: $draft.policy.minimumBatteryLevel,
                inherited: configuration?.globalPolicy.minimumBatteryLevel
            )
            Picker("Low Power Mode", selection: $draft.policy.lowPowerBehavior) {
                Text("Inherit Global").tag(nil as LowPowerBehavior?)
                ForEach(LowPowerBehavior.allCases, id: \.self) { behavior in
                    Text(folderLowPowerBehaviorTitle(behavior))
                        .tag(Optional(behavior))
                        .disabled(!lowPowerChoiceIsCompatible(behavior))
                }
            }
            Text(
                "Unavailable Low Power Mode choices cannot be represented as a restriction of the current global behavior. Inherit Global always remains available."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Picker("Thermal Pause Level", selection: $draft.policy.pauseTransfersAtThermalLevel) {
                Text("Inherit Global").tag(nil as ThermalLevel?)
                ForEach(ThermalLevel.allCases, id: \.self) { level in
                    Text(folderThermalLevelTitle(level)).tag(Optional(level))
                }
            }
        }
    }

    private var scheduleSection: some View {
        Section("Automatic Schedule") {
            FolderScheduleOverrideEditor(
                value: $draft.policy.automaticTimeWindows,
                inherited: configuration?.globalPolicy.automaticTimeWindows ?? []
            )
        }
    }

    private var backgroundSection: some View {
        Section {
            FolderOptionalBoolPicker(
                title: "Background Upload",
                value: $draft.policy.allowBackgroundUpload,
                inherited: configuration?.globalPolicy.allowBackgroundUpload ?? false
            )
            FolderOptionalBoolPicker(
                title: "Background Download",
                value: $draft.policy.allowBackgroundDownload,
                inherited: configuration?.globalPolicy.allowBackgroundDownload ?? false
            )
            FolderOptionalBoolPicker(
                title: "Background Scan",
                value: $draft.policy.allowBackgroundScan,
                inherited: configuration?.globalPolicy.allowBackgroundScan ?? false
            )
        } header: {
            Text("Background")
        } footer: {
            Text(
                "All three actions must be effectively enabled for this build's full background synchronization session."
            )
        }
    }

    private var safetySection: some View {
        Section {
            FolderByteFloorEditor(
                title: "Minimum Free Space",
                value: $draft.policy.minimumFreeDiskBytes,
                inherited: configuration?.globalPolicy.minimumFreeDiskBytes ?? 0,
                validationError: byteValidationBinding(for: .minimumFreeDisk)
            )
            FolderOptionalBoolPicker(
                title: "Allow One-Time User Overrides",
                value: $draft.policy.allowTemporaryUserOverride,
                inherited: configuration?.globalPolicy.allowTemporaryUserOverride ?? false
            )
        } header: {
            Text("Safety")
        } footer: {
            Text(
                "Folder safety settings can add stricter requirements but cannot lower the global safety floor."
            )
        }
    }

    private var effectiveSection: some View {
        Section("Effective Preview") {
            FolderEffectivePolicyRow(
                title: "Automatic Networks",
                value: automaticNetworksTitle(effectivePolicy.automaticallyAllowedNetworks),
                source: scalarSource(
                    requested: draft.policy.automaticallyAllowedNetworks,
                    effective: effectivePolicy.automaticallyAllowedNetworks
                )
            )
            FolderEffectivePolicyRow(
                title: "Cellular",
                value: folderCellularAccessTitle(effectivePolicy.cellularAccess),
                source: scalarSource(
                    requested: draft.policy.cellularAccess,
                    effective: effectivePolicy.cellularAccess
                )
            )
            FolderEffectivePolicyRow(
                title: "Expensive Networks",
                value: allowedTitle(effectivePolicy.allowExpensive),
                source: scalarSource(
                    requested: draft.policy.allowExpensive,
                    effective: effectivePolicy.allowExpensive
                )
            )
            FolderEffectivePolicyRow(
                title: "Low Data Mode",
                value: allowedTitle(effectivePolicy.allowConstrained),
                source: scalarSource(
                    requested: draft.policy.allowConstrained,
                    effective: effectivePolicy.allowConstrained
                )
            )
            FolderEffectivePolicyRow(
                title: "Cellular File Limit",
                value: byteLimitTitle(effectivePolicy.maxCellularFileBytes),
                source: limitSource(
                    requested: draft.policy.maxCellularFileBytes,
                    inherited: configuration?.globalPolicy.maxCellularFileBytes,
                    effective: effectivePolicy.maxCellularFileBytes
                )
            )
            FolderEffectivePolicyRow(
                title: "Expensive Run Limit",
                value: byteLimitTitle(effectivePolicy.maxExpensiveRunBytes),
                source: limitSource(
                    requested: draft.policy.maxExpensiveRunBytes,
                    inherited: configuration?.globalPolicy.maxExpensiveRunBytes,
                    effective: effectivePolicy.maxExpensiveRunBytes
                )
            )
            FolderEffectivePolicyRow(
                title: "Daily Expensive Limit",
                value: byteLimitTitle(effectivePolicy.dailyExpensiveBytes),
                source: limitSource(
                    requested: draft.policy.dailyExpensiveBytes,
                    inherited: configuration?.globalPolicy.dailyExpensiveBytes,
                    effective: effectivePolicy.dailyExpensiveBytes
                )
            )
            FolderEffectivePolicyRow(
                title: "Require Power for Automatic Work",
                value: requiredTitle(effectivePolicy.requirePowerForAllAutomaticWork),
                source: scalarSource(
                    requested: draft.policy.requirePowerForAllAutomaticWork,
                    effective: effectivePolicy.requirePowerForAllAutomaticWork
                )
            )
            FolderEffectivePolicyRow(
                title: "Require Power Above Transfer Size",
                value: byteLimitTitle(effectivePolicy.requirePowerForLargeTransferBytes),
                source: limitSource(
                    requested: draft.policy.requirePowerForLargeTransferBytes,
                    inherited: configuration?.globalPolicy.requirePowerForLargeTransferBytes,
                    effective: effectivePolicy.requirePowerForLargeTransferBytes
                )
            )
            FolderEffectivePolicyRow(
                title: "Require Power for Maintenance",
                value: requiredTitle(effectivePolicy.requirePowerForMaintenance),
                source: scalarSource(
                    requested: draft.policy.requirePowerForMaintenance,
                    effective: effectivePolicy.requirePowerForMaintenance
                )
            )
            FolderEffectivePolicyRow(
                title: "Minimum Battery",
                value: batteryThresholdTitle(effectivePolicy.minimumBatteryLevel),
                source: nullableScalarSource(
                    requested: draft.policy.minimumBatteryLevel,
                    effective: effectivePolicy.minimumBatteryLevel
                )
            )
            FolderEffectivePolicyRow(
                title: "Low Power Mode",
                value: folderLowPowerBehaviorTitle(effectivePolicy.lowPowerBehavior),
                source: scalarSource(
                    requested: draft.policy.lowPowerBehavior,
                    effective: effectivePolicy.lowPowerBehavior
                )
            )
            FolderEffectivePolicyRow(
                title: "Thermal Pause Level",
                value: folderThermalLevelTitle(effectivePolicy.pauseTransfersAtThermalLevel),
                source: scalarSource(
                    requested: draft.policy.pauseTransfersAtThermalLevel,
                    effective: effectivePolicy.pauseTransfersAtThermalLevel
                )
            )
            FolderEffectivePolicyRow(
                title: "Automatic Schedule",
                value: automaticScheduleTitle(effectivePolicy.automaticTimeWindows),
                source: scalarSource(
                    requested: draft.policy.automaticTimeWindows,
                    effective: effectivePolicy.automaticTimeWindows
                )
            )
            FolderEffectivePolicyRow(
                title: "Background Upload",
                value: allowedTitle(effectivePolicy.allowBackgroundUpload),
                source: scalarSource(
                    requested: draft.policy.allowBackgroundUpload,
                    effective: effectivePolicy.allowBackgroundUpload
                )
            )
            FolderEffectivePolicyRow(
                title: "Background Download",
                value: allowedTitle(effectivePolicy.allowBackgroundDownload),
                source: scalarSource(
                    requested: draft.policy.allowBackgroundDownload,
                    effective: effectivePolicy.allowBackgroundDownload
                )
            )
            FolderEffectivePolicyRow(
                title: "Background Scan",
                value: allowedTitle(effectivePolicy.allowBackgroundScan),
                source: scalarSource(
                    requested: draft.policy.allowBackgroundScan,
                    effective: effectivePolicy.allowBackgroundScan
                )
            )
            FolderEffectivePolicyRow(
                title: "Minimum Free Space",
                value: effectivePolicy.minimumFreeDiskBytes.formatted(.byteCount(style: .file)),
                source: scalarSource(
                    requested: draft.policy.minimumFreeDiskBytes,
                    effective: effectivePolicy.minimumFreeDiskBytes
                )
            )
            FolderEffectivePolicyRow(
                title: "Allow One-Time User Overrides",
                value: allowedTitle(effectivePolicy.allowTemporaryUserOverride),
                source: scalarSource(
                    requested: draft.policy.allowTemporaryUserOverride,
                    effective: effectivePolicy.allowTemporaryUserOverride
                )
            )
            FolderEffectivePolicyRow(
                title: "Queue Priority",
                value: folderQueuePriorityTitle(draft.queuePriority),
                source: .folderIncarnation
            )
        }
    }

    private var whyNotSyncingSection: some View {
        Section {
            if let folderError = folder.error, !folderError.isEmpty {
                Label("Folder error: \(folderError)", systemImage: "exclamationmark.triangle")
            } else if folder.isPaused {
                Label("This folder is paused.", systemImage: "pause.circle")
            } else if folder.pendingDownloadBytes + folder.pendingUploadBytes == 0 {
                Label("No upload or download is pending.", systemImage: "checkmark.circle")
            } else if !persistedPolicyExplanations.isEmpty {
                ForEach(persistedPolicyExplanations, id: \.reason.rawValue) { explanation in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folderPolicyBlockMessage(explanation.reason))
                            Text(
                                String(
                                    format: String(localized: "Remedy: %@"),
                                    folderPolicyBlockRemedy(explanation.reason)
                                )
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "hand.raised")
                    }
                }
            } else {
                Label(
                    "No policy block is currently reported. The request may still be waiting for the queue, a peer, or iOS background scheduling.",
                    systemImage: "clock"
                )
            }
        } header: {
            Text("Why Not Syncing")
        } footer: {
            Text(
                "Why Not Syncing uses the last saved effective policy. Unsaved preview changes are never presented as an enforced reason."
            )
        }
    }

    private var saveSection: some View {
        Section {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("Save Folder Policy")
                }
            }
            .disabled(isSaving || hasByteValidationErrors)
            .buttonStyle(.borderedProminent)
            .accessibilityHint(
                "Saves policy and priority only if this exact folder incarnation is still current."
            )
        }
    }

    private var effectivePolicy: SyncPolicy {
        guard let configuration else { return SyncPolicy() }
        guard draft.usesFolderOverride else { return configuration.globalPolicy }
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: configuration.globalPolicy,
            folderOverrides: [
                FolderSyncPolicyOverride(
                    folderID: configuration.context.folderID,
                    folderIncarnationDigest: configuration.context.folderIncarnationDigest,
                    queuePriority: draft.queuePriority,
                    policy: draft.policy
                )
            ]
        )
        return
            (try? document.resolvedPolicy(
                for: configuration.context.folderID,
                folderIncarnationDigest: configuration.context.folderIncarnationDigest
            )) ?? configuration.effectivePolicy
    }

    private var persistedPolicyExplanations: [PolicyExplanation] {
        guard let persistedPolicy = configuration?.effectivePolicy,
            let decision = model.folderPolicyDecision(
                for: folder,
                effectivePolicy: persistedPolicy
            )
        else {
            return []
        }
        var reasons = Set<String>()
        return decision.explanations
            .filter { reasons.insert($0.reason.rawValue).inserted }
            .sorted { $0.reason.rawValue < $1.reason.rawValue }
    }

    private var hasByteValidationErrors: Bool {
        draft.usesFolderOverride && !byteValidationErrors.isEmpty
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        savedMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await model.loadFolderPolicyConfiguration(for: folder)
            configuration = loaded
            draft = FolderPolicyDraft(configuration: loaded)
            byteValidationErrors.removeAll()
        } catch {
            configuration = nil
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard let configuration else { return }
        guard !hasByteValidationErrors else {
            errorMessage = String(localized: "Correct the byte values before saving.")
            return
        }
        isSaving = true
        errorMessage = nil
        savedMessage = nil
        defer { isSaving = false }
        do {
            let saved = try await model.saveFolderPolicy(
                draft.usesFolderOverride ? draft.policy : nil,
                queuePriority: draft.queuePriority,
                expectedContext: configuration.context,
                folder: folder
            )
            self.configuration = saved
            draft = FolderPolicyDraft(configuration: saved)
            byteValidationErrors.removeAll()
            savedMessage = String(localized: "Folder policy and queue priority were saved.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scalarSource<Value: Equatable>(
        requested: Value?,
        effective: Value
    ) -> FolderPolicyValueSource {
        guard draft.usesFolderOverride, let requested else { return .global }
        return requested == effective ? .folderOverride : .globalCeiling
    }

    private func nullableScalarSource<Value: Equatable>(
        requested: Value?,
        effective: Value?
    ) -> FolderPolicyValueSource {
        guard draft.usesFolderOverride, let requested else { return .global }
        return requested == effective ? .folderOverride : .globalCeiling
    }

    private func lowPowerChoiceIsCompatible(_ behavior: LowPowerBehavior) -> Bool {
        guard let configuration else { return false }
        let probe = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: configuration.globalPolicy,
            folderOverrides: [
                FolderSyncPolicyOverride(
                    folderID: configuration.context.folderID,
                    folderIncarnationDigest: configuration.context.folderIncarnationDigest,
                    policy: SyncPolicyOverride(lowPowerBehavior: behavior)
                )
            ]
        )
        return (try? probe.validatedForPersistence()) != nil
    }

    private func limitSource(
        requested: PolicyByteLimit,
        inherited: Int64?,
        effective: Int64?
    ) -> FolderPolicyValueSource {
        guard draft.usesFolderOverride, requested != .inherit else { return .global }
        let unconstrained: Int64?
        do {
            unconstrained = try requested.resolved(inheriting: inherited)
        } catch {
            return .globalCeiling
        }
        return unconstrained == effective ? .folderOverride : .globalCeiling
    }

    private func byteValidationBinding(
        for field: FolderPolicyByteField
    ) -> Binding<String?> {
        Binding(
            get: { byteValidationErrors[field] },
            set: { message in
                if let message {
                    byteValidationErrors[field] = message
                } else {
                    byteValidationErrors.removeValue(forKey: field)
                }
            }
        )
    }
}

private struct FolderPolicyDraft {
    var usesFolderOverride = false
    var policy = SyncPolicyOverride()
    var queuePriority = FolderQueuePriority.normal

    init() {}

    init(configuration: FolderPolicyConfiguration) {
        usesFolderOverride = configuration.policyOverride != nil
        policy = configuration.policyOverride ?? SyncPolicyOverride()
        queuePriority = configuration.queuePriority
    }
}

private enum FolderPolicyValueSource {
    case global
    case folderOverride
    case globalCeiling
    case folderIncarnation

    var title: String {
        switch self {
        case .global:
            String(localized: "Source: Global policy")
        case .folderOverride:
            String(localized: "Source: Folder override")
        case .globalCeiling:
            String(localized: "Source: Global ceiling")
        case .folderIncarnation:
            String(localized: "Source: Folder incarnation")
        }
    }
}

private struct FolderEffectivePolicyRow: View {
    let title: String
    let value: String
    let source: FolderPolicyValueSource

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                Text(source.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(LocalizedStringKey(title))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityValue(Text("\(value). \(source.title)"))
    }
}

private struct FolderOptionalBoolPicker: View {
    let title: String
    @Binding var value: Bool?
    let inherited: Bool
    let enabledTitle: String
    let disabledTitle: String

    init(
        title: String,
        value: Binding<Bool?>,
        inherited: Bool,
        enabledTitle: String = String(localized: "Allow"),
        disabledTitle: String = String(localized: "Deny")
    ) {
        self.title = title
        _value = value
        self.inherited = inherited
        self.enabledTitle = enabledTitle
        self.disabledTitle = disabledTitle
    }

    var body: some View {
        Picker(LocalizedStringKey(title), selection: $value) {
            Text("Inherit Global — \(inherited ? enabledTitle : disabledTitle)")
                .tag(nil as Bool?)
            Text(enabledTitle).tag(Optional(true))
            Text(disabledTitle).tag(Optional(false))
        }
        .accessibilityLabel(Text(LocalizedStringKey(title)))
    }
}

private struct FolderAllowedNetworksEditor: View {
    @Binding var value: Set<NetworkKind>?
    let inherited: Set<NetworkKind>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Override Automatic Networks", isOn: isEnabled)
                .accessibilityHint(
                    "A folder network selection is intersected with the saved global selection."
                )
            if value != nil {
                ForEach(editableNetworkKinds, id: \.self) { kind in
                    Toggle(isOn: selectionBinding(for: kind)) {
                        Text(folderNetworkKindTitle(kind))
                    }
                    .accessibilityLabel(
                        Text(
                            String(
                                format: String(localized: "Allow automatic work on %@"),
                                folderNetworkKindTitle(kind)
                            )
                        )
                    )
                }
            }
            Text(
                String(
                    format: String(localized: "Global: %@"),
                    automaticNetworksTitle(inherited)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var editableNetworkKinds: [NetworkKind] {
        [.wifi, .cellular, .ethernet, .other]
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { enabled in value = enabled ? inherited : nil }
        )
    }

    private func selectionBinding(for kind: NetworkKind) -> Binding<Bool> {
        Binding(
            get: { value?.contains(kind) ?? false },
            set: { isSelected in
                var selection = value ?? inherited
                if isSelected {
                    selection.insert(kind)
                } else {
                    selection.remove(kind)
                }
                value = selection
            }
        )
    }
}

private struct FolderBatteryThresholdEditor: View {
    @Binding var value: Double?
    let inherited: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Override Minimum Battery", isOn: isEnabled)
            if value != nil {
                Slider(value: threshold, in: 0...1, step: 0.05) {
                    Text("Minimum Battery")
                }
                .accessibilityValue(Text(batteryThresholdTitle(value)))
                Text(batteryThresholdTitle(value))
                    .font(.caption)
            }
            Text(
                String(
                    format: String(localized: "Global: %@"),
                    batteryThresholdTitle(inherited)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { enabled in
                value = enabled ? min(1, max(0, inherited ?? 0.2)) : nil
            }
        )
    }

    private var threshold: Binding<Double> {
        Binding(
            get: { value ?? inherited ?? 0.2 },
            set: { value = min(1, max(0, $0)) }
        )
    }
}

private struct FolderScheduleOverrideEditor: View {
    @Binding var value: [TimeWindow]?
    let inherited: [TimeWindow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Override Automatic Schedule", isOn: isEnabled)
                .accessibilityHint(
                    "The saved folder schedule is intersected with the global automatic schedule."
                )
            if value != nil {
                Toggle("Restrict to a Recurring Window", isOn: hasWindow)
                if !(value ?? []).isEmpty {
                    Text("Primary Window")
                        .font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(1...7, id: \.self) { weekday in
                                Toggle(isOn: weekdayBinding(weekday)) {
                                    Text(folderWeekdayShortTitle(weekday))
                                }
                                .toggleStyle(.button)
                                .accessibilityLabel(Text(folderWeekdayTitle(weekday)))
                            }
                        }
                    }
                    HStack {
                        Picker("Start", selection: startMinute) {
                            ForEach(scheduleHourValues, id: \.self) { minute in
                                Text(folderHourTitle(minute)).tag(minute)
                            }
                        }
                        Picker("End", selection: endMinute) {
                            ForEach(scheduleHourValues, id: \.self) { minute in
                                Text(folderHourTitle(minute)).tag(minute)
                            }
                        }
                    }
                    if (value?.count ?? 0) > 1 {
                        Text("Additional saved windows are preserved while the primary window is edited.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(
                String(
                    format: String(localized: "Global: %@"),
                    automaticScheduleTitle(inherited)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var scheduleHourValues: [Int] {
        Array(stride(from: 0, through: 1_440, by: 60))
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { enabled in value = enabled ? inherited : nil }
        )
    }

    private var hasWindow: Binding<Bool> {
        Binding(
            get: { !(value ?? []).isEmpty },
            set: { enabled in
                value = enabled ? [inherited.first ?? TimeWindow()] : []
            }
        )
    }

    private var startMinute: Binding<Int> {
        windowComponentBinding(\.startMinute)
    }

    private var endMinute: Binding<Int> {
        windowComponentBinding(\.endMinute)
    }

    private func windowComponentBinding(_ keyPath: WritableKeyPath<TimeWindow, Int>) -> Binding<Int> {
        Binding(
            get: { primaryWindow[keyPath: keyPath] },
            set: { newValue in
                var window = primaryWindow
                window[keyPath: keyPath] = min(1_440, max(0, newValue))
                replacePrimaryWindow(with: window)
            }
        )
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { primaryWindow.weekdays.contains(weekday) },
            set: { isSelected in
                var window = primaryWindow
                if isSelected {
                    window.weekdays.insert(weekday)
                } else {
                    window.weekdays.remove(weekday)
                }
                replacePrimaryWindow(with: window)
            }
        )
    }

    private var primaryWindow: TimeWindow {
        value?.first ?? inherited.first ?? TimeWindow()
    }

    private func replacePrimaryWindow(with window: TimeWindow) {
        var windows = value ?? []
        if windows.isEmpty {
            windows = [window]
        } else {
            windows[0] = window
        }
        value = windows
    }
}

private enum FolderPolicyLimitMode: Hashable {
    case inherit
    case unlimited
    case limit
}

private struct FolderPolicyLimitEditor: View {
    let title: String
    @Binding var value: PolicyByteLimit
    let inherited: Int64?
    @Binding var validationError: String?
    @State private var byteText: String

    init(
        title: String,
        value: Binding<PolicyByteLimit>,
        inherited: Int64?,
        validationError: Binding<String?>
    ) {
        self.title = title
        _value = value
        self.inherited = inherited
        _validationError = validationError
        if case .limit(let bytes) = value.wrappedValue {
            _byteText = State(initialValue: String(bytes))
        } else {
            _byteText = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(LocalizedStringKey(title), selection: mode) {
                Text("Inherit Global").tag(FolderPolicyLimitMode.inherit)
                Text("Unlimited").tag(FolderPolicyLimitMode.unlimited)
                Text("Set Byte Limit").tag(FolderPolicyLimitMode.limit)
            }
            if case .limit = value {
                TextField("Bytes", text: $byteText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(LocalizedStringKey(title)))
                    .accessibilityHint("Enter a nonnegative whole number of bytes.")
                    .onChange(of: byteText) { _, newValue in
                        applyByteText(newValue)
                    }
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text(
                String(
                    format: String(localized: "Global: %@"),
                    byteLimitTitle(inherited)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: value) { _, newValue in
            guard validationError == nil, case .limit(let bytes) = newValue else { return }
            byteText = String(bytes)
        }
    }

    private var mode: Binding<FolderPolicyLimitMode> {
        Binding(
            get: {
                switch value {
                case .inherit: .inherit
                case .unlimited: .unlimited
                case .limit: .limit
                }
            },
            set: { newMode in
                validationError = nil
                switch newMode {
                case .inherit:
                    value = .inherit
                case .unlimited:
                    value = .unlimited
                case .limit:
                    let defaultBytes = inherited ?? 100 * 1_024 * 1_024
                    value = .limit(max(0, defaultBytes))
                    byteText = String(max(0, defaultBytes))
                }
            }
        )
    }

    private func applyByteText(_ text: String) {
        switch validatedByteText(text) {
        case .success(let bytes):
            validationError = nil
            value = .limit(bytes)
        case .failure(let message):
            validationError = message
        }
    }
}

private struct FolderByteFloorEditor: View {
    let title: String
    @Binding var value: Int64?
    let inherited: Int64
    @Binding var validationError: String?
    @State private var byteText: String

    init(
        title: String,
        value: Binding<Int64?>,
        inherited: Int64,
        validationError: Binding<String?>
    ) {
        self.title = title
        _value = value
        self.inherited = inherited
        _validationError = validationError
        _byteText = State(initialValue: value.wrappedValue.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(LocalizedStringKey(title), isOn: isEnabled)
            if value != nil {
                TextField("Bytes", text: $byteText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(LocalizedStringKey(title)))
                    .accessibilityHint("Enter a nonnegative whole number of bytes.")
                    .onChange(of: byteText) { _, newValue in
                        applyByteText(newValue)
                    }
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text(
                String(
                    format: String(localized: "Global: %@"),
                    inherited.formatted(.byteCount(style: .file))
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: value) { _, newValue in
            guard validationError == nil, let newValue else { return }
            byteText = String(newValue)
        }
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { enabled in
                validationError = nil
                if enabled {
                    value = max(0, inherited)
                    byteText = String(max(0, inherited))
                } else {
                    value = nil
                }
            }
        )
    }

    private func applyByteText(_ text: String) {
        switch validatedByteText(text) {
        case .success(let bytes):
            validationError = nil
            value = bytes
        case .failure(let message):
            validationError = message
        }
    }
}

private enum FolderByteTextResult {
    case success(Int64)
    case failure(String)
}

private func validatedByteText(_ text: String) -> FolderByteTextResult {
    guard !text.isEmpty else {
        return .failure(String(localized: "Enter a nonnegative whole number of bytes."))
    }
    guard text.utf8.allSatisfy({ (48...57).contains($0) }) else {
        return .failure(String(localized: "Use decimal digits only."))
    }
    guard let value = Int64(text) else {
        return .failure(String(localized: "This byte value is too large."))
    }
    return .success(value)
}

private func allowedTitle(_ value: Bool) -> String {
    value ? String(localized: "Allowed") : String(localized: "Denied")
}

private func requiredTitle(_ value: Bool) -> String {
    value ? String(localized: "Required") : String(localized: "Not Required")
}

private func byteLimitTitle(_ value: Int64?) -> String {
    value.map { $0.formatted(.byteCount(style: .file)) } ?? String(localized: "Unlimited")
}

private func batteryThresholdTitle(_ value: Double?) -> String {
    value?.formatted(.percent.precision(.fractionLength(0))) ?? String(localized: "No Minimum")
}

private func automaticNetworksTitle(_ networks: Set<NetworkKind>) -> String {
    let ordered = NetworkKind.allCases.filter { networks.contains($0) && $0 != .unavailable }
    guard !ordered.isEmpty else { return String(localized: "No Automatic Networks") }
    return ordered.map(folderNetworkKindTitle).joined(separator: ", ")
}

private func folderNetworkKindTitle(_ kind: NetworkKind) -> String {
    switch kind {
    case .unavailable: String(localized: "Unavailable")
    case .wifi: String(localized: "Wi-Fi")
    case .cellular: String(localized: "Cellular")
    case .ethernet: String(localized: "Ethernet")
    case .other: String(localized: "Other Network")
    }
}

private func folderLowPowerBehaviorTitle(_ behavior: LowPowerBehavior) -> String {
    switch behavior {
    case .pauseAutomatic: String(localized: "Pause Automatic Work")
    case .indexOnly: String(localized: "Index Only")
    case .userRequestsOnly: String(localized: "User Requests Only")
    case .allowed: String(localized: "Allowed")
    }
}

private func folderThermalLevelTitle(_ level: ThermalLevel) -> String {
    switch level {
    case .nominal: String(localized: "Nominal")
    case .fair: String(localized: "Fair")
    case .serious: String(localized: "Serious")
    case .critical: String(localized: "Critical")
    }
}

private func automaticScheduleTitle(_ windows: [TimeWindow]) -> String {
    guard !windows.isEmpty else { return String(localized: "Any Time") }
    if windows.allSatisfy({ $0.weekdays.isEmpty }) {
        return String(localized: "No Automatic Time")
    }
    guard windows.count == 1, let window = windows.first else {
        return String(
            format: String(localized: "%lld Saved Windows"),
            Int64(windows.count)
        )
    }
    let weekdayTitle =
        window.weekdays == Set(1...7)
        ? String(localized: "Every Day")
        : window.weekdays.sorted().map(folderWeekdayShortTitle).joined(separator: ", ")
    return String(
        format: String(localized: "%@, %@–%@"),
        weekdayTitle,
        folderHourTitle(window.startMinute),
        folderHourTitle(window.endMinute)
    )
}

private func folderWeekdayTitle(_ weekday: Int) -> String {
    switch weekday {
    case 1: String(localized: "Sunday")
    case 2: String(localized: "Monday")
    case 3: String(localized: "Tuesday")
    case 4: String(localized: "Wednesday")
    case 5: String(localized: "Thursday")
    case 6: String(localized: "Friday")
    case 7: String(localized: "Saturday")
    default: String(localized: "Unknown Day")
    }
}

private func folderWeekdayShortTitle(_ weekday: Int) -> String {
    switch weekday {
    case 1: String(localized: "Sun")
    case 2: String(localized: "Mon")
    case 3: String(localized: "Tue")
    case 4: String(localized: "Wed")
    case 5: String(localized: "Thu")
    case 6: String(localized: "Fri")
    case 7: String(localized: "Sat")
    default: "?"
    }
}

private func folderHourTitle(_ minute: Int) -> String {
    String(format: "%02lld:%02lld", Int64(minute / 60), Int64(minute % 60))
}

private func folderQueuePriorityTitle(_ priority: FolderQueuePriority) -> String {
    switch priority {
    case .low: String(localized: "Low")
    case .normal: String(localized: "Normal")
    case .high: String(localized: "High")
    }
}

private func folderCellularAccessTitle(_ access: CellularAccess) -> String {
    switch access {
    case .denied: String(localized: "Denied")
    case .uploadOnly: String(localized: "Upload Only")
    case .downloadOnly: String(localized: "Download Only")
    case .smallFiles: String(localized: "Small Files Only")
    case .allowed: String(localized: "Allowed")
    }
}

private func folderPolicyBlockMessage(_ reason: PolicyBlockReason) -> String {
    switch reason {
    case .noRequestedAction:
        String(localized: "No synchronization action was requested.")
    case .coreBusy:
        String(localized: "The Syncthing core is busy in another process.")
    case .databaseMaintenance:
        String(localized: "Database maintenance is in progress.")
    case .networkUnavailable:
        String(localized: "The network is unavailable.")
    case .networkTypeDenied:
        String(localized: "This network type is not allowed by the saved policy.")
    case .cellularDirectionDenied:
        String(localized: "The requested cellular transfer direction is not allowed.")
    case .cellularFileTooLarge:
        String(localized: "A cellular file exceeds the saved size limit.")
    case .expensiveNetworkDenied:
        String(localized: "Expensive network access is not allowed.")
    case .constrainedNetworkDenied:
        String(localized: "Low Data Mode access is not allowed.")
    case .runTransferLimit:
        String(localized: "The estimated transfer exceeds the saved per-run limit.")
    case .dailyTransferLimit:
        String(localized: "The saved daily transfer limit would be exceeded.")
    case .dailyTransferAccountingUnavailable:
        String(localized: "Daily transfer accounting is unavailable, so the limit fails closed.")
    case .outsideTimeWindow:
        String(localized: "The current time is outside the saved automatic schedule.")
    case .externalPowerRequired:
        String(localized: "External power is required for this work.")
    case .batteryTooLow:
        String(localized: "The battery level is below the saved minimum.")
    case .lowPowerMode:
        String(localized: "Low Power Mode blocks this work.")
    case .thermalPressure:
        String(localized: "Thermal pressure blocks this work.")
    case .insufficientDisk:
        String(localized: "Available disk space is below the saved safety floor.")
    case .backgroundActionDisabled:
        String(localized: "A required background action is disabled.")
    case .unresolvedConflict:
        String(localized: "An unresolved conflict blocks this work.")
    case .unuploadedChanges:
        String(localized: "Unuploaded changes block this work.")
    }
}

private func folderPolicyBlockRemedy(_ reason: PolicyBlockReason) -> String {
    switch reason {
    case .noRequestedAction:
        String(localized: "Choose a synchronization action and retry.")
    case .coreBusy, .databaseMaintenance:
        String(localized: "Wait for the current core work to finish, then retry.")
    case .networkUnavailable, .networkTypeDenied:
        String(localized: "Connect to a network allowed by the saved policy and retry.")
    case .cellularDirectionDenied:
        String(localized: "Use a permitted direction or wait for an allowed network.")
    case .cellularFileTooLarge, .runTransferLimit:
        String(localized: "Reduce the transfer size or choose a network allowed by the saved policy.")
    case .expensiveNetworkDenied, .constrainedNetworkDenied:
        String(localized: "Review the saved global and folder network policies.")
    case .dailyTransferLimit:
        String(localized: "Wait for the accounting window to reset or reduce the requested transfer.")
    case .dailyTransferAccountingUnavailable:
        String(localized: "Open the app after accounting becomes available; this limit fails closed.")
    case .outsideTimeWindow:
        String(localized: "Wait for the saved automatic schedule or start an eligible user request.")
    case .externalPowerRequired:
        String(localized: "Connect external power or wait until the saved requirement is met.")
    case .batteryTooLow:
        String(localized: "Charge the device above the saved minimum.")
    case .lowPowerMode:
        String(localized: "Disable Low Power Mode or wait for the saved policy to allow work.")
    case .thermalPressure:
        String(localized: "Let the device cool before retrying.")
    case .insufficientDisk:
        String(localized: "Free disk space without lowering the saved safety floor.")
    case .backgroundActionDisabled:
        String(localized: "Enable every required background action in both global and folder policy.")
    case .unresolvedConflict:
        String(localized: "Resolve the conflict before retrying.")
    case .unuploadedChanges:
        String(localized: "Upload or preserve the local changes before retrying.")
    }
}

struct AddManagedFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var folderID = String(UUID().uuidString.lowercased().prefix(13))
    @State private var label = ""
    @State private var folderTypeRawValue = FolderType.sendReceive.rawValue
    @State private var rescanIntervalText = "3600"
    @State private var paused = false
    @State private var selectedDeviceIDs: Set<DeviceID> = []
    @State private var showAdvancedFolderTypes = false
    @State private var isSubmitting = false
    @State private var submissionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                    Picker("Folder Type", selection: $folderTypeRawValue) {
                        ForEach(visibleFolderTypes, id: \.rawValue) { type in
                            Text(folderTypeTitle(type)).tag(type.rawValue)
                        }
                    }
                    DisclosureGroup("Advanced Settings") {
                        TextField("Folder ID", text: $folderID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityHint(
                                "Enter the stable Syncthing folder identifier. It cannot be changed later.")
                        TextField("Rescan Interval (Seconds)", text: $rescanIntervalText)
                            .keyboardType(.numberPad)
                        Toggle("Add Paused", isOn: $paused)
                    }
                } header: {
                    Text("Internal Managed Folder")
                } footer: {
                    Text(
                        "The share appears as its own folder in the Psynguechthyngue location in Files. Its App-managed storage path cannot be changed after creation, and failed configuration attempts never delete it."
                    )
                }

                Section {
                    if peerDevices.isEmpty {
                        Text("No peer devices are configured. The local device will still be included.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(peerDevices) { device in
                            Toggle(isOn: deviceSelectionBinding(device.id)) {
                                VStack(alignment: .leading) {
                                    Text(device.name.isEmpty ? device.id.rawValue : device.name)
                                    Text(device.id.rawValue)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel(
                                Text(
                                    String(
                                        localized:
                                            "Share with \(device.name.isEmpty ? device.id.rawValue : device.name)"
                                    )
                                )
                            )
                        }
                    }
                } header: {
                    Text("Share with Devices")
                } footer: {
                    Text(
                        "Choose the devices that may access this folder. A folder without selected devices stays on this device only."
                    )
                }

                Section {
                    DisclosureGroup("Advanced Folder Types") {
                        Toggle("Show Receive Encrypted Type", isOn: $showAdvancedFolderTypes)
                            .onChange(of: showAdvancedFolderTypes) { _, isEnabled in
                                if !isEnabled, folderTypeRawValue == FolderType.receiveEncrypted.rawValue {
                                    folderTypeRawValue = FolderType.sendReceive.rawValue
                                }
                            }
                        Text(
                            "Receive Encrypted is an advanced Syncthing mode for untrusted devices. Use it only when the encrypted-folder workflow is already understood and configured."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("Cannot add folder: \(validationMessage)"))
                    }
                }
                if let submissionError {
                    Section("Request Result") {
                        Text(submissionError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Managed Folder")
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        addFolder()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .accessibilityLabel("Adding managed folder")
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(validationMessage != nil || isSubmitting)
                    .accessibilityHint("Creates the managed directory and submits the Syncthing folder configuration.")
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var peerDevices: [DeviceRecord] {
        model.snapshot.devices.filter { $0.id != model.snapshot.localDeviceID }
    }

    private var visibleFolderTypes: [FolderType] {
        var types: [FolderType] = [.sendReceive, .sendOnly, .receiveOnly]
        if showAdvancedFolderTypes { types.append(.receiveEncrypted) }
        return types
    }

    private var parsedFolderID: FolderID? {
        FolderID(rawValue: folderID)
    }

    private var parsedRescanInterval: Int? {
        strictNonnegativeInteger(rescanIntervalText)
    }

    private var validationMessage: String? {
        guard parsedFolderID != nil else {
            return String(localized: "Enter a folder ID containing 1 to 64 characters and no control characters.")
        }
        if let parsedFolderID, model.snapshot.folders.contains(where: { $0.id == parsedFolderID }) {
            return String(localized: "A folder with this ID already exists.")
        }
        guard isValidManagedFolderLabel(label) else {
            return String(localized: "Enter a label containing 1 to 256 UTF-8 bytes and no control characters.")
        }
        guard let parsedRescanInterval,
            (0...managedFolderMaximumRescanIntervalS).contains(parsedRescanInterval)
        else {
            return String(localized: "Enter a rescan interval from 0 to 31,536,000 seconds.")
        }
        return nil
    }

    private func deviceSelectionBinding(_ id: DeviceID) -> Binding<Bool> {
        Binding(
            get: { selectedDeviceIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedDeviceIDs.insert(id)
                } else {
                    selectedDeviceIDs.remove(id)
                }
            }
        )
    }

    private func addFolder() {
        guard let id = parsedFolderID,
            let type = FolderType(rawValue: folderTypeRawValue),
            let rescanIntervalS = parsedRescanInterval,
            validationMessage == nil
        else {
            return
        }
        isSubmitting = true
        submissionError = nil
        Task {
            let didSubmit = await model.addManagedFolder(
                id: id,
                label: label,
                type: type,
                paused: paused,
                deviceIDs: selectedDeviceIDs,
                rescanIntervalS: rescanIntervalS
            )
            isSubmitting = false
            if didSubmit {
                dismiss()
            } else {
                submissionError = model.errorMessage ?? model.statusMessage
            }
        }
    }
}

private struct EditManagedFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let folder: FolderRecord
    let expectedFolderIncarnationDigest: String?
    @State private var label: String
    @State private var folderTypeRawValue: String
    @State private var selectedDeviceIDs: Set<DeviceID>
    @State private var rescanIntervalText = ""
    @State private var showAdvancedFolderTypes: Bool
    @State private var isSubmitting = false
    @State private var submissionError: String?

    init(folder: FolderRecord, expectedFolderIncarnationDigest: String?) {
        self.folder = folder
        self.expectedFolderIncarnationDigest = expectedFolderIncarnationDigest
        _label = State(initialValue: folder.label)
        _folderTypeRawValue = State(initialValue: folder.type.rawValue)
        _selectedDeviceIDs = State(initialValue: Set(folder.deviceIDs ?? []))
        _showAdvancedFolderTypes = State(initialValue: folder.type == .receiveEncrypted)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Folder ID", value: folder.id.rawValue)
                    TextField("Label", text: $label)
                    Picker("Folder Type", selection: $folderTypeRawValue) {
                        ForEach(visibleFolderTypes, id: \.rawValue) { type in
                            Text(folderTypeTitle(type)).tag(type.rawValue)
                        }
                    }
                    TextField("Rescan Interval (Seconds)", text: $rescanIntervalText, prompt: Text("Unchanged"))
                        .keyboardType(.numberPad)
                } header: {
                    Text("Folder Configuration")
                } footer: {
                    Text(
                        "The current core snapshot does not expose the existing rescan interval. Leave this field blank to preserve the current core value."
                    )
                }

                Section {
                    if peerDevices.isEmpty {
                        Text("No peer devices are configured. The local device will still be included.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(peerDevices) { device in
                            Toggle(isOn: deviceSelectionBinding(device.id)) {
                                VStack(alignment: .leading) {
                                    Text(device.name.isEmpty ? device.id.rawValue : device.name)
                                    Text(device.id.rawValue)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel(
                                Text(
                                    String(
                                        localized:
                                            "Share with \(device.name.isEmpty ? device.id.rawValue : device.name)"
                                    )
                                )
                            )
                        }
                    }
                } header: {
                    Text("Share with Devices")
                } footer: {
                    Text("The local device is always included by the Syncthing core.")
                }

                Section {
                    DisclosureGroup("Advanced Folder Types") {
                        Toggle("Show Receive Encrypted Type", isOn: $showAdvancedFolderTypes)
                            .disabled(folder.type == .receiveEncrypted)
                        Text(
                            "Receive Encrypted is an advanced Syncthing mode for untrusted devices. Use it only when the encrypted-folder workflow is already understood and configured."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("Cannot save folder: \(validationMessage)"))
                    }
                }
                if let submissionError {
                    Section("Request Result") {
                        Text(submissionError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Folder Configuration")
            .interactiveDismissDisabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .accessibilityLabel("Saving folder configuration")
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(validationMessage != nil || !hasChanges || isSubmitting)
                    .accessibilityHint("Submits the changed Syncthing folder configuration.")
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var visibleFolderTypes: [FolderType] {
        var types: [FolderType] = [.sendReceive, .sendOnly, .receiveOnly]
        if showAdvancedFolderTypes { types.append(.receiveEncrypted) }
        return types
    }

    private var peerDevices: [DeviceRecord] {
        model.snapshot.devices.filter { $0.id != model.snapshot.localDeviceID }
    }

    private func deviceSelectionBinding(_ id: DeviceID) -> Binding<Bool> {
        Binding(
            get: { selectedDeviceIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedDeviceIDs.insert(id)
                } else {
                    selectedDeviceIDs.remove(id)
                }
            }
        )
    }

    private var normalizedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedRescanInterval: Int? {
        let value = rescanIntervalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : strictNonnegativeInteger(value)
    }

    private var hasChanges: Bool {
        normalizedLabel != folder.label
            || folderTypeRawValue != folder.type.rawValue
            || selectedDeviceIDs != Set(folder.deviceIDs ?? [])
            || !rescanIntervalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationMessage: String? {
        guard expectedFolderIncarnationDigest != nil else {
            return String(
                localized:
                    "This folder action no longer matches the exact folder incarnation you reviewed. Refresh before trying again."
            )
        }
        let configuredPeerIDs = Set(peerDevices.map(\.id))
        guard selectedDeviceIDs.isSubset(of: configuredPeerIDs) else {
            return String(localized: "Every selected device must still be a configured remote peer.")
        }
        guard isValidManagedFolderLabel(label) else {
            return String(localized: "Enter a label containing 1 to 256 UTF-8 bytes and no control characters.")
        }
        let rescanText = rescanIntervalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rescanText.isEmpty {
            guard let parsedRescanInterval,
                (0...managedFolderMaximumRescanIntervalS).contains(parsedRescanInterval)
            else {
                return String(localized: "Enter a rescan interval from 0 to 31,536,000 seconds, or leave it blank.")
            }
        }
        return nil
    }

    private func save() {
        guard let type = FolderType(rawValue: folderTypeRawValue),
            let expectedFolderIncarnationDigest,
            validationMessage == nil,
            hasChanges
        else {
            return
        }
        isSubmitting = true
        submissionError = nil
        Task {
            let didSubmit = await model.editManagedFolder(
                folder,
                label: label,
                type: type,
                deviceIDs: selectedDeviceIDs,
                rescanIntervalS: parsedRescanInterval,
                expectedFolderIncarnationDigest: expectedFolderIncarnationDigest
            )
            isSubmitting = false
            if didSubmit {
                dismiss()
            } else {
                submissionError = model.errorMessage ?? model.statusMessage
            }
        }
    }
}

private func strictNonnegativeInteger(_ value: String) -> Int? {
    guard !value.isEmpty,
        value.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) })
    else {
        return nil
    }
    return Int(value)
}

private func isValidManagedFolderLabel(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !normalized.isEmpty
        && normalized.utf8.count <= 256
        && normalized.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
}

private func folderTypeTitle(_ type: FolderType) -> String {
    switch type {
    case .sendReceive: String(localized: "Send & Receive")
    case .sendOnly: String(localized: "Send Only")
    case .receiveOnly: String(localized: "Receive Only")
    case .receiveEncrypted: String(localized: "Receive Encrypted")
    }
}

private func contentSelectionTitle(_ mode: ContentSelectionMode) -> String {
    switch mode {
    case .full: String(localized: "Full")
    case .manual: String(localized: "Manual")
    case .rules: String(localized: "Rules")
    case .indexOnly: String(localized: "Index Only")
    }
}
