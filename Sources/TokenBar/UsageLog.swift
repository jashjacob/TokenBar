import Foundation

/// Seven days of percent readings, so each chip can be drawn later.
/// A point is kept when the percent moves, the window really resets, or 20 minutes pass.
enum UsageLog {
    struct Sample: Codable, Equatable {
        var t: TimeInterval
        var p: Double
        var r: TimeInterval?
    }

    struct Series: Codable, Equatable {
        var label: String
        var points: [Sample]
    }

    static let horizon: TimeInterval = 7 * 24 * 3600
    private static let heartbeat: TimeInterval = 20 * 60
    private static let move: Double = 1
    /// A rolling 5h stamp can creep for minutes. A real reset lands hours later.
    private static let resetGap: TimeInterval = 3 * 3600
    private static let cap = 2_500

    private static var loaded = false
    private static var chips: [String: Series] = [:]
    private static var dirty = false
    private static var saveScheduled = false

    static func note(_ list: [Chip], now: Date = Date()) {
        load()
        let t = now.timeIntervalSince1970
        var changed = false
        for chip in list {
            let reset = chip.resetAt?.timeIntervalSince1970
            var series = chips[chip.id] ?? Series(label: chip.label, points: [])
            if series.label != chip.label {
                series.label = chip.label
                changed = true
            }
            let previous = series.points.last
            if shouldKeep(previous: previous, percent: chip.percent, reset: reset, now: t) {
                series.points.append(Sample(t: t, p: chip.percent, r: reset))
                series.points = prune(series.points, now: t)
                changed = true
            }
            chips[chip.id] = series
        }
        guard changed else { return }
        dirty = true
        scheduleSave()
    }

    static func prepare() {
        load()
    }

    static func stored() -> [String: Series] {
        load()
        return chips
    }

    static func shouldKeep(previous: Sample?, percent: Double, reset: TimeInterval?, now: TimeInterval) -> Bool {
        guard let previous else { return true }
        if now - previous.t >= heartbeat { return true }
        if abs(percent - previous.p) >= move { return true }
        if !sameReset(previous.r, reset) { return true }
        return false
    }

    /// Same countdown, including a 5h stamp that slides. A jump of hours is a new window.
    static func sameReset(_ older: TimeInterval?, _ newer: TimeInterval?) -> Bool {
        switch (older, newer) {
        case (nil, nil):
            return true
        case let (a?, b?):
            let delta = b - a
            if delta < -3600 { return false }
            if delta > resetGap { return false }
            return true
        default:
            return false
        }
    }

    static func prune(_ samples: [Sample], now: TimeInterval) -> [Sample] {
        var kept = samples.filter { now - $0.t <= horizon }
        if kept.count > cap {
            kept.removeFirst(kept.count - cap)
        }
        return kept
    }

    /// Runs of one window, in time order. A reset starts a new run.
    static func runs(_ samples: [Sample]) -> [[Sample]] {
        var groups: [[Sample]] = []
        for sample in samples.sorted(by: { $0.t < $1.t }) {
            if var last = groups.last, let end = last.last, sameReset(end.r, sample.r) {
                last.append(sample)
                groups[groups.count - 1] = last
            } else {
                groups.append([sample])
            }
        }
        return groups
    }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let disk = try? JSONDecoder().decode([String: Series].self, from: data)
        else { return }
        let now = Date().timeIntervalSince1970
        var next: [String: Series] = [:]
        for (id, series) in disk {
            let points = prune(series.points, now: now)
            guard !points.isEmpty else { continue }
            next[id] = Series(label: series.label, points: points)
        }
        chips = next
    }

    private static func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            saveScheduled = false
            save()
        }
    }

    private static func save() {
        guard dirty else { return }
        dirty = false
        let now = Date().timeIntervalSince1970
        var next: [String: Series] = [:]
        for (id, series) in chips {
            let points = prune(series.points, now: now)
            guard !points.isEmpty else { continue }
            next[id] = Series(label: series.label, points: points)
        }
        chips = next
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(chips)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.line("usage log save failed: \(error.localizedDescription)")
            dirty = true
        }
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("usage-7d.json")
    }
}
