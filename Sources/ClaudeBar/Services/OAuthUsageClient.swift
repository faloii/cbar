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
            case .noCredentials: return "No Claude credentials found — sign in with Claude Code."
            case .tokenExpired:  return "Token expired — open Claude Code to refresh."
            case .unauthorized:  return "Unauthorized (401) — re-auth in Claude Code."
            case .rateLimited:   return "Rate limited (429) — will retry later."
            case .http(let c):   return "Server returned HTTP \(c)."
            case .badResponse:   return "Unexpected response from usage endpoint."
            }
        }
    }

    /// Fresh-if-cached, otherwise fetch. Never throws — failures surface as
    /// `error` on a (possibly stale-cached) snapshot.
    func loadLimits(force: Bool = false) async -> LimitsSnapshot {
        if !force, let cached = readCache(), Date().timeIntervalSince(cached.fetchedAt) < Self.cacheTTL {
            return cached
        }
        do {
            let fresh = try await fetchRemote()
            writeCache(fresh)
            return fresh
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if var cached = readCache() {
                cached.stale = true
                cached.error = message
                return cached
            }
            return LimitsSnapshot(fetchedAt: Date(), error: message)
        }
    }

    // MARK: - Network

    private func fetchRemote() async throws -> LimitsSnapshot {
        guard let creds = ClaudeCredentials.load() else { throw FetchError.noCredentials }
        if let exp = creds.expiresAt, exp < Date() { throw FetchError.tokenExpired }

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

/// Reads Claude Code's OAuth access token from `~/.claude/.credentials.json`
/// (if present) or the macOS login Keychain (`Claude Code-credentials`).
struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date?

    static func load() -> ClaudeCredentials? {
        fromFile() ?? fromKeychain()
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

    private static func fromFile() -> ClaudeCredentials? {
        let url = ClaudeDataReader.configDir.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    private static func fromKeychain() -> ClaudeCredentials? {
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
}
