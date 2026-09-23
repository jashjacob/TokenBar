import Foundation

/// Used only when TokenTracker has no Command Code windows.
/// Reads the local Command Code login and asks Command Code for the 5h and weekly caps.
enum CommandCodeFallback {
    private static let api = URL(string: "https://api.commandcode.ai")!

    static func chips() async -> [Chip] {
        guard let key = apiKey() else {
            Log.line("command code fallback: no local login")
            return []
        }
        do {
            let org = await orgID(apiKey: key)
            guard let credits = try await getJSON(path: creditsPath(org), apiKey: key) else {
                Log.line("command code fallback: credits response was not JSON")
                return []
            }
            let chips = makeChips(credits)
            if chips.isEmpty {
                Log.line("command code fallback: no windows in credits")
            }
            return chips
        } catch {
            Log.line("command code fallback: \(error.localizedDescription)")
            return []
        }
    }

    private static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["COMMAND_CODE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".commandcode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["apiKey"] as? String
        else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func orgID(apiKey: String) async -> String? {
        guard let body = try? await getJSON(path: "/alpha/whoami?limits=1", apiKey: apiKey) else { return nil }
        if let data = body["data"] as? [String: Any],
           let org = data["org"] as? [String: Any],
           let id = org["id"] as? String, !id.isEmpty {
            return id
        }
        if let org = body["org"] as? [String: Any],
           let id = org["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private static func creditsPath(_ org: String?) -> String {
        guard let org, !org.isEmpty else { return "/alpha/billing/credits" }
        let allowed = CharacterSet.urlQueryAllowed
        let escaped = org.addingPercentEncoding(withAllowedCharacters: allowed) ?? org
        return "/alpha/billing/credits?orgId=\(escaped)"
    }

    private static func getJSON(path: String, apiKey: String) async throws -> [String: Any]? {
        guard let url = URL(string: path, relativeTo: api) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else {
            throw LimitsError.http(http.statusCode)
        }
        guard data.count <= 512_000 else { throw LimitsError.tooLarge }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func makeChips(_ body: [String: Any]) -> [Chip] {
        let limits = windowLimits(body)
        var chips: [Chip] = []
        if let window = limits?["fiveHour"] as? [String: Any] ?? limits?["five_hour"] as? [String: Any],
           let chip = chip(from: window, id: "commandCode.primary_window", label: "CmdCode 5h", windowSeconds: 5 * 3600) {
            chips.append(chip)
        }
        if let window = limits?["weekly"] as? [String: Any],
           let chip = chip(from: window, id: "commandCode.secondary_window", label: "CmdCode wk", windowSeconds: 7 * 24 * 3600) {
            chips.append(chip)
        }
        return chips
    }

    private static func windowLimits(_ body: [String: Any]) -> [String: Any]? {
        if let limits = body["windowLimits"] as? [String: Any] { return limits }
        if let data = body["data"] as? [String: Any] {
            if let limits = data["windowLimits"] as? [String: Any] { return limits }
            return data
        }
        return nil
    }

    private static func chip(from window: [String: Any], id: String, label: String, windowSeconds: Double) -> Chip? {
        guard let used = ChipParser.number(window["used"]),
              let cap = ChipParser.number(window["cap"] ?? window["total"] ?? window["limit"]),
              cap > 0, used >= 0
        else { return nil }
        let percent = min(max((used / cap) * 100, 0), 100)
        return Chip(
            id: id,
            label: label,
            percent: percent,
            resetAt: resetDate(window["resetAt"] ?? window["reset_at"] ?? window["reset"]),
            windowSeconds: windowSeconds,
            source: .fallback
        )
    }

    private static func resetDate(_ raw: Any?) -> Date? {
        if let n = ChipParser.number(raw), n > 0 {
            let seconds = n > 10_000_000_000 ? n / 1000 : n
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = raw as? String {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }
}
