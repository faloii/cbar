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

    /// Don't re-log the same alert twice in a row within this window — a
    /// projection-based alert whose `atRisk` verdict flaps around the threshold
    /// across refresh ticks can genuinely re-fire, but recording two identical
    /// "곧 소진 · 25h 16m" rows minutes apart just reads as a rendering bug in the
    /// popover's "최근 알림" list. Collapse those; a truly distinct later
    /// occurrence (different text, or well after this window) still gets its row.
    static let dedupWindow: TimeInterval = 30 * 60

    /// Whether an entry with this exact title+body already appears within the
    /// dedup window. Pure (no I/O) so it's unit-testable. Checks ALL recent
    /// entries, not just the immediately-preceding one: risk alerts commonly
    /// interleave (주간→세션→주간→세션 as each re-arms), so a last-only check
    /// would miss the alternating duplicates.
    static func isDuplicate(of entries: [NotificationLogEntry],
                            title: String, body: String, at: Date) -> Bool {
        entries.contains {
            $0.title == title && $0.body == body && at.timeIntervalSince($0.at) < dedupWindow
        }
    }

    /// Collapses within-window duplicates already present in a loaded log, keeping
    /// the earliest of each cluster. Self-heals historical duplicates written
    /// before dedup existed (they otherwise linger until the ring buffer evicts
    /// them). Entries the same text but OUTSIDE the window of every kept copy are
    /// preserved — a genuine re-occurrence hours later still gets its own row.
    static func compacted(_ entries: [NotificationLogEntry]) -> [NotificationLogEntry] {
        var kept: [NotificationLogEntry] = []
        for e in entries.sorted(by: { $0.at < $1.at }) {
            let dup = kept.contains {
                $0.title == e.title && $0.body == e.body && e.at.timeIntervalSince($0.at) < dedupWindow
            }
            if !dup { kept.append(e) }
        }
        return kept
    }

    static func append(id: String, title: String, body: String, at: Date) {
        var entries = compacted(load())
        if isDuplicate(of: entries, title: title, body: body, at: at) { return }
        entries.append(NotificationLogEntry(id: id, title: title, body: body, at: at))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
