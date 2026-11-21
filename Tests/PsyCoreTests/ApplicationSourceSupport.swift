import Foundation

// Source-level integration contracts span the feature extensions of the app
// facade. Behavioral lifecycle/index tests exercise PsyCore directly.
func applicationModelSource(root: URL) throws -> String {
    let app = root.appendingPathComponent("App")
    let urls = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
        .filter {
            $0.lastPathComponent == "AppModel.swift" || $0.lastPathComponent.hasPrefix("AppModel+")
                || $0.lastPathComponent == "AppSupport.swift"
        }
        .sorted { left, right in
            if left.lastPathComponent == "AppModel.swift" { return true }
            if right.lastPathComponent == "AppModel.swift" { return false }
            return left.lastPathComponent < right.lastPathComponent
        }
    return try urls.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}
