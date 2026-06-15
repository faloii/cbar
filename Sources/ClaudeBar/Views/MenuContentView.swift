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
            .help("새로고침")
        }
    }

    @ViewBuilder
    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "플랜 한도")
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
    }

    private var perModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "모델별 소진 · 5시간")
                Spacer()
                Text(store.burnBasis.shortLabel).font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(store.modelBurnRows) { ModelBurnRowView(row: $0, basis: store.burnBasis) }
            Text("× = 턴당 \(store.burnBasis.shortLabel) (최저 모델 대비) · “남은 턴” = 세션 한도 기준")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionLabel(text: "5시간 윈도우")
                Spacer()
                if let reset = snap.windowResetAt {
                    Label(Fmt.countdown(to: reset, from: snap.generatedAt),
                          systemImage: "clock")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("가장 오래된 요청이 \(Fmt.countdown(to: reset, from: snap.generatedAt)) 후 윈도우에서 빠집니다")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.tokens(snap.windowTokens.total))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("토큰").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Text("~\(Fmt.usd(snap.windowCost))")
                    .foregroundStyle(.secondary).monospacedDigit()
                    .help("추정 비용")
            }
            MeterBar(fraction: store.windowFraction)
            Text("예산 \(Fmt.tokens(store.fiveHourTokenBudget)) 중 \(Int(store.windowFraction * 100))%")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "오늘")
            StatRow(label: "토큰", value: Fmt.tokens(snap.todayTokens.total),
                    secondary: "~\(Fmt.usd(snap.todayCost))")
            StatRow(label: "요청", value: Fmt.int(snap.todayRequests))
            StatRow(label: "세션", value: Fmt.int(snap.todaySessions))
            StatRow(label: "도구 호출", value: Fmt.int(snap.todayToolCalls))
        }
    }

    private var trendSection: some View {
        let costDays = Array(snap.dailyCostHistory.suffix(14))
        let total = costDays.reduce(0) { $0 + $1.cost }
        let avg = costDays.isEmpty ? 0 : total / Double(costDays.count)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "일별 토큰 (14일)")
                Sparkline(values: snap.dailyTokenHistory)
            }
            if !costDays.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        SectionLabel(text: "일별 비용 · 추정")
                        Spacer()
                        Text("14일 ~\(Fmt.usd(total)) · ~\(Fmt.usd(avg))/일")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    DailyCostBars(days: costDays)
                }
            }
        }
    }

    private var lifetimeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "전체 기간")
            StatRow(label: "세션", value: Fmt.int(snap.totalSessions))
            StatRow(label: "메시지", value: Fmt.int(snap.totalMessages))
            if let first = snap.firstSessionDate {
                StatRow(label: "시작일", value: Fmt.shortDate(first))
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("업데이트 \(Fmt.time(snap.generatedAt))")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("설정…") { SettingsOpener.open() }
                .buttonStyle(.borderless).font(.caption)
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption)
        }
    }
}
