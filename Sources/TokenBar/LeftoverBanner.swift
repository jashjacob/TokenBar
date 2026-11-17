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
    /// Recent pace, not the whole week. Two hours shows whether this sitting will finish it.
    static let grokBotLookback: TimeInterval = 2 * 3600
    /// The usage log keeps a point about every 20 minutes. A shorter gap is not a pace.
    static let grokBotMinSpan: TimeInterval = 20 * 60
    /// One more line in the last two hours, after an earlier warning for this same reset.
    static let grokBotCloseHorizon: TimeInterval = 2 * 3600
    /// A week or a month. The last day is the warning.
    static let weekHorizon: TimeInterval = 24 * 3600
    static let weekMinimumUnused: Double = 20
    /// A week that still reads as 3 days. More than half left is worth saying then.
    static let weekEarlyHorizon: TimeInterval = 4 * 24 * 3600
    static let weekEarlyMinimumUnused: Double = 50
    /// More than half left, and only a few hours to use it. Say so again.
    static let closeHorizon: TimeInterval = 6 * 3600
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

    /// More than half is still unused and only a few hours remain.
    /// GrokBot can speak again in its last two hours when the recent pace still leaves some.
    static func isClose(_ choice: Choice, now: Date = Date()) -> Bool {
        if choice.remaining <= closeHorizon && choice.unused > weekEarlyMinimumUnused {
            return true
        }
        guard choice.id == grokBotID, choice.remaining <= grokBotCloseHorizon else { return false }
        return grokBotLeavesSome(
            percent: 100 - choice.unused,
            remaining: choice.remaining,
            resetAt: choice.resetAt,
            now: now
        )
    }

    struct History {
        var lastAt: Date?
        var spoken: [String: Date] = [:]
        /// The close line for a reset, so the earlier warning does not use up the last few hours.
        var closeSpoken: [String: Date] = [:]

        /// The soonest chip that has not already been said for this reset.
        /// A chip already said does not hide the next one. A close call can speak again.
        /// Nil during the quiet stretch.
        func next(_ choices: [Choice], now: Date, otherQuiet: Date?) -> Choice? {
            let ranked = choices.sorted { lhs, rhs in
                if lhs.remaining != rhs.remaining { return lhs.remaining < rhs.remaining }
                return lhs.id < rhs.id
            }
            let best = ranked.first { choice in
                let said = LeftoverBanner.isClose(choice) ? closeSpoken[choice.id] : spoken[choice.id]
                guard let said else { return true }
                return abs(said.timeIntervalSince(choice.resetAt)) >= sameWindow
            }
            guard let best else { return nil }
            if let otherQuiet, now.timeIntervalSince(otherQuiet) < PaceBanner.gap { return nil }
            if let lastAt, now.timeIntervalSince(lastAt) < PaceBanner.gap { return nil }
            return best
        }

        mutating func remember(_ choice: Choice, now: Date) {
            if LeftoverBanner.isClose(choice) {
                closeSpoken[choice.id] = choice.resetAt
            }
            spoken[choice.id] = choice.resetAt
            lastAt = now
            spoken = spoken.filter { $0.value.timeIntervalSince(now) > -86_400 }
            closeSpoken = closeSpoken.filter { $0.value.timeIntervalSince(now) > -86_400 }
        }
    }

    /// Five-hour chips come back the same afternoon, so they never qualify.
    /// GrokBot also qualifies when the recent pace will not finish what is left.
    static func qualifies(
        id: String,
        windowTag: String?,
        percent: Double,
        remaining: TimeInterval,
        resetAt: Date? = nil,
        now: Date = Date()
    ) -> Bool {
        guard remaining > floor else { return false }
        let unused = 100 - min(max(percent, 0), 100)
        if id == grokID, remaining <= grokHorizon, percent > 0, unused >= grokMinimumUnused {
            return true
        }
        let week = windowTag == "7d" || windowTag == "wk" || id == grokBotID
        if week, remaining < weekEarlyHorizon, unused > weekEarlyMinimumUnused {
            return true
        }
        if (week || windowTag == "mo"), remaining <= weekHorizon, unused >= weekMinimumUnused {
            return true
        }
        guard id == grokBotID else { return false }
        return grokBotLeavesSome(percent: percent, remaining: remaining, resetAt: resetAt, now: now)
    }

    /// True when GrokBot still shows at least 1% unused and the recent pace lands short of 100%.
    /// No trustworthy pace in the final two hours still counts: the leftover is there.
    static func grokBotLeavesSome(
        percent: Double,
        remaining: TimeInterval,
        resetAt: Date?,
        samples: [UsageLog.Sample]? = nil,
        now: Date = Date()
    ) -> Bool {
        guard remaining > floor, let resetAt else { return false }
        let used = min(max(percent, 0), 100)
        guard Int((100 - used).rounded()) >= 1 else { return false }
        let points = samples ?? (UsageLog.stored()[grokBotID]?.points ?? [])
        let nowT = now.timeIntervalSince1970
        let resetT = resetAt.timeIntervalSince1970
        guard let run = UsageLog.runs(points).last,
              let end = run.last,
              UsageLog.sameReset(end.r, resetT)
        else {
            return remaining <= grokBotCloseHorizon
        }
        let recent = run.filter { sample in
            let age = nowT - sample.t
            return age >= 0 && age <= grokBotLookback
        }
        guard let oldest = recent.first else {
            return remaining <= grokBotCloseHorizon
        }
        let span = nowT - oldest.t
        guard span >= grokBotMinSpan else {
            return remaining <= grokBotCloseHorizon
        }
        let projected = used + ((used - oldest.p) / span) * remaining
        let landed = min(max(projected, 0), 100)
        return Int((100 - landed).rounded()) >= 1
    }

    static func sentence(id: String, label: String, windowTag: String?, percent: Double, remaining: TimeInterval) -> String {
        let unused = Int((100 - min(max(percent, 0), 100)).rounded())
        let clock = time(remaining)
        let rawUnused = 100 - min(max(percent, 0), 100)
        let week = windowTag == "7d" || windowTag == "wk" || id == grokBotID
        if week, remaining > weekHorizon, remaining < weekEarlyHorizon, rawUnused > weekEarlyMinimumUnused {
            return "\(label) has \(unused)% left, with \(clock) to use it."
        }
        return "\(label) has \(unused)% left. It resets in \(clock)."
    }

    /// `3d 17h`, `1h 40m`, `2h`, `50m`. Hours alone would hide most of the second hour.
    static func time(_ interval: TimeInterval) -> String {
        let t = max(0, Int(interval.rounded(.down)))
        let days = t / 86_400
        let dayHours = (t % 86_400) / 3600
        if days > 0 && dayHours > 0 { return "\(days)d \(dayHours)h" }
        if days > 0 { return "\(days)d" }
        let hours = t / 3600
        let mins = (t % 3600) / 60
        if hours > 0 && mins >= 10 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        if mins > 0 { return "\(mins)m" }
        return "\(t)s"
    }
}
