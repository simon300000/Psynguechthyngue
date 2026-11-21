import PsyCore
import SwiftUI

struct RunHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.histories.isEmpty {
                ContentUnavailableView(
                    "No Runs", systemImage: "clock", description: Text("Completed and interrupted runs appear here."))
            } else {
                List(model.histories) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(triggerTitle(record.trigger), systemImage: icon(record.endReason))
                            Spacer()
                            Text(record.startedAt, style: .relative).font(.caption)
                        }
                        Text(endReasonTitle(record.endReason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LabeledContent(
                            "Duration", value: record.endedAt.timeIntervalSince(record.startedAt),
                            format: .number.precision(.fractionLength(1))
                        )
                        .font(.caption)
                        transferSummary(record)
                        if let failure = record.failureCode {
                            Text(failure).font(.caption.monospaced()).foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(triggerTitle(record.trigger)))
                    .accessibilityValue(Text(accessibilityValue(record)))
                }
            }
        }
        .navigationTitle("Run History")
        .refreshable { await model.refresh() }
    }

    private func icon(_ reason: SyncRunEndReason) -> String {
        switch reason {
        case .completed: "checkmark.circle"
        case .noWork: "minus.circle"
        case .cancelled, .expired: "stop.circle"
        case .policyDenied, .coreBusy: "pause.circle"
        case .failed: "xmark.octagon"
        }
    }

    private func triggerTitle(_ trigger: SyncTrigger) -> String {
        switch trigger {
        case .user: String(localized: "User")
        case .foreground: String(localized: "Foreground")
        case .backgroundRefresh: String(localized: "Background Refresh")
        case .backgroundProcessing: String(localized: "Background Processing")
        case .fileProvider: String(localized: "File Provider")
        case .appIntent: String(localized: "App Intent")
        }
    }

    private func endReasonTitle(_ reason: SyncRunEndReason) -> String {
        switch reason {
        case .completed: String(localized: "Completed")
        case .noWork: String(localized: "No Work")
        case .policyDenied: String(localized: "Denied by Policy")
        case .cancelled: String(localized: "Cancelled")
        case .expired: String(localized: "Expired")
        case .coreBusy: String(localized: "Core Busy")
        case .failed: String(localized: "Failed")
        }
    }

    private func accessibilityValue(_ record: SyncRunRecord) -> String {
        let transfer: String
        if record.trigger == .backgroundRefresh {
            transfer = String(localized: "no network transfer; local snapshot validation only")
        } else if let received = record.networkReceivedBytes,
            let sent = record.networkSentBytes
        {
            transfer = String(
                localized:
                    "\(received.formatted(.byteCount(style: .file))) received and \(sent.formatted(.byteCount(style: .file))) sent"
            )
        } else if record.transferredBytes > 0 {
            transfer = String(localized: "\(record.transferredBytes.formatted(.byteCount(style: .file))) processed")
        } else {
            transfer = String(localized: "network bytes not measured")
        }
        let summary = "\(endReasonTitle(record.endReason)), \(transfer)"
        guard let failure = record.failureCode else { return summary }
        return String(localized: "\(summary), error code \(failure)")
    }

    @ViewBuilder
    private func transferSummary(_ record: SyncRunRecord) -> some View {
        if record.trigger == .backgroundRefresh {
            LabeledContent("Network Transfer", value: String(localized: "None — local snapshot validation only"))
                .font(.caption)
        } else if let received = record.networkReceivedBytes,
            let sent = record.networkSentBytes
        {
            LabeledContent("Network Received", value: received, format: .byteCount(style: .file))
                .font(.caption)
            LabeledContent("Network Sent", value: sent, format: .byteCount(style: .file))
            if record.transferredBytes > 0,
                record.transferredBytes != record.measuredNetworkBytes
            {
                LabeledContent(
                    "Processed Bytes",
                    value: record.transferredBytes,
                    format: .byteCount(style: .file)
                )
                .font(.caption)
            }
        } else if record.transferredBytes > 0 {
            LabeledContent(
                "Processed Bytes",
                value: record.transferredBytes,
                format: .byteCount(style: .file)
            )
            .font(.caption)
        } else {
            LabeledContent("Transferred", value: String(localized: "Not measured by embedded core"))
                .font(.caption)
        }
    }
}
