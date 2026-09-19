import Foundation

struct Chip: Equatable, Identifiable {
    let id: String
    let label: String
    let percent: Double
    let resetAt: Date?
    let windowSeconds: Double?

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

    /// Used when the chip is too narrow for `shortName` (`Command Code` → `CC`).
    var compactName: String? {
        switch shortName {
        case "CmdCode", "Command Code": return "CC"
        case "OpenCode": return "OC"
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

    var menuTitle: String {
        let pct = String(format: "%.0f%%", percent)
        if remaining != nil {
            return "\(label)  \(pct)  \(countdownText)"
        }
        return "\(label)  \(pct)"
    }
}

enum Countdown {
    static func format(_ interval: TimeInterval) -> String {
        if interval.isNaN { return "—" }
        if interval <= 0 { return "now" }
        let t = Int(interval.rounded(.down))
        if t < 60 { return "\(t)s" }
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
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t / 60)m" }
        if t < 86_400 { return "\(t / 3600)h" }
        return "\(t / 86_400)d"
    }
}

enum ChipColor {
    static func band(_ percent: Double) -> String {
        if percent >= 85 { return "red" }
        if percent >= 60 { return "amber" }
        return "green"
    }
}
