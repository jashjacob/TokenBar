import Foundation

struct ChipSnapshot {
    var percent: Double
    var resetAt: Date?
    var remaining: TimeInterval?
    var source: ChipSource
}

enum ResetDetector {
    /// How the allowance came back, so the sentence can say which.
    enum Kind {
        /// The countdown jumped forward. The window started over.
        case refilled
        /// The countdown stayed put and the meter fell. Allowance came back inside this window.
        case restored
    }

    /// Rolling 5h windows often slide `resetAt` by a minute or two per poll.
    /// A provider can also hand back a fresh 5h stamp after a gap without the
    /// quota refilling. The percent has to fall before either of those counts.
    static func didReset(old: ChipSnapshot, new: Chip) -> Bool {
        noticeKind(old: old, new: new) != nil
    }

    static func noticeKind(old: ChipSnapshot, new: Chip) -> Kind? {
        let newRemaining = new.remaining ?? 0
        let oldRemaining = old.remaining ?? 0
        let sameSource = old.source == new.source
        let fell = old.percent - new.percent >= 1
        var refilled = false

        // About to end, then a long runway. Across a source change the percent
        // has to fall too, so a different clock for the same window does not flash.
        if oldRemaining > 0, oldRemaining < 180, newRemaining > 1_800, sameSource || fell {
            refilled = true
        }
        if old.percent - new.percent >= 20, newRemaining > oldRemaining + 300 {
            refilled = true
        }
        // A smaller drop with the reset pushed out. Remaining has to grow by
        // more than 15 minutes, which a 1–2 minute slide never does.
        if fell,
           let oldReset = old.resetAt, let newReset = new.resetAt,
           newReset.timeIntervalSince(oldReset) > 90,
           newRemaining > oldRemaining + 15 * 60 {
            refilled = true
        }
        // Allowance came back inside the same countdown. A 1–2 minute stamp
        // slide does not match unless the meter fell by 20 points.
        if sameWindowRestore(old: old, new: new, newRemaining: newRemaining, oldRemaining: oldRemaining) {
            return refilled ? .refilled : .restored
        }
        return refilled ? .refilled : nil
    }

    static func sentence(label: String, oldPercent: Double, newPercent: Double, kind: Kind) -> String {
        let now = Int(newPercent.rounded())
        switch kind {
        case .restored:
            let was = Int(oldPercent.rounded())
            return "\(label) was \(was)%. Now it's \(now)%."
        case .refilled:
            return "\(label) reset. Now it's \(now)%."
        }
    }

    /// Same source, same reset stamp, meter down by 20 or more.
    /// A runway that jumps is a real reset even if the stamp barely moved.
    private static func sameWindowRestore(
        old: ChipSnapshot,
        new: Chip,
        newRemaining: TimeInterval,
        oldRemaining: TimeInterval
    ) -> Bool {
        guard old.source == new.source else { return false }
        guard old.percent - new.percent >= 20 else { return false }
        guard let oldReset = old.resetAt, let newReset = new.resetAt else { return false }
        guard abs(newReset.timeIntervalSince(oldReset)) <= 120 else { return false }
        if newRemaining > oldRemaining + 300 { return false }
        return true
    }
}
