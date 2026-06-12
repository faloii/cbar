import Foundation
import SwiftUI
import Combine

/// What the menu-bar label shows at a glance.
enum BarMetric: String, CaseIterable, Identifiable {
    case sessionLimit, weeklyLimit, windowTokens, windowCost, todayTokens, todayCost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sessionLimit: return "Session limit %"
        case .weeklyLimit:  return "Weekly limit %"
        case .windowTokens: return "5h tokens"
        case .windowCost:   return "5h cost"
        case .todayTokens:  return "Today tokens"
        case .todayCost:    return "Today cost"
        }
    }
    /// Whether this metric needs the live `/usage` data.
    var needsLiveLimits: Bool { self == .sessionLimit || self == .weeklyLimit }
}

/// Owns the current snapshot, the refresh timer, and user settings.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var limits: LimitsSnapshot?
    @Published private(set) var isRefreshing = false

    @AppStorage("refreshIntervalSeconds") var refreshInterval: Double = 60 {
        didSet { restartTimer() }
    }
    @AppStorage("fiveHourTokenBudget") var fiveHourTokenBudget: Int = 100_000_000
    @AppStorage("enableLiveLimits") var enableLiveLimits: Bool = true {
        didSet { refresh(force: true) }
    }
    @AppStorage("barMetric") private var barMetricRaw: String = BarMetric.sessionLimit.rawValue

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
            self.isRefreshing = false
        }
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
}
