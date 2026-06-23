import Foundation

/// What "burn" is measured in for the per-model comparison.
enum BurnBasis: String, CaseIterable, Identifiable {
    case totalTokens   // includes cache reads — proxy for rate-limit pressure
    case freshTokens   // input+output+cacheWrite — "new work" volume
    case cost          // estimated USD — money burn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .totalTokens: return "총 토큰 (한도)"
        case .freshTokens: return "신규 토큰 (캐시 제외)"
        case .cost:        return "비용"
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

        // "Limit share per turn" is always limit-based (total tokens), independent of
        // the display basis: what fraction of the session limit one turn of this model
        // eats. `util%` corresponds to `totalTokensSum`, so one turn's tokens map to
        // `tokensPerTurn * util / totalTokensSum` percent of the full limit.
        let totalTokensSum = max(1, window.map { $0.tokens.total }.reduce(0, +))
        let util = (sessionUtil.map { $0 > 1 } ?? false) ? sessionUtil : nil

        return window.map { m -> ModelBurnRow in
            let perTurn = m.requests > 0 ? basis.weight(m) / Double(m.requests) : 0
            let tokensPerTurn = m.requests > 0 ? Double(m.tokens.total) / Double(m.requests) : 0
            let share: Double? = (util != nil && tokensPerTurn > 0)
                ? tokensPerTurn * util! / Double(totalTokensSum) : nil
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
}
