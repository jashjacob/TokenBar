import Foundation

struct ChipSnapshot {
    var percent: Double
    var resetAt: Date?
    var remaining: TimeInterval?
}

enum ResetDetector {
    /// Rolling 5h windows (Codex, etc.) often slide `resetAt` by 1–2 minutes
    /// per poll. That is not a quota reset.
    static func didReset(old: ChipSnapshot, new: Chip) -> Bool {
        let newRemaining = new.remaining ?? 0
        let oldRemaining = old.remaining ?? 0

        if oldRemaining > 0, oldRemaining < 180, newRemaining > 1_800 {
            return true
        }
        if old.percent - new.percent >= 20, newRemaining > oldRemaining + 300 {
            return true
        }
        if let oldReset = old.resetAt, let newReset = new.resetAt,
           newReset.timeIntervalSince(oldReset) > 90,
           newRemaining > oldRemaining + 15 * 60 {
            return true
        }
        return false
    }
}
