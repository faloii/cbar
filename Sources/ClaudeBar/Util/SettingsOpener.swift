import AppKit

/// Opens the SwiftUI `Settings` scene reliably from a `MenuBarExtra`.
///
/// `@Environment(\.openSettings)` is unreliable inside a MenuBarExtra for an
/// accessory (LSUIElement) app — the window often never appears because the app
/// isn't the active one. Activating first and routing the standard AppKit
/// "showSettingsWindow:" action through the responder chain is the proven fix.
enum SettingsOpener {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI wires the Settings scene to this selector (macOS 13+).
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            // Very old fallback name, just in case.
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
