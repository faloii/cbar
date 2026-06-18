import Foundation

/// Raw token counts for a single Claude request (one assistant turn).
struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0   // cache_creation_input_tokens
    var cacheRead = 0    // cache_read_input_tokens

    /// Tokens that count toward the headline "billable" number we show in the bar.
    var total: Int { input + output + cacheWrite + cacheRead }

    /// "New work" tokens — everything except cache reads (which re-read prior context).
    var fresh: Int { input + output + cacheWrite }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input,
                    output: lhs.output + rhs.output,
                    cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                    cacheRead: lhs.cacheRead + rhs.cacheRead)
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }
}

/// Tokens grouped by model, with an estimated cost.
struct ModelUsage: Identifiable {
    var id: String { model }
    let model: String
    var tokens: TokenCounts
    var cost: Double
}

/// Per-model usage within the 5-hour window, including request count (for burn math).
struct ModelWindowUsage: Identifiable {
    var id: String { model }
    let model: String
    var tokens: TokenCounts
    var cost: Double
    var requests: Int
}

/// Per-project usage within the 5-hour window.
struct ProjectUsage: Identifiable {
    var id: String { project }
    let project: String
    var tokens: TokenCounts
    var cost: Double
    var requests: Int
}

/// The currently-active conversation (most recently used session).
struct SessionUsage {
    let project: String
    let cost: Double          // cumulative cost of this session
    let requests: Int
    let contextTokens: Int    // ≈ current context size (latest turn input + cache)
    let lastActivity: Date
}

/// Everything the UI needs for one refresh.
struct UsageSnapshot {
    var generatedAt = Date()

    // Rolling 5-hour window (Claude's session-limit window).
    var windowTokens = TokenCounts()
    var windowCost = 0.0
    var windowByModel: [ModelWindowUsage] = []
    var windowByProject: [ProjectUsage] = []

    // The active conversation right now.
    var currentSession: SessionUsage?
    /// When the oldest request in the current window ages past 5h — i.e. when
    /// the window first starts to free up. `nil` when the window is empty.
    var windowResetAt: Date?

    // Today (local calendar day), computed from the session logs.
    var todayTokens = TokenCounts()
    var todayCost = 0.0
    var todayByModel: [ModelUsage] = []

    // Today's live activity, derived from the session logs.
    var todayRequests = 0   // assistant API turns
    var todaySessions = 0
    var todayToolCalls = 0

    // All-time counts from Claude's own aggregated stats cache.
    var totalSessions = 0
    var totalMessages = 0
    var firstSessionDate: Date?

    /// 14-day token history (oldest → newest) for the sparkline.
    var dailyTokenHistory: [Int] = []

    /// Per-day tokens + estimated cost (oldest → newest), up to ~30 days.
    var dailyCostHistory: [DailyCost] = []

    /// This-week vs last-week habit comparison.
    var weeklyReview: WeeklyReview?

    static let empty = UsageSnapshot()

    /// Returns a copy keeping this snapshot's stats fields but taking the
    /// session-derived fields from `other` (used when a background refresh skipped
    /// the session-log scan, to preserve the last-known session data).
    func mergingSession(from o: UsageSnapshot) -> UsageSnapshot {
        var s = self
        s.windowTokens = o.windowTokens; s.windowCost = o.windowCost; s.windowResetAt = o.windowResetAt
        s.windowByModel = o.windowByModel; s.windowByProject = o.windowByProject
        s.currentSession = o.currentSession
        s.todayTokens = o.todayTokens; s.todayCost = o.todayCost; s.todayByModel = o.todayByModel
        s.todayRequests = o.todayRequests; s.todaySessions = o.todaySessions; s.todayToolCalls = o.todayToolCalls
        return s
    }
}

/// One day's token total and estimated cost.
struct DailyCost: Identifiable {
    var id: String { date }
    let date: String     // "yyyy-MM-dd"
    let tokens: Int
    let cost: Double
}
