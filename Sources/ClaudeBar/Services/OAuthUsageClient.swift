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
        case noCredentials, unauthorized, rateLimited, http(Int), badResponse

        var errorDescription: String? {
            switch self {
            case .noCredentials: return "Claude 자격증명을 찾을 수 없음 — Claude Code에서 로그인하세요."
            case .unauthorized:  return "인증 실패(401) — Claude Code에서 재인증하세요."
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
                return c
            }
            return LimitsSnapshot(fetchedAt: Date(), error: message)
        }
    }

    private static func isBackingOff() -> Bool {
        throttleLock.lock(); defer { throttleLock.unlock() }
        return Date() < nextAllowedFetch
    }
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
        guard let creds = ClaudeCredentials.load() else { throw FetchError.noCredentials }
        do {
            return try await requestUsage(token: creds.accessToken)
        } catch FetchError.unauthorized {
            // The cached access token was rotated/revoked (Claude Code refreshes the shared
            // credential out from under us). Try a SILENT refresh with the in-memory refresh
            // token — no keychain read, so no "Always Allow" prompt — and retry once.
            if let fresh = await ClaudeCredentials.refreshSilently() {
                return try await requestUsage(token: fresh.accessToken)
            }
            // No in-memory refresh token (e.g. first 401 after an app restart). Drop the
            // cache so the next load() re-reads the keychain once — that restores the
            // refresh token, and subsequent refreshes are silent again.
            ClaudeCredentials.invalidate()
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
        case 200:  return Self.parse(data)
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

/// Reads Claude Code's OAuth token, then caches just the access token in a 0600
/// file (`~/.claudebar/token.json`). File reads never prompt, so Claude Code's
/// (prompting) Keychain item is read only on first run or after a 401 — not on
/// every launch. Only the short-lived access token is stored (not the refresh token).
struct ClaudeCredentials: Codable {
    let accessToken: String
    let expiresAt: Date?
    /// Kept ONLY in memory — never encoded to disk (see CodingKeys). Used to refresh
    /// silently so we don't re-read the (prompting) keychain on every token rotation.
    var refreshToken: String? = nil

    // refreshToken is intentionally excluded so it never lands in token.json.
    private enum CodingKeys: String, CodingKey { case accessToken, expiresAt }

    /// Claude Code's public OAuth client id + token endpoint, used to exchange the
    /// refresh token for a new access token directly (the same flow Claude Code uses).
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let keychainService = "Claude Code-credentials"

    private static let lock = NSLock()
    private static var cached: ClaudeCredentials?
    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/token.json")
    }

    static func load() -> ClaudeCredentials? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }                 // in-memory (this launch)
        if let c = readFile() { cached = c; return c } // our file — no prompt
        guard let c = readSource() else { return nil } // Claude Code (may prompt once)
        writeFile(c)
        cached = c
        return c
    }

    /// Drop the cached token (memory + file) so the next `load()` re-reads the
    /// source — used after a 401 when no refresh token is available.
    static func invalidate() {
        lock.lock(); cached = nil
        try? FileManager.default.removeItem(at: fileURL)
        lock.unlock()
    }

    // MARK: refresh (no keychain prompt)

    /// Exchange the in-memory refresh token for a fresh access token via the OAuth
    /// endpoint — no keychain read, so no prompt. On success we (1) update the in-memory
    /// + file cache and (2) write the new access+refresh tokens BACK into Claude Code's
    /// keychain item in place, so Claude Code keeps working (refresh tokens rotate, and
    /// the old one we just used is now dead). Returns nil if no refresh token is held
    /// (e.g. right after an app restart) or the refresh failed.
    static func refreshSilently() async -> ClaudeCredentials? {
        guard let rt = cachedRefreshToken(), !rt.isEmpty else { return nil }
        guard let fresh = try? await performRefresh(refreshToken: rt) else { return nil }
        // Keep Claude Code in sync first (it owns the credential); then our caches.
        writeBackToKeychain(access: fresh.accessToken,
                            refresh: fresh.refreshToken ?? rt,
                            expiresAt: fresh.expiresAt)
        setCached(fresh)
        writeFile(fresh)            // access token only (refreshToken excluded by CodingKeys)
        return fresh
    }

    // `NSLock.lock()/unlock()` are flagged unavailable when called directly inside
    // an `async` function body (Swift 6 strict concurrency) — wrapping each in a
    // plain synchronous function (as `load()`/`invalidate()` above already do)
    // sidesteps that without changing the locking behavior at all.
    private static func cachedRefreshToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        return cached?.refreshToken
    }
    private static func setCached(_ c: ClaudeCredentials) {
        lock.lock(); cached = c; lock.unlock()
    }

    private static func performRefresh(refreshToken: String) async throws -> ClaudeCredentials {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty
        else { throw OAuthUsageClient.FetchError.unauthorized }
        let newRefresh = (root["refresh_token"] as? String) ?? refreshToken
        var expires: Date?
        if let secs = root["expires_in"] as? Double { expires = Date().addingTimeInterval(secs) }
        else if let secs = root["expires_in"] as? Int { expires = Date().addingTimeInterval(Double(secs)) }
        return ClaudeCredentials(accessToken: access, expiresAt: expires, refreshToken: newRefresh)
    }

    /// Merge the refreshed tokens into Claude Code's keychain item via SecItemUpdate
    /// (in place — preserves the item's ACL, so our "Always Allow" grant survives). We
    /// only touch the three token fields and leave everything else (scopes, etc.) intact.
    /// Best-effort: any failure is silent — our own access token still works regardless.
    private static func writeBackToKeychain(access: String, refresh: String, expiresAt: Date?) {
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(readQuery as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any]
        else { return }
        oauth["accessToken"] = access
        oauth["refreshToken"] = refresh
        if let exp = expiresAt { oauth["expiresAt"] = Int(exp.timeIntervalSince1970 * 1000) }
        root["claudeAiOauth"] = oauth
        guard let newData = try? JSONSerialization.data(withJSONObject: root) else { return }
        var updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        if let account = dict[kSecAttrAccount as String] as? String {
            updateQuery[kSecAttrAccount as String] = account
        }
        SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: newData] as CFDictionary)
    }

    // MARK: file cache

    private static func readFile() -> ClaudeCredentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let c = try? dec.decode(ClaudeCredentials.self, from: data), !c.accessToken.isEmpty else { return nil }
        // If the cached token is already expired, skip it so we go straight to the
        // source (keychain) now — before the API call triggers a 401-invalidate cycle.
        if let exp = c.expiresAt, exp < Date() { return nil }
        return c
    }
    private static func writeFile(_ c: ClaudeCredentials) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(c) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: source (Claude Code)

    private static func readSource() -> ClaudeCredentials? {
        let url = ClaudeDataReader.configDir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: url), let c = parse(data) { return c }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return parse(data)
    }

    private static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        else if let ms = oauth["expiresAt"] as? Int { expires = Date(timeIntervalSince1970: Double(ms) / 1000) }
        // Keep the refresh token in memory so we can refresh silently (never persisted).
        let refresh = oauth["refreshToken"] as? String
        return ClaudeCredentials(accessToken: token, expiresAt: expires, refreshToken: refresh)
    }
}
