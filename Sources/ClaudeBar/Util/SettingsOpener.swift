import AppKit

/// Opens the Settings window. We manage the window ourselves in `AppDelegate`
/// because SwiftUI's `openSettings()` / `Settings` scene is unreliable to trigger
/// from a `MenuBarExtra` accessory app.
enum SettingsOpener {
    @MainActor static func open() {
        (NSApp.delegate as? AppDelegate)?.showSettings()
    }
}
