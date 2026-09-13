import AppKit

@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {
    private var stripItem: NSCustomTouchBarItem?
    private var bar: NSTouchBar?
    private var chips: [Chip] = []
    private var today: TodayUsage?
    private var stripBot: StripBotView?
    private var stripView: TouchBarStripView?
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
        let visible = ChipLayout.ordered(chips).filter { ChipPreferences.isVisible($0.id) }
        let next = offline ? [Chip(id: "offline", label: "TT off", percent: 100, resetAt: nil, windowSeconds: nil)] : visible
        let showTokens = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayTokensID)
        let showCost = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayCostID)
        let resetIDs = offline ? [] : detectResets(in: next)
        self.chips = next
        self.today = today
        if bar == nil { rebuildBar() }
        if stripView == nil, isPinned || presented {
            presentExpanded()
        }
        stripView?.apply(chips: next, today: today, showTokens: showTokens, showCost: showCost)
        refreshStripTitle(offline: offline)
        if !resetIDs.isEmpty {
            if isPinned { presentExpanded() }
            DispatchQueue.main.async { [weak self] in
                self?.celebrate(resetIDs)
            }
        }
    }

    func tick() {
        stripView?.tick(chips: chips, today: today)
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

    private static let mainStripID = NSTouchBarItem.Identifier("com.jashjacob.TokenBar.mainStrip")

    private func rebuildBar() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("com.jashjacob.TokenBar.bar")
        bar.defaultItemIdentifiers = [Self.mainStripID]
        self.bar = bar
        stripView = nil
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.mainStripID else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let view = TouchBarStripView(frame: NSRect(x: 0, y: 0, width: 680, height: 30))
        view.onChipTap = { [weak self] in self?.chipClicked() }
        view.onTodayTap = { [weak self] in self?.todayClicked() }
        let showTokens = today != nil && ChipPreferences.isVisible(ChipPreferences.todayTokensID)
        let showCost = today != nil && ChipPreferences.isVisible(ChipPreferences.todayCostID)
        view.apply(chips: chips, today: today, showTokens: showTokens, showCost: showCost)
        item.view = view
        item.visibilityPriority = .high
        stripView = view
        return item
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
        stripView?.playReset(ids)
        for id in ids {
            Log.line("reset effect: \(id)")
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        stripBot?.playReset()
    }
}
