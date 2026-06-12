import SwiftUI

/// The popover shown when the menu-bar icon is clicked.
struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    private var snap: UsageSnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if store.enableLiveLimits {
                Divider()
                limitsSection
            }
            Divider()
            windowSection
            if !store.modelBurnRows.isEmpty {
                Divider()
                perModelSection
            }
            Divider()
            todaySection
            if !snap.dailyTokenHistory.isEmpty {
                Divider()
                trendSection
            }
            Divider()
            lifetimeSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "sparkle")
                .foregroundStyle(.orange)
            Text("ClaudeBar").font(.headline)
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: store.isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
    }

    @ViewBuilder
    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Plan Limits")
                Spacer()
                if let l = store.limits, l.stale {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.caption2).foregroundStyle(.orange)
                        .help("Showing cached values — last refresh failed")
                }
            }

            if let l = store.limits, l.hasData {
                if let w = l.session5h {
                    LimitRow(title: "Session", subtitle: "5h", window: w, now: snap.generatedAt,
                             projection: store.sessionProjection)
                }
                if let w = l.weekly7d {
                    LimitRow(title: "Weekly", subtitle: "7d", window: w, now: snap.generatedAt,
                             projection: store.weeklyProjection)
                }
                if let w = l.weeklyOpus {
                    LimitRow(title: "Weekly", subtitle: "Opus", window: w, now: snap.generatedAt)
                }
            } else {
                Text(store.limits?.error ?? "Loading live limits…")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var perModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Per-model burn · 5h")
            ForEach(store.modelBurnRows) { ModelBurnRowView(row: $0) }
            if store.modelBurnRows.contains(where: { $0.headroomTurns != nil }) {
                Text("× = tokens/turn vs lightest · “turns left” assumes only that model")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionLabel(text: "5-Hour Window")
                Spacer()
                if let reset = snap.windowResetAt {
                    Label(Fmt.countdown(to: reset, from: snap.generatedAt),
                          systemImage: "clock")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Oldest request leaves the window in \(Fmt.countdown(to: reset, from: snap.generatedAt))")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.tokens(snap.windowTokens.total))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("tokens").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Text("~\(Fmt.usd(snap.windowCost))")
                    .foregroundStyle(.secondary).monospacedDigit()
                    .help("Estimated cost")
            }
            MeterBar(fraction: store.windowFraction)
            Text("\(Int(store.windowFraction * 100))% of \(Fmt.tokens(store.fiveHourTokenBudget)) budget")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Today")
            StatRow(label: "Tokens", value: Fmt.tokens(snap.todayTokens.total),
                    secondary: "~\(Fmt.usd(snap.todayCost))")
            StatRow(label: "Requests", value: Fmt.int(snap.todayRequests))
            StatRow(label: "Sessions", value: Fmt.int(snap.todaySessions))
            StatRow(label: "Tool calls", value: Fmt.int(snap.todayToolCalls))
        }
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Tokens / day (14d)")
            Sparkline(values: snap.dailyTokenHistory)
        }
    }

    private var lifetimeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "All time")
            StatRow(label: "Sessions", value: Fmt.int(snap.totalSessions))
            StatRow(label: "Messages", value: Fmt.int(snap.totalMessages))
            if let first = snap.firstSessionDate {
                StatRow(label: "Since", value: Fmt.shortDate(first))
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Updated \(Fmt.time(snap.generatedAt))")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Settings…") { SettingsOpener.open() }
                .buttonStyle(.borderless).font(.caption)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption)
        }
    }
}
