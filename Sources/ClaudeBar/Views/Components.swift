import SwiftUI

/// Horizontal usage meter with a colored fill that shifts toward red as it fills.
struct MeterBar: View {
    let fraction: Double   // 0...1

    private var color: Color {
        switch fraction {
        case ..<0.6:  return .green
        case ..<0.85: return .yellow
        default:      return .red
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(color)
                    .frame(width: max(3, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

/// Minimal sparkline for the daily token history.
struct Sparkline: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let n = max(values.count - 1, 1)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(n)
                    let y = geo.size.height * (1 - CGFloat(v) / CGFloat(maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, style: .init(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: 28)
    }
}

/// Small bar chart of daily cost; the most recent day is highlighted.
struct DailyCostBars: View {
    let days: [DailyCost]

    var body: some View {
        let maxV = max(days.map(\.cost).max() ?? 0, 0.0001)
        GeometryReader { geo in
            let gap: CGFloat = 2
            let n = max(days.count, 1)
            let w = max(2, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor.opacity(i == days.count - 1 ? 1.0 : 0.45))
                        .frame(width: w, height: max(2, geo.size.height * CGFloat(d.cost / maxV)))
                        .help("\(d.date): ~\(Fmt.usd(d.cost)) · \(Fmt.tokens(d.tokens))")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 30)
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
                    Text("resets in \(Fmt.countdown(to: reset, from: now))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            MeterBar(fraction: window.fraction)
            projectionLine
        }
    }

    @ViewBuilder private var projectionLine: some View {
        if let p = projection {
            switch p.verdict {
            case .measuring:
                line("measuring rate…", .secondary, "hourglass")
            case .idle:
                line("not burning", .secondary, "pause")
            case .safe:
                line("\(rateText(p.ratePerHour)) · lasts past reset", .green, "checkmark.circle")
            case .atRisk:
                let full = p.timeToFull.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
                let gap = p.blockedBy.map { Fmt.countdown(to: now.addingTimeInterval($0), from: now) } ?? "?"
                line("\(rateText(p.ratePerHour)) · full in \(full) — \(gap) before reset", .orange, "exclamationmark.triangle.fill")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.model).font(.callout.weight(.medium))
                Spacer()
                Text(String(format: "%.1f×", row.burnMultiplier))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(row.burnMultiplier >= 2 ? .orange : .secondary)
                    .help("Per-turn \(basis.shortLabel) vs the lightest model you used")
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
                if let h = row.headroomTurns {
                    Text("·")
                    Text("~\(Int(h.rounded())) turns left").foregroundStyle(row.burnMultiplier >= 2 ? .orange : .secondary)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Section header.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }
}
