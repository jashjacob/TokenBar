import AppKit

/// Per-chip widths from the text they actually draw. Short names stay
/// narrow; leftover strip space is a small tag→time gap, and goes away
/// once several chips are on so a longer name (OpenCode) can keep its letters.
enum ChipLayout {
    static let spacing: CGFloat = 6

    static func isSession(_ chip: Chip) -> Bool {
        chip.windowTag == "5h"
    }

    static func ordered(_ chips: [Chip]) -> [Chip] {
        chips.sorted { a, b in
            let a5 = isSession(a)
            let b5 = isSession(b)
            if a5 != b5 { return a5 }
            if a.percent != b.percent { return a.percent > b.percent }
            return (a.remaining ?? .greatestFiniteMagnitude) < (b.remaining ?? .greatestFiniteMagnitude)
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
        let nameW = (chip.shortName as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        ]).width
        var inner = nameW
        if let tag = chip.windowTag {
            let tagW = (tag as NSString).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            ]).width + 6
            inner += 3 + tagW
        }
        let time = compact ? chip.compactCountdownText : chip.countdownText
        let timeW = (time as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        ]).width
        return ceil(10 + inner + 6 + timeW)
    }

    /// Hug each chip's own text. `budget` is the width left for chips after Today.
    /// The overflow path always sums to <= budget so cards cannot paint past the strip.
    static func sized(_ chips: [Chip], budget: CGFloat) -> [String: CGFloat] {
        guard !chips.isEmpty else { return [:] }
        let maxExtra: CGFloat
        switch chips.count {
        case ...2: maxExtra = 20
        case 3, 4: maxExtra = 6
        default: maxExtra = 0
        }
        if let fitted = fit(chips, budget: budget, compact: false, maxExtra: maxExtra) { return fitted }
        if let fitted = fit(chips, budget: budget, compact: true, maxExtra: 0) { return fitted }
        return scaleToBudget(chips, budget: max(0, budget))
    }

    /// Proportional widths that always sum to at most `budget`. No per-chip floor.
    private static func scaleToBudget(_ chips: [Chip], budget: CGFloat) -> [String: CGFloat] {
        let weights = chips.map { max(1, contentWidth(for: $0, compact: true)) }
        let total = weights.reduce(0, +)
        guard total > 0, budget > 0 else {
            return Dictionary(uniqueKeysWithValues: chips.map { ($0.id, CGFloat(0)) })
        }
        var widths = weights.map { ($0 * budget / total).rounded(.down) }
        var remain = budget - widths.reduce(0, +)
        var i = 0
        while remain >= 1, i < widths.count {
            widths[i] += 1
            remain -= 1
            i += 1
        }
        var out: [String: CGFloat] = [:]
        for (chip, width) in zip(chips, widths) {
            out[chip.id] = width
        }
        return out
    }

    private static func fit(
        _ chips: [Chip],
        budget: CGFloat,
        compact: Bool,
        maxExtra: CGFloat
    ) -> [String: CGFloat]? {
        let tights = chips.map { contentWidth(for: $0, compact: compact) }
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
