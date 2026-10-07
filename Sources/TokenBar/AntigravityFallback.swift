import Foundation

/// Used only when TokenTracker has no Antigravity windows.
/// Reads the local Antigravity login and asks for the Claude and Gemini pools.
enum AntigravityFallback {
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    /// Filled after a refresh succeeds, so the app binary is scanned once per launch.
    private static var cachedClient: (id: String, secret: String)?
    private static let defaultHost = "https://cloudcode-pa.googleapis.com"

    private struct WindowSpec {
        let bucket: String
        let id: String
        let label: String
        let seconds: Double
    }

    private static let windows: [WindowSpec] = [
        WindowSpec(bucket: "3p-weekly", id: "antigravity.primary_window", label: "AG Cl 7d", seconds: 7 * 24 * 3600),
        WindowSpec(bucket: "3p-5h", id: "antigravity.secondary_window", label: "AG Cl 5h", seconds: 5 * 3600),
        WindowSpec(bucket: "gemini-weekly", id: "antigravity.tertiary_window", label: "Gm 7d", seconds: 7 * 24 * 3600),
        WindowSpec(bucket: "gemini-5h", id: "antigravity.quaternary_window", label: "Gm 5h", seconds: 5 * 3600),
    ]

    static func chips() async -> [Chip] {
        guard var session = loadSession() else {
            Log.line("antigravity fallback: no local login")
            return []
        }
        if session.expiresSoon {
            do {
                session = try await refresh(session)
            } catch {
                Log.line("antigravity fallback: \(error.localizedDescription)")
                return []
            }
        }
        do {
            return try await fetchWindows(session)
        } catch LimitsError.http(401) {
            do {
                let next = try await refresh(session)
                return try await fetchWindows(next)
            } catch {
                Log.line("antigravity fallback: \(error.localizedDescription)")
                return []
            }
        } catch {
            Log.line("antigravity fallback: \(error.localizedDescription)")
            return []
        }
    }

    private struct Session {
        var file: [String: Any]
        var path: URL
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?

        var expiresSoon: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    private static func loadSession() -> Session? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        guard let data = try? Data(contentsOf: path),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = file["token"] as? [String: Any],
              let access = (token["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty
        else { return nil }
        let refresh = (token["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Session(
            file: file,
            path: path,
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            expiresAt: parseISO(token["expiry"] as? String)
        )
    }

    private static func fetchWindows(_ session: Session) async throws -> [Chip] {
        let loaded = try await post(
            endpoint("v1internal:loadCodeAssist"),
            bearer: session.accessToken,
            body: [
                "metadata": [
                    "ideType": "ANTIGRAVITY",
                    "platform": "PLATFORM_UNSPECIFIED",
                    "pluginType": "GEMINI",
                ],
            ]
        )
        let named = (loaded["cloudaicompanionProject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let project = (named?.isEmpty == false) ? named! : "aicode-consumers"
        let quota = try await post(
            endpoint("v1internal:retrieveUserQuotaSummary"),
            bearer: session.accessToken,
            body: ["project": project]
        )
        let chips = makeChips(quota)
        if chips.isEmpty {
            Log.line("antigravity fallback: no windows in usage")
        }
        return chips
    }

    private static func refresh(_ session: Session) async throws -> Session {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw LimitsError.http(401)
        }
        let preferred = jwtString(session.file["id_token"] as? String, "aud")
        let pairs = await oauthPairs(preferredID: preferred)
        guard !pairs.isEmpty else {
            Log.line("antigravity fallback: Antigravity.app is not installed, so the login cannot be refreshed")
            throw LimitsError.badPayload
        }
        var lastError: Error = LimitsError.badPayload
        for pair in pairs {
            do {
                let next = try await sendRefresh(session, clientID: pair.id, clientSecret: pair.secret, refreshToken: refreshToken)
                cachedClient = pair
                return next
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func sendRefresh(
        _ session: Session,
        clientID: String,
        clientSecret: String,
        refreshToken: String
    ) async throws -> Session {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form([
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
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
            next.file["id_token"] = idToken
        }
        let expiresIn = ChipParser.number(payload["expires_in"]) ?? 3600
        next.expiresAt = Date().addingTimeInterval(expiresIn)
        var token = next.file["token"] as? [String: Any] ?? [:]
        token["access_token"] = next.accessToken
        if let refresh = next.refreshToken { token["refresh_token"] = refresh }
        if let expiresAt = next.expiresAt { token["expiry"] = isoString(expiresAt) }
        next.file["token"] = token
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
            Log.line("antigravity fallback: could not save refreshed login")
        }
    }

    private static func post(_ url: URL, bearer: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LimitsError.http(0) }
        guard http.statusCode == 200 else { throw LimitsError.http(http.statusCode) }
        guard data.count <= 512_000 else { throw LimitsError.tooLarge }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.badPayload
        }
        return obj
    }

    private static func makeChips(_ body: [String: Any]) -> [Chip] {
        var buckets: [String: [String: Any]] = [:]
        for group in body["groups"] as? [[String: Any]] ?? [] {
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = bucket["bucketId"] as? String else { continue }
                buckets[id] = bucket
            }
        }
        return windows.compactMap { spec in
            guard let bucket = buckets[spec.bucket],
                  let fraction = ChipParser.number(bucket["remainingFraction"])
            else { return nil }
            let remaining = min(max(fraction, 0), 1)
            return Chip(
                id: spec.id,
                label: spec.label,
                percent: (1 - remaining) * 100,
                resetAt: parseISO(bucket["resetTime"] as? String),
                windowSeconds: spec.seconds,
                source: .fallback
            )
        }
    }

    private static func endpoint(_ path: String) -> URL {
        var base = defaultHost
        if let raw = ProcessInfo.processInfo.environment["ANTIGRAVITY_CLOUD_CODE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            base = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        }
        return URL(string: base + "/" + path) ?? URL(string: defaultHost + "/" + path)!
    }

    private static func form(_ items: [(String, String)]) -> Data {
        items.map { key, value in
            "\(urlForm(key))=\(urlForm(value))"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private static func urlForm(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The desktop OAuth client lives in the installed Antigravity app. It is not copied into this repo.
    private static func oauthPairs(preferredID: String?) async -> [(id: String, secret: String)] {
        if let cachedClient { return [cachedClient] }
        return await Task.detached(priority: .utility) {
            guard let data = languageServerData() else { return [] }
            let secrets = secretCandidates(in: data)
            var ids = clientIDCandidates(in: data)
            if let preferredID, !preferredID.isEmpty {
                ids.removeAll { $0 == preferredID }
                ids.insert(preferredID, at: 0)
            }
            return ids.flatMap { id in secrets.map { (id: id, secret: $0) } }
        }.value
    }

    private static func languageServerData() -> Data? {
        let url = URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func secretCandidates(in data: Data) -> [String] {
        let prefix = Data("GOCSPX-".utf8)
        var found: [String] = []
        var search = data.startIndex
        while let range = data.range(of: prefix, in: search..<data.endIndex) {
            let start = range.upperBound
            let end = data.index(start, offsetBy: 28, limitedBy: data.endIndex) ?? data.endIndex
            let body = data[start..<end]
            if body.count == 28, body.allSatisfy(isSecretByte),
               let secret = String(data: prefix + body, encoding: .utf8),
               !found.contains(secret) {
                found.append(secret)
            }
            search = range.upperBound
        }
        return found
    }

    private static func clientIDCandidates(in data: Data) -> [String] {
        let suffix = Data(".apps.googleusercontent.com".utf8)
        var found: [String] = []
        var search = data.startIndex
        while let range = data.range(of: suffix, in: search..<data.endIndex) {
            var start = range.lowerBound
            while start > data.startIndex {
                let previous = data[data.index(before: start)]
                if isClientByte(previous) {
                    start = data.index(before: start)
                } else {
                    break
                }
            }
            let raw = data[start..<range.upperBound]
            if let id = String(data: raw, encoding: .utf8),
               id.contains("-"), id.first?.isNumber == true, !found.contains(id) {
                found.append(id)
            }
            search = range.upperBound
        }
        return found
    }

    private static func isSecretByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 45, 95: return true
        default: return false
        }
    }

    private static func isClientByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 97...122, 45: return true
        default: return false
        }
    }

    private static func jwtString(_ token: String?, _ key: String) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        let pad = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func isoString(_ date: Date) -> String {
        isoFractional.string(from: date)
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

    private static func parseISO(_ raw: String?) -> Date? {
        guard let raw else { return nil }
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
