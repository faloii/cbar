import Foundation

/// How much of the 5-hour window's tokens are "new work" (input+output+cacheWrite)
/// vs "re-reading old context" (cacheRead). Deliberately informational, not a
/// good/bad verdict — a big cached system prompt/tool schema makes some re-read
/// share normal for EVERY session, so a high number alone doesn't mean waste. It's
/// only actionable together with a large active conversation (`SessionCoach
/// .heavyContextTokens`): that combination means the re-read cost compounds every
/// turn as the conversation grows, and `/compact` directly cuts it.
enum CacheEfficiency {
    struct Verdict: Equatable {
        let freshShare: Double      // 0...1 — share of window tokens that are new work
        let cacheReadShare: Double  // 1 - freshShare
    }

    /// Re-read share above which, PAIRED with a heavy active conversation, the
    /// compounding cost is worth flagging as actionable (not just informational).
    static let heavyReuseThreshold = 0.75

    static func verdict(_ tokens: TokenCounts) -> Verdict? {
        guard tokens.total > 0 else { return nil }
        let fresh = Double(tokens.fresh) / Double(tokens.total)
        return Verdict(freshShare: fresh, cacheReadShare: 1 - fresh)
    }
}
