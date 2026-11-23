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

/// Turns a folder the user picked (`.fileImporter`, security-scoped URL) into
/// a bookmark, rejecting File Provider backed locations such as iCloud Drive
/// (`ExternalLocation` resolves the bookmark).
enum ExternalDirectorySelection {
    static func make(from url: URL) -> Result<ExternalSelection, ExternalDirectoryError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if DEBUG
        // Device acceptance: what the sandbox can observe about the pick.
        let facts = ExternalLocation.LocationFacts.probe(url)
        LifecycleLog.shared.record("extloc-facts", "path=\(facts.path) ubiquitous=\(facts.isUbiquitous) "
            + "dataless=\(facts.hasDatalessContent) group=\(facts.groupContainerIdentifier ?? "nil") "
            + "provider=\(facts.fileProviderIdentifier ?? "nil") "
            + "kind=\(ExternalLocation.classify(facts))")
        #endif
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        if values?.isUbiquitousItem == true || url.path.contains("/Mobile Documents/") || url.path.contains("/CloudStorage/") {
            return .failure(.cloudLocation)
        }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return .success(ExternalSelection(bookmark: data, displayPath: url.path(percentEncoded: false)))
        } catch {
            return .failure(.bookmark(error.localizedDescription))
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
        // `.fileImporter` on a rendered view: the former `.sheet` on
        // `EmptyView()` never presented (and a UIDocumentPicker sheet inside
        // this sheet dismissed the whole form), so "A folder I choose" silently
        // created the folder inside the app.
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result.map(ExternalDirectorySelection.make(from:)) {
            case .success(.success(let sel)): external = sel
            case .success(.failure(.cloudLocation)):
                useExternal = external != nil
                model.show(error: String(localized: "iCloud Drive and other cloud folders can’t be synced in place. Choose a folder on this device."))
            case .success(.failure), .failure:
                useExternal = external != nil
                model.show(error: String(localized: "That folder could not be opened."))
            }
        }
        .onChange(of: picking) { _, open in
            // Importer closed without a choice: fall back to "In this app".
            if !open, external == nil { useExternal = false }
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
    }
}
