import Foundation

/// One observed session burn rate, tagged with the hour of day it happened —
/// powers "지금 이 시간대엔 원래 이 정도 속도예요" personalization on top of the
/// existing weekday baseline (`BurnAnomaly`). Separate from `UsageHistory` (which
/// only retains ~12h, plenty for burst-rate math but not for cross-day, per-hour
/// pattern mining) and from `WeeklyHistory` (which tracks weekly %, not the
/// session-window rate). Stored at `~/.claudebar/hourly-burn-history.json`.
struct HourlyRateSample: Codable, Equatable {
    let hour: Int          // 0...23, local time
    let ratePerHour: Double
    let at: Date
}

enum HourlyBurnHistory {
    static let maxSamples = 500
    /// Below this many same-hour samples, a "typical for this hour" read is too
    /// noisy to trust — same reasoning as `BurnAnomaly.minHistoryDays`.
    static let minSamplesForBaseline = 5
    /// Ignore near-idle rates — they'd just drag every hour's baseline toward
    /// zero and dilute the signal from hours you're actually working.
    static let idleEpsilon = 0.5

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/hourly-burn-history.json")
    }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    static func load() -> [HourlyRateSample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? decoder.decode([HourlyRateSample].self, from: data) else { return [] }
        return samples
    }

    static func append(rate: Double, at: Date, calendar: Calendar = .current) {
        guard rate > idleEpsilon else { return }
        var samples = load()
        samples.append(HourlyRateSample(hour: calendar.component(.hour, from: at), ratePerHour: rate, at: at))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        guard let data = try? encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Median historical rate at this hour of day, or nil without enough samples.
    static func typicalRate(forHour hour: Int, in samples: [HourlyRateSample]) -> Double? {
        let matching = samples.filter { $0.hour == hour }.map(\.ratePerHour).sorted()
        guard matching.count >= minSamplesForBaseline else { return nil }
        let mid = matching.count / 2
        return matching.count.isMultiple(of: 2) ? (matching[mid - 1] + matching[mid]) / 2 : matching[mid]
    }
}
