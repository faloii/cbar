import AppKit
import SwiftUI

@MainActor
enum SettingsOpener {
    static func open() { SettingsWindowController.shared.show() }
}

/// Owns the Settings window directly. SwiftUI's `Settings` scene / `openSettings()`
/// is unreliable from a `MenuBarExtra` accessory app, so we build an `NSWindow`
/// ourselves and, while it's open, flip the app to a regular (Dock-visible) app so
/// the window can reliably take focus and come to the front — reverting to accessory
/// when it closes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        NSLog("ClaudeBar: SettingsOpener.show()")
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: .shared))
            let w = NSWindow(contentViewController: hosting)
            w.title = "ClaudeBar 설정"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
