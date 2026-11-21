import PsySync
import SwiftUI
import UniformTypeIdentifiers

/// Result of picking a directory for an external (in-place) folder.
struct ExternalSelection: Equatable {
    var bookmark: Data
    var displayPath: String
}

enum ExternalDirectoryError: Error {
    case cloudLocation
    case bookmark(String)
}

/// Document picker limited to folders. Creates a security-scoped bookmark and
/// rejects File Provider backed locations such as iCloud Drive (DESIGN.md §6.7).
/// (WP-B's `ExternalLocation` will take over bookmark handling for the engine.)
struct ExternalDirectoryPicker: UIViewControllerRepresentable {
    let onResult: (Result<ExternalSelection, ExternalDirectoryError>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onResult) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onResult: (Result<ExternalSelection, ExternalDirectoryError>) -> Void
        init(_ onResult: @escaping (Result<ExternalSelection, ExternalDirectoryError>) -> Void) { self.onResult = onResult }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
            if values?.isUbiquitousItem == true || url.path.contains("/Mobile Documents/") || url.path.contains("/CloudStorage/") {
                onResult(.failure(.cloudLocation))
                return
            }
            do {
                let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                onResult(.success(ExternalSelection(bookmark: data, displayPath: url.path(percentEncoded: false))))
            } catch {
                onResult(.failure(.bookmark(error.localizedDescription)))
            }
        }
    }
}

/// Shared form section: where the folder lives + how much to download.
struct FolderOptionsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var external: ExternalSelection?
    @Binding var mode: PsySync.ContentMode
    @State private var picking = false
    @State private var useExternal = false

    var location: FolderLocation {
        if useExternal, let external { return .external(bookmark: external.bookmark, displayPath: external.displayPath) }
        return .managed
    }

    var body: some View {
        Section {
            Picker("Location", selection: $useExternal) {
                Text("In this app (shown in Files)").tag(false)
                Text("A folder I choose").tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("folder.location")
            .onChange(of: useExternal) { _, now in
                if now { if external == nil { picking = true } } else { external = nil }
                if now { mode = .everything }
            }
            if useExternal, let external {
                LabeledContent("Folder") { Text(external.displayPath).font(.footnote).lineLimit(2).truncationMode(.head) }
                Button("Choose Another Folder…") { picking = true }
            }
        } header: { Text("Where to keep the files") }
        footer: {
            Text(useExternal
                 ? "Files are synced in place. Downloading on demand is not available for these folders."
                 : "Files are stored by this app and appear in the Files app under Psynguechthyngue.")
        }
        if !useExternal {
            Section {
                Picker("Download", selection: $mode) {
                    Text("Everything").tag(PsySync.ContentMode.everything)
                    Text("On demand").tag(PsySync.ContentMode.onDemand)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("folder.mode")
            } header: { Text("Download") }
            footer: {
                Text(mode == .everything
                     ? "All files are downloaded and kept on this device."
                     : "Files appear in the Files app and are downloaded when you open them.")
            }
        }
        EmptyView()
            .sheet(isPresented: $picking) {
                ExternalDirectoryPicker { result in
                    picking = false
                    switch result {
                    case let .success(sel): external = sel
                    case .failure(.cloudLocation):
                        useExternal = external != nil
                        model.show(error: String(localized: "iCloud Drive and other cloud folders can’t be synced in place. Choose a folder on this device."))
                    case .failure:
                        useExternal = external != nil
                        model.show(error: String(localized: "That folder could not be opened."))
                    }
                }
            }
    }
}
