import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let touchBar = TouchBarController()
    private var statusItem: StatusItemController?
    private var chips: [Chip] = []
    private var today: TodayUsage?
    private var offline = true
    private var lastError: String?
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    private var queuedBypass = false
    /// Last GrokBot reading TokenTracker actually sent. A null window keeps it for a few minutes.
    private var grokBotChip: Chip?
    private var grokBotSeen: Date?
    private var grokBotHolding = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ChipPreferences.migrateTodaySplit()
        Log.line("TokenBar \(AppInfo.version) (\(AppInfo.build)) starting, TokenTracker port \(LimitsClient.discoverPort())")
        statusItem = StatusItemController(touchBar: touchBar, onRefresh: { [weak self] bypass in
            self?.refreshNow(bypassFallbackCache: bypass)
        }, onVisibilityChange: { [weak self] in
            self?.push()
        })
        touchBar.onCollapsed = { [weak self] in
            self?.statusItem?.reloadMenu()
        }
        touchBar.start()
        refreshNow()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow(bypassFallbackCache: false) }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        tickTimer?.invalidate()
        touchBar.stop()
        Log.line("TokenBar stopping")
    }

    /// One fetch is applied at a time. A Refresh asked for while one is running
    /// waits, and still skips the fallback cache.
    private func refreshNow(bypassFallbackCache: Bool = false) {
        if bypassFallbackCache { queuedBypass = true }
        if refreshTask != nil {
            refreshQueued = true
            return
        }
        refreshTask = Task { @MainActor in
            while true {
                let bypass = queuedBypass
                queuedBypass = false
                refreshQueued = false
                await runRefresh(bypassFallbackCache: bypass)
                if !refreshQueued { break }
            }
            refreshTask = nil
        }
    }

    private func runRefresh(bypassFallbackCache: Bool) async {
        async let chipsTask = LimitsClient.fetch(bypassFallbackCache: bypassFallbackCache)
        async let todayTask = LimitsClient.fetchToday()
        do {
            let next = mergingGrokBot(try await chipsTask)
            chips = next
            offline = false
            lastError = nil
            Log.line("fetched \(next.count) chips: \(next.map(\.touchTitle).joined(separator: " | "))")
        } catch {
            offline = true
            lastError = error.localizedDescription
            Log.line("fetch failed: \(error.localizedDescription)")
        }
        do {
            let usage = try await todayTask
            today = usage
            Log.line("today \(usage.tokenText) \(usage.costText)")
        } catch {
            Log.line("today fetch failed: \(error.localizedDescription)")
        }
        push()
    }

    private static let grokBotID = "cursor.quaternary_window"
    private static let grokBotHold: TimeInterval = 5 * 60

    private func mergingGrokBot(_ next: [Chip]) -> [Chip] {
        if let fresh = next.first(where: { $0.id == Self.grokBotID }) {
            grokBotChip = fresh
            grokBotSeen = Date()
            if grokBotHolding {
                grokBotHolding = false
                Log.line("GrokBot is back in the feed")
            }
            return next
        }
        guard let chip = grokBotChip,
              let seen = grokBotSeen,
              Date().timeIntervalSince(seen) < Self.grokBotHold
        else {
            if grokBotHolding {
                grokBotHolding = false
                grokBotChip = nil
                grokBotSeen = nil
                Log.line("dropped held GrokBot")
            }
            return next
        }
        if !grokBotHolding {
            grokBotHolding = true
            Log.line("kept GrokBot, feed omitted it")
        }
        return next + [chip]
    }

    private func tick() {
        touchBar.tick()
    }

    private func push() {
        touchBar.update(chips: chips, today: today, offline: offline)
        statusItem?.update(chips: chips, today: today, offline: offline, error: lastError)
    }
}
