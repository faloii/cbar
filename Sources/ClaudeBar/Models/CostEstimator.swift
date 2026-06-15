import Foundation

/// Estimates per-day cost from `stats-cache.json`.
///
/// The daily data (`dailyModelTokens`) only has a single token total per model per
/// day — no input/output/cache split — so exact pricing isn't possible. Instead we
/// derive each model's lifetime blended $/token from `modelUsage` (which *does* have
/// the split) and apply it to the daily totals. It's an estimate; the trend is the point.
enum CostEstimator {
    /// Blended USD-per-token for each model, plus a global fallback for unseen models.
    static func blendedRates(_ modelUsage: [String: TokenCounts]) -> (rates: [String: Double], fallback: Double) {
        var rates: [String: Double] = [:]
        var totalTokens = 0
        var totalCost = 0.0
        for (model, tokens) in modelUsage {
            let cost = Pricing.cost(for: tokens, model: model)
            if tokens.total > 0 { rates[model] = cost / Double(tokens.total) }
            totalTokens += tokens.total
            totalCost += cost
        }
        let fallback = totalTokens > 0 ? totalCost / Double(totalTokens) : 0
        return (rates, fallback)
    }

    /// Estimated cost for one day given its per-model token totals.
    static func dailyCost(tokensByModel: [String: Int], rates: [String: Double], fallback: Double) -> Double {
        tokensByModel.reduce(0) { $0 + Double($1.value) * (rates[$1.key] ?? fallback) }
    }
}
