import Foundation

/// Remembers which checked windows are actually being spent, and which ones
/// just came back from a full window. Times survive a relaunch. A source swap
/// between TokenTracker and a fallback is not usage and is not a reset.
@MainActor
enum ChipActivity {
    /// How long a chip stays "in use" after its percent last rose, and how long
    /// a chip that just reset stays up front before it can drift right.
    nonisolated static let hold: TimeInterval = 5 * 3600
    /// A rise smaller than this is noise, including a rolling window's creep.
    nonisolated static let rise = 0.5

    private static let key = "chipActivity.v2"
    private static var loaded = false
    private static var seen: [String: ChipSnapshot] = [:]
    private static var storedActive: [String: Date] = [:]
    private static var storedReturned: [String: Date] = [:]

    static var activeAt: [String: Date] {
        ensureLoaded()
        return storedActive
    }

    static var returnedAt: [String: Date] {
        ensureLoaded()
        return storedReturned
    }

    static func note(_ chips: [Chip], now: Date = Date()) {
        ensureLoaded()
        var changed = false
        for chip in chips {
            let snapshot = ChipSnapshot(
                percent: chip.percent,
                resetAt: chip.resetAt,
                remaining: chip.remaining,
                source: chip.source
            )
            defer { seen[chip.id] = snapshot }
            guard let old = seen[chip.id] else { continue }
            if old.source != chip.source { continue }
            if chip.percent - old.percent >= rise {
                storedActive[chip.id] = now
                changed = true
            }
            // A window that was already empty resetting is not news. The quota
            // was free, and it stays free. Only a window that was actually
            // spent, or one in use right now, comes forward.
            if ResetDetector.didReset(old: old, new: chip),
               Int(old.percent.rounded()) > 0 || fresh(storedActive[chip.id], now: now) {
                storedReturned[chip.id] = now
                changed = true
            }
        }
        let freshActive = prune(storedActive, now: now)
        let freshReturned = prune(storedReturned, now: now)
        if freshActive.count != storedActive.count || freshReturned.count != storedReturned.count {
            changed = true
        }
        storedActive = freshActive
        storedReturned = freshReturned
        if changed { save() }
    }

    private static func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        UserDefaults.standard.removeObject(forKey: "chipActivity.v1")
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] else { return }
        for (id, entry) in raw {
            if let stamp = entry["a"] { storedActive[id] = Date(timeIntervalSince1970: stamp) }
            if let stamp = entry["r"] { storedReturned[id] = Date(timeIntervalSince1970: stamp) }
        }
        storedActive = prune(storedActive, now: Date())
        storedReturned = prune(storedReturned, now: Date())
    }

    private static func fresh(_ stamp: Date?, now: Date) -> Bool {
        guard let stamp else { return false }
        let age = now.timeIntervalSince(stamp)
        return age >= 0 && age < hold
    }

    private static func prune(_ times: [String: Date], now: Date) -> [String: Date] {
        times.filter { stamp in
            let age = now.timeIntervalSince(stamp.value)
            return age >= 0 && age < hold
        }
    }

    private static func save() {
        var raw: [String: [String: Double]] = [:]
        for (id, stamp) in storedActive {
            raw[id, default: [:]]["a"] = stamp.timeIntervalSince1970
        }
        for (id, stamp) in storedReturned {
            raw[id, default: [:]]["r"] = stamp.timeIntervalSince1970
        }
        UserDefaults.standard.set(raw, forKey: key)
    }
}
