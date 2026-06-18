import Foundation

/// This-week vs last-week habit comparison, from per-day per-model token totals.
struct WeeklyReview: Equatable {
    let thisCost: Double
    let lastCost: Double
    let opusShareThis: Double   // 0...1 of this week's cost from Opus
    let opusShareLast: Double

    /// Week-over-week cost change (%), nil when last week had no spend.
    var costDeltaPct: Double? { lastCost > 0 ? (thisCost - lastCost) / lastCost * 100 : nil }
    /// Change in Opus cost share, in percentage points.
    var opusShareDeltaPts: Double { (opusShareThis - opusShareLast) * 100 }

    /// One-line coaching, or nil when nothing notable.
    var coaching: String? {
        if opusShareThis >= 0.6, opusShareDeltaPts >= 5 {
            return "Opus 비중이 늘었어요 — 루틴 작업은 더 가벼운 모델로 옮겨보세요."
        }
        if let d = costDeltaPct, d >= 25 {
            return "지난주보다 비용이 늘었어요. 페이스를 점검해 보세요."
        }
        if let d = costDeltaPct, d <= -20 {
            return "지난주보다 절약했어요 👍"
        }
        return nil
    }

    static func compute(entries: [(date: Date, byModel: [String: Int])],
                        rates: [String: Double], fallback: Double,
                        now: Date, calendar: Calendar = .current) -> WeeklyReview? {
        let today = calendar.startOfDay(for: now)
        guard let thisStart = calendar.date(byAdding: .day, value: -6, to: today),
              let lastStart = calendar.date(byAdding: .day, value: -13, to: today) else { return nil }

        func cost(_ byModel: [String: Int]) -> (total: Double, opus: Double) {
            var total = 0.0, opus = 0.0
            for (model, tokens) in byModel {
                let c = Double(tokens) * (rates[model] ?? fallback)
                total += c
                if model.lowercased().contains("opus") { opus += c }
            }
            return (total, opus)
        }

        var thisCost = 0.0, thisOpus = 0.0, lastCost = 0.0, lastOpus = 0.0
        for (date, byModel) in entries {
            let day = calendar.startOfDay(for: date)
            let c = cost(byModel)
            if day >= thisStart {
                thisCost += c.total; thisOpus += c.opus
            } else if day >= lastStart && day < thisStart {
                lastCost += c.total; lastOpus += c.opus
            }
        }
        guard thisCost > 0 || lastCost > 0 else { return nil }
        return WeeklyReview(
            thisCost: thisCost, lastCost: lastCost,
            opusShareThis: thisCost > 0 ? thisOpus / thisCost : 0,
            opusShareLast: lastCost > 0 ? lastOpus / lastCost : 0)
    }
}
