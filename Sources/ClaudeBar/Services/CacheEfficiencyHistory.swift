import Foundation

/// One reading of the 5h window's fresh-work share.
struct CacheEfficiencySample: Codable, Equatable {
    let at: Date
    let freshShare: Double   // 0...1
}

/// Coarse, long-retention history of the 5h window's fresh-work share — powers
/// `CacheEfficiencyTrend`'s "재읽기 비율이 최근 늘고 있어요" read. Separate from
/// `WeeklyHistory` since it tracks a different quantity (cache mix, not
/// utilization %) and only gets a sample when the window actually has tokens.
/// Stored at `~/.claudebar/cache-efficiency-history.json`.
enum CacheEfficiencyHistory {
    static let maxSamples = 700                       // ~5 weeks at ~1 sample/hour
    static let minSampleGap: TimeInterval = 3600

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/cache-efficiency-history.json")
    }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    static func load() -> [CacheEfficiencySample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? decoder.decode([CacheEfficiencySample].self, from: data) else { return [] }
        return samples
    }

    static func append(freshShare: Double, at: Date) {
        var samples = load()
        if let last = samples.last, at.timeIntervalSince(last.at) < minSampleGap { return }
        samples.append(CacheEfficiencySample(at: at, freshShare: freshShare))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        guard let data = try? encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
