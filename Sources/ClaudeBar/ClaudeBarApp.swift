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

/// Run as a menu-bar-only accessory app (no Dock icon, no main window) and own the
/// Settings window directly — the SwiftUI `Settings` scene + `showSettingsWindow:`
/// selector is unreliable to open from a MenuBarExtra accessory app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @MainActor func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "ClaudeBar 설정"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
