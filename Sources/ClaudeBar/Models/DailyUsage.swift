import Foundation

/// One local calendar day of Claude Code usage, aggregated from this Mac's session
/// logs. Replaces `stats-cache.json`'s per-day totals, which Claude Code stopped
/// updating (its `lastComputedDate` froze at 2026-06-10), and prices each turn with
/// the current table instead of a blended lifetime rate.
struct DailyUsage: Codable, Equatable {
    struct ModelDay: Codable, Equatable {
        var tokens = 0
        var cost = 0.0
    }

    let date: String                        // "yyyy-MM-dd", local time
    var byModel: [String: ModelDay] = [:]   // display name ("Opus 5.5")
    var sessions = 0                        // distinct conversations with a turn that day
    var turns = 0                           // assistant turns

    var cost: Double { byModel.values.reduce(0) { $0 + $1.cost } }
    var tokens: Int { byModel.values.reduce(0) { $0 + $1.tokens } }

    /// Stored history with `fresh` days laid over it, sorted by date. A fresh day
    /// replaces the stored one — logs are the source of truth and the latest scan
    /// saw at least as much — except days before `fullFrom`, which the scan only
    /// partly covered (its window starts mid-day) and would undercount.
    static func merge(stored: [DailyUsage], fresh: [DailyUsage], fullFrom: String) -> [DailyUsage] {
        var byDate = Dictionary(stored.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        for d in fresh where d.date >= fullFrom { byDate[d.date] = d }
        return byDate.values.sorted { $0.date < $1.date }
    }
}
