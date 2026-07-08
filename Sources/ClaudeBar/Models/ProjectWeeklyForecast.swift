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
    /// The tokens→%P conversion factor is derived empirically from the live
    /// numbers (total tokens across all projects ÷ weekly %) rather than a
    /// hardcoded/unknown token cap, so it stays correct across plans.
    static func forecast(projects: [ProjectWeeklyUsage], weeklyUtilPct: Double,
                         daysRemaining: Double) -> [Item] {
        guard weeklyUtilPct > 0, daysRemaining > 0 else { return [] }
        let totalTokens = projects.reduce(0) { $0 + $1.tokens }
        guard totalTokens > 0 else { return [] }
        let tokensPerPercent = Double(totalTokens) / weeklyUtilPct
        return projects.map { p in
            let usedPct = Double(p.tokens) / tokensPerPercent
            let dailyRate = Double(p.tokens) / 7.0   // p.tokens is already a trailing-7-day total
            let additional = (dailyRate * daysRemaining) / tokensPerPercent
            return Item(project: p.project, usedPct: usedPct, projectedAdditionalPct: additional)
        }
        .sorted { ($0.usedPct + $0.projectedAdditionalPct) > ($1.usedPct + $1.projectedAdditionalPct) }
    }
}
