import Foundation
import ServiceManagement

/// "Launch at login" backed by `SMAppService.mainApp` (macOS 13+).
///
/// Only works for a packaged, registered `.app` (run via `Scripts/package_app.sh`,
/// ideally from /Applications). When running the bare dev binary, registration
/// fails gracefully and `isEnabled` stays false.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success. On failure (e.g. running un-bundled) returns false.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("ClaudeBar: login-item \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
