import Foundation

/// Used only when TokenTracker has no Codex windows.
/// Reads the local ChatGPT login and asks Codex for the 5h and weekly pools.
enum CodexFallback {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let defaultTokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    static func chips() async -> [Chip] {
        guard var session = loadSession() else {
            Log.line("codex fallback: no local ChatGPT login")
            return []
        }
        if session.expiresSoon {
            do {
                session = try await refresh(session)
            } catch {
                Log.line("codex fallback: \(error.localizedDescription)")
                return []
            }
        }
        do {
            return try await windows(session)
        } catch LimitsError.http(401) {
            do {
                let next = try await refresh(session)
                return try await windows(next)
            } catch {
                Log.line("codex fallback: \(error.localizedDescription)")
                return []
            }
        } catch {
            Log.line("codex fallback: \(error.localizedDescription)")
            return []
        }
    }

    private struct Session {
        var file: [String: Any]
        var path: URL
        var accessToken: String
        var refreshToken: String?
        var accountID: String?
        var expiresAt: Date?

        var expiresSoon: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    private static func loadSession() -> Session? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = file["tokens"] as? [String: Any],
              let access = (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty
        else { return nil }
        let refresh = (tokens["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = (tokens["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Session(
            file: file,
            path: path,
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            accountID: (account?.isEmpty == false) ? account : nil,
            expiresAt: jwtExpiry(access)
        )
    }

    private static func windows(_ session: Session) async throws -> [Chip] {
        guard let body = try await getJSON(session) else {
            Log.line("codex fallback: usage response was not JSON")
            return []
        }
        let chips = makeChips(body)
        if chips.isEmpty {
            Log.line("codex fallback: no windows in usage")
        }
        return chips
    }

    private static func refresh(_ session: Session) async throws -> Session {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw LimitsError.http(401)
        }
        guard let clientID = jwtString(session.accessToken, "client_id"), !clientID.isEmpty else {
            throw LimitsError.badPayload
        }
        var request = URLRequest(url: tokenURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LimitsError.http(0) }
        guard http.statusCode == 200 else { throw LimitsError.http(http.statusCode) }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = (payload["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty
        else { throw LimitsError.badPayload }
        var next = session
        next.accessToken = access
        if let rotated = (payload["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rotated.isEmpty {
            next.refreshToken = rotated
        }
        if let idToken = (payload["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !idToken.isEmpty {
            var tokens = next.file["tokens"] as? [String: Any] ?? [:]
            tokens["id_token"] = idToken
            next.file["tokens"] = tokens
        }
        next.expiresAt = jwtExpiry(access)
        var tokens = next.file["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = next.accessToken
        if let refresh = next.refreshToken { tokens["refresh_token"] = refresh }
        next.file["tokens"] = tokens
        next.file["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        persist(next)
        return next
    }

    private static func persist(_ session: Session) {
        guard let data = try? JSONSerialization.data(withJSONObject: session.file, options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = session.path.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(session.path, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Log.line("codex fallback: could not save refreshed login")
        }
    }

    private static func getJSON(_ session: Session) async throws -> [String: Any]? {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = session.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else { throw LimitsError.http(http.statusCode) }
        guard data.count <= 512_000 else { throw LimitsError.tooLarge }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func makeChips(_ body: [String: Any]) -> [Chip] {
        let rate = body["rate_limit"] as? [String: Any] ?? [:]
        return [
            window(rate["primary_window"], id: "codex.primary_window", label: "Codex 5h", seconds: 5 * 3600),
            window(rate["secondary_window"], id: "codex.secondary_window", label: "Codex 7d", seconds: 7 * 24 * 3600),
        ].compactMap { $0 }
    }

    private static func window(_ raw: Any?, id: String, label: String, seconds: Double) -> Chip? {
        guard let entry = raw as? [String: Any],
              let percent = ChipParser.number(entry["used_percent"])
        else { return nil }
        let windowSeconds = ChipParser.number(entry["limit_window_seconds"]) ?? seconds
        return Chip(
            id: id,
            label: label,
            percent: min(max(percent, 0), 100),
            resetAt: resetDate(entry),
            windowSeconds: windowSeconds,
            source: .fallback
        )
    }

    private static func resetDate(_ entry: [String: Any]) -> Date? {
        if let seconds = ChipParser.number(entry["reset_at"]), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let after = ChipParser.number(entry["reset_after_seconds"]), after > 0 {
            return Date().addingTimeInterval(after)
        }
        return nil
    }

    private static func tokenURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["CODEX_REFRESH_TOKEN_URL_OVERRIDE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        return defaultTokenURL
    }

    private static func jwtObject(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        guard let exp = ChipParser.number(jwtObject(token)?["exp"]), exp > 0 else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func jwtString(_ token: String, _ key: String) -> String? {
        jwtObject(token)?[key] as? String
    }
}
