import Foundation

enum LimitsError: LocalizedError {
    case offline
    case badPayload
    case tooLarge
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .offline: return "TokenTracker is not running"
        case .badPayload: return "TokenTracker returned unreadable limits"
        case .tooLarge: return "TokenTracker response was too large"
        case .http(let code): return "TokenTracker HTTP \(code)"
        }
    }
}

enum LimitsClient {
    static let defaultPort = 7680
    static let path = "/functions/tokentracker-usage-limits"
    /// Usage JSON is tiny. Cap so a runaway local server cannot fill RAM.
    static let maxBodyBytes = 512_000

    static func fetch() async throws -> [Chip] {
        var chips: [Chip] = []
        var trackerError: Error?
        do {
            chips = try ChipParser.parse(try await get(URL(string: "http://127.0.0.1:\(discoverPort())\(path)")!))
        } catch let error as LimitsError {
            trackerError = error
        } catch {
            trackerError = LimitsError.offline
        }
        chips = await fill(chips, prefix: "commandCode.", loader: CommandCodeFallback.chips, log: "command code")
        if chips.isEmpty, let trackerError {
            throw trackerError
        }
        return chips
    }

    private static func fill(
        _ chips: [Chip],
        prefix: String,
        loader: () async -> [Chip],
        log: String
    ) async -> [Chip] {
        if chips.contains(where: { $0.id.hasPrefix(prefix) }) { return chips }
        let extra = await loader()
        guard !extra.isEmpty else { return chips }
        Log.line("\(log) fallback: \(extra.map(\.touchTitle).joined(separator: " | "))")
        return chips + extra
    }

    static func discoverPort() -> Int {
        let stored = UserDefaults.standard.integer(forKey: "tokenTrackerPort")
        guard (1...65_535).contains(stored) else { return defaultPort }
        return stored
    }

    static func dashboardURL() -> URL {
        URL(string: "http://127.0.0.1:\(discoverPort())/limits")!
    }

    static func homeURL() -> URL {
        URL(string: "http://127.0.0.1:\(discoverPort())/")!
    }

    static func fetchToday() async throws -> TodayUsage {
        try parseToday(try await get(summaryURL()))
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LimitsError.offline }
        guard http.statusCode == 200 else { throw LimitsError.http(http.statusCode) }
        guard data.count <= maxBodyBytes else { throw LimitsError.tooLarge }
        return data
    }

    /// Same query TokenTrackerBar uses: local calendar day + timezone + account view.
    static func summaryURL() -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = discoverPort()
        components.path = "/functions/tokentracker-usage-summary"
        let day = todayStamp()
        let offsetMinutes = Int((TimeZone.current.secondsFromGMT() / 60))
        components.queryItems = [
            URLQueryItem(name: "from", value: day),
            URLQueryItem(name: "to", value: day),
            URLQueryItem(name: "tz", value: TimeZone.current.identifier),
            URLQueryItem(name: "tz_offset_minutes", value: String(offsetMinutes)),
            URLQueryItem(name: "account", value: "1"),
        ]
        return components.url!
    }

    static func parseToday(_ data: Data) throws -> TodayUsage {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any],
              let totals = root["totals"] as? [String: Any]
        else { throw LimitsError.badPayload }
        let tokens = ChipParser.number(totals["billable_total_tokens"])
            ?? ChipParser.number(totals["total_tokens"])
            ?? 0
        let cost = ChipParser.number(totals["total_cost_usd"]) ?? 0
        return TodayUsage(tokens: tokens, costUSD: cost)
    }

    static func todayStamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
