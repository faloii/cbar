import Foundation

enum Fmt {
    /// Compact token count: 1_234 → "1.2K", 8_700_000 → "8.7M".
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch abs(n) {
        case 1_000_000_000...: return trim(v / 1e9) + "B"
        case 1_000_000...:     return trim(v / 1e6) + "M"
        case 1_000...:         return trim(v / 1e3) + "K"
        default:               return "\(n)"
        }
    }

    private static func trim(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    static func usd(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }

    static func int(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "2h 13m" style countdown from now until `date`.
    static func countdown(to date: Date, from now: Date = Date()) -> String {
        let secs = max(0, Int(date.timeIntervalSince(now)))
        let h = secs / 3600, m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}
