import SwiftUI
import AppKit

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The popover shown when the menu-bar icon is clicked.
struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @State private var contentHeight: CGFloat = 0

    private var snap: UsageSnapshot { store.snapshot }

    /// Cap the scroll area to the screen (minus header/footer/menu-bar/margins) so
    /// the pinned footer always fits, adapting to small displays.
    private var maxScroll: CGFloat {
        let usable = NSScreen.main?.visibleFrame.height ?? 800
        return max(280, usable - 180)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // Cards scroll; the footer stays pinned so Settings/Quit are always
            // reachable no matter how tall the content gets.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if hasAnyData {
                        ForEach(store.orderedSections) { section in
                            if store.isVisible(section) { card(for: section) }
                        }
                    } else {
                        Card { emptyStateSection }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: contentHeight == 0 ? maxScroll : min(contentHeight, maxScroll))
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }

            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 350)
        .tint(Color.brand)
        .dynamicTypeSize(.xLarge)   // bump all text-style fonts one step up for readability
        .preferredColorScheme(store.appearance.colorScheme)   // System / Light / Dark
        .onAppear { store.setPopoverVisible(true) }
        .onDisappear { store.setPopoverVisible(false) }
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
                .accessibilityHidden(true)
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
            .accessibilityLabel("새로고침")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("업데이트 \(Fmt.time(snap.generatedAt))")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button { SettingsOpener.open() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            .help("설정")
            .accessibilityLabel("설정")
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            .help("종료")
            .accessibilityLabel("종료")
        }
        .padding(.horizontal, 2)
    }

    private var hasAnyData: Bool {
        snap.windowTokens.total > 0 || snap.todayRequests > 0
            || !snap.dailyCostHistory.isEmpty || (store.limits?.hasData ?? false)
    }

    // MARK: Sections (Card supplies the surrounding VStack + spacing)

    @ViewBuilder private func card(for section: PanelSection) -> some View {
        switch section {
        case .advice:
            if store.enableLiveLimits, !store.adviceTips.isEmpty { Card { adviceSection } }
        case .limits:
            if store.enableLiveLimits { Card { limitsSection } }
        case .limitTrend:
            if store.enableLiveLimits, store.limitHistory.filter({ $0.session != nil }).count >= 2 {
                Card { limitTrendSection }
            }
        case .currentSession:
            if let s = snap.currentSession { Card { currentSessionSection(s) } }
        case .recent:
            Card { windowSection }
        case .perModel:
            if !store.modelBurnRows.isEmpty { Card { perModelSection } }
        case .perProject:
            if !snap.windowByProject.isEmpty { Card { perProjectSection } }
        case .today:
            Card { todaySection }
        case .trend:
            if !snap.dailyTokenHistory.isEmpty { Card { trendSection } }
        case .costSummary:
            if !snap.dailyCostHistory.isEmpty { Card { costSummarySection } }
        case .budget:
            if let b = store.budgetStatus { Card { budgetSection(b) } }
        }
    }

    @ViewBuilder private var emptyStateSection: some View {
        CardHeader(icon: "tray", title: "데이터 없음")
        Text("아직 표시할 사용 데이터가 없어요.\nClaude Code로 작업하면 여기에 사용량·비용·한도가 나타납니다.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if store.enableLiveLimits, store.limits == nil {
            Text("실시간 한도 불러오는 중…").font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var adviceSection: some View {
        CardHeader(icon: "lightbulb", title: "조언")
        VStack(alignment: .leading, spacing: 7) {
            ForEach(store.adviceTips) { tip in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: tip.icon)
                        .font(.caption).foregroundStyle(adviceColor(tip.level))
                        .frame(width: 14)
                        .accessibilityHidden(true)
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

    @ViewBuilder private var limitTrendSection: some View {
        let session = store.limitHistory.compactMap { s in s.session.map { (s.at, $0) } }
        let weekly = store.limitHistory.compactMap { s in s.weekly.map { (s.at, $0) } }
        HStack {
            CardHeader(icon: "waveform.path.ecg", title: "한도 추세")
            Spacer()
            HStack(spacing: 8) {
                Label("세션", systemImage: "circle.fill").foregroundStyle(Color.brand)
                Label("주간", systemImage: "circle.fill").foregroundStyle(.secondary)
            }
            .font(.caption2).labelStyle(.titleAndIcon).imageScale(.small)
        }
        LimitTrendChart(session: session, weekly: weekly, threshold: store.warnThreshold)
        Text("최근 \(store.limitHistory.count)개 샘플 · 0–100% · 점선=경고 임계값")
            .font(.caption2).foregroundStyle(.tertiary)
    }

    @ViewBuilder private func currentSessionSection(_ s: SessionUsage) -> some View {
        CardHeader(icon: "text.bubble", title: "현재 세션")
        HStack {
            Text(s.project).font(.callout.weight(.medium)).lineLimit(1)
            Spacer()
            Text("~\(Fmt.usd(s.cost))").font(.callout).monospacedDigit()
        }
        HStack(spacing: 5) {
            Text("맥락 \(Fmt.tokens(s.contextTokens))")
            Text("·")
            Text("\(Fmt.int(s.requests))회")
            Spacer()
            Text(Fmt.time(s.lastActivity))
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var perProjectSection: some View {
        let total = max(snap.windowByProject.reduce(0) { $0 + $1.cost }, 0.0001)
        CardHeader(icon: "folder", title: "프로젝트별 · 5시간")
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(snap.windowByProject.prefix(5))) { p in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(p.project).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text("~\(Fmt.usd(p.cost))").font(.callout).monospacedDigit()
                    }
                    MeterBar(fraction: p.cost / total)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func budgetSection(_ b: BudgetStatus) -> some View {
        CardHeader(icon: "creditcard", title: "월 예산")
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("~\(Fmt.usd(b.monthToDate))")
                .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("/ \(Fmt.usd(b.budget))").foregroundStyle(.secondary).font(.callout)
            Spacer()
        }
        MeterBar(fraction: b.fraction)
        Text("이 추세면 월말 ~\(Fmt.usd(b.projected))\(b.projectedOver ? " · 예산 초과 예상" : "")")
            .font(.caption2).foregroundStyle(b.projectedOver ? Color.orange : Color.secondary)
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

    @ViewBuilder private var costSummarySection: some View {
        let last7 = snap.dailyCostHistory.suffix(7).reduce(0) { $0 + $1.cost }
        let last30 = snap.dailyCostHistory.reduce(0) { $0 + $1.cost }
        CardHeader(icon: "dollarsign.circle", title: "기간 비용 · 추정")
        VStack(spacing: 5) {
            StatRow(label: "최근 7일", value: "~\(Fmt.usd(last7))")
            StatRow(label: "최근 30일", value: "~\(Fmt.usd(last30))")
        }
    }
}
