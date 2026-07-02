import Foundation

/// Turns `ModelRecap`'s in-app "you could downshift" read into a one-shot
/// notification — model choice is a cost lever, not a limit lever (see
/// `ModelRecap`'s doc comment), so this is worth surfacing proactively rather
/// than only when the user happens to open the popover.
enum ModelDownshiftSuggestion {
    /// Rising-edge state so the notification fires once per "episode" of the same
    /// dominant model being downshift-worthy, not every refresh tick. Re-arms when
    /// the dominant model changes, or when it's no longer downshift-worthy (a
    /// different model took over, or its turns got heavier).
    struct State: Equatable {
        var model = ""
        var notified = false
    }

    /// Returns true exactly once when `verdict` newly carries a downshift
    /// suggestion — mutates `state` to track the rising edge.
    static func shouldNotify(_ verdict: ModelRecap.Verdict?, state: inout State) -> Bool {
        guard let verdict, verdict.downshiftTo != nil else { state = State(); return false }
        if state.model != verdict.model { state = State(model: verdict.model) }
        guard !state.notified else { return false }
        state.notified = true
        return true
    }
}
