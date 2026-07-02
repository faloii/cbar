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
    @State private var dropTarget: PanelSection?

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
                            if store.isVisible(section) { reorderableCard(section) }
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
            // The real app icon (not a redrawn stand-in) — stays in sync automatically
            // whenever AppIcon.icns changes.
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            Text("CBar").font(.headline)
            Spacer()
            Button { store.toggleSnooze() } label: {
                Image(systemName: store.isSnoozed ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(store.isSnoozed ? Color.brand.opacity(0.18) : Color.primary.opacity(0.06), in: Circle())
                    .foregroundStyle(store.isSnoozed ? Color.brand : Color.primary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(snoozeHelp)
            .accessibilityLabel(store.isSnoozed ? "조용히 모드 해제" : "2시간 조용히")
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

    private var snoozeHelp: String {
        guard store.isSnoozed, let until = store.snoozeUntil else { return "지금부터 2시간 조용히 — 알림만 끄고, 상태 표시는 그대로예요" }
        return "조용히 중 · \(Fmt.countdown(to: until, from: Date())) 남음 · 탭하면 해제"
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

    /// A card wrapped for inline drag-and-drop reordering, right on the popover —
    /// drag a card onto another to drop it above (a coral line marks the spot). The
    /// same `moveSection(_:before:)` powers Settings; cards have no inner buttons so
    /// the whole card is a safe drag handle.
    @ViewBuilder private func reorderableCard(_ section: PanelSection) -> some View {
        card(for: section)
            .overlay(alignment: .top) {
                if dropTarget == section {
                    Capsule().fill(Color.brand).frame(height: 3)
                        .padding(.horizontal, 10).offset(y: -6)
                }
            }
            .draggable(section.rawValue) {
                Label(section.label, systemImage: "line.3.horizontal").padding(6)
            }
            .dropDestination(for: String.self) { items, _ in
                dropTarget = nil
                guard let raw = items.first, let moved = PanelSection(rawValue: raw) else { return false }
                store.moveSection(moved, before: section)
                return true
            } isTargeted: { hovering in
                dropTarget = hovering ? section : (dropTarget == section ? nil : dropTarget)
            }
    }

    @ViewBuilder private func card(for section: PanelSection) -> some View {
        switch section {
        case .advice:
            if store.enableLiveLimits, !store.adviceTips.isEmpty { Card { adviceSection } }
        case .limits:
            if store.enableLiveLimits { Card { limitsSection } }
        case .efficiency:
            if store.hasEfficiencyData { Card { efficiencySection } }
        case .recent:
            Card { windowSection }
        case .perModel:
            if !store.modelBurnRows.isEmpty { Card { perModelSection } }
        case .modelGuide:
            if !snap.windowByModel.isEmpty { Card { modelGuideSection } }
        case .modelRecap:
            if let v = store.modelRecap { Card { modelRecapSection(v) } }
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
                                                                 secondsToReset: w.resetsAt?.timeIntervalSince(snap.generatedAt)),
                              preciseReset: true)
                }
                if let w = l.weekly7d {
                    RingGauge(title: "주간", window: w, now: snap.generatedAt,
                              paceFraction: Pace.elapsedFraction(windowSeconds: 7 * 24 * 3600,
                                                                 secondsToReset: w.resetsAt?.timeIntervalSince(snap.generatedAt)))
                }
                if let w = l.weeklyOpus { RingGauge(title: "Opus", window: w, now: snap.generatedAt) }
            }
            .padding(.top, 2)
            // Hero: the one-glance "can I keep working?" answer.
            if let w = l.session5h {
                WorkTimeLine(window: w, projection: store.sessionProjection, now: snap.generatedAt)
                    .padding(.top, 4)
            }
            // Supporting detail, visually subordinate to the hero line.
            VStack(alignment: .leading, spacing: 2) {
                if let w = l.session5h {
                    PaceLine(window: w, projection: store.sessionProjection, now: snap.generatedAt)
                }
                if let w = l.weekly7d {
                    ProjectionLine(tag: "주간", window: w, projection: store.weeklyProjection, now: snap.generatedAt)
                    if let budget = store.weeklyAllowance {
                        WeeklyAllowanceLine(budget: budget)
                    }
                }
                UpcomingResetsLine(resets: store.upcomingResets)
            }
            if let w = l.session5h {
                SessionTrendChart(samples: store.sessionTrend, now: snap.generatedAt,
                                  secondsToReset: w.resetsAt?.timeIntervalSince(snap.generatedAt))
                    .padding(.top, 4)
            }
            if let w = l.weekly7d {
                WeeklyTrendChart(samples: store.weeklyTrend, now: snap.generatedAt,
                                 secondsToReset: w.resetsAt?.timeIntervalSince(snap.generatedAt))
                    .padding(.top, 4)
            }
        } else {
            Text(store.limits?.error ?? "한도 불러오는 중…")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Folds the re-read share into the SAME sentence as the /compact action (when
    // it's the dominant driver), so the number always comes with a "so what" —
    // a bare "재읽기 95%" stat doesn't tell you what to do about it.
    private func heavyContextActionText(_ ce: CacheEfficiency.Verdict?) -> String {
        let base = "/compact 하거나 새 대화로 시작하면 같은 한도로 더 오래 가요."
        guard let ce, ce.cacheReadShare >= CacheEfficiency.heavyReuseThreshold else { return base }
        return "한도 소모의 \(Int((ce.cacheReadShare * 100).rounded()))%가 과거 대화 재읽기예요 — " + base
    }

    private func efficiencyColor(_ v: SessionCoach.EfficiencyVerdict) -> Color {
        switch v {
        case .optimal:    return .green
        case .underusing: return .brand
        case .overpacing: return .orange
        case .fair, .idle, .measuring: return .secondary
        }
    }

    @ViewBuilder private var efficiencySection: some View {
        let ctx = snap.currentContextTokens
        let verdict = store.efficiencyVerdict
        HStack(spacing: 5) {
            CardHeader(icon: "leaf", title: "효율")
            Spacer()
            if verdict.showsPill {
                Text(verdict.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(efficiencyColor(verdict).opacity(0.16)))
                    .foregroundStyle(efficiencyColor(verdict))
            }
        }
        // Per-exchange consumption — the tangible efficiency dial (context size → burn).
        if ctx > 0 {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right").frame(width: 12)
                if let p = store.perExchangePct {
                    Text("대화 ~\(Fmt.tokens(ctx)) · 주고받을 때마다 한도 ~\(ModelBurnRowView.pct(p))")
                } else {
                    Text("대화 ~\(Fmt.tokens(ctx))")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            if ctx >= SessionCoach.heavyContextTokens {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "rectangle.compress.vertical").frame(width: 12)
                    Text(heavyContextActionText(store.cacheEfficiency))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2).foregroundStyle(Color.brand)
            }
        }
        // Cache mix — purely informational context for the number above. The action
        // (if any) is already spelled out in the heavy-context line, so this never
        // repeats it or implies a verdict on its own: a big cached system prompt
        // makes a high re-read share normal even in a small conversation, so the
        // raw % alone doesn't tell you what to do about it.
        if let ce = store.cacheEfficiency {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath").frame(width: 12)
                Text("최근 5시간 새 작업 \(Int((ce.freshShare * 100).rounded()))% · 재읽기 \(Int((ce.cacheReadShare * 100).rounded()))%")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        // Learning loop: how the last completed session was spent.
        if let r = store.lastSessionRecap {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "clock.arrow.circlepath").frame(width: 12)
                Text(SessionCoach.recapText(r)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2).foregroundStyle(.tertiary)
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
        // Which project is eating the weekly limit — useful when juggling several.
        let projects = snap.weeklyProjectUsage
        if projects.count >= 2 {
            let total = max(1, projects.reduce(0) { $0 + $1.tokens })
            Divider().padding(.vertical, 2)
            Text("프로젝트별 · 최근 7일").font(.caption2).foregroundStyle(.tertiary)
                .help("이 Mac의 Claude Code 로그 기준이에요 — 다른 기기에서 쓴 프로젝트는 빠져 있어요.")
            VStack(alignment: .leading, spacing: 5) {
                ForEach(projects.prefix(3)) { p in
                    let share = Double(p.tokens) / Double(total)
                    HStack(spacing: 6) {
                        Text(p.project).font(.caption).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(Int((share * 100).rounded()))%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    MeterBar(fraction: share)
                }
            }
        }
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
            .help("이 Mac의 Claude Code 로그 기준이에요 — 다른 기기에서 쓴 건 이 수치에 반영되지 않아요. 세션/주간 한도 %는 계정 전체 기준입니다.")
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
                .help(ModelTier.effortNote + " 이 Mac의 로그 기준이라, 다른 기기 사용은 빠져 있어요.")
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
        Text("작업 난이도는 CBar가 알 수 없어요 — 권장 용도는 참고용입니다. 가벼운 작업을 더 싼 모델로 옮기면 비용이 크게 줄고, 한도(토큰)엔 거의 영향이 없습니다.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Retrospective "did I right-size?" read on the model you actually leaned on —
    // measured, not assigned. Output/turn stands in for reasoning effort (not tracked
    // locally); any saving re-prices the SAME tokens on a cheaper tier, so it's a cost
    // lever, not a limit lever.
    @ViewBuilder private func modelRecapSection(_ v: ModelRecap.Verdict) -> some View {
        CardHeader(icon: "checkmark.seal", title: "모델·effort 회고")
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: recapIcon(v)).frame(width: 12).foregroundStyle(recapColor(v))
                Text(recapHeadline(v))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).foregroundStyle(.primary)
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "brain").frame(width: 12).foregroundStyle(.secondary)
                Text(recapEffort(v))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        Text("effort는 로컬에서 측정되지 않아요 — 턴당 출력량으로 추정한 참고용입니다.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func recapFamily(_ id: String) -> String {
        let m = id.lowercased()
        if m.contains("opus")   { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku")  { return "Haiku" }
        if m.contains("fable")  { return "Fable" }
        return id
    }

    private func recapHeadline(_ v: ModelRecap.Verdict) -> String {
        let fam = recapFamily(v.model)
        let out = Fmt.tokens(v.outputPerTurn)
        if let down = v.downshiftTo, let usd = v.downshiftSavingUSD {
            // Opus, light/moderate turns: a real cost-saving downshift.
            return "주로 \(fam)를 썼는데 턴이 가벼운 편이었어요 (출력 ~\(out)/턴). 같은 작업을 \(down)으로 했다면 비용 ~1/5 (~\(Fmt.usd(usd)) 절감) — 토큰(한도)은 그대로예요."
        }
        if v.isTopTier {
            // Opus, heavy turns: justified.
            return "\(fam) 턴이 무거웠어요 (출력 ~\(out)/턴) — 깊은 추론이 필요한 작업이라 제값을 했어요."
        }
        return "주로 \(fam)를 썼어요 (출력 ~\(out)/턴) — 작업에 잘 맞는 선택이었어요."
    }

    private func recapEffort(_ v: ModelRecap.Verdict) -> String {
        switch v.intensity {
        case .light:
            return "턴당 출력이 가벼워서, effort를 낮춰도 결과가 비슷했을 가능성이 커요 (추정)."
        case .heavy:
            return "턴당 출력이 많아요 — 깊게 추론하는 작업이라 effort를 유지할 만해요 (추정)."
        case .moderate:
            return "턴당 출력은 보통 수준 — effort 기본값이 무난해요 (추정)."
        }
    }

    private func recapIcon(_ v: ModelRecap.Verdict) -> String {
        v.downshiftTo != nil ? "arrow.down.circle.fill" : "checkmark.seal.fill"
    }

    private func recapColor(_ v: ModelRecap.Verdict) -> Color {
        v.downshiftTo != nil ? .orange : .green
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
