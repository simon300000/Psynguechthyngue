import Foundation
import XCTest

@testable import PsyCore

final class SyncPolicyDocumentStoreTests: XCTestCase {
    private let firstDigest = String(repeating: "a", count: 64)
    private let secondDigest = String(repeating: "b", count: 64)

    func testLegacyBarePolicyMigratesWithoutChangingAnyPolicyField() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var legacy = SyncPolicy()
        legacy.automaticallyAllowedNetworks = [.ethernet, .cellular]
        legacy.cellularAccess = .downloadOnly
        legacy.allowExpensive = true
        legacy.allowConstrained = true
        legacy.maxCellularFileBytes = nil
        legacy.maxExpensiveRunBytes = 91
        legacy.dailyExpensiveBytes = 123
        legacy.requirePowerForAllAutomaticWork = true
        legacy.requirePowerForLargeTransferBytes = nil
        legacy.requirePowerForMaintenance = false
        legacy.minimumBatteryLevel = nil
        legacy.lowPowerBehavior = .userRequestsOnly
        legacy.pauseTransfersAtThermalLevel = .critical
        legacy.minimumFreeDiskBytes = 456
        legacy.automaticTimeWindows = [
            TimeWindow(weekdays: [2, 4], startMinute: 11, endMinute: 22)
        ]
        legacy.allowBackgroundUpload = false
        legacy.allowBackgroundDownload = true
        legacy.allowBackgroundScan = false
        legacy.automaticBackgroundMode = .refreshOnly
        legacy.allowTemporaryUserOverride = false

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var preBackgroundModeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any]
        )
        preBackgroundModeObject.removeValue(forKey: "automaticBackgroundMode")
        let preBackgroundModeData = try JSONSerialization.data(
            withJSONObject: preBackgroundModeObject,
            options: [.sortedKeys]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(SyncPolicy.self, from: preBackgroundModeData)
                .automaticBackgroundMode,
            .refreshOnly
        )

        var previouslyEnabledObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(SyncPolicy()))
                as? [String: Any]
        )
        previouslyEnabledObject.removeValue(forKey: "automaticBackgroundMode")
        let previouslyEnabledData = try JSONSerialization.data(
            withJSONObject: previouslyEnabledObject,
            options: [.sortedKeys]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(SyncPolicy.self, from: previouslyEnabledData)
                .automaticBackgroundMode,
            .refreshAndProcessing
        )
        try SecureLockFile.writeAtomically(preBackgroundModeData, to: fixture.url)

        let store = SyncPolicyDocumentStore(
            url: fixture.url,
            legacyBudgetTimeZoneIdentifier: "Europe/Berlin"
        )
        let migrated = try store.load()

        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.global, legacy)
        XCTAssertEqual(migrated.budgetTimeZoneIdentifier, "Europe/Berlin")
        XCTAssertTrue(migrated.folderOverrides.isEmpty)
        let onDisk = try XCTUnwrap(
            try SecureLockFile.readRegularFileIfPresent(at: fixture.url, maximumSize: 1_048_576)
        )
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: onDisk) as? [String: AnyHashable],
            try JSONSerialization.jsonObject(with: encoder.encode(migrated)) as? [String: AnyHashable]
        )
        XCTAssertEqual(try store.load(), migrated)
    }

    func testStructuredLegacyPolicyKeepsBackgroundProcessingDisabled() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var policy = SyncPolicy()
        policy.allowBackgroundUpload = false
        policy.allowBackgroundDownload = false
        policy.allowBackgroundScan = false
        policy.automaticBackgroundMode = .refreshOnly
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: policy
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
                as? [String: Any]
        )
        var global = try XCTUnwrap(object["global"] as? [String: Any])
        global.removeValue(forKey: "automaticBackgroundMode")
        object["global"] = global
        try SecureLockFile.writeAtomically(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            to: fixture.url
        )

        let loaded = try SyncPolicyDocumentStore(url: fixture.url).load()
        XCTAssertEqual(loaded.global.automaticBackgroundMode, .refreshOnly)
        XCTAssertFalse(
            BackgroundTaskSchedulePlanner()
                .makePlan(now: .now, policy: loaded.global, snapshot: nil)
                .processingEnabled
        )
    }

    func testLimitStatesResolveExplicitlyAndMergeConservatively() throws {
        XCTAssertEqual(try PolicyByteLimit.inherit.resolved(inheriting: 100), 100)
        XCTAssertNil(try PolicyByteLimit.unlimited.resolved(inheriting: 100))
        XCTAssertEqual(try PolicyByteLimit.limit(40).resolved(inheriting: nil), 40)
        XCTAssertEqual(
            PolicyByteLimit.conservativelyMerged([.inherit, .unlimited, .limit(40), .limit(80)]),
            .limit(40)
        )
        XCTAssertEqual(
            PolicyByteLimit.conservativelyMerged([.inherit, .unlimited]),
            .unlimited
        )
        XCTAssertEqual(PolicyByteLimit.conservativelyMerged([.inherit]), .inherit)
        XCTAssertThrowsError(try PolicyByteLimit.limit(-1).resolved(inheriting: 100))
    }

    func testFolderOverrideRequiresCurrentIncarnationAndCanInheritOrRemoveLimits() throws {
        let folder = try XCTUnwrap(FolderID(rawValue: "folder-a"))
        var global = SyncPolicy()
        global.dailyExpensiveBytes = 100
        global.maxExpensiveRunBytes = 75
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                FolderSyncPolicyOverride(
                    folderID: folder,
                    folderIncarnationDigest: firstDigest,
                    policy: SyncPolicyOverride(
                        maxExpensiveRunBytes: .inherit,
                        dailyExpensiveBytes: .unlimited,
                        allowBackgroundDownload: false
                    )
                )
            ]
        )

        let resolved = try document.resolvedPolicy(
            for: folder,
            folderIncarnationDigest: firstDigest
        )
        XCTAssertEqual(resolved.maxExpensiveRunBytes, 75)
        XCTAssertEqual(resolved.dailyExpensiveBytes, 100)
        XCTAssertFalse(resolved.allowBackgroundDownload)

        XCTAssertThrowsError(
            try document.resolvedPolicy(for: folder, folderIncarnationDigest: secondDigest)
        ) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .staleFolderOverride(folderID: folder.rawValue)
            )
        }
    }

    func testFolderOverrideCannotLowerGlobalFreeDiskSafetyFloor() throws {
        let folder = try XCTUnwrap(FolderID(rawValue: "disk-floor"))
        var global = SyncPolicy()
        global.minimumFreeDiskBytes = 500
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(
                    folderID: folder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(minimumFreeDiskBytes: 100)
                )
            ]
        )

        XCTAssertEqual(
            try document.resolvedPolicy(
                for: folder,
                folderIncarnationDigest: firstDigest
            ).minimumFreeDiskBytes,
            500
        )
    }

    func testFolderOverrideCannotEnableGloballyDisabledTemporaryOverride() throws {
        let folder = try XCTUnwrap(FolderID(rawValue: "override-gate"))
        var global = SyncPolicy()
        global.allowTemporaryUserOverride = false
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(
                    folderID: folder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(allowTemporaryUserOverride: true)
                )
            ]
        )

        XCTAssertFalse(
            try document.resolvedPolicy(
                for: folder,
                folderIncarnationDigest: firstDigest
            ).allowTemporaryUserOverride
        )
    }

    func testFolderOverrideCannotRemoveOrRaiseGlobalDailyCeiling() throws {
        let unlimitedFolder = try XCTUnwrap(FolderID(rawValue: "daily-unlimited"))
        let raisedFolder = try XCTUnwrap(FolderID(rawValue: "daily-raised"))
        let tighterFolder = try XCTUnwrap(FolderID(rawValue: "daily-tighter"))
        var global = SyncPolicy()
        global.dailyExpensiveBytes = 100
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(
                    folderID: unlimitedFolder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(dailyExpensiveBytes: .unlimited)
                ),
                .init(
                    folderID: raisedFolder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(dailyExpensiveBytes: .limit(200))
                ),
                .init(
                    folderID: tighterFolder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(dailyExpensiveBytes: .limit(40))
                ),
            ]
        )

        XCTAssertEqual(
            try document.resolvedPolicy(
                for: unlimitedFolder,
                folderIncarnationDigest: firstDigest
            ).dailyExpensiveBytes,
            100
        )
        XCTAssertEqual(
            try document.resolvedPolicy(
                for: raisedFolder,
                folderIncarnationDigest: firstDigest
            ).dailyExpensiveBytes,
            100
        )
        XCTAssertEqual(
            try document.resolvedPolicy(
                for: tighterFolder,
                folderIncarnationDigest: firstDigest
            ).dailyExpensiveBytes,
            40
        )
    }

    func testFolderOverrideCannotRelaxGlobalNetworkRunOrBackgroundCeilings() throws {
        let folder = try XCTUnwrap(FolderID(rawValue: "global-ceilings"))
        var global = SyncPolicy()
        global.automaticallyAllowedNetworks = [.wifi]
        global.cellularAccess = .denied
        global.allowExpensive = false
        global.allowConstrained = false
        global.maxCellularFileBytes = 25
        global.maxExpensiveRunBytes = 50
        global.allowBackgroundUpload = false
        global.allowBackgroundDownload = false
        global.allowBackgroundScan = false
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(
                    folderID: folder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(
                        automaticallyAllowedNetworks: [.wifi, .ethernet, .cellular],
                        cellularAccess: .allowed,
                        allowExpensive: true,
                        allowConstrained: true,
                        maxCellularFileBytes: .unlimited,
                        maxExpensiveRunBytes: .limit(500),
                        allowBackgroundUpload: true,
                        allowBackgroundDownload: true,
                        allowBackgroundScan: true
                    )
                )
            ]
        )

        let resolved = try document.resolvedPolicy(
            for: folder,
            folderIncarnationDigest: firstDigest
        )
        XCTAssertEqual(resolved.automaticallyAllowedNetworks, [.wifi])
        XCTAssertEqual(resolved.cellularAccess, .denied)
        XCTAssertFalse(resolved.allowExpensive)
        XCTAssertFalse(resolved.allowConstrained)
        XCTAssertEqual(resolved.maxCellularFileBytes, 25)
        XCTAssertEqual(resolved.maxExpensiveRunBytes, 50)
        XCTAssertFalse(resolved.allowBackgroundUpload)
        XCTAssertFalse(resolved.allowBackgroundDownload)
        XCTAssertFalse(resolved.allowBackgroundScan)
    }

    func testFolderOverrideCanTightenGlobalNetworkRunAndBackgroundCeilings() throws {
        let folder = try XCTUnwrap(FolderID(rawValue: "folder-tightening"))
        var global = SyncPolicy()
        global.automaticallyAllowedNetworks = [.wifi, .ethernet]
        global.cellularAccess = .allowed
        global.allowExpensive = true
        global.allowConstrained = true
        global.maxCellularFileBytes = nil
        global.maxExpensiveRunBytes = 50
        global.allowBackgroundUpload = true
        global.allowBackgroundDownload = true
        global.allowBackgroundScan = true
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(
                    folderID: folder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(
                        automaticallyAllowedNetworks: [.wifi],
                        cellularAccess: .uploadOnly,
                        allowExpensive: false,
                        allowConstrained: false,
                        maxCellularFileBytes: .limit(10),
                        maxExpensiveRunBytes: .limit(20),
                        allowBackgroundUpload: false,
                        allowBackgroundDownload: false,
                        allowBackgroundScan: false
                    )
                )
            ]
        )

        let resolved = try document.resolvedPolicy(
            for: folder,
            folderIncarnationDigest: firstDigest
        )
        XCTAssertEqual(resolved.automaticallyAllowedNetworks, [.wifi])
        XCTAssertEqual(resolved.cellularAccess, .uploadOnly)
        XCTAssertFalse(resolved.allowExpensive)
        XCTAssertFalse(resolved.allowConstrained)
        XCTAssertEqual(resolved.maxCellularFileBytes, 10)
        XCTAssertEqual(resolved.maxExpensiveRunBytes, 20)
        XCTAssertFalse(resolved.allowBackgroundUpload)
        XCTAssertFalse(resolved.allowBackgroundDownload)
        XCTAssertFalse(resolved.allowBackgroundScan)
    }

    func testConservativePolicyCombinesResolvedFoldersWithoutRelaxingEither() throws {
        let first = try XCTUnwrap(FolderID(rawValue: "a"))
        let second = try XCTUnwrap(FolderID(rawValue: "b"))
        var global = SyncPolicy()
        global.automaticallyAllowedNetworks = [.wifi, .ethernet]
        global.maxExpensiveRunBytes = nil
        global.allowBackgroundUpload = true
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                FolderSyncPolicyOverride(
                    folderID: first,
                    folderIncarnationDigest: firstDigest,
                    policy: SyncPolicyOverride(
                        automaticallyAllowedNetworks: [.wifi],
                        maxExpensiveRunBytes: .limit(90)
                    )
                ),
                FolderSyncPolicyOverride(
                    folderID: second,
                    folderIncarnationDigest: secondDigest,
                    policy: SyncPolicyOverride(
                        automaticallyAllowedNetworks: [.wifi, .ethernet],
                        maxExpensiveRunBytes: .limit(40),
                        allowBackgroundUpload: false
                    )
                ),
            ]
        )

        let merged = try document.conservativePolicy(
            for: [
                .init(folderID: second, folderIncarnationDigest: secondDigest),
                .init(folderID: first, folderIncarnationDigest: firstDigest),
            ]
        )
        XCTAssertEqual(merged.automaticallyAllowedNetworks, [.wifi])
        XCTAssertEqual(merged.maxExpensiveRunBytes, 40)
        XCTAssertFalse(merged.allowBackgroundUpload)
    }

    func testFolderOverrideCannotRelaxAnyGlobalPolicyField() throws {
        let folder = try XCTUnwrap(FolderID(rawValue: "all-global-ceilings"))
        let globalWindow = TimeWindow(weekdays: [2], startMinute: 540, endMinute: 1_020)
        var global = SyncPolicy()
        global.automaticallyAllowedNetworks = [.wifi]
        global.cellularAccess = .denied
        global.allowExpensive = false
        global.allowConstrained = false
        global.maxCellularFileBytes = 10
        global.maxExpensiveRunBytes = 20
        global.dailyExpensiveBytes = 30
        global.requirePowerForAllAutomaticWork = true
        global.requirePowerForLargeTransferBytes = 40
        global.requirePowerForMaintenance = true
        global.minimumBatteryLevel = 0.8
        global.lowPowerBehavior = .pauseAutomatic
        global.pauseTransfersAtThermalLevel = .fair
        global.minimumFreeDiskBytes = 1_000
        global.automaticTimeWindows = [globalWindow]
        global.allowBackgroundUpload = false
        global.allowBackgroundDownload = false
        global.allowBackgroundScan = false
        global.allowTemporaryUserOverride = false
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(
                    folderID: folder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(
                        automaticallyAllowedNetworks: [.wifi, .ethernet, .other],
                        cellularAccess: .allowed,
                        allowExpensive: true,
                        allowConstrained: true,
                        maxCellularFileBytes: .unlimited,
                        maxExpensiveRunBytes: .limit(200),
                        dailyExpensiveBytes: .limit(300),
                        requirePowerForAllAutomaticWork: false,
                        requirePowerForLargeTransferBytes: .unlimited,
                        requirePowerForMaintenance: false,
                        minimumBatteryLevel: 0.1,
                        lowPowerBehavior: .allowed,
                        pauseTransfersAtThermalLevel: .critical,
                        minimumFreeDiskBytes: 100,
                        automaticTimeWindows: [],
                        allowBackgroundUpload: true,
                        allowBackgroundDownload: true,
                        allowBackgroundScan: true,
                        allowTemporaryUserOverride: true
                    )
                )
            ]
        )

        XCTAssertEqual(
            try document.resolvedPolicy(
                for: folder,
                folderIncarnationDigest: firstDigest
            ),
            global
        )
    }

    func testFolderOverrideCanTightenRemainingSafetyFields() throws {
        let folder = try XCTUnwrap(FolderID(rawValue: "remaining-tightening"))
        let folderWindow = TimeWindow(weekdays: [3], startMinute: 600, endMinute: 660)
        var global = SyncPolicy()
        global.requirePowerForAllAutomaticWork = false
        global.requirePowerForLargeTransferBytes = nil
        global.requirePowerForMaintenance = false
        global.minimumBatteryLevel = 0.2
        global.lowPowerBehavior = .allowed
        global.pauseTransfersAtThermalLevel = .critical
        global.minimumFreeDiskBytes = 100
        global.automaticTimeWindows = []
        global.allowTemporaryUserOverride = true
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(
                    folderID: folder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(
                        requirePowerForAllAutomaticWork: true,
                        requirePowerForLargeTransferBytes: .limit(50),
                        requirePowerForMaintenance: true,
                        minimumBatteryLevel: 0.8,
                        lowPowerBehavior: .indexOnly,
                        pauseTransfersAtThermalLevel: .serious,
                        minimumFreeDiskBytes: 1_000,
                        automaticTimeWindows: [folderWindow],
                        allowTemporaryUserOverride: false
                    )
                )
            ]
        )

        let resolved = try document.resolvedPolicy(
            for: folder,
            folderIncarnationDigest: firstDigest
        )
        XCTAssertTrue(resolved.requirePowerForAllAutomaticWork)
        XCTAssertEqual(resolved.requirePowerForLargeTransferBytes, 50)
        XCTAssertTrue(resolved.requirePowerForMaintenance)
        XCTAssertEqual(resolved.minimumBatteryLevel, 0.8)
        XCTAssertEqual(resolved.lowPowerBehavior, .indexOnly)
        XCTAssertEqual(resolved.pauseTransfersAtThermalLevel, .serious)
        XCTAssertEqual(resolved.minimumFreeDiskBytes, 1_000)
        XCTAssertEqual(resolved.automaticTimeWindows, [folderWindow])
        XCTAssertFalse(resolved.allowTemporaryUserOverride)
    }

    func testIncomparableLowPowerOverrideFailsClosed() throws {
        let folder = try XCTUnwrap(FolderID(rawValue: "incomparable-low-power"))
        var global = SyncPolicy()
        global.lowPowerBehavior = .indexOnly
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(
                    folderID: folder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(lowPowerBehavior: .pauseAutomatic)
                )
            ]
        )

        XCTAssertThrowsError(
            try document.resolvedPolicy(
                for: folder,
                folderIncarnationDigest: firstDigest
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .unrepresentableConservativeMerge("lowPowerBehavior")
            )
        }
    }

    func testPersistenceRejectsIncomparableOverrideBeforeChangingDocumentBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try XCTUnwrap(FolderID(rawValue: "atomic-incomparable"))
        var global = SyncPolicy()
        global.lowPowerBehavior = .indexOnly
        let baseline = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global
        )
        let store = SyncPolicyDocumentStore(url: fixture.url)
        try store.save(baseline)
        let baselineBytes = try Data(contentsOf: fixture.url)

        let incompatible = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(
                    folderID: folder,
                    folderIncarnationDigest: firstDigest,
                    policy: .init(lowPowerBehavior: .pauseAutomatic)
                )
            ]
        )
        XCTAssertThrowsError(try store.save(incompatible)) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .unrepresentableConservativeMerge("lowPowerBehavior")
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), baselineBytes)

        XCTAssertThrowsError(
            try store.update { document in
                document.folderOverrides = incompatible.folderOverrides
            }
        ) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .unrepresentableConservativeMerge("lowPowerBehavior")
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), baselineBytes)
        XCTAssertEqual(try store.load(), baseline)
    }

    func testGlobalReplacementRejectsExistingIncomparableOverrideWithoutChangingBytes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try XCTUnwrap(FolderID(rawValue: "atomic-global"))
        var permissiveGlobal = SyncPolicy()
        permissiveGlobal.lowPowerBehavior = .allowed
        let store = SyncPolicyDocumentStore(url: fixture.url)
        try store.save(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                global: permissiveGlobal,
                folderOverrides: [
                    .init(
                        folderID: folder,
                        folderIncarnationDigest: firstDigest,
                        policy: .init(lowPowerBehavior: .pauseAutomatic)
                    )
                ]
            )
        )
        let baselineBytes = try Data(contentsOf: fixture.url)
        var incompatibleGlobal = permissiveGlobal
        incompatibleGlobal.lowPowerBehavior = .indexOnly

        XCTAssertThrowsError(
            try store.saveGlobalPreservingOverrides(incompatibleGlobal)
        ) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .unrepresentableConservativeMerge("lowPowerBehavior")
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), baselineBytes)
        XCTAssertEqual(try store.load().global.lowPowerBehavior, .allowed)
    }

    func testUnknownDuplicateInvalidAndDuplicateFolderDataFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = SyncPolicyDocumentStore(url: fixture.url)
        let valid = SyncPolicyDocumentV2(budgetTimeZoneIdentifier: "UTC")
        try store.save(valid)
        let encoded = try XCTUnwrap(String(data: Data(contentsOf: fixture.url), encoding: .utf8))

        try Data(
            encoded.replacingOccurrences(
                of: "{", with: "{\"unknown\":true,", options: [],
                range: encoded.startIndex..<encoded.index(after: encoded.startIndex)
            ).utf8
        )
        .write(to: fixture.url)
        XCTAssertThrowsError(try store.load()) { error in
            guard case .unknownField = error as? SyncPolicyDocumentError else {
                return XCTFail("Expected unknownField, got \(error)")
            }
        }

        let duplicate = encoded.replacingOccurrences(
            of: "\"schemaVersion\":2",
            with: "\"schemaVersion\":2,\"schemaVersion\":2"
        )
        try Data(duplicate.utf8).write(to: fixture.url)
        XCTAssertThrowsError(try store.load()) { error in
            guard case .duplicateField = error as? SyncPolicyDocumentError else {
                return XCTFail("Expected duplicateField, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try store.save(SyncPolicyDocumentV2(budgetTimeZoneIdentifier: "Not/A-Time-Zone"))
        ) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .invalidBudgetTimeZoneIdentifier("Not/A-Time-Zone")
            )
        }

        let folder = try XCTUnwrap(FolderID(rawValue: "duplicate"))
        let entry = FolderSyncPolicyOverride(
            folderID: folder,
            folderIncarnationDigest: firstDigest
        )
        XCTAssertThrowsError(
            try store.save(
                SyncPolicyDocumentV2(
                    budgetTimeZoneIdentifier: "UTC",
                    folderOverrides: [entry, entry]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .duplicateFolderOverride(folderID: folder.rawValue)
            )
        }
    }

    func testCanonicalSaveSortsFolderOverridesAndIsByteStable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let a = try XCTUnwrap(FolderID(rawValue: "a"))
        let z = try XCTUnwrap(FolderID(rawValue: "z"))
        var global = SyncPolicy()
        global.automaticallyAllowedNetworks = [.other, .wifi, .ethernet]
        global.automaticTimeWindows = [
            .init(weekdays: [7, 1], startMinute: 900, endMinute: 1_000),
            .init(weekdays: [2], startMinute: 10, endMinute: 20),
        ]
        let document = SyncPolicyDocumentV2(
            budgetTimeZoneIdentifier: "UTC",
            global: global,
            folderOverrides: [
                .init(folderID: z, folderIncarnationDigest: secondDigest, queuePriority: .high),
                .init(folderID: a, folderIncarnationDigest: firstDigest, queuePriority: .low),
            ]
        )
        let store = SyncPolicyDocumentStore(url: fixture.url)

        try store.save(document)
        let firstBytes = try Data(contentsOf: fixture.url)
        try store.save(document)
        XCTAssertEqual(try Data(contentsOf: fixture.url), firstBytes)
        XCTAssertEqual(try store.load().folderOverrides.map(\.folderID), [a, z])
        XCTAssertEqual(try store.load().folderOverrides.map(\.queuePriority), [.low, .high])
    }

    func testMissingQueuePriorityDefaultsNormalAndUnknownRawValueFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try XCTUnwrap(FolderID(rawValue: "priority-default"))
        let store = SyncPolicyDocumentStore(url: fixture.url)
        try store.save(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                folderOverrides: [
                    .init(folderID: folder, folderIncarnationDigest: firstDigest)
                ]
            )
        )
        let encoded = try Data(contentsOf: fixture.url)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var overrides = try XCTUnwrap(object["folderOverrides"] as? [[String: Any]])
        overrides[0].removeValue(forKey: "queuePriority")
        object["folderOverrides"] = overrides
        try SecureLockFile.writeAtomically(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            to: fixture.url
        )
        XCTAssertEqual(try store.load().folderOverrides.first?.queuePriority, .normal)

        overrides[0]["queuePriority"] = 99
        object["folderOverrides"] = overrides
        try SecureLockFile.writeAtomically(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            to: fixture.url
        )
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? SyncPolicyDocumentError, .invalidDocument)
        }
    }

    func testConcurrentGlobalFacadeAndDocumentUpdateCannotLoseFolderOverrides() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let folder = try XCTUnwrap(FolderID(rawValue: "atomic-update"))
        let store = SyncPolicyDocumentStore(
            url: fixture.url,
            legacyBudgetTimeZoneIdentifier: "UTC"
        )
        try store.save(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "Europe/Berlin",
                folderOverrides: [
                    .init(
                        folderID: folder,
                        folderIncarnationDigest: firstDigest,
                        queuePriority: .normal,
                        policy: .init(dailyExpensiveBytes: .limit(40))
                    )
                ]
            )
        )
        let failures = ConcurrentFailureCollector()

        DispatchQueue.concurrentPerform(iterations: 25) { index in
            do {
                if index == 24 {
                    try store.update { document in
                        document.folderOverrides[0].queuePriority = .high
                    }
                } else {
                    var global = SyncPolicy()
                    global.minimumFreeDiskBytes = Int64(1_000 + index)
                    global.allowBackgroundDownload = index.isMultiple(of: 2)
                    try store.saveGlobalPreservingOverrides(global)
                }
            } catch {
                failures.record(error)
            }
        }

        XCTAssertTrue(failures.values.isEmpty, "Unexpected update failures: \(failures.values)")
        let final = try store.load()
        XCTAssertEqual(final.budgetTimeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(final.folderOverrides.count, 1)
        XCTAssertEqual(final.folderOverrides[0].folderID, folder)
        XCTAssertEqual(final.folderOverrides[0].folderIncarnationDigest, firstDigest)
        XCTAssertEqual(final.folderOverrides[0].queuePriority, .high)
        XCTAssertEqual(final.folderOverrides[0].policy.dailyExpensiveBytes, .limit(40))
        XCTAssertTrue((1_000..<1_024).contains(final.global.minimumFreeDiskBytes))
    }

    func testTemporaryProfilesRoundTripCanonicallyAndRejectDuplicateNames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = TemporarySyncPolicyProfile(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            name: "Metered",
            maximumNetworkBytes: 32 * 1_024 * 1_024,
            validitySeconds: 600
        )
        let second = TemporarySyncPolicyProfile(
            id: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
            name: "Strict",
            maximumNetworkBytes: 4 * 1_024 * 1_024,
            validitySeconds: 300,
            requestsTemporaryOverride: false
        )
        let store = SyncPolicyDocumentStore(url: fixture.url)

        try store.save(
            SyncPolicyDocumentV2(
                budgetTimeZoneIdentifier: "UTC",
                temporaryProfiles: [second, first]
            )
        )
        XCTAssertEqual(try store.load().temporaryProfiles.map(\.name), ["Metered", "Strict"])
        let stableBytes = try Data(contentsOf: fixture.url)
        try store.save(try store.load())
        XCTAssertEqual(try Data(contentsOf: fixture.url), stableBytes)

        XCTAssertThrowsError(
            try store.save(
                SyncPolicyDocumentV2(
                    budgetTimeZoneIdentifier: "UTC",
                    temporaryProfiles: [
                        first,
                        .init(name: "metered", maximumNetworkBytes: 1, validitySeconds: 60),
                    ]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncPolicyDocumentError,
                .duplicateTemporaryProfileName("metered")
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), stableBytes)

        XCTAssertThrowsError(
            try store.save(
                SyncPolicyDocumentV2(
                    budgetTimeZoneIdentifier: "UTC",
                    temporaryProfiles: [
                        .init(
                            name: "Cafe" + String(UnicodeScalar(0x0301)!),
                            maximumNetworkBytes: 1,
                            validitySeconds: 60
                        )
                    ]
                )
            )
        ) { error in
            XCTAssertEqual(error as? SyncPolicyDocumentError, .invalidPolicy("temporaryProfile"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), stableBytes)
    }
}

private final class ConcurrentFailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ error: any Error) {
        lock.withLock {
            storage.append(String(describing: error))
        }
    }
}

private struct Fixture {
    let root: URL
    let url: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-document-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("sync-policy.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
