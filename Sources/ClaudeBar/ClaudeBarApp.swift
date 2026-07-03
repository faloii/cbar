import SwiftUI
import AppKit
import UserNotifications

struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            // Icon + the chosen at-a-glance metric. Becomes a warning triangle past
            // the warn threshold, a "blocked" sign once a limit is maxed out, or —
            // when safely under threshold with live limits on — a tiny ring gauge
            // of the worse window's utilization instead of a static sparkle, so the
            // menu bar itself shows rough headroom without opening the popover.
            HStack(spacing: 3) {
                if store.isBlocked {
                    Image(systemName: "nosign")
                } else if store.isOverThreshold {
                    Image(systemName: "exclamationmark.triangle.fill")
                } else if let u = store.maxLimitUtilization {
                    MenuBarMiniGauge(fraction: u / 100)
                } else {
                    Image(systemName: "sparkle")
                }
                Text(store.barText).monospacedDigit()
            }
            .foregroundStyle(store.barColor)   // green → orange → red by limit level
        }
        .menuBarExtraStyle(.window)
    }
}

/// Run as a menu-bar-only accessory app (no Dock icon, no main window).
/// The Settings window is managed by `SettingsWindowController`. Also owns the
/// notification action buttons (snooze / resume-now) since `UNUserNotificationCenterDelegate`
/// needs a long-lived object to receive them.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerCategories()
    }

    /// Show the banner (and play the sound) even when CBar has no foreground
    /// window — the default for a menu-bar-only app is to suppress this.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// Handle the action buttons registered in `Notifier.registerCategories()`.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            switch response.actionIdentifier {
            case Notifier.Action.snooze.rawValue:
                if !UsageStore.shared.isSnoozed { UsageStore.shared.toggleSnooze() }
            case Notifier.Action.resumeNow.rawValue:
                UsageStore.shared.resumeNow()
            default: break
            }
            completionHandler()
        }
    }
}
