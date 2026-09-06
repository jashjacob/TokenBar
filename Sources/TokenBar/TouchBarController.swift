import AppKit

@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {
    private var stripItem: NSCustomTouchBarItem?
    private var bar: NSTouchBar?
    private var chips: [Chip] = []
    private var today: TodayUsage?
    private var stripBot: StripBotView?
    private var todayTokenView: TodayBarView?
    private var todayCostView: TodayBarView?
    private var chipViews: [NSTouchBarItem.Identifier: ChipBarView] = [:]
    private var installedStrip = false
    private var presented = false
    private var reassertWork: DispatchWorkItem?
    private var snapshots: [String: ChipSnapshot] = [:]
    private var lastCelebratedAt: [String: Date] = [:]
    var onCollapsed: (() -> Void)?

    var isPinned: Bool {
        get { UserDefaults.standard.object(forKey: "pinTouchBar") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "pinTouchBar")
            if newValue {
                presentExpanded()
            } else if let bar {
                PrivateTouchBar.minimize(bar)
                presented = false
            }
        }
    }

    var bounceStripBot: Bool {
        get { UserDefaults.standard.object(forKey: "bounceStripBot") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "bounceStripBot")
            stripBot?.bounceEnabled = newValue
        }
    }

    func start() {
        PrivateTouchBar.installCollapseHook()
        PrivateTouchBar.onExternalCollapse = { [weak self] in
            self?.noteCollapsedBySystem()
        }
        installStrip()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        if isPinned {
            presentExpanded()
        }
    }

    func stop() {
        reassertWork?.cancel()
        PrivateTouchBar.onExternalCollapse = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let bar {
            PrivateTouchBar.dismiss(bar)
        }
        if let stripItem {
            PrivateTouchBar.removeStripItem(stripItem)
        }
        presented = false
        installedStrip = false
    }

    func update(chips: [Chip], today: TodayUsage?, offline: Bool) {
        let ordered = chips.sorted { a, b in
            let a5 = a.windowTag == "5h"
            let b5 = b.windowTag == "5h"
            if a5 != b5 { return a5 }
            return (a.remaining ?? .greatestFiniteMagnitude) < (b.remaining ?? .greatestFiniteMagnitude)
        }
        let visible = ordered.filter { ChipPreferences.isVisible($0.id) }
        let next = offline ? [Chip(id: "offline", label: "TT off", percent: 100, resetAt: nil, windowSeconds: nil)] : visible
        let showTokens = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayTokensID)
        let showCost = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayCostID)
        let resetIDs = offline ? [] : detectResets(in: next)
        let idsChanged = next.map(\.id) != self.chips.map(\.id)
            || (self.today != nil) != (today != nil)
            || (self.todayTokenView != nil) != showTokens
            || (self.todayCostView != nil) != showCost
        self.chips = next
        self.today = today
        if idsChanged {
            rebuildBar()
            if isPinned || presented {
                presentExpanded()
            }
        } else {
            refreshTitles()
        }
        refreshStripTitle(offline: offline)
        if !resetIDs.isEmpty {
            if isPinned { presentExpanded() }
            DispatchQueue.main.async { [weak self] in
                self?.celebrate(resetIDs)
            }
        }
    }

    func tick() {
        refreshTitles()
        refreshStripTitle(offline: chips.first?.id == "offline")
    }

    private func installStrip() {
        guard !installedStrip else { return }
        let item = NSCustomTouchBarItem(identifier: PrivateTouchBar.stripIdentifier)
        let bot = StripBotView()
        bot.bounceEnabled = bounceStripBot
        bot.target = self
        bot.action = #selector(stripClicked)
        item.view = bot
        stripItem = item
        stripBot = bot
        PrivateTouchBar.addStripItem(item)
        installedStrip = true
        Log.line("control strip item installed")
    }

    private func rebuildBar() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("com.jashjacob.TokenBar.bar")
        var ids: [NSTouchBarItem.Identifier] = []
        if today != nil, ChipPreferences.isVisible(ChipPreferences.todayTokensID) {
            ids.append(TodayMetric.tokens.itemID)
        }
        if today != nil, ChipPreferences.isVisible(ChipPreferences.todayCostID) {
            ids.append(TodayMetric.cost.itemID)
        }
        for chip in chips {
            ids.append(chipItemID(chip.id))
        }
        bar.defaultItemIdentifiers = ids
        self.bar = bar
        chipViews.removeAll()
        todayTokenView = nil
        todayCostView = nil
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if let today, identifier == TodayMetric.tokens.itemID {
            return makeTodayItem(metric: .tokens, usage: today)
        }
        if let today, identifier == TodayMetric.cost.itemID {
            return makeTodayItem(metric: .cost, usage: today)
        }
        guard let chip = chips.first(where: { chipItemID($0.id) == identifier }) else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let view = ChipBarView(chip: chip)
        view.target = self
        view.action = #selector(chipClicked)
        item.view = view
        chipViews[identifier] = view
        return item
    }

    private func makeTodayItem(metric: TodayMetric, usage: TodayUsage) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: metric.itemID)
        let view = TodayBarView(usage: usage, metric: metric)
        view.target = self
        view.action = #selector(todayClicked)
        item.view = view
        switch metric {
        case .tokens: todayTokenView = view
        case .cost: todayCostView = view
        }
        return item
    }

    private func refreshTitles() {
        if let today {
            todayTokenView?.usage = today
            todayCostView?.usage = today
        }
        for chip in chips {
            let id = chipItemID(chip.id)
            chipViews[id]?.chip = chip
        }
    }

    private func refreshStripTitle(offline: Bool) {
        guard let bot = stripBot else { return }
        bot.offline = offline
        bot.percent = chips.max(by: { $0.percent < $1.percent })?.percent ?? 0
    }

    private func presentExpanded() {
        if bar == nil { rebuildBar() }
        guard let bar else { return }
        PrivateTouchBar.present(bar)
        presented = true
    }

    @objc private func stripClicked() {
        isPinned = true
        presentExpanded()
    }

    private func noteCollapsedBySystem() {
        reassertWork?.cancel()
        presented = false
        UserDefaults.standard.set(false, forKey: "pinTouchBar")
        Log.line("touch bar collapsed")
        onCollapsed?()
    }

    @objc private func chipClicked() {
        openTracker(LimitsClient.dashboardURL())
    }

    @objc private func todayClicked() {
        openTracker(LimitsClient.homeURL())
    }

    private func openTracker(_ url: URL) {
        Log.line("open \(url.absoluteString)")
        NSApp.activate(ignoringOtherApps: true)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error {
                Log.line("open failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard isPinned else { return }
        reassertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.presentExpanded()
        }
        reassertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func detectResets(in chips: [Chip]) -> [String] {
        var fired: [String] = []
        for chip in chips {
            let snapshot = ChipSnapshot(percent: chip.percent, resetAt: chip.resetAt, remaining: chip.remaining)
            defer { snapshots[chip.id] = snapshot }
            guard let old = snapshots[chip.id] else { continue }
            let last = lastCelebratedAt[chip.id] ?? .distantPast
            guard Date().timeIntervalSince(last) > 60 else { continue }
            if ResetDetector.didReset(old: old, new: chip) {
                lastCelebratedAt[chip.id] = Date()
                fired.append(chip.id)
            }
        }
        return fired
    }

    private func celebrate(_ ids: [String]) {
        for id in ids {
            chipViews[chipItemID(id)]?.playReset()
            Log.line("reset effect: \(id)")
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        stripBot?.playReset()
    }

    private func chipItemID(_ id: String) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("com.jashjacob.TokenBar.chip.\(id)")
    }
}
