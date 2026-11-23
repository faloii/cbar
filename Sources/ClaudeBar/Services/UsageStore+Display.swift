import Foundation
import SwiftUI

/// Derived read-only stats for the popover and menu-bar label: efficiency/work-budget
/// readings, the bar text/color, and the simple booleans (blocked/over-threshold/at-risk)
/// several other pieces (refresh cadence, alerts) key off of.
extension UsageStore {
    /// Working-time budget for the current session window — drives the menu-bar
    /// "block in N" warning and the in-popover coach.
    var sessionWorkBudget: SessionCoach.WorkBudget? {
        guard enableLiveLimits, let w = liveSession else { return nil }
        return SessionCoach.workBudget(session: sessionProjection, util: w.utilization,
                                       resetsAt: w.resetsAt, now: Date())
    }

    /// Estimated session-limit cost of one more exchange, from the current conversation
    /// size — the tangible "efficiency" number.
    var perExchangePct: Double? {
        guard enableLiveLimits, let u = liveSession?.utilization else { return nil }
        return SessionCoach.perExchangeLimitPct(contextTokens: snapshot.currentContextTokens,
                                                windowTokens: snapshot.windowTokens.total, sessionUtil: u)
    }

    /// One-glance "am I spending this session efficiently?" verdict.
    var efficiencyVerdict: SessionCoach.EfficiencyVerdict {
        SessionCoach.efficiency(util: liveSession?.utilization, projection: sessionProjection)
    }

    /// Whether the efficiency card has anything worth showing.
    var hasEfficiencyData: Bool {
        enableLiveLimits && (snapshot.currentContextTokens > 0 || lastSessionRecap != nil)
    }

    /// The next few session-window reset times — plan heavy work around today's
    /// rhythm instead of only reacting when the current window is about to flip.
    var upcomingResets: [Date] {
        guard let next = liveSession?.resetsAt else { return [] }
        return UpcomingResets.compute(nextReset: next, now: snapshot.generatedAt)
    }

    /// New-work vs re-read-old-context share of the 5h window — how much of the
    /// limit consumed so far is "new work" vs "re-reading" (see `CacheEfficiency`).
    var cacheEfficiency: CacheEfficiency.Verdict? {
        CacheEfficiency.verdict(snapshot.windowTokens)
    }

    /// The current conversation is both large AND mostly re-read old context — the
    /// bar for "this is worth a /compact". Shared by `adviceTips` (the in-app tip)
    /// and `processAdviceFollowThrough` (the follow-through nudge tracker) so the
    /// two don't quietly drift apart if the threshold logic ever changes. Delegates
    /// to `CompactSuggestion.isHeavy` — the SAME predicate the 효율 card and the
    /// per-session badges use, including its earlier catch for a conversation
    /// that's already re-read-dominated before it's fully ballooned in size.
    /// The current conversation's prompt-cache expiry (nil for small conversations
    /// or before any turn is seen).
    var cacheExpiry: CacheExpiry.Status? {
        CacheExpiry.status(lastTurnAt: snapshot.currentTurnAt, ttl: snapshot.currentCacheTTL,
                           contextTokens: snapshot.currentContextTokens)
    }

    var isHeavyContextWithReuse: Bool {
        CompactSuggestion.isHeavy(contextTokens: snapshot.currentContextTokens,
                                  cacheReadShare: cacheEfficiency?.cacheReadShare ?? 0)
    }

    /// The session part of the bar label: self-warns "막힘 50m" (time until you'll hit
    /// the cap) when on track to block before reset, "막힘" when already blocked, else
    /// the plain %. So you see trouble coming without opening the popover.
    func sessionBarText(util: Double) -> String {
        if util >= 100 { return "막힘 100%" }
        if let b = sessionWorkBudget, b.willBlock, let at = b.blockAt {
            return "막힘 \(Fmt.shortCountdown(to: at, from: Date())) · \(Int(util.rounded()))%"
        }
        return "\(Int(util.rounded()))%"
    }

    /// The weekly part of the bar label — mirrors `sessionBarText`'s "막힘 Nh/Nd"
    /// self-warning. A weekly block is the expensive one (days, not hours), so
    /// seeing it coming without opening the popover matters just as much here.
    func weeklyBarText(util: Double) -> String {
        if util >= 100 { return "막힘 100%" }
        if let p = weeklyProjection, p.verdict == .atRisk, let ttf = p.timeToFull {
            return "막힘 \(Fmt.shortCountdown(to: Date().addingTimeInterval(ttf), from: Date())) · \(Int(util.rounded()))%"
        }
        return "\(Int(util.rounded()))%"
    }

    /// When the OTHER limit window (not the one the bar is showing) is past the
    /// warn threshold, surface it compactly — otherwise the bar can raise a warning
    /// triangle for a window whose number isn't even on screen.
    func crossWindowSuffix(other: LimitWindow?, prefix: String) -> String {
        guard let u = other?.utilization, u >= Double(warnThreshold) else { return "" }
        return " · \(prefix)\(Int(u.rounded()))%"
    }

    /// Menu-bar space is shared with the system's other extras, and a "막힘 6d
    /// 23h"-style primary reading is already long — drop the cross-window suffix
    /// rather than let the label balloon past a sane budget.
    static var maxBarTextLength: Int { 16 }
    func withCrossWindowSuffix(_ primary: String, other: LimitWindow?, prefix: String) -> String {
        let suffix = crossWindowSuffix(other: other, prefix: prefix)
        guard !suffix.isEmpty else { return primary }
        let combined = primary + suffix
        return combined.count <= Self.maxBarTextLength ? combined : primary
    }

    var barText: String {
        let s = snapshot
        switch barMetric {
        case .sessionLimit:
            if let u = liveSession?.utilization {
                return withCrossWindowSuffix(sessionBarText(util: u), other: liveWeekly, prefix: "W")
            }
            return enableLiveLimits ? "—" : Fmt.tokens(s.windowTokens.total)
        case .weeklyLimit:
            if let u = liveWeekly?.utilization {
                return withCrossWindowSuffix(weeklyBarText(util: u), other: liveSession, prefix: "S")
            }
            return enableLiveLimits ? "—" : Fmt.tokens(s.windowTokens.total)
        case .bothLimits:
            let sPart = liveSession.map { "S \(sessionBarText(util: $0.utilization))" }
            let wPart = liveWeekly.map { "W \(weeklyBarText(util: $0.utilization))" }
            let joined = [sPart, wPart].compactMap { $0 }.joined(separator: " · ")
            return joined.isEmpty ? (enableLiveLimits ? "—" : Fmt.tokens(s.windowTokens.total)) : joined
        case .windowTokens: return Fmt.tokens(s.windowTokens.total)
        case .windowCost:   return Fmt.usd(s.windowCost)
        case .todayTokens:  return Fmt.tokens(s.todayTokens.total)
        case .todayCost:    return Fmt.usd(s.todayCost)
        }
    }

    /// The last few notifications CBar has posted (newest first) — a safety net
    /// for passive/no-banner ones and anything missed while away. See `NotificationLog`.
    /// compacted() (in `reloadDiskReadings`) so pre-dedup historical duplicates
    /// already on disk disappear from the list on next open.
    var recentNotifications: [NotificationLogEntry] { diskReadings.recentNotifications }

    /// Per-model burn comparison for the current 5-hour window.
    var modelBurnRows: [ModelBurnRow] {
        ModelBurn.rows(window: snapshot.windowByModel,
                       sessionUtil: limits?.session5h?.utilization,
                       basis: burnBasis)
    }

    /// Live list-price $ per 1% of the session limit, and its usual value across
    /// past windows (nil until there's enough history) — see `LimitCalibration`.
    /// Only when the snapshot's window IS the live window: a rolling fallback
    /// window would divide the wrong cost by the live %.
    var limitCalibration: (current: Double, typical: Double?)? {
        guard let w = liveSession, let reset = w.resetsAt,
              let snapReset = snapshot.windowResetAt, LimitCalibration.sameWindow(reset, snapReset),
              let cur = LimitCalibration.dollarsPerPercent(windowCost: snapshot.windowCost, util: w.utilization)
        else { return nil }
        return (cur, LimitCalibration.typical(diskReadings.limitCalibrationHistory, excluding: reset))
    }

    /// The live ratio drifted far from its usual value — the price table (or the
    /// window's device mix) no longer matches what the plan is counting.
    var limitCalibrationDrifted: Bool {
        guard let c = limitCalibration, let t = c.typical else { return false }
        return LimitCalibration.isDrifted(current: c.current, typical: t)
    }

    func recordLimitCalibration() {
        guard let reset = liveSession?.resetsAt, let c = limitCalibration else { return }
        LimitCalibrationHistory.record(LimitCalibration.Sample(resetsAt: reset, dollarsPerPercent: c.current))
    }

    /// "남은 N% ≈ 모델 X 약 M턴" for the top models in the window.
    var modelTurnsLeft: [(model: String, turns: Int)] {
        guard let u = liveSession?.utilization else { return [] }
        return ModelBurn.turnsLeft(rows: modelBurnRows, sessionUtil: u)
    }

    /// Live list-price $ per 1% of the WEEKLY limit — the weekly window's cost on
    /// this Mac ÷ live weekly utilization. Only when the scan's weekly window is the
    /// live one. Not tracked for drift: other devices and plan changes move it, and
    /// the session ratio already watches the price table.
    var weeklyDollarsPerPercent: Double? {
        guard let w = liveWeekly, let reset = w.resetsAt,
              let snapReset = snapshot.weeklyWindowResetAt, LimitCalibration.sameWindow(reset, snapReset)
        else { return nil }
        return LimitCalibration.dollarsPerPercent(windowCost: snapshot.weeklyWindowCost, util: w.utilization)
    }

    /// Per-model weekly caps whose window is still live (Fable on Max/Ultra).
    var liveScopedWeekly: [ScopedWeeklyLimit] {
        (limits?.scopedWeekly ?? []).filter { !$0.window.expired(asOf: Date()) }
    }

    /// "남은 주간 N% ≈ 모델 X 약 M턴", priced per model under the plan's per-model
    /// weekly caps — see `WeeklyModelTurns`. Per-turn cost over the weekly window
    /// is steadier than the 5h window's.
    var weeklyModelTurnsLeft: [WeeklyModelTurns.Row] {
        guard let u = liveWeekly?.utilization, weeklyDollarsPerPercent != nil else { return [] }
        return WeeklyModelTurns.compute(window: snapshot.weeklyWindowByModel, weeklyUtil: u,
                                        scoped: liveScopedWeekly)
    }

    /// Highest of the live session/weekly utilizations, or nil if unavailable.
    /// Expired windows (reset boundary passed) don't count — see `liveSession`.
    var maxLimitUtilization: Double? {
        let vals = [liveSession?.utilization, liveWeekly?.utilization].compactMap { $0 }
        return vals.max()
    }

    /// True when a live limit has crossed the warning threshold — drives the
    /// menu-bar warning icon/color.
    var isOverThreshold: Bool {
        (maxLimitUtilization ?? 0) >= Double(warnThreshold)
    }

    /// True when you're currently rate-limited: a `rejected` status or a window at
    /// 100%. Drives the menu-bar "blocked" glyph and red tint. A cached `rejected` is only trusted while NO window from that same
    /// fetch has passed its reset — same rule as `LimitAlerts` (one expired window
    /// means the status is stale; a live window at 100% is still caught above).
    var isBlocked: Bool {
        if (maxLimitUtilization ?? 0) >= 100 { return true }
        let anyExpired = liveSession == nil && limits?.session5h != nil
            || liveWeekly == nil && limits?.weekly7d != nil
        return limits?.status == "rejected" && !anyExpired && (liveSession != nil || liveWeekly != nil)
    }

    /// Whether we're close enough to a limit to warrant the tighter refresh cadence
    /// + fresher fetches: blocked, over the warn threshold, or projected to exhaust.
    var isAtLimitRisk: Bool {
        isBlocked || isOverThreshold || sessionProjection?.verdict == .atRisk
    }

    /// The session/weekly risk the rings, the status badge and the menu-bar tint
    /// ALL read — one computation, so the three can't disagree (the menu bar used
    /// to use warnThreshold/95% while the rings used fixed 60/85%, so the same
    /// 70% showed green in the bar and orange in the popover).
    var sessionRisk: WindowRisk? {
        liveSession.map { WindowRisk(utilization: $0.utilization, projection: sessionProjection, imminentWindow: 3600) }
    }
    var weeklyRisk: WindowRisk? {
        liveWeekly.map { WindowRisk(utilization: $0.utilization, projection: weeklyProjection, imminentWindow: 24 * 3600) }
    }

    /// The weekly window is the binding constraint right now — at/over the warn
    /// threshold or projected to run out before reset. "Run heavy work now" style
    /// encouragement must stay quiet while this is true.
    var isWeeklyBinding: Bool {
        (liveWeekly?.utilization ?? 0) >= Double(warnThreshold) || weeklyProjection?.verdict == .atRisk
    }

    /// Menu-bar tint — the same `WindowRisk` tier as the ring for the displayed
    /// metric. When the warning glyph is up (raised by the WORST window), the tint
    /// follows that worst window too, so a calm "12%" can't sit next to a triangle
    /// the weekly window raised.
    var barColor: Color {
        if isBlocked { return .red }
        let worst = [sessionRisk?.tier, weeklyRisk?.tier].compactMap { $0 }.max()
        let shown: RiskTier?
        switch barMetric {
        case .sessionLimit: shown = sessionRisk?.tier
        case .weeklyLimit:  shown = weeklyRisk?.tier
        case .bothLimits:   shown = worst
        default:            return isOverThreshold ? .orange : .primary
        }
        guard let tier = isOverThreshold ? worst : shown else { return .primary }
        return tier.color
    }
}
