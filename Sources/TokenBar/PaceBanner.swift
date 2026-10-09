import Foundation

/// Which pace sentence may cover the strip, and when a later one is allowed.
///
/// One sentence at a time. A milder chip does not follow a tighter one.
/// The same window speaks again only when its estimate crosses into a shorter
/// band, and the strip stays quiet for a stretch between sentences.
enum PaceBanner {
    /// Quiet stretch after a sentence, so a second chip cannot chase the first.
    static let gap: TimeInterval = 15 * 60
    /// Floor when the same window crosses under an hour. Short enough that
    /// "almost out" is not stuck behind the mild warning it just replaced.
    static let urgentGap: TimeInterval = 60
    /// Codex 5h slides its reset by a minute or two. That is the same window.
    static let sameWindow: TimeInterval = 120

    /// Matches the estimate the sentence will actually say.
    enum Band: Int {
        case days = 0
        case hours = 1
        case fast = 2
        case close = 3

        init(eta: TimeInterval) {
            if eta >= 25 * 3600 { self = .days }
            else if eta >= 3600 { self = .hours }
            else if eta >= 15 * 60 { self = .fast }
            else { self = .close }
        }
    }

    struct Choice {
        var id: String
        var resetAt: Date
        var eta: TimeInterval
        var band: Band

        init(id: String, resetAt: Date, eta: TimeInterval) {
            self.id = id
            self.resetAt = resetAt
            self.eta = eta
            self.band = Band(eta: eta)
        }
    }

    struct Record {
        var resetAt: Date
        var firstAt: Date
        var lastAt: Date
        var band: Band
    }

    struct History {
        var lastAt: Date?
        var chips: [String: Record] = [:]

        /// The single tightest chip that is allowed to speak right now.
        /// Nil when the leader was already announced at this severity, or the
        /// quiet stretch has not finished. A milder chip does not fill that gap.
        func next(_ choices: [Choice], now: Date) -> Choice? {
            let ranked = choices.sorted { a, b in
                if a.band != b.band { return a.band.rawValue > b.band.rawValue }
                if a.eta != b.eta { return a.eta < b.eta }
                return a.id < b.id
            }
            guard let best = ranked.first else { return nil }
            let prior = chips[best.id]
            if let prior, PaceBanner.same(prior.resetAt, best.resetAt), prior.band.rawValue >= best.band.rawValue {
                return nil
            }
            if let lastAt {
                let wait = PaceBanner.wait(best, prior: prior)
                if now.timeIntervalSince(lastAt) < wait { return nil }
            }
            return best
        }

        mutating func remember(_ choice: Choice, now: Date) {
            if var existing = chips[choice.id], PaceBanner.same(existing.resetAt, choice.resetAt) {
                existing.resetAt = choice.resetAt
                existing.lastAt = now
                existing.band = choice.band
                chips[choice.id] = existing
            } else {
                chips[choice.id] = Record(
                    resetAt: choice.resetAt,
                    firstAt: now,
                    lastAt: now,
                    band: choice.band
                )
            }
            lastAt = now
            chips = chips.filter { $0.value.resetAt.timeIntervalSince(now) > -86_400 }
        }
    }

    static func sentence(label: String, percent: Double, eta: TimeInterval) -> String {
        let shown = Countdown.eta(eta)
        let used = Int(percent.rounded())
        switch Band(eta: eta) {
        case .days, .hours:
            return "\(label) may run out early. At the current pace, usage may run out in \(shown) (\(used)% used)."
        case .fast:
            return "\(label) is burning fast. At this pace it runs out in \(shown) (\(used)% used)."
        case .close:
            return "\(label) is almost out. At this pace it runs out in \(shown) (\(used)% used)."
        }
    }

    static func same(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < sameWindow
    }

    /// Escalating under an hour can speak after a minute. Anything else waits out the full gap.
    static func wait(_ choice: Choice, prior: Record?) -> TimeInterval {
        if let prior, same(prior.resetAt, choice.resetAt), choice.band.rawValue > prior.band.rawValue, choice.band.rawValue >= Band.fast.rawValue {
            return urgentGap
        }
        return gap
    }
}
