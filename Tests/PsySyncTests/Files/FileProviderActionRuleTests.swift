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

    @Test func unpinnedShowsKeepOnly() throws {
        #expect(try shown([["userInfo": ["pinned": NSNumber(value: false), "isFile": NSNumber(value: false)]]]) == [keep])
    }

    @Test func pinnedShowsRemoveOnly() throws {
        #expect(try shown([["userInfo": ["pinned": NSNumber(value: true), "isFile": NSNumber(value: true)]]]) == [remove])
    }

    @Test func missingUserInfoStillShowsKeep() throws {
        #expect(try shown([[:]]) == [keep])
        #expect(try shown([["userInfo": [String: Any]()]]) == [keep])
    }

    @Test func mixedSelectionShowsBoth() throws {
        #expect(try shown([["userInfo": ["pinned": NSNumber(value: true)]], ["userInfo": ["pinned": NSNumber(value: false)]]])
            == [keep, remove])
    }
}
