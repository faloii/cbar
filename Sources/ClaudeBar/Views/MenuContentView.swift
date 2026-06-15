import SwiftUI

/// The popover shown when the menu-bar icon is clicked.
struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    private var snap: UsageSnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if store.enableLiveLimits, !store.adviceTips.isEmpty { Card { adviceSection } }
            if store.enableLiveLimits { Card { limitsSection } }
            Card { windowSection }
            if !store.modelBurnRows.isEmpty { Card { perModelSection } }
            Card { todaySection }
            if !snap.dailyTokenHistory.isEmpty { Card { trendSection } }
            Card { lifetimeSection }
            footer
        }
        .padding(14)
        .frame(width: 350)
        .tint(Color.brand)
        .dynamicTypeSize(.xLarge)   // bump all text-style fonts one step up for readability
        .preferredColorScheme(store.appearance.colorScheme)   // System / Light / Dark
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(
                    LinearGradient(colors: [Color.brandTop, Color.brand], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            Text("ClaudeBar").font(.headline)
            Spacer()
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: store.isRefreshing)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("새로고침")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("업데이트 \(Fmt.time(snap.generatedAt))")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("설정…") { SettingsOpener.open() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Sections (Card supplies the surrounding VStack + spacing)

    @ViewBuilder private var adviceSection: some View {
        CardHeader(icon: "lightbulb", title: "조언")
        VStack(alignment: .leading, spacing: 7) {
            ForEach(store.adviceTips) { tip in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: tip.icon)
                        .font(.caption).foregroundStyle(adviceColor(tip.level))
                        .frame(width: 14)
                    Text(tip.text)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func adviceColor(_ level: AdviceTip.Level) -> Color {
        switch level {
        case .good:     return .green
        case .info:     return Color.brand
        case .warn:     return .orange
        case .critical: return .red
        }
    }

    @ViewBuilder private var limitsSection: some View {
        HStack {
            CardHeader(icon: "gauge.with.dots.needle.67percent", title: "플랜 한도")
            Spacer()
            if let l = store.limits, l.stale {
                Image(systemName: "wifi.exclamationmark")
                    .font(.caption2).foregroundStyle(.orange)
                    .help("캐시된 값 표시 중 — 마지막 새로고침 실패")
            }
        }
        if let l = store.limits, l.hasData {
            if let w = l.session5h {
                LimitRow(title: "세션", subtitle: "5시간", window: w, now: snap.generatedAt,
                         projection: store.sessionProjection)
            }
            if let w = l.weekly7d {
                LimitRow(title: "주간", subtitle: "7일", window: w, now: snap.generatedAt,
                         projection: store.weeklyProjection)
            }
            if let w = l.weeklyOpus {
                LimitRow(title: "주간", subtitle: "Opus", window: w, now: snap.generatedAt)
            }
        } else {
            Text(store.limits?.error ?? "한도 불러오는 중…")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var windowSection: some View {
        CardHeader(icon: "clock", title: "최근 5시간")
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("~\(Fmt.usd(snap.windowCost))")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Spacer()
            Text("\(Fmt.tokens(snap.windowTokens.total)) 토큰")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        Text("정가 기준 추정 · 구독이면 실제 청구는 없음")
            .font(.caption2).foregroundStyle(.tertiary)
    }

    @ViewBuilder private var perModelSection: some View {
        HStack {
            CardHeader(icon: "chart.bar.fill", title: "모델별 소진 · 5시간")
            Spacer()
            Text(store.burnBasis.shortLabel).font(.caption2).foregroundStyle(.tertiary)
        }
        VStack(alignment: .leading, spacing: 9) {
            ForEach(store.modelBurnRows) { ModelBurnRowView(row: $0, basis: store.burnBasis) }
        }
        Text("× = 턴당 \(store.burnBasis.shortLabel) (최저 모델 대비) · “남은 턴” = 세션 한도 기준")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var todaySection: some View {
        CardHeader(icon: "calendar", title: "오늘")
        VStack(spacing: 5) {
            StatRow(label: "비용", value: "~\(Fmt.usd(snap.todayCost))")
            StatRow(label: "토큰", value: Fmt.tokens(snap.todayTokens.total))
            StatRow(label: "요청", value: Fmt.int(snap.todayRequests))
            StatRow(label: "세션", value: Fmt.int(snap.todaySessions))
            StatRow(label: "도구 호출", value: Fmt.int(snap.todayToolCalls))
        }
    }

    @ViewBuilder private var trendSection: some View {
        let costDays = Array(snap.dailyCostHistory.suffix(14))
        let total = costDays.reduce(0) { $0 + $1.cost }
        let avg = costDays.isEmpty ? 0 : total / Double(costDays.count)
        CardHeader(icon: "chart.xyaxis.line", title: "추세 · 14일")
        if !costDays.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("일별 비용 · 추정").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("14일 ~\(Fmt.usd(total)) · ~\(Fmt.usd(avg))/일")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                DailyCostBars(days: costDays)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("일별 토큰").font(.caption2).foregroundStyle(.secondary)
            Sparkline(values: snap.dailyTokenHistory)
        }
    }

    @ViewBuilder private var lifetimeSection: some View {
        CardHeader(icon: "infinity", title: "전체 기간")
        VStack(spacing: 5) {
            StatRow(label: "세션", value: Fmt.int(snap.totalSessions))
            StatRow(label: "메시지", value: Fmt.int(snap.totalMessages))
            if let first = snap.firstSessionDate {
                StatRow(label: "시작일", value: Fmt.shortDate(first))
            }
        }
    }
}
