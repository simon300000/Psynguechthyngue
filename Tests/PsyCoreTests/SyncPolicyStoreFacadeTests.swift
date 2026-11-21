import Foundation
import XCTest

@testable import PsyCore

final class SyncPolicyStoreFacadeTests: XCTestCase {
    private let currentDigest = String(repeating: "a", count: 64)
    private let staleDigest = String(repeating: "b", count: 64)

    func testLegacyFacadeLoadMigratesBarePolicyToV2() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var legacy = SyncPolicy()
        legacy.allowExpensive = true
        legacy.dailyExpensiveBytes = 42
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SecureLockFile.writeAtomically(encoder.encode(legacy), to: fixture.paths.policy)
        let store = SyncPolicyStore(
            url: fixture.paths.policy,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )

        XCTAssertEqual(try store.load(), legacy)

        let migrated = try store.loadDocument()
        XCTAssertEqual(migrated.schemaVersion, SyncPolicyDocumentV2.currentSchemaVersion)
        XCTAssertEqual(migrated.budgetTimeZoneIdentifier, "UTC")
        XCTAssertEqual(migrated.global, legacy)
        XCTAssertTrue(migrated.folderOverrides.isEmpty)
        let onDisk = try XCTUnwrap(
            try SecureLockFile.readRegularFileIfPresent(
                at: fixture.paths.policy,
                maximumSize: SyncPolicyDocumentStore.maximumDocumentBytes
            )
        )
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: onDisk) as? [String: AnyHashable],
            try JSONSerialization.jsonObject(with: encoder.encode(migrated)) as? [String: AnyHashable]
        )
    }

    func testLegacyFacadeSavePreservesFolderOverridesAndBudgetTimeZone() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "preserved-folder"))
        let store = SyncPolicyStore(
            url: fixture.paths.policy,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )
        try store.saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "Europe/Berlin",
                folderOverrides: [
                    FolderSyncPolicyOverride(
                        folderID: folderID,
                        folderIncarnationDigest: currentDigest,
                        queuePriority: .high,
                        policy: SyncPolicyOverride(allowBackgroundDownload: false)
                    )
                ]
            )
        )
        var replacement = SyncPolicy()
        replacement.minimumFreeDiskBytes = 987

        try store.save(replacement)

        let document = try store.loadDocument()
        XCTAssertEqual(document.global, replacement)
        XCTAssertEqual(document.budgetTimeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(document.folderOverrides.count, 1)
        XCTAssertEqual(document.folderOverrides[0].folderID, folderID)
        XCTAssertEqual(document.folderOverrides[0].folderIncarnationDigest, currentDigest)
        XCTAssertEqual(document.folderOverrides[0].queuePriority, .high)
        XCTAssertEqual(document.folderOverrides[0].policy.allowBackgroundDownload, false)
    }

    func testResolvedPolicyAndQueuePriorityFailClosedForStaleIncarnation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "recreated-folder"))
        let store = SyncPolicyStore(
            url: fixture.paths.policy,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )
        var global = SyncPolicy()
        global.allowBackgroundUpload = true
        try store.saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                global: global,
                folderOverrides: [
                    FolderSyncPolicyOverride(
                        folderID: folderID,
                        folderIncarnationDigest: currentDigest,
                        queuePriority: .low,
                        policy: SyncPolicyOverride(allowBackgroundUpload: false)
                    )
                ]
            )
        )
        let current = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: currentDigest
        )
        let stale = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: staleDigest
        )

        XCTAssertFalse(try store.resolvedPolicy(for: current).allowBackgroundUpload)
        XCTAssertEqual(try store.queuePriority(for: current), .low)
        for operation in [
            { try store.resolvedPolicy(for: stale) as Any },
            { try store.queuePriority(for: stale) as Any },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(
                    error as? SyncPolicyDocumentError,
                    .staleFolderOverride(folderID: folderID.rawValue)
                )
            }
        }
    }

    func testMissingFolderOverrideUsesGlobalPolicyAndNormalPriority() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "unconfigured-folder"))
        let store = SyncPolicyStore(
            url: fixture.paths.policy,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )
        var global = SyncPolicy()
        global.allowBackgroundScan = false
        try store.save(global)
        let context = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: currentDigest
        )

        XCTAssertEqual(try store.resolvedPolicy(for: context), global)
        XCTAssertEqual(try store.queuePriority(for: context), .normal)
    }

    func testFolderPolicyConfigurationUpdateBindsPolicyAndPriorityToExactIncarnation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "editable-folder"))
        let store = SyncPolicyStore(
            url: fixture.paths.policy,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )
        var global = SyncPolicy()
        global.allowExpensive = true
        global.maxExpensiveRunBytes = 100
        try store.save(global)
        let context = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: currentDigest
        )

        let saved = try store.saveFolderPolicy(
            SyncPolicyOverride(
                allowExpensive: false,
                maxExpensiveRunBytes: .limit(40)
            ),
            queuePriority: .high,
            for: context
        )

        XCTAssertEqual(saved.context, context)
        XCTAssertEqual(saved.policyOverride?.allowExpensive, false)
        XCTAssertEqual(saved.policyOverride?.maxExpensiveRunBytes, .limit(40))
        XCTAssertEqual(saved.queuePriority, .high)
        XCTAssertFalse(saved.effectivePolicy.allowExpensive)
        XCTAssertEqual(saved.effectivePolicy.maxExpensiveRunBytes, 40)
        XCTAssertEqual(try store.folderPolicyConfiguration(for: context), saved)

        let inherited = try store.saveFolderPolicy(
            SyncPolicyOverride(),
            queuePriority: .normal,
            for: context
        )
        XCTAssertNil(inherited.policyOverride)
        XCTAssertEqual(inherited.queuePriority, .normal)
        XCTAssertEqual(inherited.effectivePolicy, global)
        XCTAssertTrue(try store.loadDocument().folderOverrides.isEmpty)
    }

    func testFolderPolicyConfigurationUpdateRejectsRemoveAndReaddIncarnationDrift() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "readded-folder"))
        let store = SyncPolicyStore(
            url: fixture.paths.policy,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )
        let oldContext = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: currentDigest
        )
        let readdedContext = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: staleDigest
        )
        _ = try store.saveFolderPolicy(
            SyncPolicyOverride(allowBackgroundDownload: false),
            queuePriority: .low,
            for: oldContext
        )

        for operation in [
            {
                try store.folderPolicyConfiguration(for: readdedContext) as Any
            },
            {
                try store.saveFolderPolicy(
                    SyncPolicyOverride(allowBackgroundDownload: true),
                    queuePriority: .high,
                    for: readdedContext
                ) as Any
            },
            {
                try store.saveFolderPolicy(nil, queuePriority: .normal, for: readdedContext) as Any
            },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(
                    error as? SyncPolicyDocumentError,
                    .staleFolderOverride(folderID: folderID.rawValue)
                )
            }
        }

        let unchanged = try XCTUnwrap(try store.loadDocument().folderOverrides.first)
        XCTAssertEqual(unchanged.folderIncarnationDigest, currentDigest)
        XCTAssertEqual(unchanged.queuePriority, .low)
        XCTAssertEqual(unchanged.policy.allowBackgroundDownload, false)
    }

    func testFolderPolicyEntryIsRemovedOnlyWhenPolicyInheritsAndPriorityIsNormal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "canonical-entry"))
        let context = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: currentDigest
        )
        let store = SyncPolicyStore(
            url: fixture.paths.policy,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )

        let policyAtNormalPriority = try store.saveFolderPolicy(
            SyncPolicyOverride(allowBackgroundScan: false),
            queuePriority: .normal,
            for: context
        )
        XCTAssertEqual(policyAtNormalPriority.queuePriority, .normal)
        XCTAssertEqual(policyAtNormalPriority.policyOverride?.allowBackgroundScan, false)
        XCTAssertEqual(try store.loadDocument().folderOverrides.count, 1)

        let priorityOnly = try store.saveFolderPolicy(
            SyncPolicyOverride(),
            queuePriority: .high,
            for: context
        )
        XCTAssertNil(priorityOnly.policyOverride)
        XCTAssertEqual(priorityOnly.queuePriority, .high)
        XCTAssertEqual(try store.loadDocument().folderOverrides.count, 1)

        _ = try store.saveFolderPolicy(nil, queuePriority: .normal, for: context)
        XCTAssertTrue(try store.loadDocument().folderOverrides.isEmpty)
    }

    func testFailedFolderPolicySaveIsByteAtomicAndExistingPolicyCanStillBeCleared() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "atomic-folder-save"))
        let context = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: currentDigest
        )
        var global = SyncPolicy()
        global.lowPowerBehavior = .indexOnly
        let store = SyncPolicyStore(
            url: fixture.paths.policy,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )
        try store.saveDocument(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                global: global,
                folderOverrides: [
                    .init(
                        folderID: folderID,
                        folderIncarnationDigest: currentDigest,
                        policy: .init(allowBackgroundUpload: false)
                    )
                ]
            )
        )
        let baselineBytes = try Data(contentsOf: fixture.paths.policy)

        XCTAssertThrowsError(
            try store.saveFolderPolicy(
                .init(lowPowerBehavior: .pauseAutomatic),
                queuePriority: .normal,
                for: context
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .unrepresentableConservativeMerge("lowPowerBehavior")
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.policy), baselineBytes)
        XCTAssertEqual(
            try store.folderPolicyConfiguration(for: context).policyOverride?
                .allowBackgroundUpload,
            false
        )

        let cleared = try store.saveFolderPolicy(
            nil,
            queuePriority: .normal,
            for: context
        )
        XCTAssertNil(cleared.policyOverride)
        XCTAssertTrue(try store.loadDocument().folderOverrides.isEmpty)
    }

    func testDiscardFolderPolicyIsExactIncarnationCASAndIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folderID = try XCTUnwrap(FolderID(rawValue: "discard-exact"))
        let store = SyncPolicyStore(
            url: fixture.paths.policy,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )
        let oldContext = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: currentDigest
        )
        let newContext = FolderPolicyContext(
            folderID: folderID,
            folderIncarnationDigest: staleDigest
        )
        _ = try store.saveFolderPolicy(
            SyncPolicyOverride(allowBackgroundUpload: false),
            queuePriority: .high,
            for: oldContext
        )

        XCTAssertThrowsError(try store.discardFolderPolicy(for: newContext)) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .staleFolderOverride(folderID: folderID.rawValue)
            )
        }
        XCTAssertEqual(
            try store.loadDocument().folderOverrides.first?.folderIncarnationDigest,
            currentDigest
        )
        XCTAssertTrue(try store.discardFolderPolicy(for: oldContext))
        XCTAssertFalse(try store.discardFolderPolicy(for: oldContext))
        XCTAssertTrue(try store.loadDocument().folderOverrides.isEmpty)
    }

    #if os(macOS)
        func testFolderPolicyUIExposesEffectiveSourcesAndExactIncarnationFailureWording() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let foldersView = try String(
                contentsOf: repositoryRoot.appendingPathComponent("App/FoldersView.swift"),
                encoding: .utf8
            )
            let appModel = try applicationModelSource(root: repositoryRoot)
            let settings = try String(
                contentsOf: repositoryRoot.appendingPathComponent("App/SettingsView.swift"),
                encoding: .utf8
            )
            let appIntents = try String(
                contentsOf: repositoryRoot.appendingPathComponent("App/AppIntents.swift"),
                encoding: .utf8
            )
            let english = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "App/Resources/en.lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            let simplifiedChinese = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "App/Resources/zh-Hans.lproj/Localizable.strings"
                ),
                encoding: .utf8
            )

            for required in [
                "FolderPolicyEditorView",
                "FolderAllowedNetworksEditor",
                "FolderBatteryThresholdEditor",
                "FolderScheduleOverrideEditor",
                "Effective Preview",
                "Source: Global ceiling",
                "Why Not Syncing",
                "FolderQueuePriority.allCases",
                "minimumFreeDiskBytes",
                "allowTemporaryUserOverride",
                "configuration?.effectivePolicy",
                "folderPolicyBlockMessage",
                "folderPolicyBlockRemedy",
                "lowPowerChoiceIsCompatible",
                "cannot be represented as a restriction of the current global behavior",
                "This byte value is too large.",
                "Small Files Only",
                ".accessibilityLabel",
                "Sync Folder with Temporary Profile",
                "temporaryPolicyProfileID: profile.id",
            ] {
                XCTAssertTrue(foldersView.contains(required), "Missing UI contract: \(required)")
            }
            XCTAssertFalse(
                foldersView.contains("effectivePolicy: effectivePolicy"),
                "Why Not Syncing must not present an unsaved draft as enforced policy"
            )
            XCTAssertGreaterThanOrEqual(
                appModel.components(separatedBy: "policyContext(for: folder.id)").count - 1,
                2
            )
            XCTAssertTrue(appModel.contains("expectedContext"))
            XCTAssertTrue(appModel.contains("reconcileSuccessfulFolderRemoval"))
            for required in [
                "Temporary Policy Profiles",
                "Run Sync All with This Profile",
                "temporaryPolicyProfileID: profile.id",
                "model.temporaryPolicyProfiles.first",
            ] {
                XCTAssertTrue(settings.contains(required), "Missing profile UI contract: \(required)")
            }
            for required in [
                "SyncAllWithPolicyProfileIntent",
                "temporaryPolicyProfileName: profileName",
                "document.temporaryProfiles.filter",
                "temporaryPolicyProfile: temporaryPolicyProfile",
                "@Parameter(title: \"Temporary Policy Profile Name\") var profileName: String?",
                "folderIDText: folderID",
            ] {
                XCTAssertTrue(appIntents.contains(required), "Missing profile Intent contract: \(required)")
            }
            for required in [
                "\"Policy & Queue Priority\"",
                "\"Source: Global ceiling\"",
                "\"Why Not Syncing\"",
                "\"Remedy: %@\"",
                "cannot be represented as a restriction of the current global behavior",
                "\"This byte value is too large.\"",
                "\"Small Files Only\"",
                "No settings were applied to the new folder incarnation.",
            ] {
                XCTAssertTrue(english.contains(required), "Missing English localization: \(required)")
                XCTAssertTrue(
                    simplifiedChinese.contains(required),
                    "Missing Simplified Chinese localization key: \(required)"
                )
            }
        }
    #endif

    func testSharedContainerHasDedicatedTransferAccountingPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        XCTAssertEqual(
            fixture.paths.transferAccounting,
            fixture.root.appendingPathComponent("Metadata/transfer-accounting.json")
        )
        XCTAssertNotEqual(fixture.paths.transferAccounting, fixture.paths.history)
        XCTAssertNotEqual(fixture.paths.transferAccounting, fixture.paths.policy)
    }
}

private struct Fixture {
    let root: URL
    let paths: SharedContainerPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "policy-facade-\(UUID().uuidString)",
            isDirectory: true
        )
        paths = SharedContainerPaths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
