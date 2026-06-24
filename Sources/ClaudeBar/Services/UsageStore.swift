import Foundation
import SwiftUI
import Combine

/// Popover cards the user can show/hide and reorder (Settings → 섹션).
/// Declaration order is the default layout order.
enum PanelSection: String, CaseIterable, Identifiable {
    case advice, limits, recent, perModel, modelGuide, sessions, today, weeklyReview, goals, budget
    var id: String { rawValue }
    var label: String {
        switch self {
        case .advice:         return "조언"
        case .limits:         return "플랜 한도"
        case .recent:         return "최근 5시간"
        case .perModel:       return "모델별 소진"
        case .modelGuide:     return "모델 가이드"
        case .sessions:       return "세션별"
        case .today:          return "오늘"
        case .weeklyReview:   return "주간 리뷰"
        case .goals:          return "습관 목표"
        case .budget:         return "월 예산"
        }
    }
}

/// Popover appearance — follow the system, or pin light/dark.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "시스템"
        case .light:  return "라이트"
        case .dark:   return "다크"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// What the menu-bar label shows at a glance.
enum BarMetric: String, CaseIterable, Identifiable {
    case sessionLimit, weeklyLimit, bothLimits, windowTokens, windowCost, todayTokens, todayCost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sessionLimit: return "세션 한도 %"
        case .weeklyLimit:  return "주간 한도 %"
        case .bothLimits:   return "세션 + 주간 %"
        case .windowTokens: return "5시간 토큰"
        case .windowCost:   return "5시간 비용"
        case .todayTokens:  return "오늘 토큰"
        case .todayCost:    return "오늘 비용"
        }
    }
    /// Whether this metric needs the live `/usage` data.
    var needsLiveLimits: Bool { self == .sessionLimit || self == .weeklyLimit || self == .bothLimits }
}

/// Owns the current snapshot, the refresh timer, and user settings.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var limits: LimitsSnapshot?
    @Published private(set) var sessionProjection: Projection?
    @Published private(set) var weeklyProjection: Projection?
    @Published private(set) var isRefreshing = false

    @AppStorage("refreshIntervalSeconds") var refreshInterval: Double = 60 {
        didSet { restartTimer() }
    }
    // `@AppStorage` inside an ObservableObject doesn't auto-publish to observing
    // views, so settings that other views render from explicitly send objectWillChange.
    @AppStorage("enableLiveLimits") var enableLiveLimits: Bool = true {
        didSet { refresh(force: true) }
    }
    @AppStorage("burnBasis") private var burnBasisRaw: String = BurnBasis.totalTokens.rawValue {
        didSet { objectWillChange.send() }
    }
    var burnBasis: BurnBasis {
        get { BurnBasis(rawValue: burnBasisRaw) ?? .totalTokens }
        set { burnBasisRaw = newValue.rawValue }
    }
    @AppStorage("warnThreshold") var warnThreshold: Int = 80 {
        didSet { objectWillChange.send() }
    }
    /// Monthly budget in USD; 0 = off.
    @AppStorage("monthlyBudget") var monthlyBudget: Double = 0 {
        didSet { objectWillChange.send() }
    }
    /// Habit goal: keep Opus cost share at or below this %; 0 = off.
    @AppStorage("opusShareTarget") var opusShareTarget: Int = 0 {
        didSet { objectWillChange.send() }
    }
    /// Comma-joined raw values of hidden sections. Default = lean: show only the
    /// core (advice, limits, recent, today); the analysis cards (per-model burn,
    /// model guide, per-session) are opt-in.
    @AppStorage("hiddenSections") private var hiddenSectionsRaw: String =
        "perModel,modelGuide,sessions" {
        didSet { objectWillChange.send() }
    }
    /// Comma-joined raw values defining card order (missing ones append in default order).
    @AppStorage("sectionOrder") private var sectionOrderRaw: String = "" {
        didSet { objectWillChange.send() }
    }

    func isVisible(_ section: PanelSection) -> Bool {
        !hiddenSectionsRaw.split(separator: ",").contains(Substring(section.rawValue))
    }
    func setVisible(_ section: PanelSection, _ visible: Bool) {
        var hidden = Set(hiddenSectionsRaw.split(separator: ",").map(String.init))
        if visible { hidden.remove(section.rawValue) } else { hidden.insert(section.rawValue) }
        hiddenSectionsRaw = hidden.sorted().joined(separator: ",")
    }

    /// Sections in display order (saved order first, then any new ones in default order).
    var orderedSections: [PanelSection] {
        let saved = sectionOrderRaw.split(separator: ",").compactMap { PanelSection(rawValue: String($0)) }
        return saved + PanelSection.allCases.filter { !saved.contains($0) }
    }
    /// Move a section up (delta -1) or down (delta +1).
    func moveSection(_ section: PanelSection, by delta: Int) {
        var order = orderedSections
        guard let i = order.firstIndex(of: section), order.indices.contains(i + delta) else { return }
        order.swapAt(i, i + delta)
        sectionOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }

    /// Drag-and-drop reorder: place `moved` just before `target`.
    func moveSection(_ moved: PanelSection, before target: PanelSection) {
        guard moved != target else { return }
        var order = orderedSections.filter { $0 != moved }
        guard let idx = order.firstIndex(of: target) else { return }
        order.insert(moved, at: idx)
        sectionOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }
    @AppStorage("notifyOnWarning") var notifyOnWarning: Bool = true {
        didSet { if notifyOnWarning { Notifier.requestAuthorizationIfNeeded() } }
    }
    @AppStorage("weeklySummary") var weeklySummaryEnabled: Bool = true {
        didSet { if weeklySummaryEnabled { Notifier.requestAuthorizationIfNeeded() } }
    }
    /// Run `resumeCommand` once when the session limit frees up after being blocked.
    @AppStorage("autoResumeEnabled") var autoResumeEnabled: Bool = false {
        didSet { objectWillChange.send() }
    }
    /// User-authored shell command for auto-resume (off unless non-empty + enabled).
    @AppStorage("resumeCommand") var resumeCommand: String = "" {
        didSet { objectWillChange.send() }
    }
    /// Notify when you're pacing to leave a lot of the limit unused ("you could use more").
    @AppStorage("notifyUnderpace") var notifyUnderpace: Bool = false {
        didSet { objectWillChange.send() }
    }
    /// Keep the system awake while blocked so the reset (and auto-resume) isn't missed.
    @AppStorage("keepAwakeWhileBlocked") var keepAwakeWhileBlocked: Bool = false {
        didSet { objectWillChange.send(); updatePowerAssertion() }
    }
    private let sleepBlocker = PowerAssertion(reason: "ClaudeBar: 한도 리셋 대기")
    private func updatePowerAssertion() {
        sleepBlocker.set(keepAwakeWhileBlocked && isBlocked)
    }
    @AppStorage("barMetric") private var barMetricRaw: String = BarMetric.sessionLimit.rawValue {
        didSet { objectWillChange.send() }
    }
    @AppStorage("appearance") private var appearanceRaw: String = Appearance.system.rawValue {
        didSet { objectWillChange.send() }
    }
    var appearance: Appearance {
        get { Appearance(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }

    // Rising-edge state so each limit alert fires once per episode (see LimitAlerts).
    private var alertState = LimitAlertState()
    // Tracks whether we're in the tighter "near a limit" refresh cadence.
    private var lastUrgent = false

    var barMetric: BarMetric {
        get { BarMetric(rawValue: barMetricRaw) ?? .windowTokens }
        set { barMetricRaw = newValue.rawValue }
    }

    private var timer: Timer?
    private let reader = ClaudeDataReader()
    private let limitsClient = OAuthUsageClient()

    init() {
        if notifyOnWarning { Notifier.requestAuthorizationIfNeeded() }
        refresh()
        restartTimer()
    }

    /// Refresh local usage and (if enabled) the live limits. `force` bypasses the
    /// limits cache TTL — used when the user explicitly hits Refresh.
    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let reader = self.reader
        let client = self.limitsClient
        let live = enableLiveLimits
        // Always parse the cheap stats cache (for the menu-bar/weekly summary); skip
        // only the heavy session-log scan when the popover is closed and the bar metric
        // is a limit % (driven by `limits` alone).
        let full = popoverVisible || !barMetric.needsLiveLimits
        let previous = snapshot
        // Near a limit, fetch fresher data (shorter cache TTL) so the warning is
        // timely; when safe, stay gentle on the rate-limited endpoint.
        let ttl: TimeInterval = isAtLimitRisk ? 60 : OAuthUsageClient.cacheTTL
        Task {
            var snap = await Task.detached(priority: .utility) { reader.load(includeSessionLogs: full) }.value
            let lim: LimitsSnapshot? = live ? await client.loadLimits(force: force, ttl: ttl) : nil
            if !full { snap = snap.mergingSession(from: previous) }
            self.snapshot = snap
            if live { self.limits = lim } else { self.limits = nil }
            self.recomputeProjections()
            self.processLimitAlerts()
            self.maybeWeeklySummary()
            self.updatePowerAssertion()   // hold/release based on the fresh blocked state
            // If the risk level changed, re-arm the timer at the matching cadence.
            if self.isAtLimitRisk != self.lastUrgent {
                self.lastUrgent = self.isAtLimitRisk
                self.restartTimer()
            }
            self.isRefreshing = false
        }
    }

    @AppStorage("lastWeeklySummaryAt") private var lastWeeklySummaryAt: Double = 0

    /// Fire a weekly usage summary notification ~once every 7 days.
    private func maybeWeeklySummary() {
        guard weeklySummaryEnabled, let r = snapshot.weeklyReview else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastWeeklySummaryAt >= 7 * 86400 else { return }
        lastWeeklySummaryAt = now

        var body = "지난 7일 ~\(Fmt.usd(r.thisCost))"
        if let d = r.costDeltaPct {
            body += d >= 0 ? " · 전주 ▲\(Int(d.rounded()))%" : " · 전주 ▼\(Int(abs(d).rounded()))%"
        }
        body += " · Opus 비중 \(Int((r.opusShareThis * 100).rounded()))%"
        if let coaching = r.coaching { body += "\n\(coaching)" }
        Notifier.notify(title: "주간 사용 요약", body: body, id: "weekly-summary")
    }

    private func recomputeProjections() {
        guard enableLiveLimits else {
            sessionProjection = nil; weeklyProjection = nil; return
        }
        let now = Date()
        let samples = UsageHistory.load()
        // Session = rolling 5h window → recent burst rate. Weekly = fixed 7-day
        // bucket → realized average pace since the week started (not a burst).
        sessionProjection = Projection.compute(points: samples.compactMap { s in s.session.map { (s.at, $0) } },
                                               resetsAt: limits?.session5h?.resetsAt, now: now)
        if let w = limits?.weekly7d {
            weeklyProjection = Projection.paced(util: w.utilization, resetsAt: w.resetsAt,
                                                windowSeconds: 7 * 24 * 3600, now: now)
        } else {
            weeklyProjection = nil
        }
    }

    /// Evaluate the proactive limit alerts (threshold, trajectory, blocked, reset
    /// timing) once, then act: post notifications (if enabled) and run the optional
    /// auto-resume command when the limit frees up after a block.
    private func processLimitAlerts() {
        // Always evaluate so rising-edge state advances even when notifications are off.
        let alerts = LimitAlerts.evaluate(
            session: limits?.session5h, weekly: limits?.weekly7d,
            sessionProjection: sessionProjection, weeklyProjection: weeklyProjection,
            status: limits?.status, warnThreshold: warnThreshold,
            state: &alertState, now: Date())

        for a in alerts {
            // The under-pace nudge has its own opt-in toggle; everything else follows
            // the main warning toggle.
            let allowed = a.id == "pace-slow" ? notifyUnderpace : notifyOnWarning
            if allowed { Notifier.notify(title: a.title, body: a.body, id: a.id) }
        }
        // Auto-resume on the "freed after being blocked" reset (opt-in). With no
        // custom command, default to continuing the last conversation — so just
        // flipping the toggle is enough; no button press needed. Built + run off the
        // main actor (resolving the binary/dir spawns a short-lived process).
        if autoResumeEnabled, alerts.contains(where: { $0.id == "reset-after-block" }) {
            let custom = resumeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            Task.detached(priority: .utility) {
                // Empty → safe built-in (argv, no shell injection). Filled → the user's
                // own shell command (their responsibility), run via the login shell.
                if custom.isEmpty { ResumeCommand.runContinueLast() }
                else { CommandRunner.run(custom) }
            }
        }
    }

    /// Idle cadence when the popover is closed — kept at the limits cache TTL (180s)
    /// so the menu-bar warning icon stays reasonably fresh without scanning every 60s.
    /// Tightened to `urgentIdleInterval` while near a limit so the warning is timely.
    private static let idleInterval: TimeInterval = 180
    private static let urgentIdleInterval: TimeInterval = 60
    private var popoverVisible = false

    /// Driven by the popover's onAppear/onDisappear: refresh on open and use the
    /// user's interval while visible; back off to the idle cadence when closed.
    func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        if visible { refresh() }
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        guard refreshInterval > 0 else { return }
        let idle = isAtLimitRisk ? Self.urgentIdleInterval : Self.idleInterval
        let interval = popoverVisible ? refreshInterval : max(refreshInterval, idle)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Derived values for the bar label

    var barText: String {
        let s = snapshot
        switch barMetric {
        case .sessionLimit:
            if let u = limits?.session5h?.utilization { return "\(Int(u.rounded()))%" }
            return enableLiveLimits ? "—" : Fmt.tokens(s.windowTokens.total)
        case .weeklyLimit:
            if let u = limits?.weekly7d?.utilization { return "\(Int(u.rounded()))%" }
            return enableLiveLimits ? "—" : Fmt.tokens(s.windowTokens.total)
        case .bothLimits:
            let sPart = limits?.session5h.map { "S \(Int($0.utilization.rounded()))%" }
            let wPart = limits?.weekly7d.map { "W \(Int($0.utilization.rounded()))%" }
            let joined = [sPart, wPart].compactMap { $0 }.joined(separator: " · ")
            return joined.isEmpty ? (enableLiveLimits ? "—" : Fmt.tokens(s.windowTokens.total)) : joined
        case .windowTokens: return Fmt.tokens(s.windowTokens.total)
        case .windowCost:   return Fmt.usd(s.windowCost)
        case .todayTokens:  return Fmt.tokens(s.todayTokens.total)
        case .todayCost:    return Fmt.usd(s.todayCost)
        }
    }

    /// Dynamic, situational advice from the current projections + per-model burn.
    var adviceTips: [AdviceTip] {
        Advice.compute(session: sessionProjection, weekly: weeklyProjection,
                       sessionUtil: limits?.session5h?.utilization,
                       weeklyUtil: limits?.weekly7d?.utilization,
                       models: snapshot.windowByModel,
                       warnThreshold: warnThreshold,
                       now: snapshot.generatedAt)
    }

    /// Month-to-date spend vs the monthly budget, or nil when no budget is set.
    var budgetStatus: BudgetStatus? {
        guard monthlyBudget > 0 else { return nil }
        return Budget.status(history: snapshot.dailyCostHistory, now: Date(), budget: monthlyBudget)
    }

    /// Per-model burn comparison for the current 5-hour window.
    var modelBurnRows: [ModelBurnRow] {
        ModelBurn.rows(window: snapshot.windowByModel,
                       sessionUtil: limits?.session5h?.utilization,
                       basis: burnBasis)
    }

    /// Highest of the live session/weekly utilizations, or nil if unavailable.
    var maxLimitUtilization: Double? {
        let vals = [limits?.session5h?.utilization, limits?.weekly7d?.utilization].compactMap { $0 }
        return vals.max()
    }

    /// True when a live limit has crossed the warning threshold — drives the
    /// menu-bar warning icon/color.
    var isOverThreshold: Bool {
        (maxLimitUtilization ?? 0) >= Double(warnThreshold)
    }

    /// True when you're currently rate-limited: a `rejected` status or a window at
    /// 100%. Drives the menu-bar "blocked" glyph and red tint.
    var isBlocked: Bool {
        if limits?.status == "rejected" { return true }
        return (maxLimitUtilization ?? 0) >= 100
    }

    /// Whether we're close enough to a limit to warrant the tighter refresh cadence
    /// + fresher fetches: blocked, over the warn threshold, or projected to exhaust.
    var isAtLimitRisk: Bool {
        isBlocked || isOverThreshold || sessionProjection?.verdict == .atRisk
    }

    /// Menu-bar tint: green (safe) → orange (warning) → red (nearly out), based on
    /// the utilization relevant to the chosen bar metric.
    var barColor: Color {
        if isBlocked { return .red }
        let util: Double?
        switch barMetric {
        case .sessionLimit: util = limits?.session5h?.utilization
        case .weeklyLimit:  util = limits?.weekly7d?.utilization
        case .bothLimits:   util = maxLimitUtilization
        default:            return isOverThreshold ? .orange : .primary
        }
        guard let u = util else { return .primary }
        if u >= 95 { return .red }
        if u >= Double(warnThreshold) { return .orange }
        return .green
    }
}
