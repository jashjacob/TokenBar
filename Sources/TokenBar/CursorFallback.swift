import Foundation

/// Used only when TokenTracker has no Cursor plan window.
/// Reads Cursor's local login and asks Cursor for plan, Auto, and API usage.
enum CursorFallback {
    private static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!

    static func chips() async -> [Chip] {
        guard let cookie = sessionCookie() else {
            Log.line("cursor fallback: no local login")
            return []
        }
        do {
            guard let body = try await getJSON(cookie: cookie) else {
                Log.line("cursor fallback: usage response was not JSON")
                return []
            }
            let chips = makeChips(body)
            if chips.isEmpty {
                Log.line("cursor fallback: no windows in usage")
            }
            return chips
        } catch {
            Log.line("cursor fallback: \(error.localizedDescription)")
            return []
        }
    }

    private static func sessionCookie() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let db = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard let jwt = sqliteValue(db: db, sql: "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';"),
              jwt.count > 10
        else { return nil }
        let config = home.appendingPathComponent(".cursor/cli-config.json")
        let fromFile = userID(fromConfig: config)
        guard let userID = fromFile ?? userID(fromJWT: jwt) else { return nil }
        let encoded = userID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userID
        return "WorkosCursorSessionToken=\(encoded)%3A%3A\(jwt)"
    }

    private static func sqliteValue(db: URL, sql: String) -> String? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["file:\(db.path)?mode=ro", sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func userID(fromConfig url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["authInfo"] as? [String: Any],
              let authID = info["authId"] as? String
        else { return nil }
        return normalizeSubject(authID)
    }

    private static func userID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String
        else { return nil }
        return normalizeSubject(sub)
    }

    private static func normalizeSubject(_ subject: String) -> String? {
        if let match = subject.range(of: #"\|(user_[A-Za-z0-9_]+)$"#, options: .regularExpression) {
            let piece = subject[match].dropFirst()
            return String(piece)
        }
        if subject.range(of: #"^(google-oauth2|github|oidc|auth0)\|[^|]+$"#, options: .regularExpression) != nil {
            return subject
        }
        return nil
    }

    private static func getJSON(cookie: String) async throws -> [String: Any]? {
        var request = URLRequest(url: summaryURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.cursor.com/settings", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else { throw LimitsError.http(http.statusCode) }
        guard data.count <= 512_000 else { throw LimitsError.tooLarge }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func makeChips(_ body: [String: Any]) -> [Chip] {
        let plan = (body["individualUsage"] as? [String: Any])?["plan"] as? [String: Any]
        let reset = isoDate(body["billingCycleEnd"])
        let window = windowSeconds(start: isoDate(body["billingCycleStart"]), end: reset)
        var chips: [Chip] = []
        if let percent = planPercent(plan, body: body) {
            chips.append(Chip(id: "cursor.primary_window", label: "Cursor", percent: percent, resetAt: reset, windowSeconds: window, source: .fallback))
        }
        if let auto = ChipParser.number(plan?["autoPercentUsed"]) {
            chips.append(Chip(id: "cursor.secondary_window", label: "Cursor Auto", percent: clamp(auto), resetAt: reset, windowSeconds: window, source: .fallback))
        }
        if let api = ChipParser.number(plan?["apiPercentUsed"]) {
            chips.append(Chip(id: "cursor.tertiary_window", label: "Cursor API", percent: clamp(api), resetAt: reset, windowSeconds: window, source: .fallback))
        }
        return chips
    }

    private static func planPercent(_ plan: [String: Any]?, body: [String: Any]) -> Double? {
        if let total = ChipParser.number(plan?["totalPercentUsed"]) { return clamp(total) }
        let auto = ChipParser.number(plan?["autoPercentUsed"])
        let api = ChipParser.number(plan?["apiPercentUsed"])
        if let auto, let api { return clamp((auto + api) / 2) }
        if let api { return clamp(api) }
        if let auto { return clamp(auto) }
        return nil
    }

    private static func clamp(_ value: Double) -> Double {
        var percent = value
        if percent > 0, percent < 1 { percent *= 100 }
        return min(max(percent, 0), 100)
    }

    private static func windowSeconds(start: Date?, end: Date?) -> Double? {
        guard let start, let end, end > start else { return nil }
        return end.timeIntervalSince(start)
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
