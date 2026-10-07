import Foundation

enum ChipSource: Equatable {
    case tokenTracker
    case fallback
}

enum ChipSources {
    static func names(_ chips: [Chip]) -> [String] {
        var seen: [String] = []
        for chip in chips {
            let name = providerName(chip.id)
            if !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    static func providerName(_ id: String) -> String {
        switch id.split(separator: ".").first.map(String.init) {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "grok": return "Grok"
        case "opencodeGo": return "OpenCode"
        case "commandCode": return "Command Code"
        case "kimi": return "Kimi"
        case "antigravity": return "Antigravity"
        case "gemini": return "Gemini"
        default: return id
        }
    }
}

struct Chip: Equatable, Identifiable {
    let id: String
    let label: String
    let percent: Double
    let resetAt: Date?
    let windowSeconds: Double?
    var source: ChipSource = .tokenTracker
    /// When the fallback answer was fetched. TokenTracker chips leave this empty.
    var fetchedAt: Date? = nil

    var remaining: TimeInterval? {
        resetAt.map { $0.timeIntervalSinceNow }
    }

    /// Even-burn position (0...1): how much of the window may be used by now.
    var paceFraction: Double? {
        guard let windowSeconds, windowSeconds > 0, let remaining else { return nil }
        let elapsed = (windowSeconds - remaining) / windowSeconds
        guard elapsed.isFinite else { return nil }
        return min(max(elapsed, 0), 1)
    }

    /// Seconds until this window would hit 100% at the recent rate.
    /// Set only when usage is at least 20% and more than 3 points ahead of an even burn.
    var paceRunout: TimeInterval? {
        guard let windowSeconds, windowSeconds > 0, let remaining, remaining > 0 else { return nil }
        let used = min(max(percent, 0), 100) / 100
        guard used >= 0.20 else { return nil }
        let elapsed = (windowSeconds - remaining) / windowSeconds
        guard elapsed > 0.02, elapsed.isFinite, used > elapsed + 0.03 else { return nil }
        let rate = used / (windowSeconds * elapsed)
        guard rate > 0 else { return nil }
        let eta = (1 - used) / rate
        guard eta.isFinite, eta > 0 else { return nil }
        return eta
    }

    /// Short estimate for the pace flash, such as `44m`.
    var paceRunoutText: String? {
        paceRunout.map(Countdown.eta)
    }

    /// "5h", "7d", "wk", "mo" when the label ends with a window tag.
    var windowTag: String? {
        for tag in ["5h", "7d", "wk", "mo"] where label.hasSuffix(tag) {
            return tag
        }
        return nil
    }

    var shortName: String {
        guard let windowTag, label.hasSuffix(" \(windowTag)") else { return label }
        return String(label.dropLast(windowTag.count + 1))
    }

    /// Used when the chip is too narrow for `shortName` (`CmdCode` → `CmdC`).
    var compactName: String? {
        switch shortName {
        case "CmdCode", "Command Code": return "CmdC"
        case "OpenCode": return "OpenC"
        default: return nil
        }
    }

    var countdownText: String {
        if let remaining { return Countdown.format(remaining) }
        return "\(Int(percent.rounded()))%"
    }

    /// Single unit (`5h`, `3d`) when the chip is too narrow for `4h59m`.
    var compactCountdownText: String {
        if let remaining { return Countdown.compact(remaining) }
        return "\(Int(percent.rounded()))%"
    }

    var touchTitle: String {
        "\(label) \(countdownText)"
    }

    /// Menu row. The percent stays. The countdown lives on the Touch Bar.
    var menuTitle: String {
        String(format: "%@  %.0f%%", label, percent)
    }

    /// Tooltip keeps the countdown, which the menu row no longer shows.
    var tooltipTitle: String {
        guard remaining != nil else { return menuTitle }
        return "\(menuTitle)  \(countdownText)"
    }

    /// Menu-row hover. Fallback chips add how long ago that answer was fetched.
    var rowTip: String {
        guard source == .fallback, let fetchedAt else { return tooltipTitle }
        let age = Countdown.format(max(0, Date().timeIntervalSince(fetchedAt)))
        return "\(tooltipTitle) · Fallback · \(age)"
    }

    /// Sources pill under Fallback. The heading already says where it came from.
    var fallbackPill: String {
        guard let fetchedAt else { return label }
        let age = Countdown.format(max(0, Date().timeIntervalSince(fetchedAt)))
        return "\(label) · \(age)"
    }
}

enum Countdown {
    static func format(_ interval: TimeInterval) -> String {
        if interval.isNaN { return "—" }
        if interval <= 0 { return "now" }
        let t = Int(interval.rounded(.down))
        if t < 60 { return "\(t)s" }
        if t < 120 { return String(format: "1m%02ds", t % 60) }
        if t < 3600 { return "\(t / 60)m" }
        if t < 86_400 {
            let h = t / 3600
            let m = (t % 3600) / 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        let d = t / 86_400
        let h = (t % 86_400) / 3600
        return h > 0 ? "\(d)d\(h)h" : "\(d)d"
    }

    static func compact(_ interval: TimeInterval) -> String {
        if interval.isNaN { return "—" }
        if interval <= 0 { return "now" }
        let t = Int(interval.rounded(.down))
        if t < 120 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m" }
        if t < 86_400 { return "\(t / 3600)h" }
        return "\(t / 86_400)d"
    }

    /// One unit, matching a pace banner: `44m`, `2h`, `1d`.
    static func eta(_ interval: TimeInterval) -> String {
        if interval.isNaN || interval <= 0 { return "now" }
        let t = Int(interval.rounded(.down))
        if t < 60 { return "\(t)s" }
        let hours = t / 3600
        if hours > 24 { return "\(hours / 24)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(t / 60)m"
    }
}

enum ChipColor {
    static func band(_ percent: Double) -> String {
        if percent >= 85 { return "red" }
        if percent >= 60 { return "amber" }
        return "green"
    }
}
