import Foundation

/// One notification CBar has posted — kept around after the banner disappears.
struct NotificationLogEntry: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let body: String
    let at: Date
}

/// A small on-disk log of the last few notifications CBar has posted — a safety
/// net for the ones delivered as passive/no-banner (see `AlertUrgency.fyi`, e.g.
/// the weekly recap) or simply missed while away from the Mac. macOS's own
/// Notification Center already keeps these, but users don't always think to check
/// it for a menu-bar utility, so the popover surfaces the same short history.
/// Stored at `~/.claudebar/notification-log.json`.
enum NotificationLog {
    static let maxEntries = 20

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/notification-log.json")
    }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    /// Newest last.
    static func load() -> [NotificationLogEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? decoder.decode([NotificationLogEntry].self, from: data) else { return [] }
        return entries
    }

    static func append(id: String, title: String, body: String, at: Date) {
        var entries = load()
        entries.append(NotificationLogEntry(id: id, title: title, body: body, at: at))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
