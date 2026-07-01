import Foundation

/// The next few 5-hour session-window reset times, walked forward from the next
/// known reset (resets are periodic, so every later one is just +5h). Lets you
/// plan heavy work around the day's rhythm instead of reacting only when the
/// current window is about to flip.
enum UpcomingResets {
    static func compute(nextReset: Date, now: Date, count: Int = 3,
                        windowSeconds: TimeInterval = 5 * 3600) -> [Date] {
        guard nextReset > now, count > 0 else { return [] }
        return (0..<count).map { nextReset.addingTimeInterval(Double($0) * windowSeconds) }
    }
}
