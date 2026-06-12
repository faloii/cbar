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

/// A plan-limit row: "Session (5h)  42%  ·  resets in 2h 13m" + meter.
struct LimitRow: View {
    let title: String
    let subtitle: String
    let window: LimitWindow
    let now: Date

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
