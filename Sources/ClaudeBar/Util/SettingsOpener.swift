import AppKit
import SwiftUI

@MainActor
enum SettingsOpener {
    static func open() { SettingsWindowController.shared.show() }
    static func close() { SettingsWindowController.shared.close() }
}

/// Owns the Settings window directly. SwiftUI's `Settings` scene / `openSettings()`
/// is unreliable from a `MenuBarExtra` accessory app, so we build an `NSWindow`
/// ourselves and, while it's open, flip the app to a regular (Dock-visible) app so
/// the window can reliably take focus and come to the front — reverting to accessory
/// when it closes.
/// A panel that never becomes key/main, so showing it doesn't make the menu-bar
/// popover resign key (and dismiss). All Settings controls are mouse-operable.
///
/// NOTE: an earlier version also overrode `isKeyWindow` to `true`, purely to fix
/// toggles rendering in the muted "inactive window" gray regardless of on/off
/// state. That override was reverted — it made AppKit's focus/key-window
/// bookkeeping inconsistent (this panel claiming to be key while genuinely
/// unable to become key), which reintroduced itself as a worse bug: clicking a
/// toggle could cause the real key window (the popover) to resign key and
/// dismiss, closing Settings along with it. A correct fix for the color issue,
/// if revisited, needs to not misrepresent `isKeyWindow`.
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
            p.title = "CBar 설정"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            panel = p
        }
        positionNextToPopover()
        // Float it in without activating the app, so the popover keeps key and stays open.
        panel?.orderFrontRegardless()
    }

    /// Hide the panel — used when the popover is dismissed so they close together.
    func close() { panel?.orderOut(nil) }

    /// Snap the panel against the left edge of the open popover, top-aligned.
    /// Our app's only other visible window is the MenuBarExtra popover.
    private func positionNextToPopover() {
        guard let p = panel else { return }
        let vf = NSScreen.main?.visibleFrame
        let popover = NSApp.windows.first {
            $0 !== p && $0.isVisible && $0.frame.width > 120 && $0.frame.height > 120
        }
        if let pop = popover {
            // Match the popover's (high) window level so the panel isn't hidden behind it.
            p.level = pop.level
            var x = pop.frame.minX - p.frame.width
            if let vf, x < vf.minX { x = pop.frame.maxX }   // no room on the left → go right
            var y = pop.frame.maxY - p.frame.height
            if let vf { y = max(vf.minY, y) }
            p.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            p.level = .floating
            if let vf {
                p.setFrameOrigin(NSPoint(x: vf.minX + 24, y: vf.maxY - p.frame.height - 8))
            }
        }
    }
}
