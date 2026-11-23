import Foundation

/// One `LimitCalibration.Sample` per session window — the latest reading of it,
/// since the ratio firms up as the window fills. Powers the "usual $ per 1%"
/// baseline the live ratio is checked against.
/// Stored at `~/.claudebar/limit-calibration-history.json`.
enum LimitCalibrationHistory {
    static let maxSamples = 60                        // ~2 weeks of 5h windows

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/limit-calibration-history.json")
    }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    static func load() -> [LimitCalibration.Sample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? decoder.decode([LimitCalibration.Sample].self, from: data) else { return [] }
        return samples
    }

    /// Replaces this window's earlier reading, if any.
    static func record(_ sample: LimitCalibration.Sample) {
        var samples = load()
        if let last = samples.last, LimitCalibration.sameWindow(last.resetsAt, sample.resetsAt),
           abs(last.dollarsPerPercent - sample.dollarsPerPercent) < last.dollarsPerPercent * 0.01 { return }
        samples.removeAll { LimitCalibration.sameWindow($0.resetsAt, sample.resetsAt) }
        samples.append(sample)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        guard let data = try? encoder.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
