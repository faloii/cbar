import SwiftUI
import AppKit

struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            // Icon + the chosen at-a-glance metric. Turns into an orange warning
            // glyph once a live limit crosses the warning threshold.
            HStack(spacing: 3) {
                Image(systemName: store.isOverThreshold ? "exclamationmark.triangle.fill" : "sparkle")
                    .foregroundStyle(store.isOverThreshold ? Color.orange : Color.primary)
                Text(store.barText).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Run as a menu-bar-only accessory app (no Dock icon, no main window).
/// The Settings window is managed by `SettingsWindowController`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
