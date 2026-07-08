import Foundation

/// Reads several weeks of weekly-limit peaks to suggest whether the current plan
/// tier looks like a good fit — consistently pegged near the ceiling suggests
/// upgrading, consistently low suggests a smaller (cheaper) plan would do.
/// Deliberately silent unless the pattern is unambiguous across every observed
/// week — a single unusual week (vacation, a crunch) shouldn't trigger a plan
/// suggestion, and this has no way to know your plan's price/tier, so it only
/// ever describes the PATTERN, never recommends a specific plan by name.
enum PlanFitSignal {
    enum Verdict: Equatable { case consistentlyHigh, consistentlyLow }
    struct Result: Equatable {
        let verdict: Verdict
        let weeksObserved: Int
        let avgPeakPct: Double
    }

    static let highThreshold = 90.0
    static let lowThreshold = 30.0
    static let minWeeks = 3

    /// `weeklyPeaks`: each COMPLETED week's peak weekly-utilization (0...100).
    /// The current, still-in-progress week must be excluded by the caller — its
    /// peak is necessarily an undercount and would bias toward "consistently low."
    static func evaluate(weeklyPeaks: [Double]) -> Result? {
        guard weeklyPeaks.count >= minWeeks else { return nil }
        let avg = weeklyPeaks.reduce(0, +) / Double(weeklyPeaks.count)
        if weeklyPeaks.allSatisfy({ $0 >= highThreshold }) {
            return Result(verdict: .consistentlyHigh, weeksObserved: weeklyPeaks.count, avgPeakPct: avg)
        }
        if weeklyPeaks.allSatisfy({ $0 <= lowThreshold }) {
            return Result(verdict: .consistentlyLow, weeksObserved: weeklyPeaks.count, avgPeakPct: avg)
        }
        return nil
    }

    /// Buckets weekly-utilization samples into ~7-day-wide "weeks ago from now"
    /// windows and takes each week's peak — a rolling approximation (not aligned
    /// to Anthropic's actual billing-cycle boundary, which isn't stored
    /// historically), honest about being "the last few weeks" rather than exact
    /// billing periods. Excludes week 0 (the current, in-progress week).
    static func weeklyPeaks(samples: [UsageSample], now: Date, weeks: Int) -> [Double] {
        var peaks = Array(repeating: 0.0, count: weeks)
        var seen = Array(repeating: false, count: weeks)
        for s in samples {
            guard let u = s.weekly else { continue }
            let daysAgo = now.timeIntervalSince(s.at) / 86400
            guard daysAgo >= 0 else { continue }
            let w = Int(daysAgo / 7)
            guard w < weeks else { continue }
            if u > peaks[w] { peaks[w] = u }
            seen[w] = true
        }
        return (1..<weeks).compactMap { seen[$0] ? peaks[$0] : nil }
    }
}
