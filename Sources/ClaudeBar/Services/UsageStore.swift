import Foundation
import SwiftUI
import Combine
import AppKit

/// Popover cards the user can show/hide and reorder (Settings → 섹션).
/// Declaration order is the default layout order.
enum PanelSection: String, CaseIterable, Identifiable {
    case advice, limits, efficiency, recent, perModel, modelGuide, modelRecap, sessions, today, weeklyReview, goals, budget, notificationLog
    var id: String { rawValue }
    var label: String {
        switch self {
        case .advice:         return "조언"
        case .limits:         return "플랜 한도"
        case .efficiency:     return "효율"
        case .recent:         return "최근 5시간"
        case .perModel:       return "모델별 소진"
        case .modelGuide:     return "모델 가이드"
        case .modelRecap:     return "모델·effort 회고"
        case .sessions:       return "세션별"
        case .today:          return "오늘"
        case .weeklyReview:   return "주간 리뷰"
        case .goals:          return "습관 목표"
        case .budget:         return "월 예산"
        case .notificationLog: return "최근 알림"
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
    /// Recorded session-utilization samples within the current 5h window — the in-session
    /// usage trend ("how fast / how much am I burning right now").
    @Published private(set) var sessionTrend: [UsageSample] = []
    /// Weekly-utilization samples over the last ~8 days — the within-week usage trend.
    @Published private(set) var weeklyTrend: [UsageSample] = []
    /// Efficiency recap of the most-recently-completed session (for the learning loop).
    @Published private(set) var lastSessionRecap: SessionCoach.Recap?
    /// "How much can I safely use today?" reading on the weekly limit.
    @Published private(set) var weeklyAllowance: DailyAllowance.Verdict?
    @Published private(set) var isRefreshing = false
    /// When the current/most-recent refresh cycle started — lets the Settings
    /// diagnostics panel tell "actively retrying but failing" apart from "hasn't
    /// tried in a while" (e.g. if `isRefreshing` were ever stuck, this timestamp
    /// would stop advancing — the smoking gun for exactly that class of bug).
    @Published private(set) var lastRefreshAttemptAt: Date?
    /// True when the live-limits fetch itself didn't finish within the timeout in
    /// the last cycle (see `withTimeout`) — the specific "a system call is hung"
    /// signature, distinct from an ordinary network/auth failure (which still
    /// returns promptly with `limits?.error` set).
    @Published private(set) var lastRefreshTimedOut = false

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
    /// How many minutes before a projected session block to fire the imminent warning.
    @AppStorage("blockWarnLeadMinutes") var blockWarnLeadMinutes: Int = 30 {
        didSet { objectWillChange.send() }
    }
    /// Suppress notification banners during a daily window (the in-app UI still
    /// reflects real state) — a "quiet coach" shouldn't ping overnight.
    @AppStorage("quietHoursEnabled") var quietHoursEnabled: Bool = false {
        didSet { objectWillChange.send() }
    }
    @AppStorage("quietHoursStart") var quietHoursStart: Int = 22 {
        didSet { objectWillChange.send() }
    }
    @AppStorage("quietHoursEnd") var quietHoursEnd: Int = 8 {
        didSet { objectWillChange.send() }
    }
    /// Ad-hoc "quiet right now" snooze — epoch seconds until notifications are
    /// suppressed, 0 = not snoozed. Persisted (not just in-memory) so a quick app
    /// restart (e.g. an update) doesn't silently cancel it mid-focus-session.
    @AppStorage("snoozeUntilEpoch") private var snoozeUntilEpoch: Double = 0 {
        didSet { objectWillChange.send() }
    }
    static let snoozeDuration: TimeInterval = 2 * 3600

    var snoozeUntil: Date? { snoozeUntilEpoch > 0 ? Date(timeIntervalSince1970: snoozeUntilEpoch) : nil }
    var isSnoozed: Bool { snoozeUntil.map { Date() < $0 } ?? false }

    /// One-tap toggle for the header button: snooze for `snoozeDuration`, or cancel
    /// early if already snoozed.
    func toggleSnooze() {
        snoozeUntilEpoch = isSnoozed ? 0 : Date().addingTimeInterval(Self.snoozeDuration).timeIntervalSince1970
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
        "modelGuide,modelRecap,perModel,sessions,notificationLog" {
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
    /// Notify when the conversation you're CURRENTLY in gets heavy (big context +
    /// mostly re-reading old turns) — a nudge for THIS session, not just an in-app
    /// stat. While on, forces a full session-log scan every refresh tick (see the
    /// `full` gate in `refresh()`) so this stays timely without requiring the
    /// popover to be open. Off by default — this is an efficiency nudge, not a
    /// limit warning.
    @AppStorage("notifyCompactSuggestion") var notifyCompactSuggestion: Bool = false {
        didSet { objectWillChange.send() }
    }
    private var compactSuggestState = CompactSuggestion.State()
    /// Notify when the dominant model in the 5h window looks downshift-worthy
    /// (top-tier model, but turns look light/moderate) — the same read as the
    /// in-app "모델·effort 회고" card, promoted to a one-shot notification since
    /// it's a concrete, actionable cost lever. Off by default.
    @AppStorage("notifyModelDownshift") var notifyModelDownshift: Bool = false {
        didSet { objectWillChange.send() }
    }
    private var modelDownshiftState = ModelDownshiftSuggestion.State()
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
    /// Shown once, the very first time the popover opens on a fresh install —
    /// colleagues receiving a shared build see a dense stats panel with no
    /// context otherwise. Dismissing it persists so it never reappears.
    @AppStorage("hasSeenOnboarding") var hasSeenOnboarding: Bool = false {
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
        // A plain Timer doesn't fire while the Mac sleeps, so the first tick after
        // lid-open could be minutes away — refresh immediately on wake instead.
        // NOT `force: true`: after any real sleep the cache TTL (60-180s) has long
        // since lapsed anyway, so this still fetches fresh; forcing would only
        // matter for a sleep shorter than the TTL, where it'd uselessly bypass a
        // still-fresh cache. Waking is also the moment the login Keychain is most
        // likely to be locked again, so skip forcing a Keychain-touching fetch here.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        restartTimer()
    }

    /// Live-limit windows filtered through their reset boundary: once `resetsAt`
    /// passes, the cached reading describes the PREVIOUS window (possibly "blocked
    /// at 100%" held all night through sleep) — treat it as unknown until the next
    /// fetch instead of displaying it as current truth.
    var liveSession: LimitWindow? {
        limits?.session5h.flatMap { $0.expired(asOf: Date()) ? nil : $0 }
    }
    var liveWeekly: LimitWindow? {
        limits?.weekly7d.flatMap { $0.expired(asOf: Date()) ? nil : $0 }
    }

    /// One-shot timer pinned just past the nearest limit-window reset, so the app
    /// notices the rollover (freed alert, auto-resume, fresh %) within seconds
    /// instead of waiting out the idle tick + cache TTL.
    private var resetBoundaryTimer: Timer?
    private func scheduleResetBoundaryRefresh() {
        resetBoundaryTimer?.invalidate()
        resetBoundaryTimer = nil
        let now = Date()
        guard let next = [limits?.session5h?.resetsAt, limits?.weekly7d?.resetsAt]
            .compactMap({ $0 }).filter({ $0 > now }).min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        resetBoundaryTimer = timer
    }

/// Races `operation` against a timeout so a hung call deep in the awaited chain can't
    /// block the caller forever — observed cause: macOS's Keychain `SecItemCopyMatching`
    /// blocks indefinitely while a system authorization dialog is pending, and if that
    /// fires while the Mac is asleep/locked (nobody around to answer it), it never
    /// returns. The abandoned call keeps running in the background (harmless — its
    /// result, if it ever arrives, is simply discarded) so this only stops *waiting*,
    /// it doesn't cancel the underlying work.
    private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                          operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Refresh local usage and (if enabled) the live limits. `force` bypasses the
    /// limits cache TTL — used when the user explicitly hits Refresh.
    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshAttemptAt = Date()
        let reader = self.reader
        let client = self.limitsClient
        let live = enableLiveLimits
        // Always parse the cheap stats cache (for the menu-bar/weekly summary); skip
        // only the heavy session-log scan when the popover is closed and the bar metric
        // is a limit % (driven by `limits` alone). Exception: the "current conversation
        // got heavy" nudge needs `currentSessionId` to stay fresh to be worth anything,
        // so keep scanning every tick while that's on (the per-file parse cache makes
        // repeat scans cheap — only the most recently modified log actually reparses).
        let full = popoverVisible || !barMetric.needsLiveLimits || notifyCompactSuggestion
        let previous = snapshot
        // Near a limit, fetch fresher data (shorter cache TTL) so the warning is
        // timely; when safe, stay gentle on the rate-limited endpoint.
        let ttl: TimeInterval = isAtLimitRisk ? 60 : OAuthUsageClient.cacheTTL
        Task {
            // Timeout-wrapped too (not just the live-limits fetch below): this is
            // plain file I/O and shouldn't hang, but "shouldn't" is exactly what we
            // assumed about the Keychain call before finding out otherwise — nothing
            // in this Task may block `isRefreshing` from resetting indefinitely.
            if let loaded = await self.withTimeout(seconds: 20, operation: {
                await Task.detached(priority: .utility) { reader.load(includeSessionLogs: full) }.value
            }) {
                var snap = loaded
                if !full { snap = snap.mergingSession(from: previous) }
                self.snapshot = snap
            }
            if live {
                // 20s: comfortably past the network layer's own 15s timeout, so this
                // only ever kicks in for the un-timeoutable case (a blocked Keychain
                // prompt). On timeout, deliberately leave `self.limits` untouched
                // (not nil'd) — this cycle produced nothing new, not "no data."
                if let fresh = await self.withTimeout(seconds: 20, operation: { await client.loadLimits(force: force, ttl: ttl) }) {
                    self.limits = fresh
                    self.lastRefreshTimedOut = false
                } else {
                    self.lastRefreshTimedOut = true
                }
            } else {
                self.limits = nil
                self.lastRefreshTimedOut = false
            }
            self.scheduleResetBoundaryRefresh()
            self.recomputeProjections()
            self.processLimitAlerts()
            self.processCompactSuggestion()
            self.processModelDownshiftSuggestion()
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
    /// Last-seen weekly-limit `resetsAt` (epoch seconds; 0 = never observed), to
    /// detect the moment the window actually rolls over (see `WeeklyResetRecap`)
    /// instead of firing on an arbitrary timer. Persisted: weekly resets usually
    /// land overnight while the app is quit — an in-memory marker would restart at
    /// nil, swallow the jump, and silently skip the recap.
    @AppStorage("lastSeenWeeklyResetsAt") private var lastSeenWeeklyResetsAtEpoch: Double = 0
    private var lastSeenWeeklyResetsAt: Date? {
        get { lastSeenWeeklyResetsAtEpoch > 0 ? Date(timeIntervalSince1970: lastSeenWeeklyResetsAtEpoch) : nil }
        set { lastSeenWeeklyResetsAtEpoch = newValue?.timeIntervalSince1970 ?? 0 }
    }

    /// Fire a weekly usage recap notification: once per real weekly-limit reset
    /// when live limits are on (so the recap lands right when last week wraps up),
    /// falling back to a rolling ~7-day timer when they're off (no reset to observe).
    private func maybeWeeklySummary() {
        guard weeklySummaryEnabled, let r = snapshot.weeklyReview else { return }
        let newResetsAt = limits?.weekly7d?.resetsAt
        if enableLiveLimits, newResetsAt != nil {
            guard WeeklyResetRecap.justReset(old: lastSeenWeeklyResetsAt, new: newResetsAt) else {
                lastSeenWeeklyResetsAt = newResetsAt
                return
            }
        } else {
            guard Date().timeIntervalSince1970 - lastWeeklySummaryAt >= 7 * 86400 else { return }
        }
        // Quiet hours/snooze: leave the reset "unconsumed" so this is retried (not
        // lost) on the next non-quiet tick, rather than silently skipping the week.
        guard !isQuietNow(Date()) else { return }
        lastSeenWeeklyResetsAt = newResetsAt
        lastWeeklySummaryAt = Date().timeIntervalSince1970

        var body = "지난 7일 ~\(Fmt.usd(r.thisCost))"
        if let d = r.costDeltaPct {
            body += d >= 0 ? " · 전주 ▲\(Int(d.rounded()))%" : " · 전주 ▼\(Int(abs(d).rounded()))%"
        }
        body += " · Opus 비중 \(Int((r.opusShareThis * 100).rounded()))%"
        if let ce = CacheEfficiency.verdict(snapshot.weeklyTokens) {
            body += " · 재읽기 \(Int((ce.cacheReadShare * 100).rounded()))%"
        }
        if let top = snapshot.weeklyProjectUsage.first {
            body += " · 최다 사용 \(top.project)"
        }
        if let coaching = r.coaching { body += "\n\(coaching)" }
        Notifier.notify(title: "주간 마감 리캡", body: body, id: "weekly-summary", urgency: .fyi)
    }

    /// Notify once when the dominant model in the 5h window newly looks
    /// downshift-worthy — see `ModelDownshiftSuggestion`. Independent of the
    /// limit-alert system: this is a cost-efficiency nudge, not a quota warning,
    /// so it has its own opt-in toggle.
    private func processModelDownshiftSuggestion() {
        guard notifyModelDownshift, enableLiveLimits else { return }
        guard ModelDownshiftSuggestion.shouldNotify(modelRecap, state: &modelDownshiftState) else { return }
        guard !isQuietNow(Date()), let v = modelRecap, let to = v.downshiftTo else { return }
        let savingPct = Int(((v.downshiftSaving ?? 0) * 100).rounded())
        Notifier.notify(
            title: "\(v.model) 대신 \(to)면 충분해 보여요",
            body: "최근 턴 출력이 가벼운 편이에요 — \(to)로 바꾸면 이 창에서 비용 \(savingPct)% 절감돼요 (한도 소모량은 동일).",
            id: "model-downshift-\(v.model)", urgency: .nudge, category: .limit)
    }

    private func recomputeProjections() {
        guard enableLiveLimits else {
            sessionProjection = nil; weeklyProjection = nil; sessionTrend = []; weeklyTrend = []
            lastSessionRecap = nil; weeklyAllowance = nil; return
        }
        let now = Date()
        let samples = UsageHistory.load()
        // Session-window trend: samples with a session reading from the last 5h, oldest→newest.
        let cutoff = now.addingTimeInterval(-5 * 3600)
        sessionTrend = samples.filter { $0.session != nil && $0.at >= cutoff }.sorted { $0.at < $1.at }
        // Weekly trend: from the coarser, longer-retention store (8 days), not the
        // short-lived `UsageHistory` ring buffer.
        weeklyTrend = WeeklyHistory.load().filter { $0.weekly != nil }.sorted { $0.at < $1.at }
        lastSessionRecap = SessionCoach.lastSessionRecap(samples: samples, now: now)
        // Session = rolling 5h window → recent burst rate.
        sessionProjection = Projection.compute(points: samples.compactMap { s in s.session.map { (s.at, $0) } },
                                               resetsAt: liveSession?.resetsAt, now: now)
        if let w = liveWeekly {
            // Weekly = fixed 7-day bucket → realized average pace since the week started,
            // blended with a short-burst trajectory so a fast start doesn't go unnoticed
            // for the first 6h (see `Projection.combinedWeekly`).
            let weeklyPoints = samples.compactMap { s in s.weekly.map { (s.at, $0) } }
            weeklyProjection = Projection.combinedWeekly(points: weeklyPoints, util: w.utilization,
                                                          resetsAt: w.resetsAt,
                                                          windowSeconds: 7 * 24 * 3600, now: now)
            let midnight = Calendar.current.startOfDay(for: now)
            // Baseline from the 8-day WeeklyHistory, not the ~12h UsageHistory ring
            // buffer — by afternoon that buffer has evicted every pre-midnight sample
            // and "오늘 사용" silently vanished exactly when it mattered most.
            let todayStartUtil = DailyAllowance.todayBaseline(
                points: weeklyTrend.compactMap { s in s.weekly.map { (at: s.at, util: $0) } },
                midnight: midnight)
            weeklyAllowance = DailyAllowance.verdict(util: w.utilization, resetsAt: w.resetsAt, now: now,
                                                     todayStartUtil: todayStartUtil)
        } else {
            weeklyProjection = nil
            weeklyAllowance = nil
        }
    }

    /// Evaluate the proactive limit alerts (threshold, trajectory, blocked, reset
    /// timing) once, then act: post notifications (if enabled) and run the optional
    /// auto-resume command when the limit frees up after a block.
    private func processLimitAlerts() {
        let now = Date()
        // Always evaluate so rising-edge state advances even when notifications are off.
        let alerts = LimitAlerts.evaluate(
            session: limits?.session5h, weekly: limits?.weekly7d,
            sessionProjection: sessionProjection, weeklyProjection: weeklyProjection,
            status: limits?.status, warnThreshold: warnThreshold,
            blockWarnLeadMinutes: blockWarnLeadMinutes,
            state: &alertState, now: now)

        // The under-pace nudge has its own opt-in toggle; everything else follows
        // the main warning toggle.
        let toPost = alerts.filter { $0.id == "pace-slow" ? notifyUnderpace : notifyOnWarning }
        if !isQuietNow(now) {
            // Bundle same-tick alerts into one notification so a stack of separate
            // triggers (e.g. skipping two weekly tiers at once) doesn't post a stack
            // of separate banners.
            for a in NotificationBundler.bundle(toPost) {
                // "한도 풀렸어요" gets a one-tap resume action; every other limit
                // nudge/danger gets a one-tap snooze — fyi (the weekly recap, posted
                // separately) carries neither, nothing to act on right now.
                let category: Notifier.Category? =
                    a.id.contains("reset-after-block") ? .freed : (a.urgency != .fyi ? .limit : nil)
                Notifier.notify(title: a.title, body: a.body, id: a.id, urgency: a.urgency, category: category)
            }
        }
        // Auto-resume on the "freed after being blocked" reset (opt-in). With no
        // custom command, default to continuing the last conversation — so just
        // flipping the toggle is enough; no button press needed.
        if autoResumeEnabled, alerts.contains(where: { $0.id == "reset-after-block" }) {
            resumeNow()
        }
    }

    /// Runs the configured resume command (or the built-in "continue last
    /// conversation" default) right now — the auto-resume toggle's action, also
    /// triggered manually via the "지금 이어가기" notification button. Off the main
    /// actor since resolving the binary/dir spawns a short-lived process.
    func resumeNow() {
        let custom = resumeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached(priority: .utility) {
            // Empty → safe built-in (argv, no shell injection). Filled → the user's
            // own shell command (their responsibility), run via the login shell.
            if custom.isEmpty { ResumeCommand.runContinueLast() }
            else { CommandRunner.run(custom) }
        }
    }

    /// Whether proactive notifications should be suppressed right now (ad-hoc
    /// snooze or the scheduled quiet-hours window) — the in-app UI keeps reflecting
    /// real state regardless.
    private func isQuietNow(_ now: Date) -> Bool {
        isSnoozed
            || (quietHoursEnabled
                && QuietHours.isQuiet(hour: Calendar.current.component(.hour, from: now),
                                      start: quietHoursStart, end: quietHoursEnd))
    }

    /// Notify once when the conversation you're CURRENTLY in (best-effort: whichever
    /// session log was touched most recently) crosses into "heavy" — see
    /// `CompactSuggestion`. Independent of the limit-alert system: this is about
    /// conversation efficiency, not quota, so it has its own opt-in toggle.
    private func processCompactSuggestion() {
        guard notifyCompactSuggestion, enableLiveLimits else { return }
        let current = snapshot.recentSessions.first { $0.sessionId == snapshot.currentSessionId }
        guard CompactSuggestion.shouldNotify(current: current, state: &compactSuggestState) else { return }
        guard !isQuietNow(Date()), let s = current else { return }
        Notifier.notify(
            title: "이 대화, 슬슬 무거워요",
            body: "컨텍스트 ~\(Fmt.tokens(s.lastContextTokens)) · 재읽기 \(Int((s.cacheReadShare * 100).rounded()))% — /compact 하면 같은 한도로 더 오래 가요.",
            id: "compact-suggest-\(s.sessionId)", urgency: .nudge, category: .limit)
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

    /// The session part of the bar label: self-warns "막힘 50m" (time until you'll hit
    /// the cap) when on track to block before reset, "막힘" when already blocked, else
    /// the plain %. So you see trouble coming without opening the popover.
    private func sessionBarText(util: Double) -> String {
        if util >= 100 { return "막힘 100%" }
        if let b = sessionWorkBudget, b.willBlock, let at = b.blockAt {
            return "막힘 \(Fmt.shortCountdown(to: at, from: Date())) · \(Int(util.rounded()))%"
        }
        return "\(Int(util.rounded()))%"
    }

    /// The weekly part of the bar label — mirrors `sessionBarText`'s "막힘 Nh/Nd"
    /// self-warning. A weekly block is the expensive one (days, not hours), so
    /// seeing it coming without opening the popover matters just as much here.
    private func weeklyBarText(util: Double) -> String {
        if util >= 100 { return "막힘 100%" }
        if let p = weeklyProjection, p.verdict == .atRisk, let ttf = p.timeToFull {
            return "막힘 \(Fmt.shortCountdown(to: Date().addingTimeInterval(ttf), from: Date())) · \(Int(util.rounded()))%"
        }
        return "\(Int(util.rounded()))%"
    }

    /// When the OTHER limit window (not the one the bar is showing) is past the
    /// warn threshold, surface it compactly — otherwise the bar can raise a warning
    /// triangle for a window whose number isn't even on screen.
    private func crossWindowSuffix(other: LimitWindow?, prefix: String) -> String {
        guard let u = other?.utilization, u >= Double(warnThreshold) else { return "" }
        return " · \(prefix)\(Int(u.rounded()))%"
    }

    /// Menu-bar space is shared with the system's other extras, and a "막힘 6d
    /// 23h"-style primary reading is already long — drop the cross-window suffix
    /// rather than let the label balloon past a sane budget.
    private static let maxBarTextLength = 16
    private func withCrossWindowSuffix(_ primary: String, other: LimitWindow?, prefix: String) -> String {
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

    /// Dynamic, situational advice from the current projections + per-model burn.
    var adviceTips: [AdviceTip] {
        var tips = Advice.compute(session: sessionProjection, weekly: weeklyProjection,
                       sessionUtil: liveSession?.utilization,
                       weeklyUtil: liveWeekly?.utilization,
                       models: snapshot.windowByModel,
                       contextTokens: snapshot.currentContextTokens,
                       warnThreshold: warnThreshold,
                       now: snapshot.generatedAt)
        if let a = burnAnomaly {
            let multText = a.multiplier >= 10 ? "10배 넘게" : String(format: "%.1f배", a.multiplier)
            tips.insert(AdviceTip(kind: .burnAnomaly, level: .warn, icon: "flame",
                text: "오늘 이 페이스면 평소(하루 ~\(Fmt.usd(a.typicalDailyCost))) 대비 \(multText) 쓰게 돼요"
                    + "(예상 ~\(Fmt.usd(a.projectedToday))). 계획한 작업이면 괜찮지만, 아니라면 한번 확인해보세요."),
                at: 0)
        }
        return Array(tips.prefix(3))
    }

    /// Multi-week "is your plan tier a good fit" read — see `PlanFitSignal`. Needs
    /// several completed weeks of live-limit history, so this stays nil for a
    /// while after a fresh install (nothing dishonest to say yet).
    var planFitSignal: PlanFitSignal.Result? {
        let peaks = PlanFitSignal.weeklyPeaks(samples: weeklyTrend, now: Date(), weeks: 5)
        return PlanFitSignal.evaluate(weeklyPeaks: peaks)
    }

    /// Per-project forward-looking share of the weekly limit — see `ProjectWeeklyForecast`.
    var projectWeeklyForecast: [ProjectWeeklyForecast.Item] {
        guard let w = liveWeekly, let allowance = weeklyAllowance else { return [] }
        return ProjectWeeklyForecast.forecast(projects: snapshot.weeklyProjectUsage,
                                              weeklyUtilPct: w.utilization,
                                              daysRemaining: allowance.daysRemaining)
    }

    /// "You're burning unusually fast today, FOR YOU" — a personal-baseline nudge
    /// (see `BurnAnomaly`), distinct from the fixed-threshold advice above.
    var burnAnomaly: BurnAnomaly.Verdict? {
        let now = snapshot.generatedAt
        let todayStr = DateParse.dayString(now)
        let hoursElapsed = now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 3600
        let past = snapshot.dailyCostHistory.filter { $0.date != todayStr }.map(\.cost)
        return BurnAnomaly.verdict(todayCost: snapshot.todayCost, hoursElapsedToday: hoursElapsed, pastDailyCosts: past)
    }

    /// Month-to-date spend vs the monthly budget, or nil when no budget is set.
    var budgetStatus: BudgetStatus? {
        guard monthlyBudget > 0 else { return nil }
        return Budget.status(history: snapshot.dailyCostHistory, now: Date(), budget: monthlyBudget)
    }

    /// Diagnostics panel's manual fix: clears the cached access token (forcing a
    /// fresh Keychain read next time) and any exponential backoff, then retries
    /// immediately — for when the automatic recovery (timeout + next tick) isn't
    /// enough and the user just wants to force a clean attempt right now.
    func resetCredentialsAndRetry() {
        ClaudeCredentials.invalidate()
        OAuthUsageClient.resetBackoff()
        // Force-clear a possibly-stuck in-flight cycle: this button exists
        // specifically for when the automatic recovery hasn't kicked in, so it
        // must not be silently swallowed by refresh()'s own `!isRefreshing` guard
        // the way every other caller correctly is. Safe — the abandoned old Task,
        // if one is still running, simply has its result discarded when it
        // eventually (if ever) finishes, same as any other timed-out cycle.
        isRefreshing = false
        refresh(force: true)
    }

    /// Whether the live-limits endpoint is currently being backed off from after
    /// consecutive failures, and when the next attempt is allowed — see
    /// `OAuthUsageClient.backoffStatus()`.
    var liveLimitsBackoff: (isBackingOff: Bool, retryAt: Date?) { OAuthUsageClient.backoffStatus() }

    /// The last few notifications CBar has posted (newest first) — a safety net
    /// for passive/no-banner ones and anything missed while away. See `NotificationLog`.
    var recentNotifications: [NotificationLogEntry] { NotificationLog.load().reversed() }

    /// Per-model burn comparison for the current 5-hour window.
    var modelBurnRows: [ModelBurnRow] {
        ModelBurn.rows(window: snapshot.windowByModel,
                       sessionUtil: limits?.session5h?.utilization,
                       basis: burnBasis)
    }

    /// Retrospective right-sizing read on the dominant model in the 5h window.
    var modelRecap: ModelRecap.Verdict? {
        ModelRecap.verdict(window: snapshot.windowByModel)
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
    /// 100%. Drives the menu-bar "blocked" glyph, red tint, and the keep-awake
    /// assertion. A cached `rejected` is only trusted while some un-expired window
    /// backs it — a stale overnight "blocked" otherwise held keep-awake all night
    /// for a limit that had already reset.
    var isBlocked: Bool {
        if (maxLimitUtilization ?? 0) >= 100 { return true }
        return limits?.status == "rejected" && (liveSession != nil || liveWeekly != nil)
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
        let shown: Double?
        switch barMetric {
        case .sessionLimit: shown = liveSession?.utilization
        case .weeklyLimit:  shown = liveWeekly?.utilization
        case .bothLimits:   shown = maxLimitUtilization
        default:            return isOverThreshold ? .orange : .primary
        }
        // The warning glyph keys on the WORST window (isOverThreshold) — don't let
        // the tint contradict it by following only the displayed metric (a safe-green
        // "12%" next to a triangle raised by the weekly window at 85%).
        let effective: Double? = isOverThreshold ? max(shown ?? 0, maxLimitUtilization ?? 0) : shown
        guard let u = effective else { return .primary }
        if u >= 95 { return .red }
        if u >= Double(warnThreshold) { return .orange }
        return .green
    }
}
