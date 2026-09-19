import Foundation

enum ChipParser {
    static let maxChips = 32
    static let maxScopedPerProvider = 8
    static let maxLabelChars = 32

    private struct WindowSpec {
        let jsonKey: String
        let label: String
        let utilizationKeys: [String]
        let resetKeys: [String]
    }

    private struct ProviderSpec {
        let jsonKey: String
        let includeSecondary: Bool
        let windows: [WindowSpec]
    }

    private static let providers: [ProviderSpec] = [
        ProviderSpec(jsonKey: "claude", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "five_hour", label: "Claude 5h", utilizationKeys: ["utilization", "used_percent"], resetKeys: ["resets_at", "reset_at"]),
            WindowSpec(jsonKey: "seven_day", label: "Claude 7d", utilizationKeys: ["utilization", "used_percent"], resetKeys: ["resets_at", "reset_at"]),
            WindowSpec(jsonKey: "seven_day_opus", label: "Opus 7d", utilizationKeys: ["utilization", "used_percent"], resetKeys: ["resets_at", "reset_at"]),
        ]),
        ProviderSpec(jsonKey: "codex", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Codex 5h", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "Codex 7d", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "credit_window", label: "Codex $", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "cursor", includeSecondary: false, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Cursor", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "grok", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Grok 7d", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "Grok extra", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "gemini", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Gemini Pro", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "Gemini Flash", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "tertiary_window", label: "Gemini Lite", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "kimi", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Kimi 7d", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "Kimi 5h", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "kiro", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Kiro", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "copilot", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Copilot", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "Copilot chat", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "antigravity", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "AG Cl 7d", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "AG Cl 5h", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "tertiary_window", label: "Gm 7d", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "quaternary_window", label: "Gm 5h", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "zcode", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "ZCode", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "ZCode turbo", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "opencodeGo", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "OpenCode 5h", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "OpenCode wk", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "tertiary_window", label: "OpenCode mo", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "commandCode", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "CmdCode 5h", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "CmdCode wk", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "qoder", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Qoder", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
            WindowSpec(jsonKey: "secondary_window", label: "Qoder Ult", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "qoderCn", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Qoder CN", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "codingPlan", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Coding plan", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
        ProviderSpec(jsonKey: "agentPlan", includeSecondary: true, windows: [
            WindowSpec(jsonKey: "primary_window", label: "Agent plan", utilizationKeys: ["used_percent"], resetKeys: ["reset_at"]),
        ]),
    ]

    static func parse(_ data: Data) throws -> [Chip] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw LimitsError.badPayload
        }
        var chips: [Chip] = []
        for spec in providers {
            guard let provider = root[spec.jsonKey] as? [String: Any] else { continue }
            guard isUsable(provider) else { continue }
            for window in spec.windows {
                if let chip = chip(from: provider[window.jsonKey], spec: window, id: "\(spec.jsonKey).\(window.jsonKey)") {
                    chips.append(chip)
                    if chips.count >= maxChips { return chips }
                    if !spec.includeSecondary { break }
                }
            }
            if let scoped = provider["weekly_scoped"] as? [[String: Any]] {
                for (i, row) in scoped.prefix(maxScopedPerProvider).enumerated() {
                    let label = displayLabel(row["label"] as? String, fallback: "Scoped \(i + 1)")
                    let scopedSpec = WindowSpec(
                        jsonKey: "weekly_scoped",
                        label: label,
                        utilizationKeys: ["utilization", "used_percent"],
                        resetKeys: ["resets_at", "reset_at"]
                    )
                    if let chip = chip(from: row, spec: scopedSpec, id: "\(spec.jsonKey).scoped.\(i)") {
                        chips.append(chip)
                    }
                    if chips.count >= maxChips { return chips }
                }
            }
            if chips.count >= maxChips { return chips }
        }
        return chips
    }

    private static func displayLabel(_ raw: String?, fallback: String) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.split(whereSeparator: \.isNewline).joined(separator: " ")
        let label = collapsed.isEmpty ? fallback : collapsed
        if label.count <= maxLabelChars { return label }
        return String(label.prefix(maxLabelChars))
    }

    private static func isUsable(_ provider: [String: Any]) -> Bool {
        if isStale(provider) { return false }
        if let configured = provider["configured"] as? Bool, configured == false {
            return false
        }
        if let error = provider["error"] as? String, !error.isEmpty {
            return false
        }
        return true
    }

    private static func isStale(_ dict: [String: Any]) -> Bool {
        if dict["stale"] as? Bool == true { return true }
        if let provenance = dict["provenance"] as? [String: Any],
           provenance["stale"] as? Bool == true {
            return true
        }
        return false
    }

    private static func chip(from raw: Any?, spec: WindowSpec, id: String) -> Chip? {
        guard let window = raw as? [String: Any] else { return nil }
        if isStale(window) { return nil }
        guard let rawPercent = firstNumber(window, keys: spec.utilizationKeys) else { return nil }
        let percent = min(max(rawPercent, 0), 100)
        let reset = firstDate(window, keys: spec.resetKeys) ?? resetAfter(window)
        let windowSeconds = firstNumber(window, keys: ["limit_window_seconds"])
            ?? inferredWindowSeconds(spec.label)
        return Chip(id: id, label: spec.label, percent: percent, resetAt: reset, windowSeconds: windowSeconds)
    }

    private static func inferredWindowSeconds(_ label: String) -> Double? {
        if label.hasSuffix("5h") { return 5 * 3600 }
        if label.hasSuffix("7d") || label.hasSuffix("wk") { return 7 * 24 * 3600 }
        if label.hasSuffix("mo") { return 30 * 24 * 3600 }
        return nil
    }

    private static func resetAfter(_ window: [String: Any]) -> Date? {
        if let secs = firstNumber(window, keys: ["reset_after_seconds"]), secs > 0 {
            return Date().addingTimeInterval(secs)
        }
        return nil
    }

    private static func firstNumber(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let n = number(dict[key]) { return n }
        }
        return nil
    }

    private static func firstDate(_ dict: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let d = parseDate(dict[key]) { return d }
        }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n.isFinite ? n : nil
        case let n as Int: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            if let n = Double(t), n.isFinite { return n }
            return nil
        default:
            return nil
        }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        switch value {
        case let s as String:
            return parseISO(s)
        case let n as Int:
            return dateFromUnix(Double(n))
        case let n as Double:
            return dateFromUnix(n)
        case let n as NSNumber:
            return dateFromUnix(n.doubleValue)
        default:
            return nil
        }
    }

    private static func dateFromUnix(_ n: Double) -> Date? {
        guard n.isFinite, n > 1_000_000_000 else { return nil }
        if n > 10_000_000_000 {
            return Date(timeIntervalSince1970: n / 1000)
        }
        return Date(timeIntervalSince1970: n)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoBasic.date(from: s) { return d }
        // TokenTracker sometimes emits +00:00 with 6 fractional digits.
        let trimmed = trimFractionalSeconds(s)
        if trimmed != s {
            if let d = isoFractional.date(from: trimmed) { return d }
            if let d = isoBasic.date(from: trimmed) { return d }
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
        let kept = digits.prefix(3)
        return String(s[..<after]) + kept + String(s[i...])
    }
}
