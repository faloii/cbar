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
func withTimeout<T: Sendable>(seconds: TimeInterval,
                              operation: @escaping @Sendable () async -> T) async -> T? {
    let box = TimeoutResultBox<T>()
    Task {
        let result = await operation()
        await box.set(result)
    }
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    return await box.get()
}

private actor TimeoutResultBox<T> {
    private var value: T?
    func set(_ v: T) { value = v }
    func get() -> T? { value }
}
