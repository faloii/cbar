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
        // Whether `typicalDailyCost` came from the same weekday specifically (e.g.
        // "평소 화요일" ) rather than an all-days average — a personal routine
        // (Mondays are always heavy) makes the all-days figure a poor baseline for
        // Monday specifically, so callers should word the comparison accordingly.
        var isWeekdaySpecific: Bool = false
    }

    static let minMultiplier = 2.0       // only worth a nudge at 2x+ a normal day
    // Extrapolating "today so far" to a full day right after midnight turned a
    // late-night session into a nightly "10배" false alarm (2h of night work ×12).
    static let minHoursElapsed = 6.0
    static let minTypicalCost = 0.5      // near-zero history makes any usage look "∞x"
    static let minHistoryDays = 3        // need a few real days to call anything "typical"
    static let minWeekdaySamples = 3     // need a few of the SAME weekday to trust that baseline

    static func verdict(todayCost: Double, hoursElapsedToday: Double, pastDailyCosts: [Double],
                        isWeekdaySpecific: Bool = false) -> Verdict? {
        guard todayCost > 0, hoursElapsedToday >= minHoursElapsed else { return nil }
        let usable = pastDailyCosts.filter { $0 > 0.01 }.sorted()
        guard usable.count >= minHistoryDays else { return nil }
        let mid = usable.count / 2
        let median = usable.count.isMultiple(of: 2) ? (usable[mid - 1] + usable[mid]) / 2 : usable[mid]
        guard median >= minTypicalCost else { return nil }
        let projected = todayCost / hoursElapsedToday * 24
        let multiplier = projected / median
        guard multiplier >= minMultiplier else { return nil }
        return Verdict(multiplier: multiplier, typicalDailyCost: median, projectedToday: projected,
                       isWeekdaySpecific: isWeekdaySpecific)
    }

    /// Picks which historical costs to compare today against: costs from the SAME
    /// weekday when there are enough of them to trust (`minWeekdaySamples`), since a
    /// personal routine (e.g. "Mondays are always a heavy catch-up day") makes an
    /// all-days average a misleading baseline for that one day — every Monday would
    /// look anomalous against a baseline dominated by lighter Tue-Fri days. Falls
    /// back to all recent days when there isn't enough same-weekday history yet.
    static func personalBaseline(dailyCosts: [(date: Date, cost: Double)], today: Date,
                                 calendar: Calendar = .current) -> (costs: [Double], isWeekdaySpecific: Bool) {
        let todayWeekday = calendar.component(.weekday, from: today)
        // Count only days `verdict` will actually use (> $0.01) — counting near-zero
        // days here picked the weekday baseline, then `verdict` dropped them and had
        // too few left, silently disabling detection for that weekday entirely.
        let sameWeekday = dailyCosts.filter {
            $0.cost > 0.01 && calendar.component(.weekday, from: $0.date) == todayWeekday
        }
        if sameWeekday.count >= minWeekdaySamples {
            return (sameWeekday.map(\.cost), true)
        }
        return (dailyCosts.map(\.cost), false)
    }
}
