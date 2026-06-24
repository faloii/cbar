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
                    Text("리셋 \(Fmt.shortCountdown(to: reset, from: now))")
                        .font(.caption2).foregroundStyle(.tertiary)
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

/// "On-pace" coaching for a window: the steady rate that lands you at ~100% right at
/// reset ("권장"), your current rate, and whether you're on it / fast / slow. This is
/// the actionable answer to "how fast should I be using it?".
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
        }
    }

    private func rate(_ r: Double) -> String { r >= 10 ? "\(Int(r.rounded()))%/h" : String(format: "%.1f%%/h", r) }

    private var state: (text: String, color: Color, icon: String) {
        if window.utilization >= 100 {
            let reset = window.resetsAt.map { Fmt.countdown(to: $0, from: now) } ?? "?"
            return ("지금 막힘 · \(reset) 후 리셋", .red, "nosign")
        }
        guard let rec = Pace.sustainableRate(util: window.utilization,
                                             secondsToReset: window.resetsAt?.timeIntervalSince(now)) else {
            return ("", .secondary, "")
        }
        let recTxt = "권장 ~\(rate(rec))"
        let measured = projection?.ratePerHour ?? 0
        switch projection?.verdict {
        case .idle:
            return ("지금 멈춤 · \(recTxt)까지 써도 리셋에 딱 맞아요", .secondary, "pause")
        case .measuring, .none:
            return ("\(recTxt)로 쓰면 리셋에 딱 맞아요", .secondary, "speedometer")
        case .atRisk:
            return ("빠름 ▲\(rate(measured)) · \(recTxt)로 낮추면 안 막혀요", .orange, "exclamationmark.triangle.fill")
        case .safe:
            if measured > rec * 1.25 { return ("약간 빠름 ▲\(rate(measured)) · \(recTxt)", .orange, "arrow.up.right.circle") }
            if measured < rec * 0.6  { return ("느림 ▲\(rate(measured)) · \(recTxt)까지 올려도 OK", Color.brand, "arrow.up.circle") }
            return ("딱 맞는 페이스 ▲\(rate(measured)) (\(recTxt))", .green, "checkmark.circle")
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

