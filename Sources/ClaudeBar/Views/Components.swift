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
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
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

    private var color: Color {
        switch fraction {
        case ..<0.6:  return .green
        case ..<0.85: return Color(red: 0.95, green: 0.7, blue: 0.2)
        default:      return .red
        }
    }

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
        .frame(height: 7)
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

/// A plan-limit row: "Session (5h)  42%  ·  resets in 2h 13m" + meter + a burn-rate
/// projection subline ("▲ 12%/h · lasts past reset" / "… full in 50m — 3h before reset").
struct LimitRow: View {
    let title: String
    let subtitle: String
    let window: LimitWindow
    let now: Date
    var projection: Projection? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let reset = window.resetsAt {
                    Text("\(Fmt.countdown(to: reset, from: now)) 후 리셋")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            MeterBar(fraction: window.fraction)
            projectionLine
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var projectionLine: some View {
        if window.utilization >= 100 {
            let reset = window.resetsAt.map { Fmt.countdown(to: $0, from: now) } ?? "?"
            line("지금 막힘 · \(reset) 후 리셋", .red, "nosign")
        } else if let p = projection {
            switch p.verdict {
            case .measuring:
                line("측정 중…", .secondary, "hourglass")
            case .idle:
                line("사용 없음", .secondary, "pause")
            case .safe:
                if let proj = p.projectedAtReset {
                    let pct = Int(proj.rounded())
                    if proj >= 90 {
                        line("\(rateText(p.ratePerHour)) · 리셋까지 거의 다 씀(~\(pct)%)", .green, "checkmark.circle")
                    } else {
                        line("\(rateText(p.ratePerHour)) · 리셋 때 ~\(pct)% · \(max(0, 100 - pct))% 여유", .secondary, "gauge.medium")
                    }
                } else {
                    line("\(rateText(p.ratePerHour)) · 리셋까지 충분", .green, "checkmark.circle")
                }
            case .atRisk:
                let full = p.timeToFull.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
                let gap = p.blockedBy.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
                line("\(rateText(p.ratePerHour)) · \(full) 후 소진 — 리셋보다 \(gap) 빠름", .orange, "exclamationmark.triangle.fill")
            }
        }
    }

    private func rateText(_ rate: Double) -> String {
        rate >= 10 ? "▲ \(Int(rate.rounded()))%/h" : String(format: "▲ %.1f%%/h", rate)
    }

    private func line(_ text: String, _ color: Color, _ icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(color)
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

