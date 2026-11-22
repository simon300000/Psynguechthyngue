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
/// 8. on top of 6/7: system prefers reduced resource usage (iOS 27) → reduced
///    load: limits capped at `reducedSendLimitKiBps` / `reducedReceiveLimitKiBps`
///    (a stricter user limit wins), one folder at a time, limits also on LAN.
///    Never a hold: the system asks for less, not for nothing.
///
/// Battery percentage and charging state are deliberately **not** inputs to
/// the decision (fixes AUDIT P2). While held, limits are 0 (irrelevant: all
/// devices are paused).
public struct DefaultSyncPolicy: SyncPolicy {
    /// Reduced-load caps (KiB/s). Upload is capped harder than download:
    /// radio transmit power dominates on mobile.
    public static let reducedSendLimitKiBps = 1024
    public static let reducedReceiveLimitKiBps = 4096

    public init() {}

    /// Combines a limit (0 = unlimited) with a cap: the stricter one wins.
    static func capped(_ limit: Int, at cap: Int) -> Int {
        let limit = max(0, limit)
        return limit == 0 ? cap : min(limit, cap)
    }

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
        if inputs.thermalSerious && preferences.pauseWhenHot {
            return PolicyDecision(hold: .thermal)
        }
        var decision = PolicyDecision.run
        if cellular {
            decision = PolicyDecision(
                hold: nil,
                sendLimitKiBps: max(0, preferences.cellularSendLimitKiBps),
                receiveLimitKiBps: max(0, preferences.cellularReceiveLimitKiBps)
            )
        }
        if inputs.systemPrefersReducedResourceUsage {
            decision.sendLimitKiBps = Self.capped(decision.sendLimitKiBps, at: Self.reducedSendLimitKiBps)
            decision.receiveLimitKiBps = Self.capped(decision.receiveLimitKiBps, at: Self.reducedReceiveLimitKiBps)
            decision.reducedResourceUsage = true
        }
        return decision
    }
}
