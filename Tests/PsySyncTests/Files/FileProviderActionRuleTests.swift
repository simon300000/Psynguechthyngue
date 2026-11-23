import Foundation
import Testing

/// The custom actions' activation rules in FileProvider/Info.plist, evaluated
/// the way the system does (SUBQUERY over `fileproviderItems`). "Keep
/// Downloaded" must also show when the system's cached item has no userInfo
/// (device: an item cached by an older build keeps its old properties until
/// its version changes), otherwise neither action appears.
@Suite struct FileProviderActionRuleTests {
    static let plist: URL = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "FileProvider/Info.plist")

    static func rules() throws -> [String: NSPredicate] {
        let data = try Data(contentsOf: plist)
        let root = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ext = try #require(root["NSExtension"] as? [String: Any])
        let actions = try #require(ext["NSExtensionFileProviderActions"] as? [[String: Any]])
        var out: [String: NSPredicate] = [:]
        for action in actions {
            let id = try #require(action["NSExtensionFileProviderActionIdentifier"] as? String)
            let rule = try #require(action["NSExtensionFileProviderActionActivationRule"] as? String)
            out[id] = NSPredicate(format: rule)
        }
        return out
    }

    func shown(_ items: [[String: Any]]) throws -> Set<String> {
        let context: [String: Any] = ["fileproviderItems": items]
        return Set(try Self.rules().filter { $0.value.evaluate(with: context) }.map(\.key))
    }

    let keep = "app.psynguechthyngue.action.keep-downloaded"
    let remove = "app.psynguechthyngue.action.remove-download"

    func item(pinned: Bool, onDemand: Bool = true) -> [String: Any] {
        ["userInfo": ["pinned": NSNumber(value: pinned), "isFile": NSNumber(value: true), "onDemand": NSNumber(value: onDemand)]]
    }

    @Test func unpinnedShowsKeepOnly() throws {
        #expect(try shown([item(pinned: false)]) == [keep])
    }

    @Test func pinnedShowsRemoveOnly() throws {
        #expect(try shown([item(pinned: true)]) == [remove])
    }

    /// User request: in "Download everything" folders both are meaningless.
    @Test func everythingFoldersShowNeither() throws {
        #expect(try shown([item(pinned: false, onDemand: false)]).isEmpty)
        #expect(try shown([item(pinned: true, onDemand: false)]).isEmpty)
    }

    /// Items cached by an older build (no userInfo) show nothing until the
    /// capability revision re-announces them.
    @Test func missingUserInfoShowsNothing() throws {
        #expect(try shown([[:]]).isEmpty)
    }

    @Test func mixedSelectionShowsBoth() throws {
        #expect(try shown([item(pinned: true), item(pinned: false)]) == [keep, remove])
    }
}
