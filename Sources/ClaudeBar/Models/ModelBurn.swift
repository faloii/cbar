import Foundation

/// One model's row in the per-model burn comparison.
struct ModelBurnRow: Identifiable {
    var id: String { model }
    let model: String
    let tokens: Int
    let cost: Double
    let requests: Int
    let shareFraction: Double      // 0...1 of the window's total tokens
    let tokensPerRequest: Double   // avg tokens per turn (the "burn weight")
    let burnMultiplier: Double     // tokens/turn relative to the lightest model
    /// Estimated turns left *if you used only this model* — nil when the session
    /// utilization isn't known. Lower = depletes the limit faster.
    let headroomTurns: Double?
}

/// Compares how fast each model depletes the session limit, on a total-token basis.
///
/// The session limit isn't reported per-model, so the remaining budget is estimated
/// from the local window total and the live session utilization, then divided by each
/// model's average tokens-per-turn. It's an approximation — the *comparison* between
/// models is the point, not the absolute turn counts.
enum ModelBurn {
    static func rows(window: [ModelWindowUsage], totalWindowTokens: Int, sessionUtil: Double?) -> [ModelBurnRow] {
        guard !window.isEmpty else { return [] }
        let total = max(1, totalWindowTokens)

        // Lightest = smallest tokens/turn among models that actually ran.
        let perReq = window.compactMap { $0.requests > 0 ? Double($0.tokens.total) / Double($0.requests) : nil }
        let lightest = perReq.min() ?? 1

        // Estimate remaining session budget in tokens from the live utilization.
        var remaining: Double?
        if let u = sessionUtil, u > 1 { remaining = Double(total) * (100.0 / u - 1.0) }

        return window.map { m -> ModelBurnRow in
            let tpr = m.requests > 0 ? Double(m.tokens.total) / Double(m.requests) : 0
            let headroom: Double? = (remaining != nil && tpr > 0) ? remaining! / tpr : nil
            return ModelBurnRow(
                model: m.model,
                tokens: m.tokens.total,
                cost: m.cost,
                requests: m.requests,
                shareFraction: Double(m.tokens.total) / Double(total),
                tokensPerRequest: tpr,
                burnMultiplier: (lightest > 0 && tpr > 0) ? tpr / lightest : 1,
                headroomTurns: headroom
            )
        }
        .sorted { $0.tokens > $1.tokens }
    }
}
