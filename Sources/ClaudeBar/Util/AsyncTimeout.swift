import Foundation

/// Races `operation` against a timeout so a hung call deep inside it can't block
/// the caller forever — e.g. macOS's Keychain `SecItemCopyMatching` blocks
/// indefinitely while a system authorization dialog is pending, and if that fires
/// while the Mac is asleep/locked (nobody around to answer it), it never returns.
/// The abandoned call keeps running in the background (harmless — its result, if
/// it ever arrives, is simply discarded) so this only stops *waiting*, it doesn't
/// cancel the underlying work.
///
/// Must spawn `operation` as a plain unstructured `Task { }`, NOT inside a
/// `withTaskGroup`: a task group is structured concurrency and is REQUIRED to
/// await every child task before its scope can return, timeout or not. A version
/// that used `withTaskGroup` here never actually timed out for a genuinely stuck
/// call — it silently waited for the same hang it was supposed to escape (see
/// `AsyncTimeoutTests.testReturnsNilWithoutWaitingForSlowOperation`, which would
/// fail if this regressed back to that shape).
///
/// Returns as soon as EITHER side finishes — a fast operation must not wait out
/// the full timeout (an earlier version slept unconditionally for `seconds`, so
/// every refresh cycle took the whole timeout even when the work took 50ms).
func withTimeout<T: Sendable>(seconds: TimeInterval,
                              operation: @escaping @Sendable () async -> T) async -> T? {
    let gate = TimeoutGate<T>()
    return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        let timer = Task {
            // Cancelled → the operation already won; don't resume a second time.
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) } catch { return }
            await gate.finish(nil, cont)
        }
        Task {
            let result = await operation()
            await gate.finish(result, cont)
            timer.cancel()
        }
    }
}

/// Resumes the continuation exactly once — whichever of operation/timer gets here first.
private actor TimeoutGate<T: Sendable> {
    private var done = false
    func finish(_ value: T?, _ cont: CheckedContinuation<T?, Never>) {
        guard !done else { return }
        done = true
        cont.resume(returning: value)
    }
}
