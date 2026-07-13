import Foundation

/// Detects a WEEK-OVER-WEEK drift toward more re-reading — "최근 재읽기 비율이
/// 늘고 있어요" — as opposed to `CacheEfficiency`, which only reads the current
/// 5h window's mix in isolation. A single heavy session isn't a trend; this only
/// speaks up when the recent average has drifted meaningfully past the longer
/// baseline, mirroring `BurnAnomaly`'s personal-baseline shape but for cache mix.
enum CacheEfficiencyTrend {
    struct Verdict: Equatable {
        let recentFreshShare: Double     // 0...1, averaged over the recent window
        let baselineFreshShare: Double   // 0...1, averaged over the longer baseline window
        let deltaPts: Double             // baseline - recent, in percentage points (positive = got worse)
    }

    static let minDeltaPts = 15.0   // only worth a nudge at a real, not noisy, drift
    static let minSamples = 5       // need enough samples on both sides to trust it

    /// `recentShares`/`baselineShares` are fresh-share (0...1) samples; the caller
    /// splits them by time (e.g. last 3 days vs. the weeks before that).
    static func verdict(recentShares: [Double], baselineShares: [Double]) -> Verdict? {
        guard recentShares.count >= minSamples, baselineShares.count >= minSamples else { return nil }
        let recent = recentShares.reduce(0, +) / Double(recentShares.count)
        let baseline = baselineShares.reduce(0, +) / Double(baselineShares.count)
        let deltaPts = (baseline - recent) * 100
        guard deltaPts >= minDeltaPts else { return nil }
        return Verdict(recentFreshShare: recent, baselineFreshShare: baseline, deltaPts: deltaPts)
    }
}
