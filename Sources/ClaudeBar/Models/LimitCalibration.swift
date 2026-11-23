import Foundation

/// "How many list-price dollars is 1% of the session limit, on this Mac?" — read
/// off the live window: cost logged inside it ÷ the live utilization.
///
/// Plan utilization tracks list-price cost (see `Pricing.defaults`), so this ratio
/// should hold steady from window to window while the price table is right. A sharp
/// move away from its usual value means the table drifted (a new model, a price
/// change) or other devices shared the window — either way the per-model numbers
/// are off and worth a look.
enum LimitCalibration {
    /// Below this the integer utilization's rounding dominates the ratio.
    static let minUtil = 20.0
    /// Current ratio this far from the usual one (either direction) counts as drift.
    static let driftFactor = 2.0
    /// Past windows needed before "usual" means anything.
    static let minHistory = 5

    struct Sample: Codable, Equatable {
        let resetsAt: Date              // identifies the session window
        let dollarsPerPercent: Double
    }

    static func dollarsPerPercent(windowCost: Double, util: Double) -> Double? {
        guard util >= minUtil, windowCost > 0 else { return nil }
        return windowCost / util
    }

    /// Two reset times naming the same window (the API's value can jitter slightly).
    static func sameWindow(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 300 }

    /// Median of past windows' ratios, excluding the `current` window; nil with
    /// too little history to call anything "usual".
    static func typical(_ history: [Sample], excluding current: Date?) -> Double? {
        let vals = history
            .filter { s in current.map { !sameWindow(s.resetsAt, $0) } ?? true }
            .map(\.dollarsPerPercent).sorted()
        guard vals.count >= minHistory else { return nil }
        let mid = vals.count / 2
        return vals.count % 2 == 1 ? vals[mid] : (vals[mid - 1] + vals[mid]) / 2
    }

    static func isDrifted(current: Double, typical: Double) -> Bool {
        guard current > 0, typical > 0 else { return false }
        let r = current / typical
        return r >= driftFactor || r <= 1 / driftFactor
    }
}
