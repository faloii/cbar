import Foundation

/// One rate-limit window as reported by Claude's `/api/oauth/usage` endpoint.
struct LimitWindow: Codable, Equatable {
    let utilization: Double   // 0...100 (% of the window consumed)
    let resetsAt: Date?

    var fraction: Double { max(0, min(1, utilization / 100)) }

    /// True once the reset boundary has passed: the server has rolled the window
    /// over, so this cached utilization describes the PREVIOUS window (e.g. a
    /// "blocked at 100%" reading held all night through sleep) — treat it as
    /// unknown until a fresh fetch, don't display or alert on it as current truth.
    func expired(asOf now: Date) -> Bool {
        guard let r = resetsAt else { return false }
        return r <= now
    }
}

/// A weekly cap on one model family, on top of — not instead of — the all-model
/// weekly limit. Max/Ultra plans cap Fable at a share of the weekly limit (50%):
/// Fable turns draw down both, and hitting either stops Fable.
struct ScopedWeeklyLimit: Codable, Equatable, Identifiable {
    var id: String { model }
    let model: String               // family as the plan names it: "Fable", "Opus"
    let window: LimitWindow         // utilization = % of THIS model's own allowance
    /// The cap's size, and what this model has used so far, as % of the all-model
    /// weekly limit — nil when the plan doesn't say.
    let allowancePctOfWeekly: Double?
    let usedPctOfWeekly: Double?

    private static func family(_ name: String) -> String {
        let n = name.lowercased()
        return n.hasPrefix("claude ") ? String(n.dropFirst(7)) : n
    }

    /// Whether a log model's display name ("Fable 5.2") falls under this cap ("Fable").
    func covers(_ displayName: String) -> Bool {
        Self.family(displayName).hasPrefix(Self.family(model))
    }

    /// All-model weekly % this model can still use: what's left of its own
    /// allowance, but never more than what's left of the weekly limit itself.
    func remainingPctOfWeekly(weeklyUtil: Double) -> Double? {
        guard let a = allowancePctOfWeekly, a > 0 else { return nil }
        let used = usedPctOfWeekly ?? a * window.utilization / 100
        return max(0, min(100 - weeklyUtil, a - used))
    }
}

/// The session (5h) + weekly (7d) limit picture, plus metadata about the fetch.
struct LimitsSnapshot: Codable, Equatable {
    var fetchedAt: Date
    var session5h: LimitWindow?
    var weekly7d: LimitWindow?
    /// Per-model weekly caps (Fable on Max/Ultra). Optional so caches written
    /// before it existed still decode — read it through `scopedWeekly`.
    var weeklyScoped: [ScopedWeeklyLimit]?
    var status: String?             // allowed | allowed_warning | rejected
    var error: String?              // human-readable problem, if any
    var stale = false               // true when served from cache after a failed refresh

    var hasData: Bool { session5h != nil || weekly7d != nil }
    var scopedWeekly: [ScopedWeeklyLimit] { weeklyScoped ?? [] }
}
