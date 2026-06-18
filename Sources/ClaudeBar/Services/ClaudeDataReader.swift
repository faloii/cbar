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

        // Per-day token totals + estimated cost (for the trend chart) and the
        // this-week-vs-last-week review.
        if let daily = root["dailyModelTokens"] as? [[String: Any]] {
            var history: [DailyCost] = []
            var entries: [(date: Date, byModel: [String: Int])] = []
            for entry in daily {
                guard let dateStr = entry["date"] as? String,
                      let byModel = entry["tokensByModel"] as? [String: Int] else { continue }
                history.append(DailyCost(date: dateStr,
                                         tokens: byModel.values.reduce(0, +),
                                         cost: CostEstimator.dailyCost(tokensByModel: byModel, rates: rates, fallback: fallback)))
                if let d = DateParse.day(dateStr) { entries.append((d, byModel)) }
            }
            snap.dailyCostHistory = Array(history.suffix(30))
            snap.dailyTokenHistory = Array(history.suffix(14).map(\.tokens))
            snap.weeklyReview = WeeklyReview.compute(entries: entries, rates: rates, fallback: fallback, now: now)
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
        var winByProject: [String: ProjectUsage] = [:]

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

                let proj = Self.projectName(r.cwd)
                var pu = winByProject[proj] ?? ProjectUsage(project: proj, tokens: TokenCounts(), cost: 0, requests: 0)
                pu.tokens += tokens
                pu.cost += cost
                pu.requests += 1
                winByProject[proj] = pu
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
        snap.windowByProject = winByProject.values
            .filter { $0.tokens.total > 0 }
            .sorted { $0.cost > $1.cost }

        // Active conversation = the session of the most recent assistant turn.
        let assistantTurns = records.filter { $0.type == "assistant" && $0.tokens != nil }
        if let latest = assistantTurns.max(by: { $0.timestamp < $1.timestamp }) {
            let inSession = assistantTurns.filter { $0.sessionId == latest.sessionId }
            let sessionCost = inSession.reduce(0.0) { $0 + Pricing.cost(for: $1.tokens!, model: $1.model) }
            let t = latest.tokens!
            snap.currentSession = SessionUsage(
                project: Self.projectName(latest.cwd),
                cost: sessionCost,
                requests: inSession.count,
                contextTokens: t.input + t.cacheRead + t.cacheWrite,
                lastActivity: latest.timestamp)
        }

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
        let cwd: String
        let model: String
        let tokens: TokenCounts? // assistant turns only
        let toolUseCount: Int
    }

    // Per-file parse cache so a refresh re-parses only files that actually changed
    // (keyed by modification date + size); unchanged logs are reused.
    private struct CachedParse { let mtime: Date; let size: Int; let records: [LogRecord] }
    private static let parseCacheLock = NSLock()
    private static var parseCache: [String: CachedParse] = [:]

    /// Parse session logs touched in the last ~36h. (We only need today + a 5h
    /// window, so older files are skipped for speed.)
    private func recentRecords(now: Date) -> [LogRecord] {
        let projects = Self.configDir.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: projects,
                                         includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return [] }

        let cutoff = now.addingTimeInterval(-36 * 3600)

        // 1) Find the recent files (cheap stat pass).
        var recent: [(url: URL, mtime: Date, size: Int)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mtime = vals?.contentModificationDate, mtime >= cutoff else { continue }
            recent.append((url, mtime, vals?.fileSize ?? -1))
        }
        Self.pruneCache(keeping: Set(recent.map { $0.url.path }))

        // 2) Parse them in parallel across cores (cache hits skip the work).
        var results = [[LogRecord]](repeating: [], count: recent.count)
        DispatchQueue.concurrentPerform(iterations: recent.count) { i in
            let f = recent[i]
            if let cached = Self.cachedRecords(key: f.url.path, mtime: f.mtime, size: f.size) {
                results[i] = cached
            } else {
                let parsed = self.parse(fileAt: f.url)
                Self.storeRecords(key: f.url.path, mtime: f.mtime, size: f.size, records: parsed)
                results[i] = parsed
            }
        }
        return results.flatMap { $0 }
    }

    private static func cachedRecords(key: String, mtime: Date, size: Int) -> [LogRecord]? {
        parseCacheLock.lock(); defer { parseCacheLock.unlock() }
        guard let c = parseCache[key], c.mtime == mtime, c.size == size else { return nil }
        return c.records
    }

    private static func storeRecords(key: String, mtime: Date, size: Int, records: [LogRecord]) {
        parseCacheLock.lock(); defer { parseCacheLock.unlock() }
        parseCache[key] = CachedParse(mtime: mtime, size: size, records: records)
    }

    private static func pruneCache(keeping keys: Set<String>) {
        parseCacheLock.lock(); defer { parseCacheLock.unlock() }
        parseCache = parseCache.filter { keys.contains($0.key) }
    }

    /// Stream the file line-by-line via a FileHandle so a large session log isn't
    /// loaded into memory all at once (peak memory ≈ one chunk + one line).
    private func parse(fileAt url: URL) -> [LogRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var out: [LogRecord] = []
        var buffer = Data()
        let newline = UInt8(0x0A)

        while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: newline) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let record = Self.record(from: line) { out.append(record) }
            }
        }
        if let record = Self.record(from: buffer) { out.append(record) }
        return out
    }

    /// Parse one JSONL line (as raw bytes) into a `LogRecord`, or nil to skip.
    private static func record(from line: Data) -> LogRecord? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String,
              let ts = obj["timestamp"] as? String,
              let date = DateParse.iso(ts)
        else { return nil }

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

        return LogRecord(
            timestamp: date,
            type: type,
            sessionId: sessionId,
            cwd: obj["cwd"] as? String ?? "",
            model: message?["model"] as? String ?? "unknown",
            tokens: tokens,
            toolUseCount: toolUses
        )
    }

    /// Project label for a working directory ("/Users/me/Foo" → "Foo").
    fileprivate static func projectName(_ cwd: String) -> String {
        cwd.isEmpty ? "기타" : URL(fileURLWithPath: cwd).lastPathComponent
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
    /// Parse a "yyyy-MM-dd" day string (as used by Claude's stats cache).
    static func day(_ s: String) -> Date? { dayFormatter.date(from: s) }
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
