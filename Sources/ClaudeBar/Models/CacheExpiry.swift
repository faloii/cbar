import Foundation

/// When the current conversation's prompt cache expires. Claude Code caches the
/// conversation prefix for 1h (or 5m); each turn refreshes it. Resuming after it
/// lapses re-writes the WHOLE context into the cache — measured on real logs: 76 of
/// 77 resumes after a >1h gap did exactly that, ~340k tokens each and about half of
/// a week's cache writes — while resuming inside the TTL only re-reads it (0.1×).
enum CacheExpiry {
    /// Below this, re-writing the cache is cheap enough not to mention.
    static let minContextTokens = 100_000
    /// Notify only for conversations this big — where a rewrite really costs.
    static let notifyMinContextTokens = 200_000
    /// Heads-up lead time before expiry.
    static let warnLead: TimeInterval = 10 * 60
    /// Past this long after expiry, the "만료됨" line is stale news — stop showing it.
    static let showExpiredFor: TimeInterval = 24 * 3600

    struct Status: Equatable {
        let expiresAt: Date
        let contextTokens: Int
        func remaining(at now: Date) -> TimeInterval { expiresAt.timeIntervalSince(now) }
        func expired(at now: Date) -> Bool { remaining(at: now) <= 0 }
    }

    static func status(lastTurnAt: Date?, ttl: TimeInterval, contextTokens: Int) -> Status? {
        guard let t = lastTurnAt, contextTokens >= minContextTokens else { return nil }
        return Status(expiresAt: t.addingTimeInterval(ttl), contextTokens: contextTokens)
    }

    /// Whether to send the "expires in ~10 min" heads-up now.
    static func shouldWarn(_ s: Status, now: Date) -> Bool {
        let r = s.remaining(at: now)
        return s.contextTokens >= notifyMinContextTokens && r > 0 && r <= warnLead
    }
}
