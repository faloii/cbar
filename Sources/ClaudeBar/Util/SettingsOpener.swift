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
/// A panel that never becomes key/main, so showing it doesn't make the menu-bar
/// popover resign key (and dismiss). All Settings controls are mouse-operable.
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: .shared))
            let p = NonKeyPanel(contentViewController: hosting)
            p.styleMask = [.titled, .closable, .nonactivatingPanel]
            p.title = "ClaudeBar 설정"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            // Place at the top-left so it doesn't overlap the popover (top-right).
            if let vf = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: vf.minX + 24, y: vf.maxY - p.frame.height - 8))
            } else {
                p.center()
            }
            panel = p
        }
        // Float it in without activating the app, so the popover keeps key and stays open.
        panel?.orderFrontRegardless()
    }
}
