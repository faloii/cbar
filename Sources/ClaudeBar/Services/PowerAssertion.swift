import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion to keep the *system* awake while active (the
/// display may still sleep — like `caffeinate -i`). Used to stay awake while
/// blocked so a limit reset isn't missed. Idempotent; auto-released on process exit.
///
/// Note: this prevents *idle* sleep only. Closing a laptop lid on battery (clamshell)
/// still sleeps regardless.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private var active = false
    private let reason: String

    init(reason: String) { self.reason = reason }

    func set(_ on: Bool) { on ? acquire() : release() }

    private func acquire() {
        guard !active else { return }
        var aid: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString, &aid)
        if r == kIOReturnSuccess { id = aid; active = true }
    }

    private func release() {
        guard active else { return }
        IOPMAssertionRelease(id)
        active = false
        id = 0
    }
}
