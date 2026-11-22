import Foundation
import Observation
import PsySync

/// User preferences. Changes take effect immediately (no Save button).
/// Backed by UserDefaults; the policy preferences are forwarded to the host.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "psy.onboardingDone") } }
    var syncOnCellular: Bool { didSet { defaults.set(syncOnCellular, forKey: "psy.syncOnCellular"); changed() } }
    var respectLowDataMode: Bool { didSet { defaults.set(respectLowDataMode, forKey: "psy.respectLowData"); changed() } }
    var pauseInLowPowerMode: Bool { didSet { defaults.set(pauseInLowPowerMode, forKey: "psy.pauseLowPower"); changed() } }
    var pauseWhenHot: Bool { didSet { defaults.set(pauseWhenHot, forKey: "psy.pauseWhenHot"); changed() } }
    var cellularSendLimit: Int { didSet { defaults.set(cellularSendLimit, forKey: "psy.cellularSend"); changed() } }
    var cellularReceiveLimit: Int { didSet { defaults.set(cellularReceiveLimit, forKey: "psy.cellularRecv"); changed() } }
    var backgroundSync: Bool { didSet { defaults.set(backgroundSync, forKey: BackgroundScheduler.enabledKey); changed() } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "psy.notifications") } }
    /// Submit the continued-processing request automatically when transfers
    /// start (the user's explicit consent; see AppModel.autoContinueIfNeeded).
    var autoContinueInBackground: Bool { didSet { defaults.set(autoContinueInBackground, forKey: Self.autoContinueKey) } }
    static let autoContinueKey = "psy.autoContinueInBackground"

    var lastBackgroundRun: Date? { defaults.object(forKey: BackgroundScheduler.lastRunKey) as? Date }

    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` also accepts "YES"/"NO" strings from launch arguments.
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
        onboardingDone = bool("psy.onboardingDone", false)
        syncOnCellular = bool("psy.syncOnCellular", true)
        respectLowDataMode = bool("psy.respectLowData", true)
        pauseInLowPowerMode = bool("psy.pauseLowPower", false)
        pauseWhenHot = bool("psy.pauseWhenHot", true)
        cellularSendLimit = defaults.integer(forKey: "psy.cellularSend")
        cellularReceiveLimit = defaults.integer(forKey: "psy.cellularRecv")
        backgroundSync = bool(BackgroundScheduler.enabledKey, true)
        notificationsEnabled = bool("psy.notifications", false)
        autoContinueInBackground = bool(Self.autoContinueKey, true)
    }

    var policyPreferences: PolicyPreferences {
        var p = PolicyPreferences()
        p.syncOnCellular = syncOnCellular
        p.respectLowDataMode = respectLowDataMode
        p.pauseInLowPowerMode = pauseInLowPowerMode
        p.pauseWhenHot = pauseWhenHot
        p.cellularSendLimitKiBps = cellularSendLimit
        p.cellularReceiveLimitKiBps = cellularReceiveLimit
        return p
    }

    private func changed() { onChange?() }
}
