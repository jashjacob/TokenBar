import Foundation

/// Used only when TokenTracker has no Grok windows.
/// Reads the local Grok login and asks Grok billing for the weekly pool.
enum GrokFallback {
    private static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

    static func chips() async -> [Chip] {
        guard var session = loadSession() else {
            Log.line("grok fallback: no local login")
            return []
        }
        do {
            if session.accessTokenExpiresSoon {
                session = try await refresh(session)
            }
            guard let body = try await getJSON(url: billingURL, bearer: session.accessToken) else {
                Log.line("grok fallback: billing response was not JSON")
                return []
            }
            let chips = makeChips(body)
            if chips.isEmpty {
                Log.line("grok fallback: no windows in billing")
            }
            return chips
        } catch {
            Log.line("grok fallback: \(error.localizedDescription)")
            return []
        }
    }

    private struct Session {
        var scopeKey: String
        var entry: [String: Any]
        var file: [String: Any]
        var path: URL
        var accessToken: String
        var refreshToken: String?
        var clientID: String?
        var expiresAt: Date?

        var accessTokenExpiresSoon: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    private static func loadSession() -> Session? {
        let path = grokHome().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for (scopeKey, value) in file {
            guard let entry = value as? [String: Any],
                  let key = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty
            else { continue }
            let refresh = (entry["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = (entry["oidc_client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? scopeKey.split(separator: "::").last.map(String.init)
            return Session(
                scopeKey: scopeKey,
                entry: entry,
                file: file,
                path: path,
                accessToken: key,
                refreshToken: refresh?.isEmpty == false ? refresh : nil,
                clientID: client?.isEmpty == false ? client : nil,
                expiresAt: jwtExpiry(key) ?? isoDate(entry["expires_at"])
            )
        }
        return nil
    }

    private static func grokHome() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    private static func refresh(_ session: Session) async throws -> Session {
        guard let refreshToken = session.refreshToken, let clientID = session.clientID else {
            throw LimitsError.http(401)
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
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
        } else {
            next.expiresAt = jwtExpiry(access)
        }
        persist(next)
        return next
    }

    private static func persist(_ session: Session) {
        var entry = session.entry
        entry["key"] = session.accessToken
        if let refreshToken = session.refreshToken { entry["refresh_token"] = refreshToken }
        if let expiresAt = session.expiresAt {
            entry["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
        } else {
            entry.removeValue(forKey: "expires_at")
        }
        var file = session.file
        file[session.scopeKey] = entry
        guard let data = try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = session.path.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(session.path, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Log.line("grok fallback: could not save refreshed login")
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
        guard let config = body["config"] as? [String: Any] else { return [] }
        let period = config["currentPeriod"] as? [String: Any]
        let reset = isoDate(period?["end"]) ?? isoDate(config["billingPeriodEnd"])
        let percent = usagePercent(config)
        guard let percent else { return [] }
        let label = periodLabel(period?["type"] as? String, start: isoDate(period?["start"]), end: reset)
        var chips = [
            Chip(id: "grok.primary_window", label: label, percent: percent, resetAt: reset, windowSeconds: 7 * 24 * 3600, source: .fallback),
        ]
        if let cap = nestedNumber(config["onDemandCap"]), cap > 0,
           let used = nestedNumber(config["onDemandUsed"]) {
            let extra = min(max(used / cap * 100, 0), 100)
            chips.append(Chip(id: "grok.secondary_window", label: "Grok extra", percent: extra, resetAt: reset, windowSeconds: 7 * 24 * 3600, source: .fallback))
        }
        return chips
    }

    private static func usagePercent(_ config: [String: Any]) -> Double? {
        if let raw = ChipParser.number(config["creditUsagePercent"]) {
            return min(max(raw, 0), 100)
        }
        if let products = config["productUsage"] as? [[String: Any]] {
            let sum = products.compactMap { ChipParser.number($0["usagePercent"]) }.reduce(0, +)
            if !products.isEmpty { return min(max(sum, 0), 100) }
        }
        if let limit = nestedNumber(config["monthlyLimit"]), limit > 0, let used = nestedNumber(config["used"]) {
            return min(max(used / limit * 100, 0), 100)
        }
        if config["creditUsagePercent"] == nil, config["productUsage"] == nil, config["currentPeriod"] != nil {
            return 0
        }
        return nil
    }

    private static func periodLabel(_ type: String?, start: Date?, end: Date?) -> String {
        let upper = (type ?? "").uppercased()
        if upper.contains("WEEK") { return "Grok 7d" }
        if upper.contains("MONTH") { return "Grok mo" }
        if upper.contains("DAY") { return "Grok 1d" }
        if let start, let end {
            let days = end.timeIntervalSince(start) / 86_400
            if days > 1.5, days <= 8 { return "Grok 7d" }
            if days >= 25, days <= 35 { return "Grok mo" }
            if days > 0.5, days <= 1.5 { return "Grok 1d" }
        }
        return "Grok 7d"
    }

    private static func nestedNumber(_ value: Any?) -> Double? {
        if let box = value as? [String: Any] { return ChipParser.number(box["val"]) }
        return ChipParser.number(value)
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = ChipParser.number(obj["exp"]), exp > 0
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
