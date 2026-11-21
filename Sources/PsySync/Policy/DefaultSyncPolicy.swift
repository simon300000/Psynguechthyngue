import Foundation

/// The production policy (DESIGN.md §4.4). Priority order:
///
/// 1. no network → hold `.noNetwork`
/// 2. cellular and cellular sync disabled → hold `.cellularDisallowed`
/// 3. Low Data Mode and "respect Low Data Mode" → hold `.lowDataMode`
/// 4. Low Power Mode and "pause in Low Power Mode" → hold `.lowPowerMode`
/// 5. thermal serious/critical → hold `.thermal`
/// 6. cellular → run with the cellular rate limits
/// 7. otherwise → run, unlimited
///
/// Battery percentage and charging state are deliberately **not** inputs to
/// the decision (fixes AUDIT P2). While held, limits are 0 (irrelevant: all
/// devices are paused).
public struct DefaultSyncPolicy: SyncPolicy {
    public init() {}

    public func decide(inputs: PolicyInputs, preferences: PolicyPreferences) -> PolicyDecision {
        if inputs.network == .none {
            return PolicyDecision(hold: .noNetwork)
        }
        let cellular = inputs.network == .cellular
        if cellular && !preferences.syncOnCellular {
            return PolicyDecision(hold: .cellularDisallowed)
        }
        if inputs.isConstrained && preferences.respectLowDataMode {
            return PolicyDecision(hold: .lowDataMode)
        }
        if inputs.isLowPowerMode && preferences.pauseInLowPowerMode {
            return PolicyDecision(hold: .lowPowerMode)
        }
        if inputs.thermalSerious {
            return PolicyDecision(hold: .thermal)
        }
        if cellular {
            return PolicyDecision(
                hold: nil,
                sendLimitKiBps: max(0, preferences.cellularSendLimitKiBps),
                receiveLimitKiBps: max(0, preferences.cellularReceiveLimitKiBps)
            )
        }
        return .run
    }
}
