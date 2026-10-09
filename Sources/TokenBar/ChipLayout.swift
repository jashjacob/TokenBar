import AppKit

/// Per-chip widths from the text they actually draw. Short names stay
/// narrow; leftover strip space is a small tag→time gap, and goes away
/// once several chips are on so a longer name (OpenCode) can keep its letters.
enum ChipLayout {
    static let spacing: CGFloat = 6

    static func isSession(_ chip: Chip) -> Bool {
        chip.windowTag == "5h"
    }

    /// Left to right among the chips already checked on:
    /// in use, then a full card counting down or a card that just came back,
    /// then cards that still have some usage, then other full cards, then 0%.
    static func ordered(
        _ chips: [Chip],
        now: Date = Date(),
        activeAt: [String: Date] = [:],
        returnedAt: [String: Date] = [:]
    ) -> [Chip] {
        chips.enumerated().sorted { lhs, rhs in
            rank(lhs.element, index: lhs.offset, now: now, activeAt: activeAt, returnedAt: returnedAt)
                < rank(rhs.element, index: rhs.offset, now: now, activeAt: activeAt, returnedAt: returnedAt)
        }.map(\.element)
    }

    static func describe(
        _ chips: [Chip],
        now: Date = Date(),
        activeAt: [String: Date] = [:],
        returnedAt: [String: Date] = [:]
    ) -> String {
        ordered(chips, now: now, activeAt: activeAt, returnedAt: returnedAt).map { chip in
            let name = placement(of: chip, now: now, activeAt: activeAt, returnedAt: returnedAt).label
            return "\(chip.label) (\(name))"
        }.joined(separator: " | ")
    }

    private struct Rank: Comparable {
        var band: Int
        var a: Double
        var b: Double
        var c: Double
        var index: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            if lhs.band != rhs.band { return lhs.band < rhs.band }
            if lhs.a != rhs.a { return lhs.a < rhs.a }
            if lhs.b != rhs.b { return lhs.b < rhs.b }
            if lhs.c != rhs.c { return lhs.c < rhs.c }
            return lhs.index < rhs.index
        }
    }

    private enum Placement {
        case active
        case reminder
        case working
        case full
        case empty

        var label: String {
            switch self {
            case .active: return "in use"
            case .reminder: return "reminder"
            case .working: return "usage"
            case .full: return "full"
            case .empty: return "empty"
            }
        }

        var band: Int {
            switch self {
            case .active: return 0
            case .reminder: return 1
            case .working: return 2
            case .full: return 3
            case .empty: return 4
            }
        }
    }

    private static func placement(
        of chip: Chip,
        now: Date,
        activeAt: [String: Date],
        returnedAt: [String: Date]
    ) -> Placement {
        let full = chip.showsStackedFull
        let empty = Int(chip.percent.rounded()) == 0
        if fresh(activeAt[chip.id], now: now) { return .active }
        // A full card stays on the left until that window resets. A reset comes
        // forward only when the window was actually spent. An empty one was
        // already free, so its new window is not a reminder.
        if full, chip.remaining != nil { return .reminder }
        if fresh(returnedAt[chip.id], now: now) { return .reminder }
        if empty { return .empty }
        if full { return .full }
        return .working
    }

    private static func fresh(_ stamp: Date?, now: Date) -> Bool {
        guard let stamp else { return false }
        let age = now.timeIntervalSince(stamp)
        return age >= 0 && age < ChipActivity.hold
    }

    private static func rank(
        _ chip: Chip,
        index: Int,
        now: Date,
        activeAt: [String: Date],
        returnedAt: [String: Date]
    ) -> Rank {
        let remaining = chip.remaining ?? .greatestFiniteMagnitude
        let place = placement(of: chip, now: now, activeAt: activeAt, returnedAt: returnedAt)
        switch place {
        case .active:
            let when = activeAt[chip.id]?.timeIntervalSince1970 ?? 0
            return Rank(band: place.band, a: -when, b: remaining, c: -chip.percent, index: index)
        case .reminder:
            let when = returnedAt[chip.id]?.timeIntervalSince1970 ?? 0
            return Rank(band: place.band, a: remaining, b: -when, c: -chip.percent, index: index)
        case .working:
            let session = isSession(chip) ? 0.0 : 1.0
            return Rank(band: place.band, a: session, b: -chip.percent, c: remaining, index: index)
        case .full:
            return Rank(band: place.band, a: remaining, b: 0, c: 0, index: index)
        case .empty:
            return Rank(band: place.band, a: remaining, b: 0, c: 0, index: index)
        }
    }

    static func todayWidth(metric: TodayMetric, usage: TodayUsage) -> CGFloat {
        let caption = metric.caption as NSString
        let value = (metric == .tokens ? usage.tokenText : usage.costText) as NSString
        let capW = caption.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
        ]).width
        let valW = value.size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
        ]).width
        return ceil(max(capW, valW) + 12)
    }

    static func contentWidth(for chip: Chip, compact: Bool = false) -> CGFloat {
        contentWidth(for: chip, abbrevNames: compact, compactTime: compact)
    }

    static func contentWidth(for chip: Chip, abbrevNames: Bool, compactTime: Bool) -> CGFloat {
        let name = (abbrevNames ? chip.compactName : nil) ?? chip.shortName
        let nameW = (name as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        ]).width
        let time = compactTime ? chip.compactCountdownText : chip.countdownText
        let timeW = (time as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        ]).width
        if chip.showsStackedFull {
            var top = nameW
            if let tag = chip.windowTag {
                let tagW = (tag as NSString).size(withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                ]).width + 6
                top += 3 + tagW
            }
            let bottom = chip.remaining == nil ? 0 : timeW
            return ceil(10 + max(top, bottom))
        }
        var inner = nameW
        if let tag = chip.windowTag {
            let tagW = (tag as NSString).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            ]).width + 6
            inner += 3 + tagW
        }
        return ceil(10 + inner + 6 + timeW)
    }

    /// Hug each chip's text. OpenCode stays whole unless GrokBot is on a crowded
    /// strip, where it becomes OC so that card can fit. Countdowns shorten only
    /// after that. Claude, Codex, and Grok keep their full names.
    static func sized(_ chips: [Chip], budget: CGFloat) -> [String: CGFloat] {
        guard !chips.isEmpty else { return [:] }
        let maxExtra: CGFloat
        switch chips.count {
        case ...2: maxExtra = 20
        case 3, 4: maxExtra = 6
        default: maxExtra = 0
        }
        let grokBotOn = chips.contains { $0.shortName == "GrokBot" }
        let full = pack(chips, budget: budget, abbrevNames: false, compactTime: false, maxExtra: maxExtra)
        let shortNames = grokBotOn
            ? pack(chips, budget: budget, abbrevNames: true, compactTime: false, maxExtra: 0)
            : nil
        if let full {
            let spare = budget - full.values.reduce(0, +)
            if grokBotOn, spare < 40, let shortNames { return shortNames }
            return full
        }
        if let shortNames { return shortNames }
        if let fitted = pack(chips, budget: budget, abbrevNames: grokBotOn, compactTime: true, maxExtra: 0) {
            return fitted
        }
        var out: [String: CGFloat] = [:]
        for chip in chips {
            out[chip.id] = contentWidth(for: chip, abbrevNames: grokBotOn, compactTime: true)
        }
        return out
    }

    private static func pack(
        _ chips: [Chip],
        budget: CGFloat,
        abbrevNames: Bool,
        compactTime: Bool,
        maxExtra: CGFloat
    ) -> [String: CGFloat]? {
        let tights = chips.map { contentWidth(for: $0, abbrevNames: abbrevNames, compactTime: compactTime) }
        let total = tights.reduce(0, +)
        guard total <= budget else { return nil }
        let extra = min(maxExtra, (budget - total) / CGFloat(chips.count))
        var out: [String: CGFloat] = [:]
        for (chip, tight) in zip(chips, tights) {
            out[chip.id] = (tight + extra).rounded()
        }
        return out
    }
}
