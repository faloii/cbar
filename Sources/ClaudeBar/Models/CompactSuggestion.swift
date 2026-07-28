import Foundation

/// Detects when a conversation's most recent turn is "heavy" — the bar used
/// for the per-session /compact badges in the sessions card.
enum CompactSuggestion {
    /// A session whose most recent turn is both a heavy context AND dominated by
    /// re-reading old context — the bar for "this conversation is worth /compact-ing".
    static func isHeavy(_ s: SessionStat) -> Bool {
        s.lastContextTokens >= SessionCoach.heavyContextTokens && s.cacheReadShare >= CacheEfficiency.heavyReuseThreshold
    }
}
