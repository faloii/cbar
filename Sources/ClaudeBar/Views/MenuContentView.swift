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
        .onDisappear {
            store.setPopoverVisible(false)
            SettingsOpener.close()   // dismiss Settings together with the popover
        }
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
        case .recent:
            Card { windowSection }
        case .perModel:
            if !store.modelBurnRows.isEmpty { Card { perModelSection } }
        case .modelGuide:
            if !snap.windowByModel.isEmpty { Card { modelGuideSection } }
        case .sessions:
            if !snap.recentSessions.isEmpty { Card { sessionsSection } }
        case .today:
            Card { todaySection }
        case .weeklyReview:
            if let r = snap.weeklyReview { Card { weeklyReviewSection(r) } }
        case .goals:
            if store.opusShareTarget > 0, !snap.weeklyOpusShares.isEmpty { Card { goalsSection } }
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
        HStack(spacing: 6) {
            CardHeader(icon: "gauge.with.dots.needle.67percent", title: "플랜 한도")
            Spacer()
            if let l = store.limits, l.hasData {
                Text("\(Fmt.age(l.fetchedAt, from: snap.generatedAt)) 갱신")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("이 수치가 마지막으로 갱신된 시점")
                if l.stale {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.caption2).foregroundStyle(.orange)
                        .help("캐시된 값 표시 중 — 마지막 새로고침 실패")
                }
            }
        }
        if let l = store.limits, l.hasData {
            HStack(alignment: .top, spacing: 10) {
                if let w = l.session5h {
                    RingGauge(title: "세션", window: w, now: snap.generatedAt,
                              paceFraction: Pace.elapsedFraction(windowSeconds: 5 * 3600,
                                                                 secondsToReset: w.resetsAt?.timeIntervalSince(snap.generatedAt)))
                }
                if let w = l.weekly7d {
                    RingGauge(title: "주간", window: w, now: snap.generatedAt,
                              paceFraction: Pace.elapsedFraction(windowSeconds: 7 * 24 * 3600,
                                                                 secondsToReset: w.resetsAt?.timeIntervalSince(snap.generatedAt)))
                }
                if let w = l.weeklyOpus { RingGauge(title: "Opus", window: w, now: snap.generatedAt) }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if let w = l.session5h {
                    PaceLine(window: w, projection: store.sessionProjection, now: snap.generatedAt)
                }
                if let w = l.weekly7d {
                    ProjectionLine(tag: "주간", window: w, projection: store.weeklyProjection, now: snap.generatedAt)
                }
            }
            .padding(.top, 2)
        } else {
            Text(store.limits?.error ?? "한도 불러오는 중…")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var goalsSection: some View {
        let shares = snap.weeklyOpusShares
        let current = shares.first?.opusShare ?? 0
        let used = shares.filter { $0.hasUsage }
        let compliant = used.filter { $0.opusShare * 100 <= Double(store.opusShareTarget) }.count
        let over = (shares.first?.hasUsage ?? false) && current * 100 > Double(store.opusShareTarget)
        CardHeader(icon: "target", title: "습관 목표")
        HStack(alignment: .firstTextBaseline) {
            Text("Opus 비중 ≤ \(store.opusShareTarget)%").font(.callout.weight(.medium))
            Spacer()
            Text("이번 주 \(Int((current * 100).rounded()))%").font(.callout).monospacedDigit()
            Text(over ? "초과" : "준수")
                .font(.caption2.weight(.medium)).foregroundStyle(over ? .red : .green)
        }
        MeterBar(fraction: current)
        if !used.isEmpty {
            Text("최근 \(used.count)주 중 \(compliant)주 준수")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func weeklyReviewSection(_ r: WeeklyReview) -> some View {
        CardHeader(icon: "calendar.badge.clock", title: "주간 리뷰")
        VStack(spacing: 5) {
            StatRow(label: "비용", value: "~\(Fmt.usd(r.thisCost))", secondary: deltaText(r.costDeltaPct))
            StatRow(label: "Opus 비중", value: "\(Int((r.opusShareThis * 100).rounded()))%",
                    secondary: opusDeltaText(r.opusShareDeltaPts))
        }
        if let coaching = r.coaching {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "lightbulb").font(.caption).foregroundStyle(Color.brand)
                Text(coaching).font(.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        Text("이번 주 vs 지난주").font(.caption2).foregroundStyle(.tertiary)
    }

    private func deltaText(_ pct: Double?) -> String? {
        guard let p = pct else { return nil }
        if abs(p) < 1 { return "지난주와 비슷" }
        return p > 0 ? "지난주 ▲\(Int(p.rounded()))%" : "지난주 ▼\(Int(abs(p).rounded()))%"
    }
    private func opusDeltaText(_ pts: Double) -> String? {
        if abs(pts) < 1 { return nil }
        return pts > 0 ? "▲\(Int(pts.rounded()))%p" : "▼\(Int(abs(pts).rounded()))%p"
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
                .help(ModelTier.effortNote)
            Spacer()
            Text(store.burnBasis.shortLabel).font(.caption2).foregroundStyle(.tertiary)
        }
        VStack(alignment: .leading, spacing: 9) {
            ForEach(store.modelBurnRows) { ModelBurnRowView(row: $0, basis: store.burnBasis) }
        }
        Text("× = 턴당 \(store.burnBasis.shortLabel) (최저 모델 대비) · 한도 %/턴 = 한 번 쓸 때 세션 한도를 먹는 비중")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Recommended model per kind of work + your real per-turn cost for each model
    // you've used. ClaudeBar can't judge task difficulty, so this is guidance, not a
    // per-task verdict — the choice stays with you.
    @ViewBuilder private var modelGuideSection: some View {
        CardHeader(icon: "slider.horizontal.3", title: "모델 가이드")
        VStack(alignment: .leading, spacing: 7) {
            ForEach(snap.windowByModel.sorted { $0.cost > $1.cost }) { m in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(m.model).font(.callout.weight(.medium))
                    if let tier = ModelTier.of(m.model) {
                        Text(tier.useFor).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if m.requests > 0 {
                        Text("~\(Fmt.usd(m.cost / Double(m.requests)))/턴")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        Text("작업 난이도는 ClaudeBar가 알 수 없어요 — 권장 용도는 참고용입니다. 가벼운 작업을 더 싼 모델로 옮기면 비용이 크게 줄고, 한도(토큰)엔 거의 영향이 없습니다.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Recent conversations by cost — spot which sessions ran on which model so you
    // can right-size the model next time.
    @ViewBuilder private var sessionsSection: some View {
        CardHeader(icon: "rectangle.stack.fill", title: "세션별 · 최근")
        VStack(alignment: .leading, spacing: 9) {
            ForEach(snap.recentSessions.prefix(5)) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(s.project).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("~\(Fmt.usd(s.cost))").font(.callout.weight(.semibold)).monospacedDigit()
                    }
                    HStack(spacing: 5) {
                        ForEach(Array(s.models.prefix(2)), id: \.self) { model in
                            Text(model)
                                .foregroundStyle(ModelTier.of(model)?.short == "최고 성능" ? .orange : .secondary)
                        }
                        if s.models.count > 2 { Text("외 \(s.models.count - 2)") }
                        Text("·")
                        Text("\(Fmt.int(s.requests))턴")
                        Spacer(minLength: 6)
                        Text(Fmt.time(s.lastActivity))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        Text("비용이 큰 대화 순. 한 모델로만 비쌌다면 다음엔 작업에 맞춰 모델을 바꿔보세요.")
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

}
