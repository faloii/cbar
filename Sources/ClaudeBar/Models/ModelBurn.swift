import Foundation

/// What "burn" is measured in for the per-model comparison.
enum BurnBasis: String, CaseIterable, Identifiable {
    case totalTokens   // includes cache reads — context size, not limit pressure
    case freshTokens   // input+output+cacheWrite — "new work" volume
    case cost          // list-price USD — best measured proxy for limit pressure

    var id: String { rawValue }

    var label: String {
        switch self {
        case .totalTokens: return "총 토큰 (캐시 읽기 포함)"
        case .freshTokens: return "신규 토큰 (캐시 제외)"
        case .cost:        return "비용 가중 (한도)"
        }
    }

    var shortLabel: String {
        switch self {
        case .totalTokens: return "총 토큰"
        case .freshTokens: return "신규 토큰"
        case .cost:        return "비용"
        }
    }

    /// The model's contribution to the chosen basis.
    func weight(_ m: ModelWindowUsage) -> Double {
        switch self {
        case .totalTokens: return Double(m.tokens.total)
        case .freshTokens: return Double(m.tokens.fresh)
        case .cost:        return m.cost
        }
    }

    /// Format a per-turn weight value for display ("3.1k/turn" or "$0.42/turn").
    func formatPerTurn(_ v: Double) -> String {
        switch self {
        case .cost: return Fmt.usd(v) + "/턴"
        default:    return Fmt.tokens(Int(v.rounded())) + "/턴"
        }
    }
}

/// One model's row in the per-model burn comparison.
struct ModelBurnRow: Identifiable {
    var id: String { model }
    let model: String
    let tokens: Int               // total tokens (for reference)
    let cost: Double
    let requests: Int
    let shareFraction: Double     // 0...1 of the window's total weight (basis-dependent)
    let perTurnWeight: Double     // avg basis-weight per turn (the "burn weight")
    let burnMultiplier: Double    // per-turn weight relative to the lightest model
    /// What % of the session limit ONE turn of this model consumes — always limit
    /// (total-token) based, nil when session utilization is unknown. Higher = greedier.
    /// Answers "how much does one use of this model cost me?" without the confusing
    /// counterfactual of "turns left if only this model".
    let limitSharePerTurn: Double?
}

/// Compares how fast each model depletes the chosen basis (limit tokens / fresh tokens /
/// cost). The session limit isn't reported per-model, so headroom estimates the remaining
/// budget from the local window total and live session utilization. The *comparison*
/// between models is the point, not the absolute numbers.
enum ModelBurn {
    static func rows(window: [ModelWindowUsage], sessionUtil: Double?, basis: BurnBasis) -> [ModelBurnRow] {
        guard !window.isEmpty else { return [] }

        let totalWeight = max(1e-9, window.map { basis.weight($0) }.reduce(0, +))
        let perTurnWeights = window.compactMap { $0.requests > 0 ? basis.weight($0) / Double($0.requests) : nil }
        let lightest = perTurnWeights.filter { $0 > 0 }.min() ?? 1

        // "Limit share per turn" is always cost-weighted, independent of the display
        // basis: list-price cost tracks plan utilization far better than raw tokens
        // (see `Pricing.defaults`) — a token of Fable output and a cache-read token
        // of Haiku draw very different amounts of limit. `util%` corresponds to the
        // window's total cost, so one turn maps to `costPerTurn * util / totalCost`.
        let totalCost = window.map(\.cost).reduce(0, +)
        let util = (sessionUtil.map { $0 > 1 } ?? false) && totalCost > 0 ? sessionUtil : nil

        return window.map { m -> ModelBurnRow in
            let perTurn = m.requests > 0 ? basis.weight(m) / Double(m.requests) : 0
            let costPerTurn = m.requests > 0 ? m.cost / Double(m.requests) : 0
            let share: Double? = (util != nil && costPerTurn > 0)
                ? costPerTurn * util! / totalCost : nil
            return ModelBurnRow(
                model: m.model,
                tokens: m.tokens.total,
                cost: m.cost,
                requests: m.requests,
                shareFraction: basis.weight(m) / totalWeight,
                perTurnWeight: perTurn,
                burnMultiplier: (lightest > 0 && perTurn > 0) ? perTurn / lightest : 1,
                limitSharePerTurn: share
            )
        }
        .sorted { $0.shareFraction > $1.shareFraction }
    }

    /// Turns of each model the remaining session limit would cover, for the top
    /// `limit` models with enough turns (≥ `minRequests`) to have a stable per-turn
    /// cost. Each figure is "if every remaining turn were this model" — a scale
    /// for comparing models, not a forecast of the actual mix.
    static func turnsLeft(rows: [ModelBurnRow], sessionUtil: Double,
                          limit: Int = 2, minRequests: Int = 3) -> [(model: String, turns: Int)] {
        let left = 100 - sessionUtil
        guard left > 0 else { return [] }
        return rows
            .filter { $0.requests >= minRequests && ($0.limitSharePerTurn ?? 0) > 0 }
            .sorted { $0.cost > $1.cost }
            .prefix(limit)
            .map { ($0.model, Int((left / $0.limitSharePerTurn!).rounded(.down))) }
    }
}
