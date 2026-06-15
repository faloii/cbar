import Foundation
import SwiftUI
import Combine

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
    @AppStorage("fiveHourTokenBudget") var fiveHourTokenBudget: Int = 100_000_000 {
        didSet { objectWillChange.send() }
    }
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
    @AppStorage("notifyOnWarning") var notifyOnWarning: Bool = false {
        didSet { if notifyOnWarning { Notifier.requestAuthorizationIfNeeded() } }
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

    // Rising-edge tracking so a notification fires once per threshold crossing.
    private var notifiedSession = false
    private var notifiedWeekly = false

    var barMetric: BarMetric {
        get { BarMetric(rawValue: barMetricRaw) ?? .windowTokens }
        set { barMetricRaw = newValue.rawValue }
    }

    private var timer: Timer?
    private let reader = ClaudeDataReader()
    private let limitsClient = OAuthUsageClient()

    init() {
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
        Task {
            let snap = await Task.detached(priority: .utility) { reader.load() }.value
            let lim: LimitsSnapshot? = live ? await client.loadLimits(force: force) : nil
            self.snapshot = snap
            if live { self.limits = lim } else { self.limits = nil }
            self.recomputeProjections()
            self.maybeNotify()
            self.isRefreshing = false
        }
    }

    private func recomputeProjections() {
        guard enableLiveLimits else { sessionProjection = nil; weeklyProjection = nil; return }
        let now = Date()
        sessionProjection = Projection.compute(points: UsageHistory.sessionPoints(),
                                               resetsAt: limits?.session5h?.resetsAt, now: now)
        weeklyProjection = Projection.compute(points: UsageHistory.weeklyPoints(),
                                              resetsAt: limits?.weekly7d?.resetsAt, now: now)
    }

    /// Fire a macOS notification once when a limit first crosses the threshold.
    private func maybeNotify() {
        guard notifyOnWarning else { return }
        let t = Double(warnThreshold)

        func check(_ window: LimitWindow?, name: String, key: String, flag: inout Bool) {
            guard let u = window?.utilization else { return }
            if u >= t, !flag {
                flag = true
                Notifier.notify(title: "\(name) 한도 \(Int(u.rounded()))%",
                                body: "\(name) 한도의 \(warnThreshold)%를 넘었습니다.",
                                id: "limit-\(key)")
            } else if u < t {
                flag = false
            }
        }
        check(limits?.session5h, name: "세션", key: "session", flag: &notifiedSession)
        check(limits?.weekly7d, name: "주간", key: "weekly", flag: &notifiedWeekly)
    }

    private func restartTimer() {
        timer?.invalidate()
        guard refreshInterval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
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

    /// 0...1 fill of the 5-hour window meter against the configured budget.
    var windowFraction: Double {
        guard fiveHourTokenBudget > 0 else { return 0 }
        return min(1, Double(snapshot.windowTokens.total) / Double(fiveHourTokenBudget))
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
}
