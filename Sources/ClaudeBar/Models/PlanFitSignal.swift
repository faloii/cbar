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

    /// A drop this large between two readings inside one bucket isn't usage going
    /// down — utilization only falls at a reset. It's the plan rescaling the week
    /// mid-window (seen: 82% → 36% with `resetsAt` unchanged), or a reset landing a
    /// little off the bucket edge. Either way, readings before it are on another
    /// scale, so the week's peak restarts from there.
    static let rescaleDrop = 20.0

    /// Buckets weekly-utilization samples into 7-day weeks and takes each week's
    /// peak. With the live `resetsAt`, the buckets end on the real reset boundaries
    /// (the weekly window is a fixed 7-day bucket, so past boundaries are that
    /// minus whole weeks); without it they fall back to "weeks ago from now".
    /// Excludes week 0 (the current, in-progress week).
    static func weeklyPeaks(samples: [UsageSample], now: Date, weeks: Int, resetsAt: Date? = nil) -> [Double] {
        let anchor = resetsAt.flatMap { $0 > now ? $0 : nil } ?? now
        var peaks = [Double?](repeating: nil, count: weeks)
        var last = [Double?](repeating: nil, count: weeks)
        for s in samples.sorted(by: { $0.at < $1.at }) {
            guard let u = s.weekly, s.at <= now else { continue }
            let w = Int(anchor.timeIntervalSince(s.at) / (7 * 86400))
            guard w >= 0, w < weeks else { continue }
            if let prev = last[w], prev - u >= rescaleDrop {
                peaks[w] = u
            } else {
                peaks[w] = max(peaks[w] ?? 0, u)
            }
            last[w] = u
        }
        return (1..<weeks).compactMap { peaks[$0] }
    }
}
