import Foundation

struct ChipSnapshot {
    var percent: Double
    var resetAt: Date?
    var remaining: TimeInterval?
}

enum ResetDetector {
    static func didReset(old: ChipSnapshot, new: Chip) -> Bool {
        let newRemaining = new.remaining ?? 0
        let oldRemaining = old.remaining ?? 0

        if let oldReset = old.resetAt, let newReset = new.resetAt,
           newReset.timeIntervalSince(oldReset) > 90 {
            return true
        }
        if oldRemaining > 0, oldRemaining < 180, newRemaining > 1_800 {
            return true
        }
        if old.percent - new.percent >= 20, newRemaining > oldRemaining + 300 {
            return true
        }
        return false
    }
}
