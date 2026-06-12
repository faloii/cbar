import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for limit-threshold alerts.
///
/// `UNUserNotificationCenter.current()` throws if the process has no bundle
/// identifier (e.g. the bare `swift run` dev binary), so every call is guarded —
/// notifications simply no-op until the app is run as a packaged `.app`.
enum Notifier {
    private static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorizationIfNeeded() {
        guard isBundled else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, id: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
