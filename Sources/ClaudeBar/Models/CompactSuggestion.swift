import Foundation

/// Detects when a conversation's most recent turn is "heavy" — the bar used
/// for the per-session /compact badges in the sessions card, and (via
/// `UsageStore.isHeavyContextWithReuse`) the "효율" card's nudge.
enum CompactSuggestion {
    /// Below `SessionCoach.heavyContextTokens`, re-reading THIS much of the
    /// conversation is unusual enough on its own to flag early — catches a
    /// conversation that's already trending toward heavy before it actually
    /// crosses the absolute size line, instead of only after.
    static let earlyReuseThreshold = 0.85
    /// Below this, the re-read share is too small a sample to mean much (e.g.
    /// one big system prompt read twice in a 3-turn conversation can look like
    /// "90% re-read" without being a real problem yet) — half the full
    /// threshold, so the early catch only fires on a conversation that's
    /// already meaningfully sized, not a brand-new one.
    static let earlyContextFloor = SessionCoach.heavyContextTokens / 2

    /// A conversation worth a /compact nudge: either already heavy by size
    /// (same bar as before — context ≥ full threshold AND re-read ≥ 75%), or
    /// already dominated by re-reading at a moderate size (context ≥ half the
    /// threshold AND re-read ≥ 85%) — the earlier catch.
    static func isHeavy(contextTokens: Int, cacheReadShare: Double) -> Bool {
        if contextTokens >= SessionCoach.heavyContextTokens {
            return cacheReadShare >= CacheEfficiency.heavyReuseThreshold
        }
        if contextTokens >= earlyContextFloor {
            return cacheReadShare >= earlyReuseThreshold
        }
        return false
    }

    /// A session whose most recent turn is both a heavy context AND dominated by
    /// re-reading old context — the bar for "this conversation is worth /compact-ing".
    static func isHeavy(_ s: SessionStat) -> Bool {
        isHeavy(contextTokens: s.lastContextTokens, cacheReadShare: s.cacheReadShare)
    }
}
