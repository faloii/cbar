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
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }   // "140h 32m" reads poorly
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    /// Single-unit countdown for tight spaces (under a gauge): "6d" / "2h" / "13m" / "<1m".
    static func shortCountdown(to date: Date, from now: Date = Date()) -> String {
        let secs = max(0, Int(date.timeIntervalSince(now)))
        if secs >= 86400 { return "\(secs / 86400)d" }
        if secs >= 3600  { return "\(secs / 3600)h" }
        if secs >= 60    { return "\(secs / 60)m" }
        return "<1m"
    }

    /// Two-unit countdown for under a gauge when minutes matter (the session window):
    /// "1d 4h" / "2h 13m" / "13m" / "<1m".
    static func mediumCountdown(to date: Date, from now: Date = Date()) -> String {
        let secs = max(0, Int(date.timeIntervalSince(now)))
        if secs >= 86400 { return "\(secs / 86400)d \((secs % 86400) / 3600)h" }
        if secs >= 3600  { return "\(secs / 3600)h \((secs % 3600) / 60)m" }
        if secs >= 60    { return "\(secs / 60)m" }
        return "<1m"
    }

    /// "방금" / "N분 전" / "N시간 M분 전" — how long ago `date` was. Keeps minute
    /// precision through the whole under-a-day range (not just whole hours) — two
    /// events 10 minutes apart both truncating to the same "N시간 전" reads as a
    /// bug (looks like a duplicate/stuck timestamp) even though it's just coarse
    /// rounding.
    static func age(_ date: Date, from now: Date = Date()) -> String {
        let secs = max(0, Int(now.timeIntervalSince(date)))
        if secs < 60 { return "방금" }
        let m = secs / 60
        if m < 60 { return "\(m)분 전" }
        let h = m / 60
        if h < 24 {
            let remM = m % 60
            return remM > 0 ? "\(h)시간 \(remM)분 전" : "\(h)시간 전"
        }
        return "\(h / 24)일 전"
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

    /// Compact 24-hour wall-clock "15:30" — for tight UI (the gauge reset line) where
    /// the locale-short "오후 3:30" would be too wide.
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Compact "9/15" — pairs with a multi-day countdown ("4d") so "언제" has an
    /// actual calendar date, not just a relative offset you'd have to do the
    /// math on yourself.
    static func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
}
