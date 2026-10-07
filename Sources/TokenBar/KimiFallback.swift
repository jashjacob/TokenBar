import Foundation

/// Used only when TokenTracker has no Kimi windows.
/// Reads the local Kimi Code login and asks Kimi for the 5h, weekly, and monthly pools.
enum KimiFallback {
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    static func chips() async -> [Chip] {
        let base = baseURL()
        if let key = staticKey() {
            return await load(base: base, bearer: key, refresh: nil)
        }
        guard var session = loadSession() else {
            Log.line("kimi fallback: no local login")
            return []
        }
        if session.expiresSoon {
            do {
                session = try await refresh(session)
            } catch {
                Log.line("kimi fallback: \(error.localizedDescription)")
                return []
            }
        }
        return await load(base: base, bearer: session.accessToken, refresh: session)
    }

    private struct Session {
        var file: [String: Any]
        var path: URL
        var accessToken: String
        var refreshToken: String
        var oauthHost: URL
        var expiresAt: Date?

        var expiresSoon: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    private static func load(base: URL, bearer: String, refresh session: Session?) async -> [Chip] {
        do {
            return try await windows(base: base, bearer: bearer)
        } catch LimitsError.http(401) {
            guard let session else {
                Log.line("kimi fallback: HTTP 401")
                return []
            }
            do {
                let next = try await refresh(session)
                return try await windows(base: base, bearer: next.accessToken)
            } catch {
                Log.line("kimi fallback: \(error.localizedDescription)")
                return []
            }
        } catch {
            Log.line("kimi fallback: \(error.localizedDescription)")
            return []
        }
    }

    private static func windows(base: URL, bearer: String) async throws -> [Chip] {
        guard let url = endpoint(base, "usages") else { return [] }
        guard let body = try await getJSON(url: url, bearer: bearer) else {
            Log.line("kimi fallback: usage response was not JSON")
            return []
        }
        let chips = makeChips(body)
        if chips.isEmpty {
            Log.line("kimi fallback: no windows in usage")
        }
        return chips
    }

    private static func staticKey() -> String? {
        for name in ["KIMI_CODING_API_KEY", "KIMI_API_KEY"] {
            if let raw = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw
            }
        }
        return nil
    }

    private static func loadSession() -> Session? {
        let dir = kimiHome().appendingPathComponent("credentials")
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).filter { $0.pathExtension == "json" }
        let ordered = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for path in ordered {
            guard let data = try? Data(contentsOf: path),
                  let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = (file["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let refresh = (file["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !access.isEmpty, !refresh.isEmpty
            else { continue }
            if let scope = file["scope"] as? String, !scope.isEmpty, scope != "kimi-code" { continue }
            return Session(
                file: file,
                path: path,
                accessToken: access,
                refreshToken: refresh,
                oauthHost: oauthHost(),
                expiresAt: expiry(file["expires_at"])
            )
        }
        return nil
    }

    private static func refresh(_ session: Session) async throws -> Session {
        guard let tokenURL = endpoint(session.oauthHost, "api/oauth/token") else { throw LimitsError.badPayload }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": session.refreshToken,
        ]
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
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
        if let seconds = ChipParser.number(payload["expires_in"]), seconds > 0 {
            next.expiresAt = Date().addingTimeInterval(seconds)
            next.file["expires_in"] = Int(seconds)
        }
        if let expiresAt = next.expiresAt {
            next.file["expires_at"] = Int(expiresAt.timeIntervalSince1970)
        }
        next.file["access_token"] = next.accessToken
        next.file["refresh_token"] = next.refreshToken
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
            Log.line("kimi fallback: could not save refreshed login")
        }
    }

    private static func getJSON(url: URL, bearer: String) async throws -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else { throw LimitsError.http(http.statusCode) }
        guard data.count <= 512_000 else { throw LimitsError.tooLarge }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func makeChips(_ body: [String: Any]) -> [Chip] {
        let usages = body["usages"] as? [String: Any] ?? [:]
        return [
            window(usages["limit_5h"], id: "kimi.secondary_window", label: "Kimi 5h", seconds: 5 * 3600),
            window(usages["limit_7d"], id: "kimi.primary_window", label: "Kimi 7d", seconds: 7 * 24 * 3600),
            window(usages["limit_month_total"], id: "kimi.tertiary_window", label: "Kimi mo", seconds: 30 * 24 * 3600),
        ].compactMap { $0 }
    }

    private static func window(_ raw: Any?, id: String, label: String, seconds: Double) -> Chip? {
        guard let entry = raw as? [String: Any],
              let ratio = ChipParser.number(entry["used_ratio"])
        else { return nil }
        let percent = min(max(ratio <= 1 ? ratio * 100 : ratio, 0), 100)
        return Chip(
            id: id,
            label: label,
            percent: percent,
            resetAt: isoDate(entry["reset_time"]),
            windowSeconds: seconds,
            source: .fallback
        )
    }

    private static func endpoint(_ base: URL, _ path: String) -> URL? {
        var raw = base.absoluteString
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: raw + "/" + path)
    }

    private static func kimiHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
    }

    private static func baseURL() -> URL {
        if let raw = env("KIMI_CODE_BASE_URL") ?? configValue("base_url"),
           let url = URL(string: raw) {
            return url
        }
        let region = (try? String(contentsOf: kimiHome().appendingPathComponent("region"), encoding: .utf8)) ?? ""
        let raw = region.contains("cn") ? "https://api.kimi.ai/coding/v1" : "https://api.kimi.com/coding/v1"
        return URL(string: raw)!
    }

    private static func oauthHost() -> URL {
        if let raw = env("KIMI_CODE_OAUTH_HOST") ?? configValue("oauth_host"),
           let url = URL(string: raw) {
            return url
        }
        let region = (try? String(contentsOf: kimiHome().appendingPathComponent("region"), encoding: .utf8)) ?? ""
        let raw = region.contains("cn") ? "https://auth.kimi.ai" : "https://auth.kimi.com"
        return URL(string: raw)!
    }

    private static func env(_ name: String) -> String? {
        let raw = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private static func configValue(_ key: String) -> String? {
        let path = kimiHome().appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func expiry(_ value: Any?) -> Date? {
        guard let seconds = ChipParser.number(value), seconds > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
