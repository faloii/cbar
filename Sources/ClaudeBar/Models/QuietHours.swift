import Foundation

/// A simple do-not-disturb window for proactive notifications. Only the
/// interruptive banner is suppressed — the menu-bar icon/color and the popover
/// keep reflecting real state regardless, so nothing is actually hidden, just
/// not pushed at you.
enum QuietHours {
    /// `start`/`end` are hours 0...23. Wraps past midnight when `start > end`
    /// (e.g. 22 → 8 means quiet from 22:00 through 07:59). Equal values mean a
    /// zero-length window, i.e. never quiet.
    static func isQuiet(hour: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }
}
