import Foundation

/// Reads Claude Code's local data (no network) and builds a `UsageSnapshot`.
///
/// Two sources:
///   • `~/.claude/stats-cache.json` — Claude's own aggregated counts (sessions,
///     messages, tool calls, per-day token totals).
///   • `~/.claude/projects/**/*.jsonl` — per-request token usage with timestamps,
///     which we sum for the rolling 5-hour window and today's cost breakdown.
struct ClaudeDataReader {

    static let windowDuration: TimeInterval = 5 * 3600

    /// Honors `CLAUDE_CONFIG_DIR`, falling back to `~/.claude`.
    static var configDir: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Build a fresh snapshot. Safe to call off the main thread.
    func load(now: Date = Date()) -> UsageSnapshot {
        var snap = UsageSnapshot(generatedAt: now)
        applyStatsCache(to: &snap, now: now)
        applySessionLogs(to: &snap, now: now)
        return snap
    }

    // MARK: - stats-cache.json

    private func applyStatsCache(to snap: inout UsageSnapshot, now: Date) {
        let url = Self.configDir.appendingPathComponent("stats-cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        snap.totalSessions = root["totalSessions"] as? Int ?? 0
        snap.totalMessages = root["totalMessages"] as? Int ?? 0
        if let first = root["firstSessionDate"] as? String {
            snap.firstSessionDate = DateParse.iso(first)
        }

        // Per-model lifetime blended rates (for daily cost estimation).
        var modelUsage: [String: TokenCounts] = [:]
        if let mu = root["modelUsage"] as? [String: [String: Any]] {
            for (model, v) in mu {
                modelUsage[model] = TokenCounts(
                    input: v["inputTokens"] as? Int ?? 0,
                    output: v["outputTokens"] as? Int ?? 0,
                    cacheWrite: v["cacheCreationInputTokens"] as? Int ?? 0,
                    cacheRead: v["cacheReadInputTokens"] as? Int ?? 0
                )
            }
        }
        let (rates, fallback) = CostEstimator.blendedRates(modelUsage)

        // Per-day token totals + estimated cost (for the trend chart).
        if let daily = root["dailyModelTokens"] as? [[String: Any]] {
            let history: [DailyCost] = daily.compactMap { entry in
                guard let date = entry["date"] as? String,
                      let byModel = entry["tokensByModel"] as? [String: Int] else { return nil }
                return DailyCost(date: date,
                                 tokens: byModel.values.reduce(0, +),
                                 cost: CostEstimator.dailyCost(tokensByModel: byModel, rates: rates, fallback: fallback))
            }
            snap.dailyCostHistory = Array(history.suffix(30))
            snap.dailyTokenHistory = Array(history.suffix(14).map(\.tokens))
        }
    }

    // MARK: - session *.jsonl logs

    private func applySessionLogs(to snap: inout UsageSnapshot, now: Date) {
        let records = recentRecords(now: now)
        let windowStart = now.addingTimeInterval(-Self.windowDuration)
        let todayStart = Calendar.current.startOfDay(for: now)

        var windowTokens = TokenCounts()
        var windowCost = 0.0
        var oldestInWindow: Date?
        var winByModel: [String: ModelWindowUsage] = [:]

        var todayTokens = TokenCounts()
        var todayCost = 0.0
        var byModel: [String: ModelUsage] = [:]
        var todayRequests = 0
        var todayToolCalls = 0
        var todaySessions = Set<String>()

        for r in records {
            let isToday = r.timestamp >= todayStart
            if isToday {
                if !r.sessionId.isEmpty { todaySessions.insert(r.sessionId) }
                todayToolCalls += r.toolUseCount
            }

            // Only assistant turns carry token usage / cost.
            guard let tokens = r.tokens, r.type == "assistant" else { continue }
            let cost = Pricing.cost(for: tokens, model: r.model)

            if r.timestamp >= windowStart {
                windowTokens += tokens
                windowCost += cost
                if oldestInWindow == nil || r.timestamp < oldestInWindow! {
                    oldestInWindow = r.timestamp
                }
                let key = ModelName.display(r.model)
                var mw = winByModel[key] ?? ModelWindowUsage(model: key, tokens: TokenCounts(), cost: 0, requests: 0)
                mw.tokens += tokens
                mw.cost += cost
                mw.requests += 1
                winByModel[key] = mw
            }

            if isToday {
                todayRequests += 1
                todayTokens += tokens
                todayCost += cost
                let key = ModelName.display(r.model)
                var mu = byModel[key] ?? ModelUsage(model: key, tokens: TokenCounts(), cost: 0)
                mu.tokens += tokens
                mu.cost += cost
                byModel[key] = mu
            }
        }

        snap.windowTokens = windowTokens
        snap.windowCost = windowCost
        snap.windowResetAt = oldestInWindow.map { $0.addingTimeInterval(Self.windowDuration) }
        snap.windowByModel = winByModel.values
            .filter { $0.tokens.total > 0 }
            .sorted { $0.tokens.total > $1.tokens.total }

        snap.todayTokens = todayTokens
        snap.todayCost = todayCost
        snap.todayRequests = todayRequests
        snap.todayToolCalls = todayToolCalls
        snap.todaySessions = todaySessions.count
        snap.todayByModel = byModel.values
            .filter { $0.tokens.total > 0 }
            .sorted { $0.tokens.total > $1.tokens.total }
    }

    /// One parsed line from a session log.
    private struct LogRecord {
        let timestamp: Date
        let type: String        // "user" | "assistant" | ...
        let sessionId: String
        let model: String
        let tokens: TokenCounts? // assistant turns only
        let toolUseCount: Int
    }

    /// Parse session logs touched in the last ~36h. (We only need today + a 5h
    /// window, so older files are skipped for speed.)
    private func recentRecords(now: Date) -> [LogRecord] {
        let projects = Self.configDir.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: projects,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return [] }

        let cutoff = now.addingTimeInterval(-36 * 3600)
        var records: [LogRecord] = []

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < cutoff { continue }
            records.append(contentsOf: parse(fileAt: url))
        }
        return records
    }

    private func parse(fileAt url: URL) -> [LogRecord] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [LogRecord] = []

        content.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  let ts = obj["timestamp"] as? String,
                  let date = DateParse.iso(ts)
            else { return }

            let sessionId = obj["sessionId"] as? String ?? ""
            let message = obj["message"] as? [String: Any]

            var tokens: TokenCounts?
            var toolUses = 0
            if let message {
                if let usage = message["usage"] as? [String: Any] {
                    tokens = TokenCounts(
                        input: usage["input_tokens"] as? Int ?? 0,
                        output: usage["output_tokens"] as? Int ?? 0,
                        cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                        cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0
                    )
                }
                if let content = message["content"] as? [[String: Any]] {
                    toolUses = content.reduce(0) { $0 + (($1["type"] as? String) == "tool_use" ? 1 : 0) }
                }
            }

            out.append(LogRecord(
                timestamp: date,
                type: type,
                sessionId: sessionId,
                model: message?["model"] as? String ?? "unknown",
                tokens: tokens,
                toolUseCount: toolUses
            ))
        }
        return out
    }
}

// MARK: - Helpers

enum DateParse {
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601NoFrac = ISO8601DateFormatter()

    static func iso(_ s: String) -> Date? {
        iso8601.date(from: s) ?? iso8601NoFrac.date(from: s)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local-calendar day key like Claude's stats cache uses ("2026-06-12").
    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
}

enum ModelName {
    /// Friendly label for a model id, e.g. "claude-opus-4-8" → "Opus 4.8".
    static func display(_ id: String) -> String {
        let lower = id.lowercased()
        func ver(_ prefix: String) -> String {
            // pull the trailing version digits: "claude-opus-4-8" → "4.8"
            let tail = lower.replacingOccurrences(of: "claude-", with: "")
                .replacingOccurrences(of: prefix + "-", with: "")
            let digits = tail.split(separator: "-").prefix(2).joined(separator: ".")
            return digits.first?.isNumber == true ? " " + digits : ""
        }
        if lower.contains("opus")   { return "Opus" + ver("opus") }
        if lower.contains("sonnet") { return "Sonnet" + ver("sonnet") }
        if lower.contains("haiku")  { return "Haiku" + ver("haiku") }
        if lower.contains("fable")  { return "Fable" + ver("fable") }
        return id
    }
}
