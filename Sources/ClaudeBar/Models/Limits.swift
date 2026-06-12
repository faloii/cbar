import Foundation

/// One rate-limit window as reported by Claude's `/api/oauth/usage` endpoint.
struct LimitWindow: Codable, Equatable {
    let utilization: Double   // 0...100 (% of the window consumed)
    let resetsAt: Date?

    var fraction: Double { max(0, min(1, utilization / 100)) }
}

/// The session (5h) + weekly (7d) limit picture, plus metadata about the fetch.
struct LimitsSnapshot: Codable, Equatable {
    var fetchedAt: Date
    var session5h: LimitWindow?
    var weekly7d: LimitWindow?
    var weeklyOpus: LimitWindow?    // Max plans expose a separate Opus weekly cap
    var status: String?             // allowed | allowed_warning | rejected
    var error: String?              // human-readable problem, if any
    var stale = false               // true when served from cache after a failed refresh

    var hasData: Bool { session5h != nil || weekly7d != nil }
}
