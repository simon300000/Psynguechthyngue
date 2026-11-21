import PsyCore
import SwiftUI

struct SyncDiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                LabeledContent("Network", value: model.network.kind.rawValue)
                LabeledContent("Devices", value: "\(model.snapshot.remoteDevices.count)")
                LabeledContent("Folders", value: "\(model.snapshot.folders.count)")
                LabeledContent("Indexed Items", value: "\(model.indexedItemCount)")
                LabeledContent("Last saved state") { Text(model.snapshot.generatedAt, style: .relative) }
            }
            Section { backgroundTaskCard }
            Section { NavigationLink("View Run History") { RunHistoryView() } }
        }
        .navigationTitle("Sync Details")
    }

    private var backgroundTaskCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                backgroundAttemptRow(
                    title: String(localized: "Refresh request"),
                    attempt: model.backgroundTaskScheduleStatus.refresh
                )
                backgroundAttemptRow(
                    title: String(localized: "Processing request"),
                    attempt: model.backgroundTaskScheduleStatus.processing
                )
                if let processing = model.backgroundTaskScheduleStatus.processing,
                    processing.result == .scheduled
                {
                    LabeledContent(
                        "External power scheduler hint",
                        value: processing.requiresExternalPower
                            ? String(localized: "Required")
                            : String(localized: "Not requested")
                    )
                    .font(.caption)
                }
                Text(
                    "Refresh only validates the last saved snapshot locally. Full policy-checked synchronization runs only in background processing, if iOS grants time."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Background Scheduling", systemImage: "clock.arrow.circlepath")
        }
    }

    @ViewBuilder
    private func backgroundAttemptRow(
        title: String,
        attempt: BackgroundTaskScheduleAttempt?
    ) -> some View {
        if let attempt {
            VStack(alignment: .leading, spacing: 3) {
                LabeledContent(
                    title,
                    value: backgroundScheduleResultTitle(attempt.result)
                )
                .font(.caption)
                if let code = attempt.failureCode {
                    Text(code.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                } else if let earliest = attempt.earliestBeginDate {
                    Text(backgroundEarliestDescription(earliest))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent(title, value: String(localized: "Not requested yet"))
                .font(.caption)
        }
    }

    private func backgroundScheduleResultTitle(_ result: BackgroundTaskScheduleResult) -> String {
        switch result {
        case .scheduled: String(localized: "Request accepted")
        case .disabled: String(localized: "Disabled by setting")
        case .failed: String(localized: "Request failed")
        }
    }

    private func backgroundEarliestDescription(_ date: Date) -> String {
        let formattedDate = date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "May run no earlier than \(formattedDate); iOS may defer or skip it.")
    }

}
