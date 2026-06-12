import Foundation

/// Append-only (ring-buffered) usage time-series on disk, used to compute burn rate.
/// Stored at `~/.claudebar/usage-history.json`.
enum UsageHistory {
    static let maxSamples = 240   // ~12h at one sample / 3 min

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/usage-history.json")
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

    /// Record a sample, skipping exact-timestamp duplicates. No-op if both values are nil.
    static func append(session: Double?, weekly: Double?, at: Date) {
        guard session != nil || weekly != nil else { return }
        var samples = load()
        if let last = samples.last, last.at == at { return }
        samples.append(UsageSample(at: at, session: session, weekly: weekly))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }

        guard let data = try? encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func sessionPoints() -> [(Date, Double)] {
        load().compactMap { s in s.session.map { (s.at, $0) } }
    }
    static func weeklyPoints() -> [(Date, Double)] {
        load().compactMap { s in s.weekly.map { (s.at, $0) } }
    }
}
