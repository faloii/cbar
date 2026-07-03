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
    /// `includeSessionLogs: false` parses only the cheap stats cache (totals, daily
    /// cost, weekly review) and skips the expensive session-log scan — used in the
    /// background so the weekly summary stays available without the heavy work.
    func load(now: Date = Date(), includeSessionLogs: Bool = true) -> UsageSnapshot {
        var snap = UsageSnapshot(generatedAt: now)
        applyStatsCache(to: &snap, now: now)
        if includeSessionLogs { applySessionLogs(to: &snap, now: now) }
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
            snap.weeklyReview = WeeklyReview.compute(entries: entries, rates: rates, fallback: fallback, now: now)
            snap.weeklyOpusShares = WeeklyReview.opusShares(entries: entries, rates: rates, fallback: fallback, now: now, weeks: 4)
        }
    }

    // MARK: - session *.jsonl logs

    private func applySessionLogs(to snap: inout UsageSnapshot, now: Date) {
        // Scan the full 7-day range once (not just the 36h the window/today figures
        // need) so the per-project weekly breakdown below can piggyback on the same
        // pass — the per-file parse cache means this costs nothing extra on repeat
        // refreshes (only genuinely new/changed files get re-parsed).
        let records = recentRecords(now: now, since: 7 * 24 * 3600)
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

        // The latest assistant turn's context size (input + cache read/write ≈ prompt
        // tokens carried into that turn) — a "how big is my current conversation" signal
        // that drives the /compact-or-new-session lever.
        var latestTurnAt = Date.distantPast
        var currentContextTokens = 0
        var currentSessionId = ""

        // Per-conversation accumulation for the session breakdown.
        struct SessAcc { var cost = 0.0; var requests = 0; var last = Date.distantPast
                         var project = "기타"; var modelCost: [String: Double] = [:]
                         var tokens = TokenCounts(); var lastContextTokens = 0 }
        var bySession: [String: SessAcc] = [:]

        // Per-project totals across the full 7-day scan (independent of the 5h/today
        // filters below) — "which project is eating the weekly limit?"
        struct ProjAcc { var tokens = 0; var cost = 0.0 }
        var byProject: [String: ProjAcc] = [:]
        // Token totals across the same full 7-day scan (fresh vs re-read), for the
        // weekly recap notification's cache-efficiency read.
        var weeklyTokens = TokenCounts()

        for r in records {
            let isToday = r.timestamp >= todayStart
            if isToday {
                if !r.sessionId.isEmpty { todaySessions.insert(r.sessionId) }
                todayToolCalls += r.toolUseCount
            }

            // Only assistant turns carry token usage / cost.
            guard let tokens = r.tokens, r.type == "assistant" else { continue }
            let cost = Pricing.cost(for: tokens, model: r.model)
            let key = ModelName.display(r.model)

            // Track the single most-recent turn's context size (prompt tokens, not output).
            if r.timestamp > latestTurnAt {
                latestTurnAt = r.timestamp
                currentContextTokens = tokens.input + tokens.cacheRead + tokens.cacheWrite
                currentSessionId = r.sessionId
            }

            let proj = Self.projectName(r.cwd)
            if !r.sessionId.isEmpty {
                var acc = bySession[r.sessionId] ?? SessAcc()
                acc.cost += cost
                acc.requests += 1
                acc.tokens += tokens
                if r.timestamp > acc.last {
                    acc.last = r.timestamp
                    acc.lastContextTokens = tokens.input + tokens.cacheRead + tokens.cacheWrite
                }
                if proj != "기타" { acc.project = proj }
                acc.modelCost[key, default: 0] += cost
                bySession[r.sessionId] = acc
            }
            var pAcc = byProject[proj] ?? ProjAcc()
            pAcc.tokens += tokens.total
            pAcc.cost += cost
            byProject[proj] = pAcc
            weeklyTokens += tokens

            if r.timestamp >= windowStart {
                windowTokens += tokens
                windowCost += cost
                if oldestInWindow == nil || r.timestamp < oldestInWindow! {
                    oldestInWindow = r.timestamp
                }
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
                var mu = byModel[key] ?? ModelUsage(model: key, tokens: TokenCounts(), cost: 0)
                mu.tokens += tokens
                mu.cost += cost
                byModel[key] = mu
            }
        }

        snap.recentSessions = bySession.map { id, a in
            SessionStat(sessionId: id, project: a.project, cost: a.cost, requests: a.requests,
                        models: a.modelCost.sorted { $0.value > $1.value }.map(\.key),
                        lastActivity: a.last,
                        cacheReadShare: a.tokens.total > 0 ? Double(a.tokens.cacheRead) / Double(a.tokens.total) : 0,
                        lastContextTokens: a.lastContextTokens)
        }
        .filter { $0.cost > 0 }
        .sorted { $0.cost > $1.cost }

        snap.weeklyProjectUsage = byProject.map { ProjectWeeklyUsage(project: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
            .filter { $0.cost > 0 }
            .sorted { $0.cost > $1.cost }
        snap.weeklyTokens = weeklyTokens

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
        snap.currentContextTokens = currentContextTokens
        snap.currentSessionId = currentSessionId
    }

    /// One parsed line from a session log.
    struct LogRecord {
        let timestamp: Date
        let type: String        // "user" | "assistant" | ...
        let sessionId: String
        let cwd: String         // working dir → project label for the per-session view
        let model: String
        let tokens: TokenCounts? // assistant turns only
        let toolUseCount: Int
        /// "message.id:requestId" — the identity of one API response. The same
        /// response is written to the logs again whenever a conversation is
        /// resumed/forked into a new session file, so summing raw lines counts the
        /// same tokens repeatedly (measured ~2× on real logs). nil when either id
        /// is missing (no dedup possible for that line).
        let dedupKey: String?
    }

    /// Drops repeated copies of the same API response (see `LogRecord.dedupKey`),
    /// keeping the copy with the MOST tokens: streaming logs interim copies whose
    /// output_tokens are still growing (measured on real logs: every diverging
    /// duplicate's earliest copy is the smaller one), so keeping the earliest would
    /// systematically undercount output. Ties (identical fork/resume copies) break
    /// to the earliest timestamp, preserving the original session's attribution.
    /// Key-less records pass through. Result is sorted by timestamp.
    static func dedupe(_ records: [LogRecord]) -> [LogRecord] {
        var best: [String: LogRecord] = [:]
        var out: [LogRecord] = []
        for r in records {
            guard let k = r.dedupKey else { out.append(r); continue }
            if let cur = best[k] {
                let rT = r.tokens?.total ?? 0, cT = cur.tokens?.total ?? 0
                if rT > cT || (rT == cT && r.timestamp < cur.timestamp) { best[k] = r }
            } else {
                best[k] = r
            }
        }
        out.append(contentsOf: best.values)
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    // Per-file parse cache so a refresh re-parses only files that actually changed
    // (keyed by modification date + size); unchanged logs are reused.
    private struct CachedParse { let mtime: Date; let size: Int; let records: [LogRecord] }
    private static let parseCacheLock = NSLock()
    private static var parseCache: [String: CachedParse] = [:]

    /// Parse session logs touched in the last `since` seconds (default 7 days — wide
    /// enough for the per-project weekly breakdown; the 5h-window/today figures then
    /// just filter this same superset by timestamp). Older files are skipped for speed.
    /// The working directory of the most recently active conversation — used to
    /// build the "continue last conversation" auto-resume command. Reads `cwd` from
    /// the newest session log (off the hot path; called only when wiring up resume).
    static func lastProjectDir() -> String? {
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: projects,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
        var newest: (url: URL, mtime: Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if newest == nil || m > newest!.mtime { newest = (url, m) }
        }
        guard let file = newest?.url,
              let fh = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 65_536)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if let d = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }

    private func recentRecords(now: Date, since: TimeInterval = 7 * 24 * 3600) -> [LogRecord] {
        let projects = Self.configDir.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: projects,
                                         includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return [] }

        let cutoff = now.addingTimeInterval(-since)

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
        // Dedup must happen at merge time (the copies live in DIFFERENT files), so
        // the per-file cache keeps raw lines and this collapses them per refresh.
        return Self.dedupe(results.flatMap { $0 })
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

        var dedupKey: String?
        if let mid = message?["id"] as? String, !mid.isEmpty,
           let rid = obj["requestId"] as? String, !rid.isEmpty {
            dedupKey = "\(mid):\(rid)"
        }

        return LogRecord(
            timestamp: date,
            type: type,
            sessionId: sessionId,
            cwd: obj["cwd"] as? String ?? "",
            model: message?["model"] as? String ?? "unknown",
            tokens: tokens,
            toolUseCount: toolUses,
            dedupKey: dedupKey
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
