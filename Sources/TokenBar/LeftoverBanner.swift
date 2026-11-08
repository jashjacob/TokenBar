import Foundation

/// One soft sentence when a week or a month is about to reset and a real slice is still unused.
/// Five-hour chips stay quiet. They come back the same afternoon.
enum LeftoverBanner {
    /// Grok's only quota window. A smaller leftover is still worth saying this close to the reset.
    static let grokID = "grok.primary_window"
    static let grokHorizon: TimeInterval = 2 * 3600
    static let grokMinimumUnused: Double = 10
    /// The label is just "GrokBot", but the window behind it is always 7 days.
    static let grokBotID = "cursor.quaternary_window"
    /// A week or a month. The last day is the warning.
    static let weekHorizon: TimeInterval = 24 * 3600
    static let weekMinimumUnused: Double = 20
    /// Already rolling into the next window. The reset celebration covers that moment.
    static let floor: TimeInterval = 2 * 60
    /// Codex slides its reset by a minute or two. That is the same window.
    static let sameWindow: TimeInterval = 120

    struct Choice {
        var id: String
        var resetAt: Date
        var remaining: TimeInterval
        var unused: Double
    }

    struct History {
        var lastAt: Date?
        var spoken: [String: Date] = [:]

        /// The soonest chip that has not already been said for this reset.
        /// A chip already said does not hide the next one. Nil during the quiet stretch.
        func next(_ choices: [Choice], now: Date, otherQuiet: Date?) -> Choice? {
            let ranked = choices.sorted { lhs, rhs in
                if lhs.remaining != rhs.remaining { return lhs.remaining < rhs.remaining }
                return lhs.id < rhs.id
            }
            let best = ranked.first { choice in
                guard let said = spoken[choice.id] else { return true }
                return abs(said.timeIntervalSince(choice.resetAt)) >= sameWindow
            }
            guard let best else { return nil }
            if let otherQuiet, now.timeIntervalSince(otherQuiet) < PaceBanner.gap { return nil }
            if let lastAt, now.timeIntervalSince(lastAt) < PaceBanner.gap { return nil }
            return best
        }

        mutating func remember(_ choice: Choice, now: Date) {
            spoken[choice.id] = choice.resetAt
            lastAt = now
            spoken = spoken.filter { $0.value.timeIntervalSince(now) > -86_400 }
        }
    }

    /// Five-hour chips come back the same afternoon, so they never qualify.
    static func qualifies(id: String, windowTag: String?, percent: Double, remaining: TimeInterval) -> Bool {
        guard remaining > floor else { return false }
        let unused = 100 - min(max(percent, 0), 100)
        if id == grokID, remaining <= grokHorizon, percent > 0, unused >= grokMinimumUnused {
            return true
        }
        let closing = windowTag == "7d" || windowTag == "wk" || windowTag == "mo" || id == grokBotID
        guard closing else { return false }
        guard remaining <= weekHorizon else { return false }
        return unused >= weekMinimumUnused
    }

    static func sentence(label: String, percent: Double, remaining: TimeInterval) -> String {
        let unused = Int((100 - min(max(percent, 0), 100)).rounded())
        return "\(label) still has \(unused)% left, and it resets in \(time(remaining))."
    }

    /// `1h 40m`, `2h`, `50m`. Hours alone would hide most of the second hour.
    static func time(_ interval: TimeInterval) -> String {
        let t = max(0, Int(interval.rounded(.down)))
        let hours = t / 3600
        let mins = (t % 3600) / 60
        if hours > 0 && mins >= 10 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        if mins > 0 { return "\(mins)m" }
        return "\(t)s"
    }
}
