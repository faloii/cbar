import Foundation

/// Detects "you're burning unusually fast TODAY, for you" — a personal baseline
/// instead of a fixed threshold, since a heavy user's normal day would trip any
/// fixed % and a light user's normal day never would. Extrapolates today's pace
/// (cost so far ÷ hours elapsed since midnight × 24) and compares it to the
/// median of past days — explicitly framed as "if this pace continues," not a
/// prediction, so it stays honest about what it can't know (what you'll actually
/// do for the rest of the day).
enum BurnAnomaly {
    struct Verdict: Equatable {
        let multiplier: Double        // projectedToday ÷ typicalDailyCost
        let typicalDailyCost: Double  // median of past days with real usage
        let projectedToday: Double    // today's cost linearly extrapolated to a full day
    }

    static let minMultiplier = 2.0       // only worth a nudge at 2x+ a normal day
    static let minHoursElapsed = 1.0     // <1h of data is too noisy to extrapolate
    static let minTypicalCost = 0.5      // near-zero history makes any usage look "∞x"
    static let minHistoryDays = 3        // need a few real days to call anything "typical"

    static func verdict(todayCost: Double, hoursElapsedToday: Double, pastDailyCosts: [Double]) -> Verdict? {
        guard todayCost > 0, hoursElapsedToday >= minHoursElapsed else { return nil }
        let usable = pastDailyCosts.filter { $0 > 0.01 }.sorted()
        guard usable.count >= minHistoryDays else { return nil }
        let median = usable[usable.count / 2]
        guard median >= minTypicalCost else { return nil }
        let projected = todayCost / hoursElapsedToday * 24
        let multiplier = projected / median
        guard multiplier >= minMultiplier else { return nil }
        return Verdict(multiplier: multiplier, typicalDailyCost: median, projectedToday: projected)
    }
}
