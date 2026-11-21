import Foundation
import PsyCore
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingIdentity = false

    var body: some View {
        Form {
            Section("Synchronization") {
                Toggle(
                    "Sync while app is open",
                    isOn: Binding(
                        get: { model.foregroundSyncEnabled },
                        set: { model.setForegroundSyncEnabled($0) }
                    ))
                NavigationLink("Network & Data Usage") { AdvancedSettingsView(filter: "network") }
                NavigationLink("Power & Background Sync") { AdvancedSettingsView(filter: "power") }
                NavigationLink("Advanced Settings") { AdvancedSettingsView() }
            }
            Section("This Device") {
                Button("Share Device ID") { showingIdentity = true }
                NavigationLink("Review Notifications") { AdvancedSettingsView(filter: "notification") }
            }
            Section("Help & Diagnostics") {
                NavigationLink("Sync Details") { SyncDiagnosticsView() }
                NavigationLink("Diagnostics") { AdvancedSettingsView(filter: "diagnostic") }
                NavigationLink("About your file copies") { AdvancedSettingsView(filter: "risk") }
                NavigationLink("About") { AdvancedSettingsView(filter: "about") }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingIdentity) { ThisDeviceView() }
    }
}

private struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = SyncPolicy()
    @State private var temporaryProfiles: [TemporarySyncPolicyProfile] = []
    @State private var searching = ""
    @State private var diagnosticExport: DiagnosticExportPresentation?
    @State private var pendingDiagnosticCleanupURL: URL?
    @State private var isPreparingDiagnosticExport = false

    init(filter: String = "") { _searching = State(initialValue: filter) }

    var body: some View {
        Form {
            if shows(
                "risk", "peer", "backup", "uploaded", "offline", "remove download",
                String(localized: "Peer-to-Peer Storage Risk")
            ) {
                Section("Peer-to-Peer Storage Risk") {
                    Text(
                        "This app has no permanent central cloud copy. Offline Uploaded status uses the last exact peer evidence. If every device removes the same download, the bytes may be permanently lost while only placeholders and index metadata remain."
                    )
                    .foregroundStyle(.secondary)
                    Label(
                        "Keep at least one complete desktop, NAS, or independent backup copy.",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                }
            }

            if shows(
                "network", "wifi", "ethernet", "cellular", "expensive", "data",
                String(localized: "Network"), String(localized: "Cellular"),
                String(localized: "Expensive"), String(localized: "Low Data Mode")
            ) {
                Section("Network") {
                    Toggle("Automatic on Wi-Fi", isOn: automaticNetworkBinding(.wifi))
                    Toggle("Automatic on Ethernet", isOn: automaticNetworkBinding(.ethernet))
                    Toggle("Automatic on Other Networks", isOn: automaticNetworkBinding(.other))
                    Picker("Cellular", selection: $draft.cellularAccess) {
                        ForEach(CellularAccess.allCases, id: \.self) { Text(cellularAccessTitle($0)).tag($0) }
                    }
                    if draft.cellularAccess == .uploadOnly || draft.cellularAccess == .downloadOnly {
                        Label(
                            "Upload Only and Download Only run direction-bound network sessions. Cellular policy is checked again before and during every transfer.",
                            systemImage: "arrow.left.arrow.right"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Toggle("Allow Expensive Networks", isOn: $draft.allowExpensive)
                    Toggle("Allow Low Data Mode", isOn: $draft.allowConstrained)
                    OptionalByteLimitRow(title: "Cellular File Limit", value: $draft.maxCellularFileBytes)
                    OptionalByteLimitRow(title: "Expensive Run Limit", value: $draft.maxExpensiveRunBytes)
                    OptionalByteLimitRow(title: "Daily Expensive Limit", value: $draft.dailyExpensiveBytes)
                    Text(
                        "For a fail-safe cap, all measured Syncthing protocol bytes count toward the daily expensive-network limit. If today's accounting is incomplete, transfer is blocked until the user explicitly applies a temporary policy override."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if shows(
                "diagnostic", "support", "privacy", "json", "export",
                String(localized: "Diagnostics"), String(localized: "Export Diagnostic Summary")
            ) {
                Section("Diagnostics") {
                    Text(
                        "A diagnostic summary includes app, OS, policy, scheduler, and aggregate sync health fields from this device. It is not a complete log."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Text(
                        "It never includes device or folder IDs, file names or paths, peer addresses, bookmarks, identity keys, command arguments, request IDs, file contents, or raw error messages."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Button {
                        isPreparingDiagnosticExport = true
                        Task {
                            defer { isPreparingDiagnosticExport = false }
                            if let url = await model.prepareDiagnosticSummaryExport() {
                                pendingDiagnosticCleanupURL = url
                                diagnosticExport = DiagnosticExportPresentation(url: url)
                            }
                        }
                    } label: {
                        if isPreparingDiagnosticExport {
                            ProgressView()
                                .accessibilityLabel("Preparing Diagnostic Summary")
                        } else {
                            Label("Export Diagnostic Summary", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isPreparingDiagnosticExport)
                    .accessibilityHint(
                        "Creates a redacted local JSON summary and opens the system share sheet. Nothing is uploaded automatically."
                    )
                }
            }

            if shows(
                "notification", "alert", "review", "permission", "background",
                String(localized: "Notifications"),
                String(localized: "Review Notifications")
            ) {
                Section("Notifications") {
                    Toggle(
                        "Review Notifications",
                        isOn: Binding(
                            get: { model.notificationsEnabled },
                            set: { enabled in
                                Task { await model.setNotificationsEnabled(enabled) }
                            }
                        )
                    )
                    .disabled(model.isUpdatingNotificationSettings)
                    LabeledContent(
                        "System Permission",
                        value: notificationAuthorizationTitle(model.notificationAuthorizationStatus)
                    )
                    Text(
                        "Notifications contain only generic review prompts. Lock-screen text never includes file paths, device or folder IDs, peer addresses, or recovery locators."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Text(
                        "The app checks for new review items only after a foreground refresh or when iOS actually grants a background execution opportunity. This is not real-time push delivery, and iOS does not guarantee when a notification appears."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    if model.notificationAuthorizationStatus == .provisional {
                        Text(
                            "iOS granted provisional delivery. Notifications may appear quietly until you change the system notification setting."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if model.notificationAuthorizationStatus == .denied {
                        Button("Open Notification Settings") {
                            model.openSystemNotificationSettings()
                        }
                    }
                    if model.notificationStateUnavailable {
                        Label(
                            "Notification history is unavailable or failed strict validation. No new notification will be scheduled until it can be read safely.",
                            systemImage: "exclamationmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if shows(
                "power", "battery", "charging", "low power", "thermal",
                String(localized: "Power"), String(localized: "Minimum Battery Level"),
                String(localized: "Low Power Mode"), String(localized: "Thermal Pause Level")
            ) {
                Section("Power") {
                    Toggle("Require Power for Automatic Work", isOn: $draft.requirePowerForAllAutomaticWork)
                    Text(
                        "This power requirement is applied to policy-checked synchronization and to the background processing scheduler hint. Local snapshot validation may still run during a short refresh."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Toggle("Require Power for Maintenance", isOn: $draft.requirePowerForMaintenance)
                    OptionalByteLimitRow(
                        title: "Require Power Above Transfer Size",
                        value: $draft.requirePowerForLargeTransferBytes
                    )
                    Toggle("Minimum Battery Level", isOn: minimumBatteryEnabled)
                    if draft.minimumBatteryLevel != nil {
                        Slider(value: minimumBatteryBinding, in: 0.05...1, step: 0.05) {
                            Text("Minimum Battery Level")
                        } minimumValueLabel: {
                            Text("5%")
                        } maximumValueLabel: {
                            Text("100%")
                        }
                        LabeledContent(
                            "Battery Threshold",
                            value: minimumBatteryBinding.wrappedValue,
                            format: .percent.precision(.fractionLength(0))
                        )
                        .accessibilityHint("Sets the minimum battery level for automatic work.")
                    }
                    Picker("Low Power Mode", selection: $draft.lowPowerBehavior) {
                        ForEach(LowPowerBehavior.allCases, id: \.self) { Text(lowPowerTitle($0)).tag($0) }
                    }
                    if draft.lowPowerBehavior == .indexOnly {
                        Label(
                            "Index Only exchanges bounded metadata without transferring file contents. Live power and network policy still apply.",
                            systemImage: "list.bullet.rectangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Picker("Thermal Pause Level", selection: $draft.pauseTransfersAtThermalLevel) {
                        ForEach(ThermalLevel.allCases, id: \.self) { Text(thermalTitle($0)).tag($0) }
                    }
                }
            }

            if shows(
                "schedule", "time", "weekday", "window",
                String(localized: "Automatic Schedule"), String(localized: "Start Hour"),
                String(localized: "End Hour")
            ) {
                Section("Automatic Schedule") {
                    Toggle("Restrict Automatic Work to a Time Window", isOn: scheduleEnabled)
                    if scheduleEnabled.wrappedValue {
                        Picker("Start Hour", selection: scheduleStartHour) {
                            ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                        }
                        Picker("End Hour", selection: scheduleEndHour) {
                            ForEach(0...24, id: \.self) { Text(hourLabel($0)).tag($0) }
                        }
                        ForEach(1...7, id: \.self) { weekday in
                            Toggle(weekdayLabel(weekday), isOn: scheduleWeekdayBinding(weekday))
                        }
                        Text("If the end hour is earlier than the start hour, the window continues overnight.")
                            .font(.footnote)
                    }
                }
            }

            if shows(
                "background", "disabled", "processing", "refresh", "ios", "upload", "download", "scan",
                String(localized: "Background"), String(localized: "Automatic Background Work")
            ) {
                Section("Background") {
                    Picker("Automatic Background Work", selection: $draft.automaticBackgroundMode) {
                        ForEach(AutomaticBackgroundMode.allCases, id: \.self) { mode in
                            Text(automaticBackgroundModeTitle(mode)).tag(mode)
                        }
                    }
                    if draft.automaticBackgroundMode == .refreshAndProcessing {
                        Toggle("Background Upload", isOn: $draft.allowBackgroundUpload)
                        Toggle("Background Download", isOn: $draft.allowBackgroundDownload)
                        Toggle("Background Scan", isOn: $draft.allowBackgroundScan)
                        Text(
                            "Each folder may further restrict background upload, download, and scan. Disabled directions are not silently promoted to a full sync."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Text(
                        "Background refresh only validates the last saved snapshot locally; it does not synchronize or consume queued commands."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Text(
                        "iOS schedules background work opportunistically. Fixed intervals and exact run times are not guaranteed."
                    )
                    .font(.footnote)
                }
            }

            if shows(
                "safety", "space", "disk", "override", "conflict",
                String(localized: "Safety"), String(localized: "Minimum Free Space")
            ) {
                Section("Safety") {
                    Toggle("Allow One-Time User Overrides", isOn: $draft.allowTemporaryUserOverride)
                    ByteLimitRow(title: "Minimum Free Space", value: $draft.minimumFreeDiskBytes)
                    Text(
                        "Conflicts, unuploaded edits, and insufficient disk space are never bypassed by a policy override."
                    )
                    .font(.footnote)
                    if !model.externalDirectories.isEmpty {
                        NavigationLink {
                            ExternalDirectoriesView()
                        } label: {
                            Label("Existing External Directory Authorizations", systemImage: "externaldrive")
                        }
                        Text(
                            "This compatibility page remains available only to review or remove authorizations created by an earlier build. New shares no longer use this workflow."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if shows(
                "profile", "temporary", "shortcut", "limit", "override",
                String(localized: "Temporary Policy Profiles")
            ) {
                Section("Temporary Policy Profiles") {
                    Text(
                        "A profile authorizes one user or Shortcut request for all folders or one exact folder, expires automatically, and always has a finite protocol-byte limit. It never changes saved global or folder policy."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    ForEach($temporaryProfiles) { $profile in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Profile Name", text: $profile.name)
                                .textInputAutocapitalization(.words)
                            ByteLimitRow(
                                title: "Maximum Network Bytes",
                                value: $profile.maximumNetworkBytes,
                                minimumValue: 1,
                                maximumValue: TemporarySyncPolicyProfile.maximumNetworkBytes
                            )
                            Stepper(
                                value: $profile.validitySeconds,
                                in: TemporarySyncPolicyProfile
                                    .minimumValiditySeconds...TemporarySyncPolicyProfile.maximumValiditySeconds,
                                step: 60
                            ) {
                                LabeledContent(
                                    "Valid For",
                                    value: "\(profile.validitySeconds / 60) min"
                                )
                            }
                            Toggle(
                                "Allow Overrideable Policy Blocks",
                                isOn: $profile.requestsTemporaryOverride
                            )
                            Button("Run Sync All with This Profile") {
                                Task {
                                    _ = await model.submit(
                                        kind: .sync,
                                        temporaryPolicyProfileID: profile.id
                                    )
                                }
                            }
                            .disabled(
                                profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || model.temporaryPolicyProfiles.first(where: {
                                        $0.id == profile.id
                                    }) != profile
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in temporaryProfiles.remove(atOffsets: offsets) }
                    Button("Add Temporary Profile") {
                        guard temporaryProfiles.count < TemporarySyncPolicyProfile.maximumProfiles else {
                            return
                        }
                        let existingNames = Set(temporaryProfiles.map(\.name))
                        var suffix = 1
                        var name = String(localized: "New Temporary Profile")
                        while existingNames.contains(name) {
                            suffix += 1
                            name = String(localized: "New Temporary Profile") + " \(suffix)"
                        }
                        temporaryProfiles.append(
                            TemporarySyncPolicyProfile(
                                name: name
                            )
                        )
                    }
                    .disabled(temporaryProfiles.count >= TemporarySyncPolicyProfile.maximumProfiles)
                }
            }

            if shows(
                "about", "version", "core", "license", "notice", "open source",
                String(localized: "About"), String(localized: "Open Source Notices")
            ) {
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Syncthing Core", value: PlatformCoreBootstrap.coreRevision)
                    NavigationLink {
                        LegalNoticesView()
                    } label: {
                        Label("Open Source Notices", systemImage: "doc.text")
                    }
                    Text(
                        "A release-specific corresponding-source archive and its durable public download location must be published before this binary is distributed. This development build does not claim that source offer is available."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Save Settings") {
                    Task {
                        await model.savePolicy(
                            draft,
                            temporaryProfiles: temporaryProfiles
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command])
                .accessibilityHint("Saves this policy for foreground and background work.")
                Button("Restore Defaults") { draft = SyncPolicy() }
                    .accessibilityHint("Replaces the unsaved settings draft; save to apply it.")
            }
        }
        .navigationTitle("Advanced Settings")
        .searchable(text: $searching, prompt: "Search settings")
        .task {
            draft = model.policy
            temporaryProfiles = model.temporaryPolicyProfiles
        }
        .onChange(of: model.policy) { _, value in
            draft = value
        }
        .onChange(of: model.temporaryPolicyProfiles) { _, value in
            temporaryProfiles = value
        }
        .sheet(
            item: $diagnosticExport,
            onDismiss: { finishPendingDiagnosticSharing() },
            content: { export in
                DiagnosticSummaryShareSheet(url: export.url) {
                    finishDiagnosticSharing(export.url)
                }
                .onDisappear {
                    finishDiagnosticSharing(export.url)
                }
            }
        )
        .onDisappear { finishPendingDiagnosticSharing() }
    }

    private func shows(_ terms: String...) -> Bool {
        let query = searching.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return query.isEmpty || terms.contains(where: { $0.localizedCaseInsensitiveContains(query) })
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return switch (version, build) {
        case (.some(let version), .some(let build)): "\(version) (\(build))"
        case (.some(let version), .none): version
        case (.none, .some(let build)): build
        case (.none, .none): String(localized: "Unavailable")
        }
    }

    private func finishDiagnosticSharing(_ url: URL) {
        guard pendingDiagnosticCleanupURL == url else { return }
        pendingDiagnosticCleanupURL = nil
        diagnosticExport = nil
        Task { await model.discardDiagnosticSummaryExport(at: url) }
    }

    private func finishPendingDiagnosticSharing() {
        guard let url = pendingDiagnosticCleanupURL else { return }
        finishDiagnosticSharing(url)
    }

    private func automaticNetworkBinding(_ network: NetworkKind) -> Binding<Bool> {
        Binding(
            get: { draft.automaticallyAllowedNetworks.contains(network) },
            set: { enabled in
                if enabled {
                    draft.automaticallyAllowedNetworks.insert(network)
                } else {
                    draft.automaticallyAllowedNetworks.remove(network)
                }
            }
        )
    }

    private var minimumBatteryEnabled: Binding<Bool> {
        Binding(
            get: { draft.minimumBatteryLevel != nil },
            set: { enabled in draft.minimumBatteryLevel = enabled ? (draft.minimumBatteryLevel ?? 0.20) : nil }
        )
    }

    private var minimumBatteryBinding: Binding<Double> {
        Binding(
            get: { draft.minimumBatteryLevel ?? 0.20 },
            set: { draft.minimumBatteryLevel = min(max($0, 0.05), 1) }
        )
    }

    private func automaticBackgroundModeTitle(_ mode: AutomaticBackgroundMode) -> String {
        switch mode {
        case .disabled: String(localized: "Off")
        case .refreshOnly: String(localized: "Local Status Refresh Only")
        case .refreshAndProcessing: String(localized: "Refresh and Long Processing")
        }
    }

    private var scheduleEnabled: Binding<Bool> {
        Binding(
            get: { !draft.automaticTimeWindows.isEmpty },
            set: { enabled in
                if enabled, draft.automaticTimeWindows.isEmpty {
                    draft.automaticTimeWindows = [TimeWindow(startMinute: 0, endMinute: 24 * 60)]
                } else if !enabled {
                    draft.automaticTimeWindows = []
                }
            }
        )
    }

    private var scheduleStartHour: Binding<Int> {
        Binding(
            get: { (draft.automaticTimeWindows.first?.startMinute ?? 0) / 60 },
            set: { hour in updateSchedule { $0.startMinute = min(max(hour, 0), 23) * 60 } }
        )
    }

    private var scheduleEndHour: Binding<Int> {
        Binding(
            get: { (draft.automaticTimeWindows.first?.endMinute ?? 24 * 60) / 60 },
            set: { hour in updateSchedule { $0.endMinute = min(max(hour, 0), 24) * 60 } }
        )
    }

    private func scheduleWeekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { draft.automaticTimeWindows.first?.weekdays.contains(weekday) ?? false },
            set: { enabled in
                updateSchedule { window in
                    if enabled {
                        window.weekdays.insert(weekday)
                    } else {
                        window.weekdays.remove(weekday)
                    }
                }
            }
        )
    }

    private func updateSchedule(_ update: (inout TimeWindow) -> Void) {
        var window =
            draft.automaticTimeWindows.first
            ?? TimeWindow(startMinute: 0, endMinute: 24 * 60)
        update(&window)
        draft.automaticTimeWindows = [window]
    }

    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return String(weekday) }
        return symbols[weekday - 1]
    }

    private func cellularAccessTitle(_ access: CellularAccess) -> String {
        switch access {
        case .denied: String(localized: "Denied")
        case .uploadOnly: String(localized: "Upload Only")
        case .downloadOnly: String(localized: "Download Only")
        case .smallFiles: String(localized: "Small Files Only")
        case .allowed: String(localized: "Allowed")
        }
    }

    private func lowPowerTitle(_ behavior: LowPowerBehavior) -> String {
        switch behavior {
        case .pauseAutomatic: String(localized: "Pause Automatic Work")
        case .indexOnly: String(localized: "Index Only")
        case .userRequestsOnly: String(localized: "User Requests Only")
        case .allowed: String(localized: "Allowed")
        }
    }

    private func thermalTitle(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: String(localized: "Nominal")
        case .fair: String(localized: "Fair")
        case .serious: String(localized: "Serious")
        case .critical: String(localized: "Critical")
        }
    }

    private func notificationAuthorizationTitle(
        _ status: NotificationAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined: String(localized: "Not Requested")
        case .denied: String(localized: "Denied")
        case .provisional: String(localized: "Provisional")
        case .authorized: String(localized: "Authorized")
        case .ephemeral: String(localized: "Temporary")
        }
    }
}

private enum BundledLegalDocument: String, CaseIterable, Identifiable {
    case projectLicense = "LICENSE"
    case projectNotice = "NOTICE"
    case thirdPartyNotices = "THIRD_PARTY_NOTICES"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .projectLicense: "Project License"
        case .projectNotice: "Project Notice"
        case .thirdPartyNotices: "Third-Party Notices"
        }
    }

    var resourceExtension: String? {
        switch self {
        case .projectLicense, .projectNotice: nil
        case .thirdPartyNotices: "md"
        }
    }

    func contents(in bundle: Bundle = .main) -> String? {
        guard
            let url = bundle.url(forResource: rawValue, withExtension: resourceExtension),
            let text = try? String(contentsOf: url, encoding: .utf8),
            !text.isEmpty
        else { return nil }
        return text
    }
}

private struct LegalNoticesView: View {
    var body: some View {
        List(BundledLegalDocument.allCases) { document in
            NavigationLink(document.title) {
                LegalDocumentView(document: document)
            }
        }
        .navigationTitle("Open Source Notices")
    }
}

private struct LegalDocumentView: View {
    let document: BundledLegalDocument

    var body: some View {
        ScrollView {
            if let contents = document.contents() {
                Text(verbatim: contents)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                ContentUnavailableView(
                    "Legal Document Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        "This signed build is missing a required legal document. Do not distribute it."
                    )
                )
                .padding()
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiagnosticExportPresentation: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct DiagnosticSummaryShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor () -> Void

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in completion() }
        }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

private struct OptionalByteLimitRow: View {
    let title: LocalizedStringKey
    @Binding var value: Int64?

    var body: some View {
        LabeledContent(title) {
            TextField(
                "Unlimited",
                value: Binding(
                    get: { value },
                    set: { value = $0.map { max(0, $0) } }
                ),
                format: .number
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
        }
    }
}

private struct ByteLimitRow: View {
    let title: LocalizedStringKey
    @Binding var value: Int64
    var minimumValue: Int64 = 0
    var maximumValue: Int64 = .max

    var body: some View {
        LabeledContent(title) {
            TextField(
                "Bytes",
                value: Binding(
                    get: { value },
                    set: { value = min(max(minimumValue, $0), maximumValue) }
                ),
                format: .number
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
        }
    }
}
