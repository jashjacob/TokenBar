import Foundation

/// What the last 7 days say about a tool that has both a 5h chip and a week.
enum UsageInsight {
    struct Note: Equatable {
        var tool: String
        var text: String
    }

    static func notes(chips: [Chip], samples: [String: UsageLog.Series], now: Date = Date()) -> [Note] {
        let grouped = Dictionary(grouping: chips, by: \.shortName)
        var lines: [Note] = []
        for tool in grouped.keys.sorted() {
            let members = grouped[tool] ?? []
            guard let session = members.first(where: { $0.windowTag == "5h" }),
                  let week = members.first(where: { $0.windowTag == "7d" || $0.windowTag == "wk" })
            else { continue }
            let text = sentence(
                session: session,
                week: week,
                windows: decided(UsageLog.runs(samples[session.id]?.points ?? []), now: now),
                now: now
            )
            if let text {
                lines.append(Note(tool: tool, text: text))
            }
        }
        return lines
    }

    /// A window counts once it has ended, or once it has already reached 80%.
    static func decided(_ runs: [[UsageLog.Sample]], now: Date) -> [[UsageLog.Sample]] {
        let t = now.timeIntervalSince1970
        return runs.filter { run in
            guard run.count >= 2 else { return false }
            let peak = run.map(\.p).max() ?? 0
            if peak >= 80 { return true }
            guard let reset = run.last?.r else { return false }
            return reset < t - 60
        }
    }

    static func filledEarly(_ run: [UsageLog.Sample]) -> Bool {
        run.contains { sample in
            guard sample.p >= 80, let reset = sample.r else { return false }
            return reset - sample.t > 3600
        }
    }

    private static func sentence(
        session: Chip,
        week: Chip,
        windows: [[UsageLog.Sample]],
        now: Date
    ) -> String? {
        let early = windows.filter(filledEarly).count
        let seen = windows.count
        let weekLine = weekSentence(week, now: now)
        guard seen >= 3 else { return nil }
        if early * 2 >= seen {
            var text = "\(session.label) reached 80% with time still left in \(early) of \(seen) windows. \(weekLine)"
            if weekIsHot(week, now: now) {
                text += " Worth a look at a higher plan if this is a normal week."
            }
            return text
        }
        if weekIsHot(week, now: now) {
            return "\(week.label) is the one climbing. \(weekLine) The 5h windows still have room when they end."
        }
        return nil
    }

    private static func weekSentence(_ chip: Chip, now: Date) -> String {
        let used = Int(chip.percent.rounded())
        guard let reset = chip.resetAt else {
            return "\(chip.label) is at \(used)%."
        }
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0 else {
            return "\(chip.label) is at \(used)%."
        }
        var line = "\(chip.label) is at \(used)% with \(LeftoverBanner.time(remaining)) left"
        if let ahead = aheadOfEven(chip, now: now) {
            if ahead >= 15 {
                line += ", ahead of an even week"
            }
        }
        return line + "."
    }

    private static func weekIsHot(_ chip: Chip, now: Date) -> Bool {
        if let ahead = aheadOfEven(chip, now: now), ahead >= 15 { return true }
        guard let reset = chip.resetAt else { return chip.percent >= 80 }
        let remaining = reset.timeIntervalSince(now)
        if chip.percent >= 60, remaining > 2 * 86_400 { return true }
        if chip.percent >= 80, remaining > 12 * 3600 { return true }
        return false
    }

    /// Percentage points above a steady burn. Nil when the window length is unknown.
    private static func aheadOfEven(_ chip: Chip, now: Date) -> Double? {
        guard let window = chip.windowSeconds, window > 0, let reset = chip.resetAt else { return nil }
        let remaining = reset.timeIntervalSince(now)
        let elapsed = window - remaining
        guard elapsed > 0, elapsed < window * 1.05 else { return nil }
        let expected = elapsed / window * 100
        return chip.percent - expected
    }
}
