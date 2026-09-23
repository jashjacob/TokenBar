import Foundation

/// Used only when TokenTracker has no OpenCode windows.
/// Reads the local OpenCode Go key and asks OpenCode for the 5h, weekly, and monthly caps.
enum OpenCodeFallback {
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static func chips() async -> [Chip] {
        guard let key = apiKey() else {
            Log.line("opencode fallback: no local login")
            return []
        }
        do {
            guard let body = try await getJSON(apiKey: key) else {
                Log.line("opencode fallback: usage response was not JSON")
                return []
            }
            let chips = makeChips(body)
            if chips.isEmpty {
                Log.line("opencode fallback: no windows in usage")
            }
            return chips
        } catch {
            Log.line("opencode fallback: \(error.localizedDescription)")
            return []
        }
    }

    private static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENCODE_GO_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        let url = dataDirectory().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let go = obj["opencode-go"] as? [String: Any],
              let key = go["key"] as? String
        else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dataDirectory() -> URL {
        if let raw = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: raw).appendingPathComponent("opencode")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode")
    }

    private static func getJSON(apiKey: String) async throws -> [String: Any]? {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else { throw LimitsError.http(http.statusCode) }
        guard data.count <= 512_000 else { throw LimitsError.tooLarge }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func makeChips(_ body: [String: Any]) -> [Chip] {
        let usage = body["usage"] as? [String: Any]
        let specs: [(String, String, String, Double)] = [
            ("opencodeGo.primary_window", "OpenCode 5h", "rolling", 5 * 3600),
            ("opencodeGo.secondary_window", "OpenCode wk", "weekly", 7 * 24 * 3600),
            ("opencodeGo.tertiary_window", "OpenCode mo", "monthly", 30 * 24 * 3600),
        ]
        let legacyKeys = ["rolling": "rollingUsage", "weekly": "weeklyUsage", "monthly": "monthlyUsage"]
        return specs.compactMap { id, label, key, seconds in
            let modern = usage?[key] as? [String: Any] ?? body[key] as? [String: Any]
            let legacy = body[legacyKeys[key] ?? ""] as? [String: Any]
            return chip(modern: modern, legacy: legacy, id: id, label: label, windowSeconds: seconds)
        }
    }

    private static func chip(
        modern: [String: Any]?,
        legacy: [String: Any]?,
        id: String,
        label: String,
        windowSeconds: Double
    ) -> Chip? {
        let source = modern ?? legacy
        guard let source else { return nil }
        guard let raw = ChipParser.number(source["percent"] ?? source["usagePercent"] ?? source["usage_percent"]) else {
            return nil
        }
        var percent = raw
        if percent > 0, percent < 1 { percent *= 100 }
        percent = min(max(percent, 0), 100)
        let reset = resetDate(source) ?? resetAfterSeconds(source)
        return Chip(id: id, label: label, percent: percent, resetAt: reset, windowSeconds: windowSeconds)
    }

    private static func resetDate(_ window: [String: Any]) -> Date? {
        let raw = window["resetsAt"] ?? window["resets_at"] ?? window["resetAt"] ?? window["reset_at"]
        guard let text = raw as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func resetAfterSeconds(_ window: [String: Any]) -> Date? {
        guard let seconds = ChipParser.number(window["resetInSec"] ?? window["reset_in_sec"]), seconds >= 0 else {
            return nil
        }
        return Date().addingTimeInterval(seconds)
    }
}
