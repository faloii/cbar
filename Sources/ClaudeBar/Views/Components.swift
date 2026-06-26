import SwiftUI

extension Color {
    /// Brand coral, matching the app icon.
    static let brand = Color(red: 0.85, green: 0.45, blue: 0.30)
    static let brandTop = Color(red: 0.93, green: 0.59, blue: 0.45)
}

/// A rounded, subtly-filled panel that groups one section's content.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    // Faint top-to-bottom gradient reads as a subtle raised surface.
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.075), Color.primary.opacity(0.035)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

/// Section header: a tinted SF Symbol + uppercase title.
struct CardHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2.weight(.semibold)).foregroundStyle(Color.brand)
                .accessibilityHidden(true)
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
        }
    }
}

/// Horizontal usage meter with a gradient fill that shifts toward red as it fills.
struct MeterBar: View {
    let fraction: Double   // 0...1

    /// Green → amber → red by fill level. Shared so the headline % can match the bar.
    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.6:  return .green
        case ..<0.85: return Color(red: 0.95, green: 0.7, blue: 0.2)
        default:      return .red
        }
    }
    private var color: Color { Self.color(for: fraction) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)   // decorative; the % is shown as text alongside
    }
}

/// One "label … value" row.
struct StatRow: View {
    let label: String
    let value: String
    var secondary: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let secondary {
                Text(secondary).foregroundStyle(.tertiary).font(.callout)
            }
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// The headline plan-limit visual: a circular gauge with the % in the center, the
/// ring filling green→amber→red, the window name + a compact reset time below.
struct RingGauge: View {
    let title: String        // "세션" / "주간" / "Opus"
    let window: LimitWindow
    let now: Date
    var paceFraction: Double? = nil   // even-usage marker ("on this much by now")
    var size: CGFloat = 66
    var preciseReset: Bool = false    // show hours+minutes (session) vs a single unit (weekly)

    private var color: Color { MeterBar.color(for: window.fraction) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.012, min(1, window.fraction)))
                    .stroke(LinearGradient(colors: [color.opacity(0.7), color],
                                           startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: window.fraction)
                // Even-usage marker: where you'd be if pacing linearly to 100% at reset.
                if let pf = paceFraction {
                    Capsule().fill(Color.primary.opacity(0.55))
                        .frame(width: 2.5, height: 10)
                        .frame(width: size, height: size, alignment: .top)
                        .rotationEffect(.degrees(360 * min(1, max(0, pf))))
                }
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.system(size: 17, weight: .bold)).monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.5), value: window.utilization)
            }
            .frame(width: size, height: size)
            VStack(spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                if let reset = window.resetsAt {
                    // Session (preciseReset): show the countdown *and* the actual reset
                    // clock time, e.g. "리셋 1h 18m (15:30)". Weekly/Opus stay single-unit.
                    Text(preciseReset
                         ? "리셋 \(Fmt.mediumCountdown(to: reset, from: now)) (\(Fmt.clock(reset)))"
                         : "리셋 \(Fmt.shortCountdown(to: reset, from: now))")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) 한도 \(Int(window.utilization.rounded()))퍼센트")
    }
}

/// A tagged burn-rate projection caption shown under the gauges ("세션 · 측정 중…" /
/// "주간 · ▲ 0.1%/h · 리셋 때 ~15% · 85% 여유"). Renders nothing when there's no signal.
struct ProjectionLine: View {
    let tag: String
    let window: LimitWindow
    let projection: Projection?
    let now: Date

    var body: some View {
        let s = state
        if !s.text.isEmpty {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: s.icon).frame(width: 12)
                Text("\(tag) · \(s.text)").fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .foregroundStyle(s.color)
        }
    }

    private func rateText(_ rate: Double) -> String {
        rate >= 10 ? "▲ \(Int(rate.rounded()))%/h" : String(format: "▲ %.1f%%/h", rate)
    }

    private var state: (text: String, color: Color, icon: String) {
        if window.utilization >= 100 { return ("지금 막힘", .red, "nosign") }
        guard let p = projection else { return ("", .secondary, "circle") }
        switch p.verdict {
        case .measuring: return ("측정 중…", .secondary, "hourglass")
        case .idle:      return ("사용 없음", .secondary, "pause")
        case .safe:
            if let proj = p.projectedAtReset {
                let pct = Int(proj.rounded())
                if proj >= 90 {
                    return ("\(rateText(p.ratePerHour)) · 리셋까지 거의 다 씀(~\(pct)%)", .green, "checkmark.circle")
                }
                return ("\(rateText(p.ratePerHour)) · 리셋 때 ~\(pct)% · \(max(0, 100 - pct))% 여유", .secondary, "gauge.medium")
            }
            return ("\(rateText(p.ratePerHour)) · 리셋까지 충분", .green, "checkmark.circle")
        case .atRisk:
            let full = p.timeToFull.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
            let gap = p.blockedBy.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
            return ("\(rateText(p.ratePerHour)) · \(full) 후 소진 — 리셋보다 \(gap) 빠름", .orange, "exclamationmark.triangle.fill")
        }
    }
}

/// Plain-language "am I using too fast / just right / relaxed" verdict for a window.
/// Deliberately number-free — "30%/h" doesn't land — using hare/tortoise framing and
/// an action. The block/working-time facts are owned by `WorkTimeLine`; the exact
/// rates live in the hover tooltip for anyone who wants them.
struct PaceLine: View {
    let window: LimitWindow
    let projection: Projection?
    let now: Date

    var body: some View {
        let s = state
        if !s.text.isEmpty {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: s.icon).frame(width: 12)
                Text(s.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .foregroundStyle(s.color)
            .help(detail)
        }
    }

    private func rate(_ r: Double) -> String { r >= 10 ? "\(Int(r.rounded()))%/h" : String(format: "%.1f%%/h", r) }

    /// Exact numbers, tucked into the tooltip so the headline can stay number-free.
    private var detail: String {
        guard let rec = Pace.sustainableRate(util: window.utilization,
                                             secondsToReset: window.resetsAt?.timeIntervalSince(now)) else { return "" }
        let measured = projection?.ratePerHour ?? 0
        return "현재 \(rate(measured)) · 권장 ~\(rate(rec))"
    }

    private var state: (text: String, color: Color, icon: String) {
        // util ≥ 100 and the "you'll block" message belong to WorkTimeLine.
        if window.utilization >= 100 { return ("", .secondary, "") }
        guard let rec = Pace.sustainableRate(util: window.utilization,
                                             secondsToReset: window.resetsAt?.timeIntervalSince(now)) else {
            return ("", .secondary, "")
        }
        let measured = projection?.ratePerHour ?? 0
        switch projection?.verdict {
        case .idle:
            return ("지금은 거의 안 쓰는 중 — 리셋까지 여유 있어요", .secondary, "pause")
        case .measuring, .none:
            // Can't judge the pace yet; WorkTimeLine + 추이 차트가 대신 보여줍니다.
            return ("", .secondary, "")
        case .atRisk:
            return ("좀 빠르게 쓰는 중 — 살짝 늦추면 리셋까지 안 막혀요", .orange, "hare.fill")
        case .safe:
            if measured > rec * 1.25 { return ("살짝 빠른 편 — 이대로도 괜찮지만 늦추면 더 여유로워요", .orange, "hare") }
            if measured < rec * 0.6  { return ("여유롭게 쓰는 중 — 더 써도 리셋 전엔 안 막혀요", Color.brand, "tortoise") }
            return ("딱 좋은 속도로 쓰고 있어요", .green, "checkmark.circle")
        }
    }
}

/// The headline "can I keep working?" line: working-time left + a wall-clock block
/// time when you're on track to hit the cap, plus a one-line directive. The visceral
/// answer to "how much longer can I go before I'm blocked".
struct WorkTimeLine: View {
    let window: LimitWindow
    let projection: Projection?
    let now: Date

    var body: some View {
        let s = state
        if !s.text.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: s.icon).font(.footnote)
                Text(s.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(s.color)
        }
    }

    private func dur(_ s: TimeInterval) -> String { Fmt.countdown(to: now.addingTimeInterval(s), from: now) }

    private var state: (text: String, color: Color, icon: String) {
        let toReset = window.resetsAt?.timeIntervalSince(now)
        if window.utilization >= 100 {
            let r = window.resetsAt.map { Fmt.countdown(to: $0, from: now) } ?? "?"
            return ("지금 막힘 · \(r) 후 새로 채워져요", .red, "nosign")
        }
        // About to refresh anyway — tell them to park big work for the reset.
        if let tr = toReset, tr > 0, tr <= 15 * 60 {
            return ("리셋 \(dur(tr)) 전 — 큰 작업은 리셋 직후 돌리세요", .green, "hourglass.bottomhalf.filled")
        }
        guard let b = SessionCoach.workBudget(session: projection, util: window.utilization,
                                              resetsAt: window.resetsAt, now: now) else {
            return ("", .secondary, "")
        }
        if b.willBlock {
            let clock = b.blockAt.map { " · \(Fmt.time($0))경 막힘" } ?? ""
            return ("앞으로 ~\(dur(b.workableSeconds)) 더 작업 가능\(clock)", .orange, "hourglass.tophalf.filled")
        }
        // Won't block before reset. Flag big leftover headroom as "go faster" room.
        if let left = projection?.headroomAtReset, left >= 25 {
            return ("리셋까지 안 막힘 · ~\(dur(b.workableSeconds)) 여유 — 미룬 큰 작업 지금 돌리세요",
                    .green, "checkmark.circle")
        }
        return ("리셋까지 ~\(dur(b.workableSeconds)) 더 작업 가능 (안 막힘)", .secondary, "clock")
    }
}

/// In-session usage trend: session utilization (%) over the last few hours, with a
/// dashed "even-pace" guide (where you'd sit pacing linearly to 100% at reset). Lets
/// you eyeball how fast you're burning and how much you've used vs. the steady rate.
/// Needs ≥2 samples; shows a "measuring" hint otherwise.
struct SessionTrendChart: View {
    let samples: [UsageSample]          // session != nil; sorted oldest→newest
    let now: Date
    let secondsToReset: TimeInterval?
    var windowSeconds: TimeInterval = 5 * 3600
    var height: CGFloat = 46

    /// Points for the CURRENT session only: trim everything up to and including the most
    /// recent reset (a downward jump), so a prior session's curve isn't shown.
    private var pts: [(t: Date, v: Double)] {
        let all = samples.compactMap { s in s.session.map { (s.at, $0) } }
        var seg = all
        if all.count >= 2 {
            for i in stride(from: all.count - 1, to: 0, by: -1)
            where all[i].1 + Projection.resetDrop < all[i - 1].1 {
                seg = Array(all[i...]); break
            }
        }
        return seg
    }

    /// %-value of the even-pace guide at a given time: linear from window-start (0%)
    /// to reset (100%). nil when the reset time is unknown.
    private func paceValue(at t: Date) -> Double? {
        guard let s = secondsToReset else { return nil }
        let reset = now.addingTimeInterval(s)
        return min(100, max(0, (windowSeconds - reset.timeIntervalSince(t)) / windowSeconds * 100))
    }

    private func niceTop(_ v: Double) -> Double {
        for c in [25.0, 50, 75, 100] where v <= c { return c }
        return 100
    }

    var body: some View {
        let pts = self.pts
        if pts.count >= 2, let first = pts.first {
            let last = pts[pts.count - 1]
            let tMin = first.t
            let tMax = max(now, last.t)
            let span = max(1, tMax.timeIntervalSince(tMin))
            let paceNow = paceValue(at: tMax)
            let top = niceTop(max(pts.map(\.v).max() ?? 0, paceNow ?? 0, 8) * 1.1)
            let color = MeterBar.color(for: last.v / 100)

            VStack(alignment: .leading, spacing: 3) {
                Canvas { ctx, size in
                    let w = size.width, h = size.height
                    func px(_ t: Date) -> CGFloat { CGFloat(t.timeIntervalSince(tMin) / span) * w }
                    func py(_ v: Double) -> CGFloat { h - CGFloat(min(v, top) / top) * h }

                    // Even-pace guide (dashed): the steady line that lands at 100% on reset.
                    if let pNow = paceNow, let pMin = paceValue(at: tMin) {
                        var guide = Path()
                        guide.move(to: CGPoint(x: px(tMin), y: py(pMin)))
                        guide.addLine(to: CGPoint(x: px(tMax), y: py(pNow)))
                        ctx.stroke(guide, with: .color(.primary.opacity(0.35)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    // Area under the actual usage curve.
                    var area = Path()
                    area.move(to: CGPoint(x: px(pts[0].t), y: h))
                    for pt in pts { area.addLine(to: CGPoint(x: px(pt.t), y: py(pt.v))) }
                    area.addLine(to: CGPoint(x: px(last.t), y: h))
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(
                        Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
                    // Actual usage line.
                    var line = Path()
                    line.move(to: CGPoint(x: px(pts[0].t), y: py(pts[0].v)))
                    for pt in pts.dropFirst() { line.addLine(to: CGPoint(x: px(pt.t), y: py(pt.v))) }
                    ctx.stroke(line, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    // Head dot at the latest reading.
                    let dot = CGRect(x: px(last.t) - 2.5, y: py(last.v) - 2.5, width: 5, height: 5)
                    ctx.fill(Path(ellipseIn: dot), with: .color(color))
                }
                .frame(height: height)
                .accessibilityHidden(true)

                HStack(spacing: 5) {
                    Text("최근 \(Fmt.mediumCountdown(to: tMax, from: tMin))")
                    Text("·")
                    Text("\(Int(first.v.rounded()))% → \(Int(last.v.rounded()))%").monospacedDigit()
                    if paceNow != nil {
                        Spacer(minLength: 4)
                        HStack(spacing: 3) {
                            Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 8, height: 1)
                            Text("이상 페이스")
                        }
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text("세션 추이 측정 중… (몇 분 더 쌓이면 표시)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// One row of the per-model burn comparison: share bar + tokens/turn + cost +
/// burn multiplier, with optional "turns left if only this model".
struct ModelBurnRowView: View {
    let row: ModelBurnRow
    let basis: BurnBasis

    /// Compact percent: "5%", "0.4%", "0.07%" — keeps small per-turn shares legible.
    static func pct(_ v: Double) -> String {
        let s = v >= 1 ? String(format: "%.0f", v)
              : v >= 0.1 ? String(format: "%.1f", v)
              : String(format: "%.2f", v)
        return s + "%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.model).font(.callout.weight(.medium))
                if let tier = ModelTier.of(row.model) {
                    Text(tier.short).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Text(String(format: "%.1f×", row.burnMultiplier))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(row.burnMultiplier >= 2 ? .orange : .secondary)
                    .help("사용한 모델 중 최저 대비 턴당 \(basis.shortLabel)")
                Text("\(Int((row.shareFraction * 100).rounded()))%")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            MeterBar(fraction: row.shareFraction)
            HStack(spacing: 5) {
                Text(basis.formatPerTurn(row.perTurnWeight))
                if basis != .cost {
                    Text("·")
                    Text("~\(Fmt.usd(row.cost))")
                }
                if let share = row.limitSharePerTurn {
                    Text("·")
                    Text("한도 \(Self.pct(share))/턴")
                        .foregroundStyle(row.burnMultiplier >= 2 ? .orange : .secondary)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .help(ModelTier.of(row.model)?.blurb ?? "")
        .accessibilityElement(children: .combine)
    }
}

