import Foundation

/// One week's top-tier (Fable·Opus) cost share, for the habit-goal adherence track.
struct WeekShare: Equatable {
    let topTierShare: Double   // 0...1
    let hasUsage: Bool
}

/// This-week vs last-week habit comparison, from per-day per-model costs.
struct WeeklyReview: Equatable {
    /// One day's cost per model (display name) — see `entries(from:)`.
    typealias Entry = (date: Date, costByModel: [String: Double])

    let thisCost: Double
    let lastCost: Double
    let topTierShareThis: Double   // 0...1 of this week's cost from Fable/Opus
    let topTierShareLast: Double
    /// Average cost over the last 4 completed weeks (this week excluded, since
    /// it's still in progress), skipping weeks with zero usage. A single "last
    /// week" can be misleadingly quiet (vacation) or heavy (a crunch) on its
    /// own — this gives a steadier baseline to compare against too. nil when no
    /// past week had any usage.
    let avgPast4WeeksCost: Double?

    /// Week-over-week cost change (%), nil when last week had no spend.
    var costDeltaPct: Double? { lastCost > 0 ? (thisCost - lastCost) / lastCost * 100 : nil }
    /// This week vs the steadier 4-week average — nil when there's nothing to
    /// compare against.
    var costDeltaVsAvgPct: Double? {
        guard let avg = avgPast4WeeksCost, avg > 0 else { return nil }
        return (thisCost - avg) / avg * 100
    }
    /// Change in top-tier cost share, in percentage points.
    var topTierShareDeltaPts: Double { (topTierShareThis - topTierShareLast) * 100 }

    /// One-line coaching, or nil when nothing notable.
    var coaching: String? {
        if topTierShareThis >= 0.6, topTierShareDeltaPts >= 5 {
            return "상위 모델(Fable·Opus) 비중이 늘었어요 — 루틴 작업은 한 단계 낮은 모델로 옮겨보세요."
        }
        if let d = costDeltaPct, d >= 25 {
            return "지난주보다 비용이 늘었어요. 페이스를 점검해 보세요."
        }
        if let d = costDeltaPct, d <= -20 {
            return "지난주보다 절약했어요 👍"
        }
        return nil
    }

    static func entries(from days: [DailyUsage]) -> [Entry] {
        days.compactMap { d in
            DateParse.day(d.date).map { ($0, d.byModel.mapValues(\.cost)) }
        }
    }

    private static func split(_ costByModel: [String: Double]) -> (total: Double, topTier: Double) {
        var total = 0.0, top = 0.0
        for (model, c) in costByModel {
            total += c
            if ModelRecap.isTopTier(model) { top += c }
        }
        return (total, top)
    }

    /// Top-tier cost share for each of the last `weeks` weeks (index 0 = current week).
    static func topTierShares(entries: [Entry], now: Date, weeks: Int,
                              calendar: Calendar = .current) -> [WeekShare] {
        let today = calendar.startOfDay(for: now)
        var totals = Array(repeating: 0.0, count: weeks)
        var tops = Array(repeating: 0.0, count: weeks)
        for (date, costByModel) in entries {
            let day = calendar.startOfDay(for: date)
            guard let daysAgo = calendar.dateComponents([.day], from: day, to: today).day, daysAgo >= 0 else { continue }
            let w = daysAgo / 7
            guard w < weeks else { continue }
            let c = split(costByModel)
            totals[w] += c.total
            tops[w] += c.topTier
        }
        return (0..<weeks).map { w in
            WeekShare(topTierShare: totals[w] > 0 ? tops[w] / totals[w] : 0, hasUsage: totals[w] > 0)
        }
    }

    static func compute(entries: [Entry], now: Date, calendar: Calendar = .current) -> WeeklyReview? {
        let today = calendar.startOfDay(for: now)
        guard let thisStart = calendar.date(byAdding: .day, value: -6, to: today),
              let lastStart = calendar.date(byAdding: .day, value: -13, to: today) else { return nil }

        var thisCost = 0.0, thisTop = 0.0, lastCost = 0.0, lastTop = 0.0
        for (date, costByModel) in entries {
            let day = calendar.startOfDay(for: date)
            let c = split(costByModel)
            if day >= thisStart {
                thisCost += c.total; thisTop += c.topTier
            } else if day >= lastStart && day < thisStart {
                lastCost += c.total; lastTop += c.topTier
            }
        }
        guard thisCost > 0 || lastCost > 0 else { return nil }

        // Past 4 completed weeks (bucket 0 = last week, matching `lastCost`'s
        // window, through bucket 3 = 4 weeks ago), for the steadier baseline.
        var pastWeekCosts = Array(repeating: 0.0, count: 4)
        for (date, costByModel) in entries {
            let day = calendar.startOfDay(for: date)
            guard day < thisStart,
                  let daysAgo = calendar.dateComponents([.day], from: day, to: thisStart).day,
                  daysAgo >= 1 else { continue }
            let w = (daysAgo - 1) / 7
            guard w < 4 else { continue }
            pastWeekCosts[w] += split(costByModel).total
        }
        let nonZeroPastWeeks = pastWeekCosts.filter { $0 > 0 }
        let avgPast4 = nonZeroPastWeeks.isEmpty ? nil : nonZeroPastWeeks.reduce(0, +) / Double(nonZeroPastWeeks.count)

        return WeeklyReview(
            thisCost: thisCost, lastCost: lastCost,
            topTierShareThis: thisCost > 0 ? thisTop / thisCost : 0,
            topTierShareLast: lastCost > 0 ? lastTop / lastCost : 0,
            avgPast4WeeksCost: avgPast4)
    }
}
