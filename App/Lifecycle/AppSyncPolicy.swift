import Foundation
import PsySync

/// Policy table from DESIGN.md §4.4. Pure and deterministic.
/// (WP-B ships `DefaultSyncPolicy` with the same table; the app can switch to it
/// once merged — see Docs/REWRITE/notes/wp-d-project.md.)
struct AppSyncPolicy: SyncPolicy {
    func decide(inputs: PolicyInputs, preferences: PolicyPreferences) -> PolicyDecision {
        if inputs.network == .none { return PolicyDecision(hold: .noNetwork) }
        let onCellular = inputs.network == .cellular
        if onCellular && !preferences.syncOnCellular { return PolicyDecision(hold: .cellularDisallowed) }
        if inputs.isConstrained && preferences.respectLowDataMode { return PolicyDecision(hold: .lowDataMode) }
        if inputs.isLowPowerMode && preferences.pauseInLowPowerMode { return PolicyDecision(hold: .lowPowerMode) }
        if inputs.thermalSerious { return PolicyDecision(hold: .thermal) }
        if onCellular {
            return PolicyDecision(
                hold: nil,
                sendLimitKiBps: max(0, preferences.cellularSendLimitKiBps),
                receiveLimitKiBps: max(0, preferences.cellularReceiveLimitKiBps)
            )
        }
        return .run
    }
}
