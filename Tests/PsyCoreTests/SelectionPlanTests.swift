import Foundation
import XCTest

@testable import PsyCore

final class SelectionPlanTests: XCTestCase {
    private let folder = FolderID(rawValue: "documents")!

    func testEveryExplicitModeRoundTripsWithoutCollapsingGlobAndRegex() throws {
        for mode in FolderContentSelectionMode.allCases {
            let plan = FolderSelectionPlan(mode: mode)
            let decoded = try JSONDecoder().decode(
                FolderSelectionPlan.self,
                from: JSONEncoder().encode(plan)
            )
            XCTAssertEqual(decoded.mode, mode)
        }

        var plan = FolderSelectionPlan(mode: .globRules)
        let globID = plan.appendRule(syntax: .syncthingGlob, action: .exclude, pattern: "**/*.tmp")
        plan.mode = .regexRules
        let regexID = plan.appendRule(syntax: .re2SafeRegex, action: .exclude, pattern: #"\.tmp$"#)
        XCTAssertTrue(plan.globRules.contains(where: { $0.id == globID && $0.syntax == .syncthingGlob }))
        XCTAssertTrue(plan.regexRules.contains(where: { $0.id == regexID && $0.syntax == .re2SafeRegex }))
    }

    func testDirectoryDirectiveIsTriStateAndAppliesToFutureChildren() {
        let directory = item(id: "photos", path: "Photos", isDirectory: true)
        let first = item(id: "first", path: "Photos/first.jpg")
        let second = item(id: "second", path: "Photos/second.jpg")
        var plan = FolderSelectionPlan(mode: .manualSelection)

        plan.setManualValue(.included, for: directory.relativePath, isDirectory: true)
        XCTAssertEqual(plan.manualValue(for: first.relativePath, isDirectory: false), .included)
        XCTAssertEqual(plan.manualDirectoryState(for: directory.relativePath, items: [first, second]), .included)

        plan.setManualValue(.excluded, for: first.relativePath, isDirectory: false)
        XCTAssertEqual(plan.manualDirectoryState(for: directory.relativePath, items: [first, second]), .mixed)
        var projection = plan.manualSelectionProjection(items: [directory, first, second])
        XCTAssertEqual(projection.directoryState(itemID: directory.id), .mixed)
        XCTAssertEqual(projection.value(itemID: first.id), .excluded)
        XCTAssertEqual(projection.value(itemID: second.id), .included)

        let future = item(id: "future", path: "Photos/created-later.jpg")
        XCTAssertEqual(plan.manualValue(for: future.relativePath, isDirectory: false), .included)

        plan.setManualValue(.excluded, for: directory.relativePath, isDirectory: true)
        XCTAssertEqual(
            plan.manualDirectoryState(for: directory.relativePath, items: [first, second, future]), .excluded)
        projection = plan.manualSelectionProjection(items: [directory, first, second, future])
        XCTAssertEqual(projection.directoryState(itemID: directory.id), .excluded)
        XCTAssertEqual(projection.value(itemID: future.id), .excluded)
        XCTAssertFalse(plan.manualDirectives.contains(where: { $0.relativePath == first.relativePath }))
    }

    func testFileDirectiveIsExactWhileDeepestDirectoryOverrideControlsFutureChildren() {
        var plan = FolderSelectionPlan(mode: .manualSelection, manualDefault: .excluded)
        plan.setManualValue(.included, for: "A", isDirectory: true)
        plan.setManualValue(.excluded, for: "A/one.txt", isDirectory: false)
        plan.setManualValue(.excluded, for: "A/private", isDirectory: true)
        plan.setManualValue(.included, for: "A/private/keep.txt", isDirectory: false)

        XCTAssertEqual(plan.manualValue(for: "A/one.txt", isDirectory: false), .excluded)
        XCTAssertEqual(plan.manualValue(for: "A/one.txt/future", isDirectory: false), .included)
        XCTAssertEqual(plan.manualValue(for: "A/private/other.txt", isDirectory: false), .excluded)
        XCTAssertEqual(plan.manualValue(for: "A/private/keep.txt", isDirectory: false), .included)
        XCTAssertEqual(plan.manualValue(for: "A/private/keep.txt/future", isDirectory: false), .excluded)
        XCTAssertEqual(plan.manualValue(for: "A/public/future.txt", isDirectory: false), .included)

        var rootPlan = FolderSelectionPlan(mode: .manualSelection, manualDefault: .excluded)
        rootPlan.setManualValue(.included, for: "", isDirectory: true)
        rootPlan.setManualValue(.excluded, for: "Nested/file.txt", isDirectory: false)
        let root = item(id: "root", path: "", isDirectory: true)
        let nested = item(id: "nested", path: "Nested/file.txt")
        let projection = rootPlan.manualSelectionProjection(items: [root, nested])
        XCTAssertEqual(projection.value(itemID: root.id), .included)
        XCTAssertEqual(projection.value(itemID: nested.id), .excluded)
        XCTAssertEqual(projection.directoryState(itemID: root.id), .excluded)
    }

    func testSelectAllInvertAndBatchSelectionAreDeterministic() {
        let directory = item(id: "dir", path: "Dir", isDirectory: true)
        let child = item(id: "child", path: "Dir/child.txt")
        let other = item(id: "other", path: "other.txt")
        var plan = FolderSelectionPlan(mode: .manualSelection)

        plan.selectAllManually()
        XCTAssertEqual(plan.manualValue(for: child.relativePath, isDirectory: false), .included)
        plan.invertManualSelection()
        XCTAssertEqual(plan.manualValue(for: child.relativePath, isDirectory: false), .excluded)

        plan.setManualValue(.included, forItemIDs: [directory.id, child.id], items: [directory, child, other])
        XCTAssertEqual(plan.manualValue(for: child.relativePath, isDirectory: false), .included)
        XCTAssertEqual(plan.manualValue(for: other.relativePath, isDirectory: false), .excluded)
        XCTAssertEqual(plan.manualDirectives.count, 1, "the selected parent should cover its selected child")
    }

    func testRuleOrderingEnableDuplicateAndRestore() throws {
        let excludeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let includeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var plan = FolderSelectionPlan(
            mode: .globRules,
            globRules: [
                SelectionRule(id: excludeID, syntax: .syncthingGlob, action: .exclude, pattern: "cache/**"),
                SelectionRule(id: includeID, syntax: .syncthingGlob, action: .include, pattern: "**"),
            ]
        )
        let target = item(id: "cache", path: "cache/value.bin")
        XCTAssertEqual(try plan.disposition(for: target), .excluded)

        XCTAssertTrue(plan.moveRule(id: includeID, syntax: .syncthingGlob, to: 0))
        XCTAssertEqual(try plan.disposition(for: target), .synchronized)

        let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        XCTAssertEqual(plan.duplicateRule(id: excludeID, syntax: .syncthingGlob, newID: duplicateID), duplicateID)
        XCTAssertEqual(plan.globRules.first(where: { $0.id == duplicateID })?.pattern, "cache/**")

        var duplicate = try XCTUnwrap(plan.globRules.first(where: { $0.id == duplicateID }))
        duplicate.isEnabled = false
        XCTAssertTrue(plan.updateRule(duplicate))
        XCTAssertEqual(plan.globRules.first(where: { $0.id == duplicateID })?.isEnabled, false)

        plan.restoreDefaultRules(for: .syncthingGlob)
        XCTAssertEqual(plan.globRules.count, 1)
        XCTAssertEqual(plan.globRules[0].syntax, .syncthingGlob)
        XCTAssertEqual(plan.globRules[0].pattern, "**")
    }

    func testRegexModeUsesExistingRE2SafeValidator() {
        let id = UUID()
        let plan = FolderSelectionPlan(
            mode: .regexRules,
            regexRules: [
                SelectionRule(id: id, syntax: .re2SafeRegex, action: .exclude, pattern: #"^(a+)\1$"#)
            ]
        )
        XCTAssertEqual(
            plan.validate(),
            [.invalidRule(id, .unsupportedRegexFeature("backreference"))]
        )
    }

    func testPreviewKeepsEveryGlobalIndexItemAndUsesUploadedForReleaseEligibility() throws {
        let previous = FolderSelectionPlan(mode: .fullSync)
        var proposed = FolderSelectionPlan(mode: .manualSelection)
        let items = [
            item(id: "safe", path: "safe.txt", size: 10, availability: .local, replicas: 1),
            item(id: "dirty", path: "dirty.txt", size: 20, availability: .local, dirty: true, replicas: 1),
            item(id: "unique", path: "unique.txt", size: 30, availability: .local, replicas: 0),
            item(id: "remote", path: "remote.txt", size: 40, availability: .remoteOnly, replicas: 1),
        ]
        proposed.setManualValue(.included, for: "remote.txt", isDirectory: false)

        let preview = try proposed.preview(items: items, comparedTo: previous)
        XCTAssertEqual(preview.totalFiles, 4)
        XCTAssertEqual(preview.indexedFiles, 4)
        XCTAssertEqual(preview.matchedFiles, 1)
        XCTAssertEqual(preview.matchedBytes, 40)
        XCTAssertEqual(preview.excludedFiles, 3)
        XCTAssertEqual(preview.downloadBytes, 40)
        XCTAssertEqual(preview.releasableBytes, 10)
        XCTAssertNil(preview.confirmation.requiredPhrase)
        XCTAssertFalse(preview.confirmation.accepts(acknowledged: false, typedPhrase: ""))
        XCTAssertTrue(preview.confirmation.accepts(acknowledged: true, typedPhrase: ""))
    }

    func testDraftSerializationCannotMasqueradeAsACoreCommandAndIgnoresLegacyFields() throws {
        let draft = FolderSelectionDraft(
            folderID: folder,
            baselineGeneration: 42,
            plan: FolderSelectionPlan(mode: .indexOnly),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(draft)) as? [String: Any]
        )
        XCTAssertNil(object["preparedCommandArguments"])
        XCTAssertNil(object["selectionPlanState"])
        XCTAssertNil(object["selectionPlanJSON"])

        object["preparedCommandArguments"] = [
            "selectionPlanState": "draft",
            "selectionPlanJSON": "legacy-pseudo-command",
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(FolderSelectionDraft.self, from: legacyData), draft)
    }

    func testDraftStoreRoundTripsAndUsesFolderSafeFilename() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-plan-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = FolderSelectionDraftStore(root: root)
        let folderWithSlash = try XCTUnwrap(FolderID(rawValue: "team/docs"))
        let draft = FolderSelectionDraft(
            folderID: folderWithSlash,
            baselineGeneration: 7,
            plan: FolderSelectionPlan(mode: .onDemand),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        try store.save(draft)
        XCTAssertEqual(try store.load(folderID: folderWithSlash), draft)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertFalse(files.contains(where: { $0.contains("/") }))
    }

    func testFileTreeBuildsHierarchyAndSearchesAllTokensCaseInsensitively() {
        let items = [
            item(id: "docs", path: "Docs", isDirectory: true),
            item(id: "report", path: "Docs/Annual Report.PDF"),
            item(id: "notes", path: "Notes.txt"),
        ]
        let tree = SelectionFileTree(items: items)
        XCTAssertEqual(tree.roots.map(\.id), ["docs", "notes"])
        XCTAssertEqual(tree.roots[0].children.map(\.id), ["report"])
        XCTAssertEqual(tree.search("annual pdf").map(\.id), ["report"])
        XCTAssertEqual(tree.search("NOTES").map(\.id), ["notes"])

        var scaleItems: [IndexedItem] = []
        scaleItems.reserveCapacity(100_000)
        var directives: [ManualSelectionDirective] = []
        directives.reserveCapacity(101)
        for directoryIndex in 0..<100 {
            let directoryPath = String(format: "Directory-%03d", directoryIndex)
            scaleItems.append(
                item(id: "directory-\(directoryIndex)", path: directoryPath, isDirectory: true)
            )
            directives.append(
                ManualSelectionDirective(
                    relativePath: directoryPath,
                    isDirectory: true,
                    value: directoryIndex.isMultiple(of: 2) ? .included : .excluded
                )
            )
            for fileIndex in 0..<999 {
                scaleItems.append(
                    item(
                        id: "file-\(directoryIndex)-\(fileIndex)",
                        path: "\(directoryPath)/File-\(fileIndex).bin"
                    )
                )
            }
        }
        directives.append(
            ManualSelectionDirective(
                relativePath: "Directory-000/File-0.bin",
                isDirectory: false,
                value: .excluded
            )
        )
        let scalePlan = FolderSelectionPlan(
            mode: .manualSelection,
            manualDefault: .excluded,
            manualDirectives: directives
        )
        let clock = ContinuousClock()
        let started = clock.now
        let scaleProjection = scalePlan.manualSelectionProjection(items: scaleItems)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(10))
        XCTAssertEqual(scaleProjection.value(itemID: "file-0-0"), .excluded)
        XCTAssertEqual(scaleProjection.value(itemID: "file-0-998"), .included)
        XCTAssertEqual(scaleProjection.directoryState(itemID: "directory-0"), .mixed)
        XCTAssertEqual(scaleProjection.directoryState(itemID: "directory-1"), .excluded)
    }

    private func item(
        id: String,
        path: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        availability: FileAvailability = .remoteOnly,
        dirty: Bool = false,
        replicas: Int = 1
    ) -> IndexedItem {
        IndexedItem(
            id: id,
            folderID: folder,
            relativePath: path,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: Date(timeIntervalSince1970: 0),
            contentVersion: Data(id.utf8),
            metadataVersion: Data(id.utf8),
            availability: availability,
            hasUnuploadedChanges: dirty,
            remoteReplicaCount: replicas
        )
    }
}
