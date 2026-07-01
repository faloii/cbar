import Foundation

/// Turns the abstract weekly utilization % into a concrete daily allowance — "how much
/// can I safely use *today*?" — so a fast start to the week doesn't quietly burn through
/// days of headroom before a trajectory alert catches up. Complements `Projection`
/// (which answers "will I block before reset") with the more actionable daily framing.
enum DailyAllowance {
    struct Verdict: Equatable {
        let daysRemaining: Double        // fractional days until the weekly reset
        let recommendedPctPerDay: Double // even pace to land at ~100% right at reset
        let usedTodayPct: Double?        // %P used since local midnight; nil if unknown
    }

    /// `todayStartUtil` is the weekly utilization at local midnight (from usage-sample
    /// history), or nil when there's no sample from before today (app just started,
    /// or it's the first day of tracking) — `usedTodayPct` degrades to nil in that case.
    static func verdict(util: Double, resetsAt: Date?, now: Date, todayStartUtil: Double?) -> Verdict? {
        guard let reset = resetsAt else { return nil }
        let secondsToReset = reset.timeIntervalSince(now)
        guard secondsToReset > 0, util < 100 else { return nil }
        // Floor at ~1h so the recommended rate doesn't blow up to an absurd number
        // in the last minutes before reset.
        let daysRemaining = max(secondsToReset / 86400, 1.0 / 24)
        let recommended = max(0, 100 - util) / daysRemaining
        let usedToday = todayStartUtil.map { max(0, util - $0) }
        return Verdict(daysRemaining: daysRemaining, recommendedPctPerDay: recommended, usedTodayPct: usedToday)
    }
}
