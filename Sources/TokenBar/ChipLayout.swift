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
        contentWidth(for: chip, abbrevNames: compact, compactTime: compact)
    }

    static func contentWidth(for chip: Chip, abbrevNames: Bool, compactTime: Bool) -> CGFloat {
        let name = (abbrevNames ? chip.compactName : nil) ?? chip.shortName
        let nameW = (name as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        ]).width
        var inner = nameW
        if let tag = chip.windowTag {
            let tagW = (tag as NSString).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            ]).width + 6
            inner += 3 + tagW
        }
        let time = compactTime ? chip.compactCountdownText : chip.countdownText
        let timeW = (time as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        ]).width
        return ceil(10 + inner + 6 + timeW)
    }

    /// Hug each chip's text. CmdCode/OpenCode can shrink to CmdC/OpenC. Claude, Codex,
    /// Grok never go below their full name — extra cards clip off the right instead.
    static func sized(_ chips: [Chip], budget: CGFloat) -> [String: CGFloat] {
        guard !chips.isEmpty else { return [:] }
        let maxExtra: CGFloat
        switch chips.count {
        case ...2: maxExtra = 20
        case 3, 4: maxExtra = 6
        default: maxExtra = 0
        }
        if let fitted = pack(chips, budget: budget, abbrevNames: false, compactTime: false, maxExtra: maxExtra) {
            return fitted
        }
        if let fitted = pack(chips, budget: budget, abbrevNames: false, compactTime: true, maxExtra: 0) {
            return fitted
        }
        if let fitted = pack(chips, budget: budget, abbrevNames: true, compactTime: true, maxExtra: 0) {
            return fitted
        }
        var out: [String: CGFloat] = [:]
        for chip in chips {
            out[chip.id] = contentWidth(for: chip, abbrevNames: true, compactTime: true)
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
