import Foundation

/// Coarse, long-retention weekly-utilization time series — separate from the
/// fine-grained `UsageHistory` ring buffer, which only retains a few hours (plenty
/// for the session trend, but nowhere near enough to draw a within-week chart).
/// Stored at `~/.claudebar/weekly-history.json`.
enum WeeklyHistory {
    static let maxSamples = 800                        // ~8 days at one sample / ~15min
    static let minSampleGap: TimeInterval = 12 * 60     // throttle so 8 days stays small

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/weekly-history.json")
    }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    static func load() -> [UsageSample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? decoder.decode([UsageSample].self, from: data) else { return [] }
        return samples
    }

    /// Record a weekly-utilization reading, throttled to `minSampleGap` — a within-week
    /// trend doesn't need session-grade granularity, so this keeps 8 days of history
    /// small on disk. No-op when there's nothing to record.
    static func append(weekly: Double?, at: Date) {
        guard let weekly else { return }
        var samples = load()
        if let last = samples.last, at.timeIntervalSince(last.at) < minSampleGap { return }
        samples.append(UsageSample(at: at, session: nil, weekly: weekly))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }

        guard let data = try? encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
