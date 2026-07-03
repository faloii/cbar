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

    /// Longest gap between the last pre-midnight sample and midnight for which
    /// that sample still credibly describes "utilization at midnight" (samples
    /// arrive every ~12min while the app runs; a bigger gap means the Mac was
    /// off/asleep all evening and the true midnight value is unknown).
    static let baselineMaxAge: TimeInterval = 6 * 3600

    /// The weekly utilization at local midnight, from the coarse long-retention
    /// history (`WeeklyHistory`, ~8 days): the last sample before midnight, if
    /// recent enough to trust. `points` must be sorted ascending by time.
    static func todayBaseline(points: [(at: Date, util: Double)], midnight: Date) -> Double? {
        guard let last = points.last(where: { $0.at < midnight }) else { return nil }
        return midnight.timeIntervalSince(last.at) <= baselineMaxAge ? last.util : nil
    }

    /// `todayStartUtil` is the weekly utilization at local midnight (see
    /// `todayBaseline`), or nil when there's no trustworthy pre-midnight sample
    /// (app just started, or the Mac was off) — `usedTodayPct` degrades to nil then.
    static func verdict(util: Double, resetsAt: Date?, now: Date, todayStartUtil: Double?) -> Verdict? {
        guard let reset = resetsAt else { return nil }
        let secondsToReset = reset.timeIntervalSince(now)
        guard secondsToReset > 0, util < 100 else { return nil }
        // Floor at ~1h so the recommended rate doesn't blow up to an absurd number
        // in the last minutes before reset.
        let daysRemaining = max(secondsToReset / 86400, 1.0 / 24)
        let recommended = max(0, 100 - util) / daysRemaining
        // A baseline ABOVE the current reading means the week reset overnight —
        // everything on the meter now accrued today (≈), not "0% used today".
        let usedToday = todayStartUtil.map { $0 > util ? util : util - $0 }
        return Verdict(daysRemaining: daysRemaining, recommendedPctPerDay: recommended, usedTodayPct: usedToday)
    }
}
