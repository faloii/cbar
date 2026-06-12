import Foundation

/// One point in the recorded usage time-series.
struct UsageSample: Codable, Equatable {
    let at: Date
    let session: Double?
    let weekly: Double?
}

enum PaceVerdict: Equatable {
    case measuring   // not enough data yet
    case idle        // not meaningfully burning
    case safe        // burning, but the window resets before you'd hit 100%
    case atRisk      // at this rate you hit 100% *before* the window resets
}

/// Burn-rate projection for a single limit window, derived from recent samples.
struct Projection: Equatable {
    let ratePerHour: Double          // percentage points per hour (>= 0)
    let timeToFull: TimeInterval?    // seconds until 100% at current rate, nil if not projecting
    let secondsToReset: TimeInterval?
    let verdict: PaceVerdict

    /// `timeToFull` shortfall before reset, i.e. how long you'd be blocked. nil unless `.atRisk`.
    var blockedBy: TimeInterval? {
        guard verdict == .atRisk, let f = timeToFull, let r = secondsToReset else { return nil }
        return max(0, r - f)
    }

    static let measuring = Projection(ratePerHour: 0, timeToFull: nil, secondsToReset: nil, verdict: .measuring)

    /// Lookback for the slope; only samples this recent are used.
    static let lookback: TimeInterval = 45 * 60
    /// Below this %/h we treat the window as not actively burning.
    static let idleEpsilon = 0.5
    /// A drop larger than this between consecutive samples marks a window reset.
    static let resetDrop = 3.0

    /// `points` are (time, utilization%) for ONE window, any order.
    static func compute(points: [(Date, Double)], resetsAt: Date?, now: Date) -> Projection {
        let secondsToReset = resetsAt.map { $0.timeIntervalSince(now) }

        // Recent, sorted oldest→newest.
        let recent = points
            .filter { now.timeIntervalSince($0.0) <= lookback && $0.0 <= now }
            .sorted { $0.0 < $1.0 }

        // Use only the segment after the most recent reset (a downward jump).
        var usable = recent
        if recent.count >= 2 {
            for i in stride(from: recent.count - 1, to: 0, by: -1) where recent[i].1 + resetDrop < recent[i - 1].1 {
                usable = Array(recent[i...])
                break
            }
        }
        guard usable.count >= 2, let first = usable.first, let last = usable.last else {
            return Projection(ratePerHour: 0, timeToFull: nil, secondsToReset: secondsToReset, verdict: .measuring)
        }

        let hours = last.0.timeIntervalSince(first.0) / 3600
        guard hours > 0 else {
            return Projection(ratePerHour: 0, timeToFull: nil, secondsToReset: secondsToReset, verdict: .measuring)
        }

        let rate = (last.1 - first.1) / hours
        guard rate > idleEpsilon else {
            return Projection(ratePerHour: max(0, rate), timeToFull: nil, secondsToReset: secondsToReset, verdict: .idle)
        }

        let remaining = max(0, 100 - last.1)
        let timeToFull = (remaining / rate) * 3600
        var verdict: PaceVerdict = .safe
        if let r = secondsToReset, timeToFull < r { verdict = .atRisk }

        return Projection(ratePerHour: rate, timeToFull: timeToFull, secondsToReset: secondsToReset, verdict: verdict)
    }
}
