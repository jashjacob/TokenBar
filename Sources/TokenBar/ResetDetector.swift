import Foundation

struct ChipSnapshot {
    var percent: Double
    var resetAt: Date?
    var remaining: TimeInterval?
    var source: ChipSource
}

enum ResetDetector {
    /// Rolling 5h windows often slide `resetAt` by a minute or two per poll.
    /// A provider can also hand back a fresh 5h stamp after a gap without the
    /// quota refilling. The percent has to fall before either of those counts.
    static func didReset(old: ChipSnapshot, new: Chip) -> Bool {
        let newRemaining = new.remaining ?? 0
        let oldRemaining = old.remaining ?? 0
        let sameSource = old.source == new.source
        let fell = old.percent - new.percent >= 1

        // About to end, then a long runway. Across a source change the percent
        // has to fall too, so a different clock for the same window does not flash.
        if oldRemaining > 0, oldRemaining < 180, newRemaining > 1_800, sameSource || fell {
            return true
        }
        if old.percent - new.percent >= 20, newRemaining > oldRemaining + 300 {
            return true
        }
        // A smaller drop with the reset pushed out. Remaining has to grow by
        // more than 15 minutes, which a 1–2 minute slide never does.
        if fell,
           let oldReset = old.resetAt, let newReset = new.resetAt,
           newReset.timeIntervalSince(oldReset) > 90,
           newRemaining > oldRemaining + 15 * 60 {
            return true
        }
        return false
    }
}
