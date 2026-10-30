import Foundation
import SwiftUI
import Combine
import AppKit

/// Popover cards the user can show/hide and reorder (Settings → 섹션).
/// Declaration order is the default layout order.
/// Readings derived from the on-disk history files (cache-efficiency samples,
/// hourly burn history, notification log), cached per refresh cycle.
struct DiskReadings {
    var cacheEfficiencyTrend: CacheEfficiencyTrend.Verdict?
    var typicalHourRate: Double?
    var recentNotifications: [NotificationLogEntry] = []
}

enum PanelSection: String, CaseIterable, Identifiable {
    case advice, limits, efficiency, recent, perModel, modelGuide, sessions, today, weeklyReview, goals, notificationLog
    var id: String { rawValue }
    var label: String {
        switch self {
        case .advice:         return "조언"
        case .limits:         return "플랜 한도"
        case .efficiency:     return "효율"
        case .recent:         return "최근 5시간"
        case .perModel:       return "모델별 소진"
        case .modelGuide:     return "모델 가이드"
        case .sessions:       return "대화별"
        case .today:          return "오늘"
        case .weeklyReview:   return "주간 리뷰"
        case .goals:          return "습관 목표"
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
///
/// This core file holds every STORED property (Swift requires those in the
/// primary declaration, not extensions) plus `init()`. The behavior itself is
/// split across `UsageStore+Sections/Refresh/Notifications/Advice/Display.swift`
/// — each a plain `extension UsageStore` grouping one area of responsibility.
/// A few properties below are `internal` (not `private`) specifically because an
/// extension in another file needs to read/write them; that's a same-module
/// visibility relaxation only, nothing becomes public API.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var snapshot = UsageSnapshot.empty
    @Published var limits: LimitsSnapshot?
    @Published var sessionProjection: Projection?
    @Published var weeklyProjection: Projection?
    /// Recorded session-utilization samples within the current 5h window — the in-session
    /// usage trend ("how fast / how much am I burning right now").
    @Published var sessionTrend: [UsageSample] = []
    /// Weekly-utilization samples over the last ~8 days — the within-week usage trend.
    @Published var weeklyTrend: [UsageSample] = []
    /// Efficiency recap of every completed session in roughly the last 12h, oldest →
    /// newest — lets `Advice` compare consecutive sessions for a feast/famine swing.
    @Published var sessionRecapsToday: [SessionCoach.Recap] = []
    /// On-disk history readings, reloaded once per refresh — see `reloadDiskReadings()`.
    @Published var diskReadings = DiskReadings()
    /// The most-recently-completed session (for the learning loop) — always just
    /// `sessionRecapsToday.last`; kept as a computed property so the two can't
    /// drift out of sync the way two independently-set `@Published` vars could.
    var lastSessionRecap: SessionCoach.Recap? { sessionRecapsToday.last }
    /// "How much can I safely use today?" reading on the weekly limit.
    @Published var weeklyAllowance: DailyAllowance.Verdict?
    @Published var isRefreshing = false
    /// When the current/most-recent refresh cycle started — lets the Settings
    /// diagnostics panel tell "actively retrying but failing" apart from "hasn't
    /// tried in a while" (e.g. if `isRefreshing` were ever stuck, this timestamp
    /// would stop advancing — the smoking gun for exactly that class of bug).
    @Published var lastRefreshAttemptAt: Date?
    /// True when the live-limits fetch itself didn't finish within the timeout in
    /// the last cycle (see `withTimeout`) — the specific "a system call is hung"
    /// signature, distinct from an ordinary network/auth failure (which still
    /// returns promptly with `limits?.error` set).
    @Published var lastRefreshTimedOut = false

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
    /// Ad-hoc "quiet right now" snooze — epoch seconds until notifications are
    /// suppressed, 0 = not snoozed. Persisted (not just in-memory) so a quick app
    /// restart (e.g. an update) doesn't silently cancel it mid-focus-session. Not
    /// `private` — `UsageStore+Notifications.swift` (`toggleSnooze`, `isQuietNow`'s
    /// sibling logic) reads/writes it.
    @AppStorage("snoozeUntilEpoch") var snoozeUntilEpoch: Double = 0 {
        didSet { objectWillChange.send() }
    }
    static let snoozeDuration: TimeInterval = 2 * 3600

    /// Habit goal: keep Opus cost share at or below this %; 0 = off.
    @AppStorage("opusShareTarget") var opusShareTarget: Int = 0 {
        didSet { objectWillChange.send() }
    }
    /// Progressive disclosure for the 플랜 한도 card: collapsed by default shows
    /// just the badge + rings + hero line ("am I fine?"); this reveals the pace
    /// detail, full reset schedule, trend chart, and today's session history.
    @AppStorage("showLimitDetails") var showLimitDetails: Bool = false {
        didSet { objectWillChange.send() }
    }
    /// Comma-joined raw values of hidden sections. Default = lean: show only the
    /// core (advice, limits, recent, today); the analysis cards (per-model burn,
    /// model guide, per-session) are opt-in. Not `private` — `UsageStore+Sections.swift` reads/writes it.
    @AppStorage("hiddenSections") var hiddenSectionsRaw: String =
        "modelGuide,perModel,sessions,notificationLog" {
        didSet { objectWillChange.send() }
    }
    /// Comma-joined raw values defining card order (missing ones append in default
    /// order). Not `private` — `UsageStore+Sections.swift` reads/writes it.
    @AppStorage("sectionOrder") var sectionOrderRaw: String = "" {
        didSet { objectWillChange.send() }
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
    /// Notify when the dominant model in the 5h window looks downshift-worthy
    /// (top-tier model, but turns look light/moderate) — the same read as the
    /// in-app "모델·effort 회고" logic, promoted to a one-shot notification since
    /// it's a concrete, actionable cost lever. Off by default.
    @AppStorage("notifyModelDownshift") var notifyModelDownshift: Bool = false {
        didSet { objectWillChange.send() }
    }
    /// Heads-up ~10 min before a big conversation's prompt cache expires (see
    /// `CacheExpiry`). On by default: it targets the single biggest avoidable cost
    /// measured in real logs, and fires at most once per idle stretch.
    @AppStorage("notifyCacheExpiry") var notifyCacheExpiry: Bool = true {
        didSet { objectWillChange.send() }
    }
    /// When the downshift suggestion last fired — persisted so the rising-edge state
    /// resetting on every relaunch (or verdict flicker) can't repeat the same nudge
    /// daily (seen: 9× in 7 days, identical text).
    @AppStorage("modelDownshiftNotifiedAt") var modelDownshiftNotifiedAt: Double = 0
    static let modelDownshiftCooldown: TimeInterval = 3 * 86400
    /// Rising-edge state for `processModelDownshiftSuggestion` (`UsageStore+Notifications.swift`).
    var modelDownshiftState = ModelDownshiftSuggestion.State()
    /// A past "compact this conversation" nudge that then actually paid off —
    /// surfaced once as quiet positive reinforcement, not persisted across app
    /// restarts (same as `modelDownshiftState` above). Written from
    /// `processAdviceFollowThrough` in `UsageStore+Notifications.swift`.
    @Published var adviceWorkedTip: AdviceTip?
    struct AdviceFollowThroughState {
        var sessionId: String?
        var contextTokens = 0
        var at: Date?
    }
    var followThroughState = AdviceFollowThroughState()
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
    /// The popover is already bumped one step (.xLarge) for readability, but with
    /// many cards enabled it becomes a very tall, narrow column — screenshotted or
    /// viewed shrunk, the smallest body text (captions/notification log) can read
    /// as tiny/blurry even though it renders crisp at 100%. Opt-in second bump.
    @AppStorage("largeText") var largeText: Bool = false {
        didSet { objectWillChange.send() }
    }

    // Rising-edge state so each limit alert fires once per episode (see LimitAlerts).
    // Persisted so restarting the app (or installing an update) doesn't replay the
    // 50/75% weekly tiers and threshold alerts the user already got.
    var alertState: LimitAlertState = UsageStore.loadAlertState() {
        didSet { if alertState != oldValue { Self.saveAlertState(alertState) } }
    }
    private static let alertStateKey = "limitAlertState"
    private static func loadAlertState() -> LimitAlertState {
        guard let data = UserDefaults.standard.data(forKey: alertStateKey),
              let s = try? JSONDecoder().decode(LimitAlertState.self, from: data) else { return LimitAlertState() }
        return s.restoredForLaunch
    }
    private static func saveAlertState(_ s: LimitAlertState) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: alertStateKey) }
    }
    // Tracks whether we're in the tighter "near a limit" refresh cadence.
    var lastUrgent = false

    var barMetric: BarMetric {
        get { BarMetric(rawValue: barMetricRaw) ?? .windowTokens }
        set { barMetricRaw = newValue.rawValue }
    }

    var timer: Timer?
    let reader = ClaudeDataReader()
    let limitsClient = OAuthUsageClient()

    init() {
        if notifyOnWarning { Notifier.requestAuthorizationIfNeeded() }
        reloadDiskReadings()   // so the notification log etc. show before the first refresh completes
        ClaudeCredentials.removeLegacyTokenFile()   // no longer used; held a refresh token
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

    /// One-shot timer pinned just past the nearest limit-window reset, so the app
    /// notices the rollover (freed alert, auto-resume, fresh %) within seconds
    /// instead of waiting out the idle tick + cache TTL. See `UsageStore+Refresh.swift`.
    var resetBoundaryTimer: Timer?
    /// Fires ~10 min before the current conversation's prompt cache expires, to
    /// rescan the logs and (if still idle) post the heads-up — background refreshes
    /// alone are too coarse to land inside that window.
    var cacheExpiryTimer: Timer?
    /// "\(sessionId)@\(lastTurnAt)" of the last cache-expiry heads-up, so one idle
    /// stretch gets one notification.
    @AppStorage("cacheExpiryNotifiedKey") var cacheExpiryNotifiedKey: String = ""
    /// A refresh queued mid-cycle that must include the session-log scan.
    var pendingSessionScan = false
    /// The server can lag a few seconds past the predicted reset before it
    /// actually reflects the new window — the first forced refetch right after a
    /// reset can still come back with the OLD (now-expired) window. Without this,
    /// `scheduleResetBoundaryRefresh` would then only find a FUTURE reset to wait
    /// for (the next one, hours/days away) and fall back to the idle cadence —
    /// leaving the session ring missing from the popover for up to several
    /// minutes after every single reset. Bounded quick retries close that gap.
    var resetConfirmAttempts = 0
    static let maxResetConfirmAttempts = 6           // ~1 minute of quick retries
    static let resetConfirmRetryInterval: TimeInterval = 10
    /// A refresh requested while another cycle was in flight (e.g. the popover
    /// opening mid-cycle) — run once more when the current cycle finishes, instead
    /// of silently dropping it and showing a background cycle's carried-over data.
    var pendingRefresh = false
    /// Background cycles skip the session-log scan, but never for longer than this
    /// (and always after midnight), so carried-over "today"/window figures and the
    /// current-conversation id can't go stale indefinitely.
    static let maxSessionScanAge: TimeInterval = 30 * 60

    @AppStorage("lastWeeklySummaryAt") var lastWeeklySummaryAt: Double = 0
    /// Last-seen weekly-limit `resetsAt` (epoch seconds; 0 = never observed), to
    /// detect the moment the window actually rolls over (see `WeeklyResetRecap`)
    /// instead of firing on an arbitrary timer. Persisted: weekly resets usually
    /// land overnight while the app is quit — an in-memory marker would restart at
    /// nil, swallow the jump, and silently skip the recap.
    @AppStorage("lastSeenWeeklyResetsAt") var lastSeenWeeklyResetsAtEpoch: Double = 0

    var lastAutoResumeAt: Date?
    /// Guards against launching several `claude` processes in a short burst —
    /// observed after the reset-boundary retry (fires refresh(force:true) every
    /// ~10s near a reset): if "reset-after-block" ends up qualifying on more than
    /// one of those quick retries, each would otherwise independently relaunch
    /// the resume command, and if that command itself reads the shared Keychain
    /// credential (Claude Code's CLI does, via a `security` subprocess — a
    /// different requesting process than CBar, so it needs its own Keychain
    /// grant), several concurrent launches show up as several stacked
    /// "security..." access prompts. One resume attempt per cooldown window is
    /// enough; a genuinely new block-then-reset cycle is always well outside it.
    static let autoResumeCooldown: TimeInterval = 90

    /// Idle cadence when the popover is closed — deliberately looser than the
    /// limits cache TTL (180s): when nothing is at risk there's no need to wake up
    /// and hit the network/disk that often just to keep a background number fresh
    /// a user isn't even looking at right now. Tightened to `urgentIdleInterval`
    /// while near a limit so the warning icon still stays timely.
    static let idleInterval: TimeInterval = 300
    static let urgentIdleInterval: TimeInterval = 60
    var popoverVisible = false
}
