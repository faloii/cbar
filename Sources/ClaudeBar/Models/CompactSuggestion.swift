import Foundation

/// Detects when the conversation you're CURRENTLY in (best-effort: whichever
/// session log was touched most recently) crosses into "heavy" — the same bar
/// used for the per-session /compact badges — and decides when that's worth a
/// one-shot notification rather than a per-refresh nag.
enum CompactSuggestion {
    /// A session whose most recent turn is both a heavy context AND dominated by
    /// re-reading old context — the bar for "this conversation is worth /compact-ing".
    static func isHeavy(_ s: SessionStat) -> Bool {
        s.lastContextTokens >= SessionCoach.heavyContextTokens && s.cacheReadShare >= CacheEfficiency.heavyReuseThreshold
    }

    /// Rising-edge state so the notification fires once per session per crossing,
    /// not every refresh tick. Re-arms if the session drops back below the bar
    /// (e.g. an actual `/compact` shows up as a smaller context on the next turn) or
    /// if you've moved on to a different conversation.
    struct State: Equatable {
        var sessionId = ""
        var notified = false
    }

    /// Returns true exactly once when the currently-active session crosses into
    /// "heavy" — mutates `state` to track the rising edge. `current` is the
    /// `SessionStat` matching the snapshot's `currentSessionId`, or nil if unknown.
    static func shouldNotify(current: SessionStat?, state: inout State) -> Bool {
        guard let current, !current.sessionId.isEmpty else { state = State(); return false }
        if state.sessionId != current.sessionId { state = State(sessionId: current.sessionId) }
        guard isHeavy(current) else { state.notified = false; return false }
        guard !state.notified else { return false }
        state.notified = true
        return true
    }
}
