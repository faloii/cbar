import Foundation

/// Detects the moment the weekly limit window actually rolls over: `resetsAt`
/// jumps forward to a new future date the instant the old window elapses. Lets
/// the weekly recap notification fire on a real reset instead of an arbitrary
/// 7-day timer, when live limits are available to observe it.
enum WeeklyResetRecap {
    /// `nil` on either side means nothing to compare yet (first observation, or
    /// live limits unavailable) — correctly stays quiet then.
    static func justReset(old: Date?, new: Date?) -> Bool {
        guard let old, let new else { return false }
        return new > old
    }
}
