import Foundation

/// Combines multiple alerts that fire in the SAME evaluation tick into one
/// notification, instead of posting a stack of separate banners at once — e.g.
/// jumping straight past two weekly severity tiers in one refresh, or a session
/// risk and a weekly risk landing together. Keeps the "quiet coach" quiet even
/// as the number of distinct alert types grows. 0 or 1 alerts pass through
/// unchanged — bundling only kicks in when there's actually a stack to flatten.
enum NotificationBundler {
    static func bundle(_ alerts: [LimitAlert]) -> [LimitAlert] {
        guard alerts.count > 1 else { return alerts }
        let body = alerts.map { "· \($0.title)" }.joined(separator: "\n")
        let id = "bundle-" + alerts.map(\.id).sorted().joined(separator: "-")
        return [LimitAlert(id: id, title: "한도 알림 \(alerts.count)건", body: body)]
    }
}
