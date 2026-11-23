import Foundation

/// Turns of each model the remaining WEEKLY limit covers, under the plan's per-model
/// weekly caps (Fable on Max/Ultra: up to 50% of the weekly limit).
///
/// One blended "$ per 1%" over the weekly window misprices a capped model: the plan
/// reports that model's own draw (`usedPctOfWeekly`), and it doesn't follow its
/// list-price share of the window. So when the plan reports enough to split on, a
/// capped model is priced from its own reported use and every other model from
/// what's left of the weekly % — and a capped model only counts what's left of its
/// cap, since it stops there even with weekly to spare.
enum WeeklyModelTurns {
    struct Row: Equatable {
        let model: String
        let turns: Int
        let capped: Bool   // its own cap, not the weekly limit, is what runs out first
    }

    /// Reported % below this is mostly integer rounding — don't split on it.
    static let minSplitPct = 2.0

    static func compute(window: [ModelWindowUsage], weeklyUtil: Double, scoped: [ScopedWeeklyLimit],
                        limit: Int = 2, minRequests: Int = 3) -> [Row] {
        let left = 100 - weeklyUtil
        let totalCost = window.reduce(0) { $0 + $1.cost }
        guard left > 0, weeklyUtil > 0, totalCost > 0 else { return [] }

        // $ per 1% of weekly: per cap from its reported use, then the rest.
        var capRate: [String: Double] = [:]
        var cappedCost = 0.0, cappedPct = 0.0
        for s in scoped {
            guard let used = s.usedPctOfWeekly, used >= minSplitPct else { continue }
            let cost = window.filter { s.covers($0.model) }.reduce(0) { $0 + $1.cost }
            guard cost > 0 else { continue }
            capRate[s.model] = cost / used
            cappedCost += cost
            cappedPct += used
        }
        let restPct = weeklyUtil - cappedPct
        let restRate = restPct >= minSplitPct && totalCost - cappedCost > 0
            ? (totalCost - cappedCost) / restPct
            : totalCost / weeklyUtil

        return window
            .filter { $0.requests >= minRequests && $0.cost > 0 }
            .sorted { $0.cost > $1.cost }
            .prefix(limit)
            .map { m in
                let cap = scoped.first { $0.covers(m.model) }
                let rate = cap.flatMap { capRate[$0.model] } ?? restRate
                let pctPerTurn = m.cost / Double(m.requests) / rate
                let capLeft = cap?.remainingPctOfWeekly(weeklyUtil: weeklyUtil)
                let usable = min(left, capLeft ?? left)
                return Row(model: m.model, turns: Int((usable / pctPerTurn).rounded(.down)),
                           capped: capLeft.map { $0 < left } ?? false)
            }
    }
}
