import Foundation
import Security

/// Used only when TokenTracker has no Claude 5h or 7d window.
/// Reads the local Claude Code login and asks Claude for those pools.
enum ClaudeFallback {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Public Claude Code client. It identifies the app. It is not a secret.
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let service = "Claude Code-credentials"
    private static let beta = "oauth-2025-04-20"

    static func chips() async -> [Chip] {
        guard var session = await loadSession() else { return [] }
        if session.expiresSoon {
            do {
                session = try await refresh(session)
            } catch {
                Log.line("claude fallback: \(LimitsError.describe(error, host: "Claude"))")
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
                Log.line("claude fallback: \(LimitsError.describe(error, host: "Claude"))")
                return []
            }
        } catch {
            Log.line("claude fallback: \(LimitsError.describe(error, host: "Claude"))")
            return []
        }
    }

    private struct Session {
        var credential: [String: Any]
        var accessToken: String
        var refreshToken: String?
        var scopes: [String]
        var expiresAt: Date?

        var expiresSoon: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    private static func loadSession() async -> Session? {
        let (data, status) = await Task.detached(priority: .userInitiated) {
            copyCredential()
        }.value
        guard status == errSecSuccess, let data else {
            if status == errSecItemNotFound {
                Log.line("claude fallback: no local login")
            } else {
                Log.line("claude fallback: could not read the local login")
            }
            return nil
        }
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = file["claudeAiOauth"] as? [String: Any],
              let access = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty
        else {
            Log.line("claude fallback: local login was unreadable")
            return nil
        }
        let refresh = (oauth["refreshToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = oauth["scopes"] as? [String] ?? []
        return Session(
            credential: file,
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            scopes: scopes,
            expiresAt: expiry(oauth["expiresAt"])
        )
    }

    private static func windows(_ session: Session) async throws -> [Chip] {
        guard let body = try await getJSON(session) else {
            Log.line("claude fallback: usage response was not JSON")
            return []
        }
        let chips = makeChips(body)
        if chips.isEmpty {
            Log.line("claude fallback: no windows in usage")
        }
        return chips
    }

    private static func refresh(_ session: Session) async throws -> Session {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw LimitsError.http(401)
        }
        var payload: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if !session.scopes.isEmpty {
            payload["scope"] = session.scopes.joined(separator: " ")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LimitsError.http(0) }
        guard http.statusCode == 200 else { throw LimitsError.http(http.statusCode) }
        guard data.count <= 512_000 else { throw LimitsError.tooLarge }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty
        else { throw LimitsError.badPayload }
        var next = session
        next.accessToken = access
        if let rotated = (body["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rotated.isEmpty {
            next.refreshToken = rotated
        }
        if let seconds = ChipParser.number(body["expires_in"]), seconds > 0 {
            next.expiresAt = Date().addingTimeInterval(seconds)
        }
        var oauth = next.credential["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = next.accessToken
        if let refresh = next.refreshToken { oauth["refreshToken"] = refresh }
        if let expiresAt = next.expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        next.credential["claudeAiOauth"] = oauth
        await persist(next)
        return next
    }

    /// `security` is already allowed to read this item. TokenBar's own signature
    /// changes on every install, so a direct keychain call waits on a dialog
    /// that never appears.
    private static func copyCredential() -> (Data?, OSStatus) {
        let result = runSecurity(["find-generic-password", "-s", service, "-w"])
        guard result.status == 0 else {
            if result.error.contains("could not be found") { return (nil, errSecItemNotFound) }
            return (nil, errSecAuthFailed)
        }
        var data = result.output
        if data.last == 10 { data.removeLast() }
        return (data, errSecSuccess)
    }

    private static func persist(_ session: Session) async {
        guard let data = try? JSONSerialization.data(withJSONObject: session.credential),
              let password = String(data: data, encoding: .utf8)
        else { return }
        let saved = await Task.detached(priority: .userInitiated) {
            runSecurity([
                "add-generic-password", "-U",
                "-s", service,
                "-a", NSUserName(),
                "-w", password,
            ]).status == 0
        }.value
        if !saved {
            Log.line("claude fallback: could not save refreshed login")
        }
    }

    private static func runSecurity(_ arguments: [String]) -> (status: Int32, output: Data, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, Data(), "")
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output, error)
    }

    private static func getJSON(_ session: Session) async throws -> [String: Any]? {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else { throw LimitsError.http(http.statusCode) }
        guard data.count <= 512_000 else { throw LimitsError.tooLarge }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func makeChips(_ body: [String: Any]) -> [Chip] {
        [
            window(body["five_hour"], id: "claude.five_hour", label: "Claude 5h", seconds: 5 * 3600),
            window(body["seven_day"], id: "claude.seven_day", label: "Claude 7d", seconds: 7 * 24 * 3600),
        ].compactMap { $0 }
    }

    private static func window(_ raw: Any?, id: String, label: String, seconds: Double) -> Chip? {
        guard let entry = raw as? [String: Any],
              let percent = ChipParser.number(entry["utilization"])
        else { return nil }
        return Chip(
            id: id,
            label: label,
            percent: min(max(percent, 0), 100),
            resetAt: resetDate(entry),
            windowSeconds: seconds,
            source: .fallback
        )
    }

    private static func resetDate(_ entry: [String: Any]) -> Date? {
        if let n = ChipParser.number(entry["resets_at"]) ?? ChipParser.number(entry["reset_at"]) {
            if n > 10_000_000_000 { return Date(timeIntervalSince1970: n / 1000) }
            if n > 1_000_000_000 { return Date(timeIntervalSince1970: n) }
        }
        if let raw = (entry["resets_at"] as? String) ?? (entry["reset_at"] as? String) {
            return parseISO(raw)
        }
        return nil
    }

    private static func expiry(_ value: Any?) -> Date? {
        guard let n = ChipParser.number(value), n > 0 else { return nil }
        if n > 10_000_000_000 { return Date(timeIntervalSince1970: n / 1000) }
        return Date(timeIntervalSince1970: n)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseISO(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let date = isoFractional.date(from: s) { return date }
        if let date = isoBasic.date(from: s) { return date }
        let trimmed = trimFractionalSeconds(s)
        if trimmed != s {
            if let date = isoFractional.date(from: trimmed) { return date }
            if let date = isoBasic.date(from: trimmed) { return date }
        }
        return nil
    }

    /// ISO-8601 allows many fractional digits. The formatter accepts three.
    private static func trimFractionalSeconds(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        let after = s.index(after: dot)
        var i = after
        while i < s.endIndex, s[i].isNumber { i = s.index(after: i) }
        let digits = s[after..<i]
        if digits.count <= 3 { return s }
        return String(s[..<after]) + digits.prefix(3) + String(s[i...])
    }
}
