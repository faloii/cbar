import Foundation

/// "Can I keep working?" math for the session window — translates the burn-rate
/// projection into concrete working-time and a wall-clock block time, so the answer
/// is "you've got ~1h50m, you'll block around 14:25" instead of an abstract %/h.
enum SessionCoach {
    struct WorkBudget: Equatable {
        let workableSeconds: TimeInterval   // how long you can keep working from now
        let willBlock: Bool                 // you'll hit 100% before the window resets
        let blockAt: Date?                  // wall-clock block time (willBlock only)
        let resetAt: Date?
        /// You're already at the cap right now.
        var blockedNow: Bool { willBlock && workableSeconds <= 0 }
    }

    /// How much working-time the current session has left.
    /// - `.atRisk`  → until you hit 100% (you'll block before reset).
    /// - `.safe`/`.idle` → until reset (you won't block; the allowance refreshes).
    /// - `.measuring` or no data → nil (not enough signal yet).
    static func workBudget(session: Projection?, util: Double?, resetsAt: Date?, now: Date) -> WorkBudget? {
        guard let util else { return nil }
        if util >= 100 {
            return WorkBudget(workableSeconds: 0, willBlock: true, blockAt: now, resetAt: resetsAt)
        }
        guard let s = session else { return nil }
        let toReset = resetsAt.map { $0.timeIntervalSince(now) }
        switch s.verdict {
        case .atRisk:
            guard let ttf = s.timeToFull, ttf > 0 else { return nil }
            return WorkBudget(workableSeconds: ttf, willBlock: true,
                              blockAt: now.addingTimeInterval(ttf), resetAt: resetsAt)
        case .safe, .idle:
            guard let tr = toReset, tr > 0 else { return nil }
            return WorkBudget(workableSeconds: tr, willBlock: false, blockAt: nil, resetAt: resetsAt)
        case .measuring:
            return nil
        }
    }

    /// Context size above which each turn eats a notable chunk of the limit, so
    /// `/compact` or a fresh session is worth suggesting. ~60% of the 200k window.
    static let heavyContextTokens = 120_000

    // MARK: - Efficiency (spend less per unit of work)

    /// Estimated share of the session limit that ONE more exchange costs, from the
    /// current conversation size. The window's measured tokens map to its utilization%
    /// (impliedLimit = windowTokens / util), and the next turn reads ~contextTokens, so
    /// perExchange% = contextTokens · util / windowTokens. An estimate (token accounting
    /// is approximate), but it makes the context→burn lever tangible.
    static func perExchangeLimitPct(contextTokens: Int, windowTokens: Int, sessionUtil: Double) -> Double? {
        guard contextTokens > 0, windowTokens > 0, sessionUtil > 0 else { return nil }
        return Double(contextTokens) * sessionUtil / Double(windowTokens)
    }

    /// A recap of the most-recently-completed session window (the segment just before
    /// the latest reset), for the "how did I spend it?" learning loop.
    struct Recap: Equatable {
        let peak: Double      // highest utilization reached
        let endedAt: Double   // utilization right before the reset
        var blocked: Bool { peak >= 99 }              // hit the cap (≈ got blocked)
        var leftover: Double { max(0, 100 - endedAt) } // allowance left unused at reset
    }

    /// Every COMPLETED session segment within `maxAge` (each demarcated by a
    /// downward jump = reset), oldest → newest — the raw material for spotting a
    /// feast/famine pattern across today's sessions (see `Advice`'s
    /// `.sessionImbalance` tip). The still-in-progress segment (no reset since) is
    /// excluded, same as `lastSessionRecap`. Empty until at least one session has
    /// completed within `maxAge`. Default matches `UsageHistory`'s own retention
    /// (~12h) — asking for more than that would just find nothing older anyway.
    static func recentSessionRecaps(samples: [UsageSample], now: Date, maxAge: TimeInterval = 12 * 3600) -> [Recap] {
        let pts = samples.compactMap { s in s.session.map { (s.at, $0) } }
            .filter { now.timeIntervalSince($0.0) <= maxAge && $0.0 <= now }
            .sorted { $0.0 < $1.0 }
        guard pts.count >= 2 else { return [] }
        var segments: [[Double]] = [[pts[0].1]]
        for i in 1..<pts.count {
            if pts[i].1 + Projection.resetDrop < pts[i - 1].1 { segments.append([]) }
            segments[segments.count - 1].append(pts[i].1)
        }
        guard segments.count >= 2 else { return [] }   // no completed session yet — only the in-progress one
        return segments.dropLast().map { seg in Recap(peak: seg.max() ?? 0, endedAt: seg.last ?? 0) }
    }

    /// Coarse shape of one completed session, by peak — the same split `Advice`
    /// uses for its imbalance check, pulled out so streak detection can reuse it.
    enum RecapShape { case aggressive, idle, even }
    static func shape(_ r: Recap) -> RecapShape {
        if r.blocked || r.peak >= 90 { return .aggressive }
        if r.peak < 55 { return .idle }
        return .even
    }

    /// True when the most recent `minRun` sessions strictly alternate between
    /// aggressive and idle (either direction) — a repeating habit, not a single
    /// swing. `.even` sessions anywhere in the run break the streak.
    static func isAlternatingStreak(_ recaps: [Recap], minRun: Int = 3) -> Bool {
        guard recaps.count >= minRun else { return false }
        let tail = recaps.suffix(minRun).map(shape)
        guard tail.allSatisfy({ $0 != .even }) else { return false }
        return zip(tail, tail.dropFirst()).allSatisfy { $0 != $1 }
    }

    /// The most recently completed session window (the segment just before the
    /// latest reset), for the "how did I spend it?" learning loop. nil until at
    /// least one session has completed within `maxAge`.
    static func lastSessionRecap(samples: [UsageSample], now: Date, maxAge: TimeInterval = 12 * 3600) -> Recap? {
        recentSessionRecaps(samples: samples, now: now, maxAge: maxAge).last
    }

    static func recapText(_ r: Recap) -> String {
        if r.blocked { return "지난 세션: 한도를 끝까지 썼어요 (막혔을 수 있음)" }
        if r.peak >= 85 { return "지난 세션: 한도 \(Int(r.peak.rounded()))%까지 — 알뜰하게 썼어요" }
        if r.peak < 55 {
            return "지난 세션: 최고 \(Int(r.peak.rounded()))% — \(Int(r.leftover.rounded()))%P 남기고 리셋, 더 써도 됐어요"
        }
        return "지난 세션: 최고 \(Int(r.peak.rounded()))% 사용"
    }

    /// One-glance efficiency verdict for the CURRENT session: are you on track to use
    /// the allowance fully (no waste) AND without blocking (no over-pacing)?
    enum EfficiencyVerdict: Equatable {
        case optimal, fair, underusing, overpacing, idle, measuring
        var label: String {
            switch self {
            case .optimal:    return "최적"
            case .fair:       return "양호"
            case .underusing: return "여유 낭비"
            case .overpacing: return "과속"
            case .idle:       return "쉬는 중"
            case .measuring:  return "측정 중"
            }
        }
        var showsPill: Bool { self != .measuring }
    }

    static func efficiency(util: Double?, projection: Projection?) -> EfficiencyVerdict {
        guard let p = projection else { return .measuring }
        switch p.verdict {
        case .atRisk:    return .overpacing
        case .idle:      return .idle
        case .measuring: return .measuring
        case .safe:
            let proj = p.projectedAtReset ?? util ?? 0
            if proj >= 80 { return .optimal }
            if proj >= 55 { return .fair }
            return .underusing
        }
    }
}
