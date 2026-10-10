import Foundation

/// Used only when TokenTracker is missing a Command Code window.
/// The 5h and weekly caps come from `windowLimits`. There is no monthly window:
/// the monthly meter is included credits left against the plan allowance, and it
/// resets at the end of the billing period.
enum CommandCodeFallback {
    private static let api = URL(string: "https://api.commandcode.ai")!

    static func chips() async -> [Chip] {
        guard let key = apiKey() else {
            Log.line("command code fallback: no local login")
            return []
        }
        do {
            let org = await orgID(apiKey: key)
            async let creditsReq = getJSON(path: creditsPath(org), apiKey: key)
            async let subscriptionReq = getJSON(path: subscriptionPath(org), apiKey: key)
            guard let credits = try await creditsReq else {
                Log.line("command code fallback: credits response was not JSON")
                return []
            }
            let chips = makeChips(credits, subscription: try? await subscriptionReq)
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
        billingPath("/alpha/billing/credits", org: org)
    }

    private static func subscriptionPath(_ org: String?) -> String {
        billingPath("/alpha/billing/subscriptions", org: org)
    }

    private static func billingPath(_ path: String, org: String?) -> String {
        guard let org, !org.isEmpty else { return path }
        let escaped = org.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? org
        return "\(path)?orgId=\(escaped)"
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

    /// Included monthly credits. Keyed by the 5-hour and weekly caps, which the
    /// credits payload already carries, then by plan id when the caps are new.
    private static let allowanceByCaps: [String: Double] = [
        "2/5": 10,
        "3/6": 10,
        "9/18": 30,
        "14/35": 70,
        "16/40": 80,
        "12/24": 40,
        "45/90": 150,
        "90/180": 300,
    ]
    private static let allowanceByPlan: [String: Double] = [
        "individual-go": 10,
        "individual-goat": 70,
        "individual-pro": 30,
        "individual-pro-v1": 80,
        "individual-max": 150,
        "individual-ultra": 300,
        "teams-pro": 40,
    ]

    private static func makeChips(_ body: [String: Any], subscription: [String: Any]?) -> [Chip] {
        let limits = windowLimits(body)
        var chips: [Chip] = []
        let fiveHour = limits?["fiveHour"] as? [String: Any] ?? limits?["five_hour"] as? [String: Any]
        let weekly = limits?["weekly"] as? [String: Any]
        if let fiveHour, let chip = chip(from: fiveHour, id: "commandCode.primary_window", label: "CmdCode 5h", windowSeconds: 5 * 3600) {
            chips.append(chip)
        }
        if let weekly, let chip = chip(from: weekly, id: "commandCode.secondary_window", label: "CmdCode wk", windowSeconds: 7 * 24 * 3600) {
            chips.append(chip)
        }
        if let monthly = monthlyChip(body, fiveHour: fiveHour, weekly: weekly, subscription: subscription) {
            chips.append(monthly)
        }
        return chips
    }

    private static func monthlyChip(
        _ body: [String: Any],
        fiveHour: [String: Any]?,
        weekly: [String: Any]?,
        subscription: [String: Any]?
    ) -> Chip? {
        let credits = (body["credits"] as? [String: Any])
            ?? ((body["data"] as? [String: Any])?["credits"] as? [String: Any])
        guard let remaining = credits.flatMap({ ChipParser.number($0["monthlyCredits"]) }) else { return nil }
        let plan = subscription.flatMap(subscriptionFields)
        let allowance = monthlyAllowance(
            planID: plan?.planID,
            fiveHourCap: fiveHour.flatMap { ChipParser.number($0["cap"] ?? $0["limit"]) },
            weeklyCap: weekly.flatMap { ChipParser.number($0["cap"] ?? $0["limit"]) }
        )
        guard let allowance, allowance > 0 else { return nil }
        let used = min(max(allowance - remaining, 0), allowance)
        let window: Double
        if let start = plan?.start, let end = plan?.end, end > start {
            window = end.timeIntervalSince(start)
        } else {
            window = 30 * 24 * 3600
        }
        return Chip(
            id: "commandCode.tertiary_window",
            label: "CmdCode mo",
            percent: (used / allowance) * 100,
            resetAt: plan?.end,
            windowSeconds: window,
            source: .fallback
        )
    }

    private static func monthlyAllowance(planID: String?, fiveHourCap: Double?, weeklyCap: Double?) -> Double? {
        if let fiveHourCap, let weeklyCap {
            let key = "\(Int(fiveHourCap.rounded()))/\(Int(weeklyCap.rounded()))"
            if let allowance = allowanceByCaps[key] { return allowance }
        }
        if let planID, let allowance = allowanceByPlan[planID] { return allowance }
        return nil
    }

    private static func subscriptionFields(_ body: [String: Any]) -> (planID: String?, start: Date?, end: Date?)? {
        let data = (body["data"] as? [String: Any]) ?? body
        let planID = data["planId"] as? String
        let start = resetDate(data["currentPeriodStart"])
        let end = resetDate(data["currentPeriodEnd"])
        guard planID != nil || end != nil else { return nil }
        return (planID, start, end)
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
        guard let text = raw as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
