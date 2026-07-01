import Foundation

/// Pacing math for "land near 100% right at reset, spread evenly".
enum Pace {
    /// %/h you'd need to burn from now to reach 100% exactly at reset — the steady
    /// rate that fully uses the window without blocking early. nil when the reset is
    /// past/imminent or you're already full.
    static func sustainableRate(util: Double, secondsToReset: TimeInterval?) -> Double? {
        guard let s = secondsToReset, s > 60, util < 100 else { return nil }
        return (100 - util) / (s / 3600)
    }

    /// Fraction of the window elapsed (0…1) — where the even-usage line sits *now*,
    /// i.e. the % you'd be at if pacing linearly to 100% at reset. nil if unknown.
    static func elapsedFraction(windowSeconds: TimeInterval, secondsToReset: TimeInterval?) -> Double? {
        guard let s = secondsToReset, windowSeconds > 0 else { return nil }
        return min(1, max(0, (windowSeconds - s) / windowSeconds))
    }
}

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
    /// Projected utilization (%) at reset time at the current rate — answers the
    /// other half of "limit awareness": will I actually use my full allowance
    /// before it resets, or leave headroom on the table? May exceed 100 when
    /// `.atRisk` (you'd be blocked before reset). nil when there's no rate yet.
    var projectedAtReset: Double? = nil

    /// `timeToFull` shortfall before reset, i.e. how long you'd be blocked. nil unless `.atRisk`.
    var blockedBy: TimeInterval? {
        guard verdict == .atRisk, let f = timeToFull, let r = secondsToReset else { return nil }
        return max(0, r - f)
    }

    /// Unused headroom (%) you're on track to leave at reset; nil if unknown.
    /// Meaningful only when not `.atRisk` (otherwise you hit the cap early).
    var headroomAtReset: Double? {
        guard let p = projectedAtReset else { return nil }
        return max(0, 100 - p)
    }

    static let measuring = Projection(ratePerHour: 0, timeToFull: nil, secondsToReset: nil, verdict: .measuring)

    /// Lookback for the slope; only samples this recent are used.
    static let lookback: TimeInterval = 45 * 60
    /// Below this %/h we treat the window as not actively burning.
    static let idleEpsilon = 0.5
    /// A drop larger than this between consecutive samples marks a window reset.
    static let resetDrop = 3.0

    /// Pace projection for a FIXED-bucket window (e.g. weekly): uses the realized
    /// average rate since the window started — not a short burst — so a momentary
    /// spike doesn't extrapolate to an absurd "runs out in 12h" for a barely-used week.
    /// `windowSeconds` is the bucket length (7d for weekly); reset marks the bucket end.
    static func paced(util: Double, resetsAt: Date?, windowSeconds: TimeInterval, now: Date) -> Projection {
        guard let reset = resetsAt else { return .measuring }
        let secondsToReset = reset.timeIntervalSince(now)
        let elapsed = windowSeconds - secondsToReset
        guard util > 0 else {
            return Projection(ratePerHour: 0, timeToFull: nil, secondsToReset: secondsToReset, verdict: .idle)
        }
        guard elapsed >= 6 * 3600 else {   // too early in the bucket to judge a pace
            return Projection(ratePerHour: 0, timeToFull: nil, secondsToReset: secondsToReset, verdict: .safe)
        }
        let ratePerHour = util / (elapsed / 3600)
        let timeToFull = ratePerHour > 0 ? (max(0, 100 - util) / ratePerHour) * 3600 : nil
        var verdict: PaceVerdict = .safe
        if let f = timeToFull, secondsToReset > 0, f < secondsToReset { verdict = .atRisk }
        let projected = util + ratePerHour * (max(0, secondsToReset) / 3600)
        return Projection(ratePerHour: ratePerHour, timeToFull: timeToFull, secondsToReset: secondsToReset,
                          verdict: verdict, projectedAtReset: projected)
    }

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
        let projected = secondsToReset.map { last.1 + rate * (max(0, $0) / 3600) }

        return Projection(ratePerHour: rate, timeToFull: timeToFull, secondsToReset: secondsToReset,
                          verdict: verdict, projectedAtReset: projected)
    }

    /// Weekly projection that combines the realized whole-week average pace (`paced`,
    /// stable, ignores short bursts) with a short recent-burst trajectory (`compute`,
    /// the same ~45min-lookback math the session uses). `paced` alone has a blind spot
    /// early in the week — it refuses to judge a pace before 6h have elapsed (to avoid
    /// over-reacting to noise), so burning fast in the first few hours produces *no*
    /// signal until hour 6, often too late to react. `compute` catches that immediately.
    /// Whichever view is more urgent (`.atRisk` with the sooner time-to-full) wins;
    /// otherwise `paced` is the stable default.
    static func combinedWeekly(points: [(Date, Double)], util: Double, resetsAt: Date?,
                               windowSeconds: TimeInterval, now: Date) -> Projection {
        let paced = Projection.paced(util: util, resetsAt: resetsAt, windowSeconds: windowSeconds, now: now)
        let burst = Projection.compute(points: points, resetsAt: resetsAt, now: now)
        guard burst.verdict == .atRisk else { return paced }
        guard paced.verdict == .atRisk, let pf = paced.timeToFull, let bf = burst.timeToFull else { return burst }
        return bf <= pf ? burst : paced
    }
}
