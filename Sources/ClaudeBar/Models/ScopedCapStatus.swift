import Foundation

/// One per-model weekly cap (Fable on Max/Ultra: up to 50% of the weekly limit),
/// with its own pace and whether it runs out BEFORE the all-model weekly limit.
/// Only a cap that binds first needs its own warnings: while the weekly limit is
/// the tighter one, the weekly alerts and tips already cover that model too.
struct ScopedCapStatus: Equatable, Identifiable {
    var id: String { cap.model }
    let cap: ScopedWeeklyLimit
    /// Average-pace projection of the cap's own % since the week started. The plan
    /// reports the cap's % only as a point reading (no history), so it's paced, not
    /// burst-blended like the weekly ring.
    let projection: Projection
    /// What's left of the cap is less than what's left of the weekly limit — this
    /// model stops first while the other models keep working.
    let bindsFirst: Bool

    static let windowSeconds: TimeInterval = 7 * 24 * 3600

    var risk: WindowRisk {
        WindowRisk(utilization: cap.window.utilization, projection: projection, imminentWindow: 24 * 3600)
    }

    static func evaluate(scoped: [ScopedWeeklyLimit], weekly: LimitWindow?, now: Date) -> [ScopedCapStatus] {
        let weeklyUtil = weekly.flatMap { $0.expired(asOf: now) ? nil : $0.utilization } ?? 0
        return scoped.filter { !$0.window.expired(asOf: now) }.map { s in
            // Without the cap's size, compare fill levels: a cap fuller than the
            // weekly limit runs out first at any shared pace.
            let binds = s.remainingPctOfWeekly(weeklyUtil: weeklyUtil).map { $0 < 100 - weeklyUtil }
                ?? (s.window.utilization > weeklyUtil)
            let p = Projection.paced(util: s.window.utilization, resetsAt: s.window.resetsAt,
                                     windowSeconds: windowSeconds, now: now)
            return ScopedCapStatus(cap: s, projection: p, bindsFirst: binds)
        }
    }
}
