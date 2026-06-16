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
        case noCredentials, tokenExpired, unauthorized, rateLimited, http(Int), badResponse

        var errorDescription: String? {
            switch self {
            case .noCredentials: return "Claude 자격증명을 찾을 수 없음 — Claude Code에서 로그인하세요."
            case .tokenExpired:  return "토큰 만료 — Claude Code를 열어 갱신하세요."
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

    func loadLimits(force: Bool = false) async -> LimitsSnapshot {
        let cached = readCache()
        if !force, let c = cached, Date().timeIntervalSince(c.fetchedAt) < Self.cacheTTL {
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
        guard let creds = ClaudeCredentials.load() else { throw FetchError.noCredentials }
        if let exp = creds.expiresAt, exp < Date() {
            ClaudeCredentials.invalidate()
            throw FetchError.tokenExpired
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        // Must start with "claude-code/" or the endpoint uses a tiny 429-prone bucket.
        req.setValue(userAgent(), forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse }
        switch http.statusCode {
        case 200:  return Self.parse(data)
        case 401:  ClaudeCredentials.invalidate(); throw FetchError.unauthorized
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

/// ClaudeBar's own Keychain item caching the credential blob, so we read it
/// back without a prompt (we own it) on subsequent launches.
private enum TokenStore {
    static let service = "com.claudebar.token"
    static let account = "default"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return d
    }
    static func write(_ data: Data) {
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    static func clear() { SecItemDelete(base as CFDictionary) }
}

/// Reads Claude Code's OAuth token, then caches it in ClaudeBar's own Keychain item
/// so later launches don't re-prompt. Claude Code's (prompting) item is only read
/// when our copy is missing or stale — minimizing the access prompt.
struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date?
    var stillValid: Bool { expiresAt.map { $0 > Date().addingTimeInterval(60) } ?? true }

    private static let lock = NSLock()
    private static var cached: ClaudeCredentials?

    static func load() -> ClaudeCredentials? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.stillValid { return c }
        // Our own item first — no prompt.
        if let data = TokenStore.read(), let c = parse(data), c.stillValid { cached = c; return c }
        // Else read Claude Code's item (may prompt once), then cache a copy.
        guard let data = sourceData(), let c = parse(data) else { return nil }
        TokenStore.write(data)
        cached = c
        return c
    }

    /// Drop our cached token (memory + our Keychain copy) so the next `load()`
    /// re-reads Claude Code's item — used after a 401 / expiry.
    static func invalidate() {
        lock.lock(); cached = nil; TokenStore.clear(); lock.unlock()
    }

    private static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        else if let ms = oauth["expiresAt"] as? Int { expires = Date(timeIntervalSince1970: Double(ms) / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expires)
    }

    /// Claude Code's credential JSON: file first, else its Keychain item (prompts).
    private static func sourceData() -> Data? {
        let url = ClaudeDataReader.configDir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: url) { return data }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }
}
