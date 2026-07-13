import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for limit-threshold alerts.
///
/// `UNUserNotificationCenter.current()` throws if the process has no bundle
/// identifier (e.g. the bare `swift run` dev binary), so every call is guarded —
/// notifications simply no-op until the app is run as a packaged `.app`.
enum Notifier {
    private static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Notification action identifiers — handled in `AppDelegate`'s
    /// `UNUserNotificationCenterDelegate` conformance.
    enum Action: String {
        case snooze = "cbar.snooze"             // "2시간 조용히" — same as the header snooze button
        case resumeNow = "cbar.resumeNow"       // "지금 이어가기" — manually run the resume command
        case copyCompact = "cbar.copyCompact"   // "/compact 복사" — copies the command to the clipboard
    }

    /// Notification categories, each wiring up the one action that's actually
    /// worth a tap right from the banner (not a settings shortcut for its own sake).
    enum Category: String {
        case limit = "cbar.limit"                 // any limit-related nudge/danger → can snooze
        case freed = "cbar.freed"                 // "한도 풀렸어요" → can resume immediately
        case compactSuggest = "cbar.compactSuggest"  // "/compact 하세요" → can snooze or copy the command
    }

    /// Registers the action buttons notifications can carry. Must run before any
    /// notification using a category is posted (called once at app launch).
    static func registerCategories() {
        guard isBundled else { return }
        let snooze = UNNotificationAction(identifier: Action.snooze.rawValue,
                                          title: "2시간 조용히", options: [])
        let resume = UNNotificationAction(identifier: Action.resumeNow.rawValue,
                                          title: "지금 이어가기", options: [.foreground])
        let copyCompact = UNNotificationAction(identifier: Action.copyCompact.rawValue,
                                               title: "/compact 복사", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Category.limit.rawValue, actions: [snooze],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Category.freed.rawValue, actions: [resume],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Category.compactSuggest.rawValue, actions: [copyCompact, snooze],
                                   intentIdentifiers: [], options: []),
        ])
    }

    static func requestAuthorizationIfNeeded() {
        guard isBundled else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, id: String,
                       urgency: AlertUrgency = .danger, category: Category? = nil) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Quiet-coach delivery: only danger makes a sound, and fyi doesn't even
        // banner (notification list only) — see `AlertUrgency`.
        if urgency == .danger { content.sound = .default }
        content.interruptionLevel = urgency == .fyi ? .passive : .active
        if let category { content.categoryIdentifier = category.rawValue }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        // A safety net for passive (no-banner) and easily-missed notifications —
        // see `NotificationLog`.
        NotificationLog.append(id: id, title: title, body: body, at: Date())
    }
}
