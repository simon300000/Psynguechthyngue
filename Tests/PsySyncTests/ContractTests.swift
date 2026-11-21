import Foundation
import Testing
@testable import PsySync

@Suite struct BridgeContractTests {
    @Test func parsesBridgeErrors() {
        let parsed = BridgeContract.parse("psy:no_peer: no device for f1")
        #expect(parsed.code == .noPeer)
        #expect(parsed.detail == "no device for f1")
        #expect(BridgeContract.parse("psy:cancelled").code == .cancelled)
        #expect(BridgeContract.parse("boom").code == nil)
    }

    @Test func apiVersionMatchesGoBridge() {
        #expect(BridgeContract.apiVersion == 2)
    }
}

@Suite struct ModelTests {
    @Test func relativePathNavigation() {
        let p = RelativePath(rawValue: "a/b/c.txt")
        #expect(p.lastComponent == "c.txt")
        #expect(p.parent == RelativePath(rawValue: "a/b"))
        #expect(RelativePath(rawValue: "x").parent == .root)
        #expect(RelativePath.root.appending("y") == RelativePath(rawValue: "y"))
    }

    @Test func progressFraction() {
        #expect(SyncProgress(globalBytes: 100, needBytes: 25).fractionCompleted == 0.75)
        #expect(SyncProgress().fractionCompleted == 1)
    }

    @Test func layoutPaths() {
        let layout = AppGroupLayout(root: URL(filePath: "/tmp/group"))
        #expect(layout.managedFolder(FolderID(rawValue: "abc")).path(percentEncoded: false).hasSuffix("Folders/abc/"))
        #expect(layout.engineLock.lastPathComponent == "engine.lock")
    }
}
