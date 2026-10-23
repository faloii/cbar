import Foundation
import Security

/// Fetches Claude's real session/weekly limit usage from the (undocumented)
/// `GET https://api.anthropic.com/api/oauth/usage` endpoint — the same data
/// Claude Code's `/usage` command shows.
///
/// The endpoint is aggressively rate-limited, so responses are cached to
/// `~/.claudebar/usage-cache.json` and only refreshed past `cacheTTL`. On any
/// failure we serve the (marked-stale) cache rather than flapping to empty.
///
/// Network + the user's OAuth token are required; this is opt-in (see
/// `UsageStore.enableLiveLimits`).
struct OAuthUsageClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"
    static let cacheTTL: TimeInterval = 180

    enum FetchError: LocalizedError {
        case noCredentials, awaitingKeychain, unauthorized, rateLimited, http(Int), badResponse

        var errorDescription: String? {
            switch self {
            case .noCredentials: return "Claude 자격증명을 찾을 수 없음 — Claude Code에서 로그인하세요."
            case .awaitingKeychain: return "키체인 승인 대기 중 — 확인 창에 응답하면 이어서 가져와요."
            case .unauthorized:  return "인증 실패(401) — 토큰이 만료됐어요. Claude Code를 한 번 쓰면 갱신돼요(안 되면 /login)."
            case .rateLimited:   return "요청 제한(429) — 잠시 후 재시도합니다."
            case .http(let c):   return "서버 응답 HTTP \(c)."
            case .badResponse:   return "사용량 응답이 예상과 다릅니다."
            }
        }
    }

    /// Fresh-if-cached, otherwise fetch. Never throws — failures surface as
    /// `error` on a (possibly stale-cached) snapshot.
    // Exponential backoff after consecutive failures so we don't hammer the
    // (rate-limited) endpoint — beyond the normal 180s cache TTL.
    private static let throttleLock = NSLock()
    private static var nextAllowedFetch = Date.distantPast
    private static var consecutiveFailures = 0

    func loadLimits(force: Bool = false, ttl: TimeInterval = OAuthUsageClient.cacheTTL) async -> LimitsSnapshot {
        let cached = readCache()
        if !force, let c = cached, Date().timeIntervalSince(c.fetchedAt) < ttl {
            return c
        }
        if !force, Self.isBackingOff(), var c = cached {
            c.stale = true
            return c
        }
        do {
            let fresh = try await fetchRemote()
            writeCache(fresh)
            UsageHistory.append(session: fresh.session5h?.utilization,
                                weekly: fresh.weekly7d?.utilization,
                                at: fresh.fetchedAt)
            WeeklyHistory.append(weekly: fresh.weekly7d?.utilization, at: fresh.fetchedAt)
            Self.recordSuccess()
            return fresh
        } catch {
            Self.recordFailure()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if var c = cached {
                c.stale = true
                c.error = message
                // Persisted, not just returned in-memory: otherwise the very next
                // tick's backoff branch (line ~47) re-reads the ORIGINAL on-disk
                // cache — which still has the last SUCCESS's nil `.error` — and
                // the real failure reason silently vanishes after one tick even
                // though the failures keep happening underneath.
                writeCache(c)
                return c
            }
            let empty = LimitsSnapshot(fetchedAt: Date(), error: message)
            writeCache(empty)
            return empty
        }
    }

    private static func isBackingOff() -> Bool {
        throttleLock.lock(); defer { throttleLock.unlock() }
        return Date() < nextAllowedFetch
    }

    /// Exposed read-only for the Settings diagnostics panel — "정직하게" means the
    /// user shouldn't have to guess whether a stale reading is a rare hiccup or the
    /// endpoint actively refusing every attempt right now.
    static func backoffStatus() -> (isBackingOff: Bool, retryAt: Date?) {
        throttleLock.lock(); defer { throttleLock.unlock() }
        let now = Date()
        return (now < nextAllowedFetch, nextAllowedFetch > now ? nextAllowedFetch : nil)
    }

    /// Manual escape hatch for the diagnostics panel's "초기화 후 재시도" — clears the
    /// exponential backoff so a forced retry isn't immediately turned away by it.
    static func resetBackoff() { recordSuccess() }
    private static func recordSuccess() {
        throttleLock.lock(); consecutiveFailures = 0; nextAllowedFetch = .distantPast; throttleLock.unlock()
    }
    private static func recordFailure() {
        throttleLock.lock(); defer { throttleLock.unlock() }
        consecutiveFailures += 1
        let backoff = min(cacheTTL * pow(2, Double(min(consecutiveFailures, 4))), 1800)
        nextAllowedFetch = Date().addingTimeInterval(backoff)
    }

    // MARK: - Network

    private func fetchRemote() async throws -> LimitsSnapshot {
        // Don't gate on expiresAt (its format is unreliable and a valid token can look
        // "expired"); just use the token and let a 401 trigger a refresh.
        guard let creds = ClaudeCredentials.load() else {
            throw ClaudeCredentials.isAwaitingKeychain ? FetchError.awaitingKeychain : FetchError.noCredentials
        }
        do {
            return try await requestUsage(token: creds.accessToken)
        } catch FetchError.unauthorized {
            // Claude Code rotated the token since we cached it — re-read the source
            // (prompt-free) and retry once if it actually changed.
            ClaudeCredentials.invalidate()
            if let fresh = ClaudeCredentials.load(), fresh.accessToken != creds.accessToken {
                return try await requestUsage(token: fresh.accessToken)
            }
            throw FetchError.unauthorized
        }
    }

    /// One usage request with a given bearer token. 401 surfaces as `.unauthorized`
    /// so the caller can decide whether to refresh-and-retry.
    private func requestUsage(token: String) async throws -> LimitsSnapshot {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        // Must start with "claude-code/" or the endpoint uses a tiny 429-prone bucket.
        req.setValue(userAgent(), forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse }
        switch http.statusCode {
        case 200:
            // An undocumented endpoint can change shape and still answer 200. Treat a
            // body with no usable windows as a failure, so the last good cache is kept
            // (marked stale) and backoff applies — instead of overwriting it with an
            // empty snapshot and re-requesting every TTL.
            let snap = Self.parse(data)
            guard snap.hasData else { throw FetchError.badResponse }
            return snap
        case 401:  throw FetchError.unauthorized
        case 429:  throw FetchError.rateLimited
        default:   throw FetchError.http(http.statusCode)
        }
    }

    /// Parse the usage JSON defensively — the schema is undocumented and may shift.
    static func parse(_ data: Data) -> LimitsSnapshot {
        var snap = LimitsSnapshot(fetchedAt: Date())
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            snap.error = FetchError.badResponse.errorDescription
            return snap
        }
        snap.status = root["status"] as? String ?? root["unified_status"] as? String

        func window(_ keys: [String]) -> LimitWindow? {
            for key in keys {
                guard let o = root[key] as? [String: Any] else { continue }
                let utilAny = o["utilization"] ?? o["used_percent"]
                let util = (utilAny as? Double) ?? Double(utilAny as? Int ?? 0)
                var reset: Date?
                if let s = o["resets_at"] as? String { reset = DateParse.iso(s) }
                else if let n = o["resets_at"] as? Double { reset = Date(timeIntervalSince1970: n) }
                else if let n = o["resets_at"] as? Int { reset = Date(timeIntervalSince1970: Double(n)) }
                return LimitWindow(utilization: util, resetsAt: reset)
            }
            return nil
        }

        snap.session5h  = window(["five_hour"])
        snap.weekly7d   = window(["seven_day"])
        snap.weeklyOpus = window(["seven_day_opus", "seven_day_oauth_apps"])
        if !snap.hasData { snap.error = FetchError.badResponse.errorDescription }
        return snap
    }

    private func userAgent() -> String {
        let url = ClaudeDataReader.configDir.appendingPathComponent(".last-update-result.json")
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = root["version_to"] as? String, !v.isEmpty {
            return "claude-code/\(v)"
        }
        return "claude-code/2.1.173"
    }

    // MARK: - Disk cache

    private var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/usage-cache.json")
    }

    private func readCache() -> LimitsSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LimitsSnapshot.self, from: data)
    }

    private func writeCache(_ snap: LimitsSnapshot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(snap) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// Reads Claude Code's OAuth access token — WITHOUT a Keychain prompt.
///
/// Claude Code stores its credential in the login Keychain by shelling out to
/// `/usr/bin/security`, so that tool is always on the item's access list. Every
/// time Claude Code refreshes its token it recreates the item, and any other app
/// the user had approved ("Always Allow") drops off the list — that's why reading
/// it in-process (`SecItemCopyMatching`) kept re-prompting for the login password.
/// Reading through `/usr/bin/security` instead rides on that permanent entry.
///
/// CBar no longer refreshes tokens itself. It used to exchange Claude Code's
/// refresh token directly and keep the rotated one in `~/.claudebar/token.json`;
/// that left two clients racing over one refresh token (each rotation can
/// invalidate the other's copy) and kept a long-lived secret on disk. Now a 401
/// just re-reads the source: Claude Code keeps the token fresh while it's in use,
/// and the read is free.
struct ClaudeCredentials {
    let accessToken: String

    private static let keychainService = "Claude Code-credentials"
    private static let lock = NSLock()
    private static var cached: ClaudeCredentials?
    /// Single-flight for the source read (spawns a short-lived process).
    private static let sourceLock = NSLock()
    private static var awaitingSource = false

    /// True while a Keychain read is in flight — `security` itself can still block
    /// on a LOCKED keychain's unlock dialog — so the fetch can report "waiting for
    /// approval" instead of "no credentials".
    static var isAwaitingKeychain: Bool {
        lock.lock(); defer { lock.unlock() }
        return awaitingSource
    }

    static func load() -> ClaudeCredentials? {
        if let c = cachedValue() { return c }
        guard sourceLock.try() else { return nil }
        defer { sourceLock.unlock() }
        if let c = cachedValue() { return c }
        setAwaitingSource(true); defer { setAwaitingSource(false) }
        guard let c = readSource() else { return nil }
        lock.lock(); cached = c; lock.unlock()
        return c
    }

    /// Drop the in-memory token so the next `load()` re-reads the source — after a
    /// 401 (Claude Code rotated it) or from the diagnostics "retry" button.
    static func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    /// Older builds persisted the token AND refresh token here; remove that copy.
    static func removeLegacyTokenFile() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/token.json")
        try? FileManager.default.removeItem(at: url)
    }

    private static func cachedValue() -> ClaudeCredentials? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }
    private static func setAwaitingSource(_ v: Bool) {
        lock.lock(); awaitingSource = v; lock.unlock()
    }

    // MARK: source (Claude Code)

    private static func readSource() -> ClaudeCredentials? {
        let url = ClaudeDataReader.configDir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: url), let c = parse(data) { return c }
        guard let data = readKeychainViaSecurityTool() else { return nil }
        return parse(data)
    }

    /// `security find-generic-password -s <service> -w` — prints only the secret,
    /// to our pipe (never logged). Fixed argv, no shell. Killed after 10s if it
    /// hangs (e.g. a locked keychain whose unlock dialog nobody answers).
    private static func readKeychainViaSecurityTool() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return ClaudeCredentials(accessToken: token)
    }
}
