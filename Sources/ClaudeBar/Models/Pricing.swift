import Foundation

/// USD price per 1M tokens for one model family.
struct ModelPrice {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    func cost(for t: TokenCounts) -> Double {
        (Double(t.input)      * input
         + Double(t.output)     * output
         + Double(t.cacheWrite) * cacheWrite
         + Double(t.cacheRead)  * cacheRead) / 1_000_000.0
    }
}

/// Public Anthropic list prices (USD / 1M tokens). These are *estimates* — costs
/// shown in the UI are labeled as such. Override via `~/.claudebar/pricing.json`.
enum Pricing {
    // Family defaults, matched by substring of the model id.
    static let defaults: [(match: String, price: ModelPrice)] = [
        ("opus",   ModelPrice(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.50)),
        ("sonnet", ModelPrice(input: 3,  output: 15, cacheWrite: 3.75,  cacheRead: 0.30)),
        ("haiku",  ModelPrice(input: 1,  output: 5,  cacheWrite: 1.25,  cacheRead: 0.10)),
        // Fable: fast model, no public list price — approximate at Sonnet tier.
        ("fable",  ModelPrice(input: 3,  output: 15, cacheWrite: 3.75,  cacheRead: 0.30)),
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

    static func cost(for tokens: TokenCounts, model: String) -> Double {
        price(for: model).cost(for: tokens)
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
