import Foundation

/// Detects the moment the weekly limit window actually rolls over: `resetsAt`
/// jumps forward to a new future date the instant the old window elapses. Lets
/// the weekly recap notification fire on a real reset instead of an arbitrary
/// 7-day timer, when live limits are available to observe it.
enum WeeklyResetRecap {
    /// A real rollover moves `resetsAt` forward by about a week. The API's value
    /// also jitters by fractions of a second between fetches, and a bare
    /// `new > old` read every upward jitter as a reset — repeating the recap.
    static let minJump: TimeInterval = 3600
    /// More than one window back means `old` is stale (rollovers went unrecorded),
    /// not that the window just rolled over.
    static let maxJump: TimeInterval = 8 * 24 * 3600

    /// `nil` on either side means nothing to compare yet (first observation, or
    /// live limits unavailable) — correctly stays quiet then.
    static func justReset(old: Date?, new: Date?) -> Bool {
        guard let old, let new else { return false }
        let jump = new.timeIntervalSince(old)
        return jump >= minJump && jump <= maxJump
    }
}
