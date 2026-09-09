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
        /// Same recommendation, but spread only over the remaining Mon–Fri days —
        /// a calendar-day pace looks falsely safe on a Friday even though the
        /// whole weekend it's counting usually isn't spent, which is exactly how
        /// "안전한 줄 알았는데 주 후반에 부족해지는" happens. nil when there's no
        /// weekend left in the window (same number as `recommendedPctPerDay`,
        /// not worth a second line) or no workday time left before reset.
        let recommendedPctPerWorkday: Double?
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
    static func verdict(util: Double, resetsAt: Date?, now: Date, todayStartUtil: Double?,
                        calendar: Calendar = .current) -> Verdict? {
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

        let workdays = remainingWorkdays(now: now, resetsAt: reset, calendar: calendar)
        var recommendedPerWorkday: Double?
        if workdays >= 0.2 {
            let perWorkday = max(0, 100 - util) / workdays
            // Only worth a second line when it actually diverges from the
            // calendar-day number — i.e. a weekend sits in the remaining window.
            if abs(perWorkday - recommended) / max(recommended, 1) >= 0.15 {
                recommendedPerWorkday = perWorkday
            }
        }
        return Verdict(daysRemaining: daysRemaining, recommendedPctPerDay: recommended,
                       usedTodayPct: usedToday, recommendedPctPerWorkday: recommendedPerWorkday)
    }

    /// Like `daysRemaining`, but counts only Mon–Fri, fractionally at both ends —
    /// walks the window day by day, weighting the first (partial) day by time
    /// remaining in it and the last (partial) day by time elapsed before reset,
    /// and skipping Saturday/Sunday entirely.
    static func remainingWorkdays(now: Date, resetsAt: Date, calendar: Calendar = .current) -> Double {
        guard resetsAt > now else { return 0 }
        var total = 0.0
        var dayStart = calendar.startOfDay(for: now)
        while dayStart < resetsAt {
            guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let weekday = calendar.component(.weekday, from: dayStart)   // 1 = Sunday, 7 = Saturday
            if weekday != 1, weekday != 7 {
                let segStart = max(dayStart, now)
                let segEnd = min(nextDayStart, resetsAt)
                total += max(0, segEnd.timeIntervalSince(segStart)) / 86400
            }
            dayStart = nextDayStart
        }
        return total
    }
}
