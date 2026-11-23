import Foundation

/// Projects each project's own trailing-7-day pace forward to the weekly reset,
/// expressed as a share of the weekly LIMIT — not just relative to other
/// projects (which `weeklyProjectUsage` already shows), but "how many points of
/// my weekly % would this project alone add by reset, at the pace it's been
/// running." Honest about being an extrapolation: labelled "이 페이스면", built
/// from the same trailing-7-day data as the existing per-project view, not a
/// promise about what will actually happen.
enum ProjectWeeklyForecast {
    struct Item: Equatable, Identifiable {
        var id: String { project }
        let project: String
        let usedPct: Double                 // %P of the weekly limit already used, by this project
        let projectedAdditionalPct: Double  // %P this project would add by reset, at its trailing pace
    }

    /// `weeklyUtilPct`: current weekly utilization (0...100) from the live limits.
    /// `daysRemaining`: days until the weekly reset (see `DailyAllowance`).
    /// The $→%P factor is derived empirically from the live numbers (cost inside
    /// the weekly window ÷ weekly %) rather than an unknown cap, so it stays correct
    /// across plans. Cost, not tokens: utilization tracks list-price cost far
    /// better than raw tokens (see `Pricing.defaults`) — a cache-heavy project
    /// isn't eating the limit in proportion to its token count.
    static func forecast(projects: [ProjectWeeklyUsage], weeklyUtilPct: Double,
                         daysRemaining: Double) -> [Item] {
        guard weeklyUtilPct > 0, daysRemaining > 0 else { return [] }
        let inWindow = projects.map { $0.limitWindowCost ?? $0.cost }
        let windowCost = inWindow.reduce(0, +)
        guard windowCost > 0 else { return [] }
        let costPerPercent = windowCost / weeklyUtilPct
        return zip(projects, inWindow).map { p, used in
            let dailyRate = p.cost / 7.0   // p.cost is a trailing-7-day total
            let additional = (dailyRate * daysRemaining) / costPerPercent
            return Item(project: p.project, usedPct: used / costPerPercent, projectedAdditionalPct: additional)
        }
        .sorted { ($0.usedPct + $0.projectedAdditionalPct) > ($1.usedPct + $1.projectedAdditionalPct) }
    }
}
