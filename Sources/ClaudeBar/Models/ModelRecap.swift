import Foundation

/// Retrospective "did I right-size the model & effort?" read on the last 5h window.
///
/// ClaudeBar can't judge task difficulty and can't observe the reasoning-effort setting,
/// so this never *assigns* a model — it reflects the two signals it CAN measure and frames
/// them as estimates:
///   1. Output tokens per turn → a proxy for how much reasoning each turn actually needed
///      (the closest observable stand-in for effort, which isn't tracked locally).
///   2. The model's exact token volume re-priced on a cheaper tier → the cost lever, honest
///      because only the *price* changes; the token count (and thus the session limit hit)
///      stays the same. That's the whole point: model is a cost lever, not a limit lever.
enum ModelRecap {
    /// Avg output tokens/turn below which turns look "light" (a cheaper model or lower
    /// effort would likely have matched) and above which they look "heavy" (the strong
    /// model / higher effort earned its keep). Soft bands — guidance, not a verdict.
    static let lightOutputPerTurn = 600.0
    static let heavyOutputPerTurn = 1500.0

    enum Intensity: Equatable { case light, moderate, heavy }

    static func intensity(outputPerTurn: Double) -> Intensity {
        if outputPerTurn < lightOutputPerTurn { return .light }
        if outputPerTurn >= heavyOutputPerTurn { return .heavy }
        return .moderate
    }

    struct Verdict: Equatable {
        let model: String            // dominant model id (most expensive in the window)
        let isTopTier: Bool          // opus — the tier with a real downshift lever
        let outputPerTurn: Int       // measured avg output tokens / turn
        let requests: Int
        let intensity: Intensity
        /// A cheaper tier to consider, only when the dominant model is top-tier AND its
        /// turns looked light/moderate. nil when already right-sized or no cheaper tier.
        let downshiftTo: String?
        let downshiftSaving: Double?     // fraction of this model's cost saved (0...1)
        let downshiftSavingUSD: Double?
    }

    /// Builds a verdict for the dominant model (highest cost) in the window, or nil when
    /// there isn't a model with completed turns to reason about.
    static func verdict(window: [ModelWindowUsage]) -> Verdict? {
        guard let m = window.filter({ $0.requests > 0 }).max(by: { $0.cost < $1.cost }) else { return nil }
        let outPerTurn = Double(m.tokens.output) / Double(m.requests)
        let intens = intensity(outputPerTurn: outPerTurn)
        let isOpus = m.model.lowercased().contains("opus")

        var dsTo: String?; var dsFrac: Double?; var dsUSD: Double?
        // Only Opus carries a worthwhile, defensible downshift (≈5× cheaper at Sonnet),
        // and only suggest it when the turns didn't look like they needed the top tier.
        if isOpus, intens != .heavy, m.cost > 0 {
            let sonnetCost = Pricing.price(for: "sonnet").cost(for: m.tokens)
            let saving = m.cost - sonnetCost
            if saving > 0 { dsTo = "Sonnet"; dsFrac = saving / m.cost; dsUSD = saving }
        }
        return Verdict(model: m.model, isTopTier: isOpus,
                       outputPerTurn: Int(outPerTurn.rounded()), requests: m.requests,
                       intensity: intens, downshiftTo: dsTo,
                       downshiftSaving: dsFrac, downshiftSavingUSD: dsUSD)
    }
}
