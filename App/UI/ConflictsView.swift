import PsySync
import SwiftUI

/// Problem sheet for a folder's conflict copies (Home ▸ Recent problems,
/// Folder ▸ Conflicts). Each conflict can be ignored, or all at once.
/// Ignoring only hides it in the App: the conflict copy stays in the folder.
struct ConflictsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folderID: FolderID
    /// Several conflicts open at full height so the list is visible at once.
    @State private var detent: PresentationDetent

    init(folderID: FolderID, count: Int) {
        self.folderID = folderID
        _detent = State(initialValue: count > 1 ? .large : .medium)
    }

    var body: some View {
        let conflicts = model.conflicts(in: folderID)
        NavigationStack {
            List {
                Section {
                    Label {
                        if conflicts.count > 1 { Text("\(conflicts.count) file conflicts") } else { Text("File conflict") }
                    } icon: {
                        Image(systemName: "doc.on.doc").foregroundStyle(.orange)
                    }
                    Text(SyncIssue.Kind.conflict.advice)
                }
                Section {
                    ForEach(conflicts) { issue in
                        row(issue)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Ignore") { ignore([issue]) }.tint(.gray)
                            }
                    }
                } header: {
                    if let label = model.folders.first(where: { $0.id == folderID })?.label { Text(label) }
                } footer: {
                    Text("Ignoring only hides a conflict here. The conflict copy stays in the folder until you delete it in Files.")
                }
            }
            .glassScreen()
            .animation(.smooth, value: conflicts.map(\.id))
            .navigationTitle("Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if conflicts.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Ignore All") { ignore(conflicts) }
                            .accessibilityIdentifier("conflicts.ignoreAll")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: conflicts.isEmpty) { _, empty in if empty { dismiss() } }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    private func row(_ issue: SyncIssue) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.path?.lastComponent ?? issue.technicalDetail)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let dir = issue.path.flatMap(Self.directory) {
                    Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button("Ignore") { ignore([issue]) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityIdentifier("conflict.ignore.\(issue.path?.rawValue ?? issue.id)")
        }
    }

    private func ignore(_ issues: [SyncIssue]) {
        withAnimation(.smooth) { model.ignoreConflicts(issues) }
    }

    private static func directory(_ path: RelativePath) -> String? {
        let parts = path.rawValue.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }
}
