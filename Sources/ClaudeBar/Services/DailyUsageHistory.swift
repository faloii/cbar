import Foundation

/// Persisted `DailyUsage` per day, so the weekly review, burn-anomaly baseline and
/// habit goal keep their history even after Claude Code prunes old session logs.
/// Each full log scan merges its complete days in; a one-time backfill seeds every
/// day the existing logs still cover. Stored at `~/.claudebar/daily-usage.json`.
enum DailyUsageHistory {
    static let maxDays = 120

    struct File: Codable {
        var backfilled = false
        var days: [DailyUsage] = []
    }

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/daily-usage.json")
    }

    static func load() -> File {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    /// Read-modify-write against what's on disk NOW, so a backfill and a regular
    /// scan finishing in either order can't drop each other's days.
    static func update(_ change: (inout File) -> Void) {
        var file = load()
        change(&file)
        if file.days.count > maxDays { file.days.removeFirst(file.days.count - maxDays) }
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
