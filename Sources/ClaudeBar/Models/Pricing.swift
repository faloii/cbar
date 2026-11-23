import Foundation

/// USD price per 1M tokens for one model family.
struct ModelPrice {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    /// `hourCache`: the turn wrote with the 1-hour TTL, billed at 2× input instead
    /// of the 5-minute 1.25× (`cacheWrite`).
    func cost(for t: TokenCounts, hourCache: Bool = false) -> Double {
        (Double(t.input)      * input
         + Double(t.output)     * output
         + Double(t.cacheWrite) * (hourCache ? input * 2 : cacheWrite)
         + Double(t.cacheRead)  * cacheRead) / 1_000_000.0
    }

    /// List price: cache writes 1.25× input (5-minute TTL).
    init(input: Double, output: Double, cacheRead: Double) {
        self.init(input: input, output: output, cacheWrite: input * 1.25, cacheRead: cacheRead)
    }

    init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
}

/// Public Anthropic list prices (USD / 1M tokens). These are *estimates* — costs
/// shown in the UI are labeled as such. Override via `~/.claudebar/pricing.json`.
enum Pricing {
    // Matched by substring of the model id, FIRST match wins — so a specific
    // version must precede its family catch-all ("opus-5-5" before "opus").
    // Prices as of 2026-11. These also drive the limit-share estimate: measured on
    // 4 weeks of this machine's logs, cost at these prices tracks the plan's
    // utilization (R² 0.91) far better than raw tokens (0.71) — models and cache
    // reads draw on the limit at very different rates per token.
    static let defaults: [(match: String, price: ModelPrice)] = [
        ("fable-5-2",  ModelPrice(input: 8,    output: 40,   cacheRead: 0.20)),
        ("fable-5-1",  ModelPrice(input: 10,   output: 50,   cacheRead: 0.25)),
        ("fable",      ModelPrice(input: 10,   output: 50,   cacheRead: 1.00)),   // Fable 5
        ("opus-5-5",   ModelPrice(input: 4,    output: 20,   cacheRead: 0.20)),
        ("opus",       ModelPrice(input: 5,    output: 25,   cacheRead: 0.50)),   // Opus 5 / 4.8 / 4.7 / 4.6
        ("sonnet-5-5", ModelPrice(input: 2,    output: 10,   cacheRead: 0.10)),
        ("sonnet-5",   ModelPrice(input: 2,    output: 10,   cacheRead: 0.20)),
        ("sonnet",     ModelPrice(input: 3,    output: 15,   cacheRead: 0.30)),   // Sonnet 4.6
        ("haiku-5-5",  ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("haiku",      ModelPrice(input: 1,    output: 5,    cacheRead: 0.10)),   // Haiku 4.5
    ]

    /// Fallback when no family matches.
    static let fallback = ModelPrice(input: 5, output: 20, cacheWrite: 6.25, cacheRead: 0.50)

    /// User overrides loaded from disk, keyed by family match string.
    private static let overrides: [String: ModelPrice] = loadOverrides()

    static func price(for model: String) -> ModelPrice {
        let m = model.lowercased()
        for (match, price) in defaults where m.contains(match) {
            return overrides[match] ?? price
        }
        return overrides["default"] ?? fallback
    }

    static func cost(for tokens: TokenCounts, model: String, hourCache: Bool = false) -> Double {
        price(for: model).cost(for: tokens, hourCache: hourCache)
    }

    // MARK: - Overrides

    private static func loadOverrides() -> [String: ModelPrice] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudebar/pricing.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]]
        else { return [:] }

        var result: [String: ModelPrice] = [:]
        for (key, v) in raw {
            result[key.lowercased()] = ModelPrice(
                input: v["input"] ?? 0,
                output: v["output"] ?? 0,
                cacheWrite: v["cacheWrite"] ?? v["input"] ?? 0,
                cacheRead: v["cacheRead"] ?? 0
            )
        }
        return result
    }
}
