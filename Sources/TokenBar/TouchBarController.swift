import AppKit

@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {
    private var stripItem: NSCustomTouchBarItem?
    private var bar: NSTouchBar?
    private var chips: [Chip] = []
    private var today: TodayUsage?
    private var offline = false
    private var stripBot: StripBotView?
    private var stripView: TouchBarStripView?
    private var installedStrip = false
    private var presented = false
    private var reassertWork: DispatchWorkItem?
    private var snapshots: [String: ChipSnapshot] = [:]
    private var lastCelebratedAt: [String: Date] = [:]
    /// Reset time we already flashed for. A slide under two minutes is the same window.
    private var paceFlashedReset: [String: Date] = [:]
    private var demoPending = false
    private var demoRunning = false
    private var demoID = 0
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
        let demoFlag = URL(fileURLWithPath: "/tmp/tokenbar-demo-flashes")
        if FileManager.default.fileExists(atPath: demoFlag.path) {
            demoPending = true
            try? FileManager.default.removeItem(at: demoFlag)
            Log.line("pace demo armed")
        }
    }

    /// Scrolls two full-bar sentences, the 49-minute case and then the 1-minute case.
    func previewFlashes() {
        demoID += 1
        demoRunning = false
        demoPending = true
        guard !chips.isEmpty else { return }
        beginDemo()
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
        let showTokens = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayTokensID)
        let showCost = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayCostID)
        let resetIDs = offline || demoPending || demoRunning ? [] : detectResets(in: visible)
        let paceIDs = offline || demoPending || demoRunning ? [] : detectPaceFlashes(in: visible).filter { !resetIDs.contains($0) }
        self.chips = visible
        self.today = today
        self.offline = offline
        if bar == nil { rebuildBar() }
        if stripView == nil, isPinned || presented {
            presentExpanded()
        }
        stripView?.apply(chips: visible, today: today, showTokens: showTokens, showCost: showCost, dimmed: offline)
        refreshStripTitle(offline: offline)
        if !resetIDs.isEmpty {
            if isPinned { presentExpanded() }
            DispatchQueue.main.async { [weak self] in
                self?.celebrate(resetIDs)
            }
        }
        if !paceIDs.isEmpty {
            if isPinned, stripView == nil { presentExpanded() }
            DispatchQueue.main.async { [weak self] in
                self?.flashPace(paceIDs)
            }
        }
        if demoPending, !visible.isEmpty {
            beginDemo()
        }
    }

    func tick() {
        stripView?.tick(chips: chips, today: today)
        refreshStripTitle(offline: offline)
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
        let showTokens = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayTokensID)
        let showCost = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayCostID)
        view.apply(chips: chips, today: today, showTokens: showTokens, showCost: showCost, dimmed: offline)
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
            let snapshot = ChipSnapshot(
                percent: chip.percent,
                resetAt: chip.resetAt,
                remaining: chip.remaining,
                source: chip.source
            )
            defer { snapshots[chip.id] = snapshot }
            guard let old = snapshots[chip.id] else { continue }
            // A fallback taking over, or TokenTracker coming back, moves resetAt
            // without the quota actually resetting.
            if old.source != chip.source { continue }
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

    /// One amber flash per reset time when a visible chip is running ahead of an even burn.
    private func detectPaceFlashes(in chips: [Chip]) -> [String] {
        var fired: [String] = []
        for chip in chips {
            guard chip.paceRunoutText != nil, let reset = chip.resetAt else { continue }
            if let old = paceFlashedReset[chip.id], abs(reset.timeIntervalSince(old)) < 120 {
                continue
            }
            paceFlashedReset[chip.id] = reset
            fired.append(chip.id)
        }
        return fired
    }

    private func beginDemo() {
        guard demoPending, !demoRunning else { return }
        demoPending = false
        demoRunning = true
        demoID += 1
        let id = demoID
        if isPinned { presentExpanded() }
        Log.line("pace demo starting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.playDemo(step: 0, id: id)
        }
    }

    private func playDemo(step: Int, id: Int) {
        guard id == demoID else { return }
        guard let chip = chips.first else {
            demoRunning = false
            return
        }
        let line: String
        switch step {
        case 0:
            line = "\(chip.label) may run out early. At the current pace, usage may run out in 49m (82% used)."
        case 1:
            line = "\(chip.label) may run out early. At the current pace, usage may run out in 1m (98% used)."
        default:
            demoRunning = false
            return
        }
        presentBanner(line) { [weak self] in
            guard let self, id == self.demoID else { return }
            guard step == 0 else {
                self.demoRunning = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.playDemo(step: 1, id: id)
            }
        }
    }

    private func flashPace(_ ids: [String]) {
        let lines: [String] = ids.compactMap { id in
            guard let chip = chips.first(where: { $0.id == id }), let eta = chip.paceRunoutText else { return nil }
            let percent = Int(chip.percent.rounded())
            return "\(chip.label) may run out early. At the current pace, usage may run out in \(eta) (\(percent)% used)."
        }
        presentBanners(lines)
    }

    private func presentBanners(_ lines: [String]) {
        guard let first = lines.first else { return }
        presentBanner(first) { [weak self] in
            let rest = Array(lines.dropFirst())
            guard !rest.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.presentBanners(rest)
            }
        }
    }

    private func presentBanner(_ text: String, attempt: Int = 0, completion: @escaping () -> Void) {
        if isPinned { presentExpanded() }
        if let strip = stripView {
            Log.line("pace banner: \(text)")
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            strip.showBanner(text, completion: completion)
            return
        }
        guard attempt < 20 else {
            Log.line("pace banner missed, strip not ready")
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.presentBanner(text, attempt: attempt + 1, completion: completion)
        }
    }
}
