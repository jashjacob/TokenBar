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
    private var lastOrder: [String] = []
    /// When each window last spoke, and when any sentence last covered the strip.
    /// Saved once the sentence is actually on the bar.
    private var paceHistory = PaceBanner.History()
    private var paceHistoryLoaded = false
    private var pacePending = false
    private var paceChoice: PaceBanner.Choice?
    private static let paceFlashKey = "paceFlashes.v2"
    private static let paceFlashLegacyKey = "paceFlashedReset.v1"
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
        let live = chips.map { $0.withClock(previousReset: snapshots[$0.id]?.resetAt) }
        if !offline {
            ChipActivity.note(live)
        }
        let visible = ChipLayout.ordered(
            live.filter { ChipPreferences.isVisible($0.id) },
            activeAt: ChipActivity.activeAt,
            returnedAt: ChipActivity.returnedAt
        )
        let order = visible.map(\.id)
        if order != lastOrder {
            lastOrder = order
            Log.line("strip order: \(ChipLayout.describe(visible, activeAt: ChipActivity.activeAt, returnedAt: ChipActivity.returnedAt))")
        }
        let showTokens = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayTokensID)
        let showCost = !offline && today != nil && ChipPreferences.isVisible(ChipPreferences.todayCostID)
        let resetIDs = offline ? [] : detectResets(in: visible)
        let paceIDs = offline ? [] : detectPaceFlashes(in: visible, skipping: Set(resetIDs))
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
    }

    func tick() {
        let live = chips.map { $0.withClock(previousReset: snapshots[$0.id]?.resetAt) }
        stripView?.tick(chips: live, today: today)
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
            // An unused window resetting does not flash. It was already free.
            if ResetDetector.didReset(old: old, new: chip), Int(old.percent.rounded()) > 0 {
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

    /// At most one sentence. Only a chip in use, and only the tightest estimate
    /// that has not already been said at this severity.
    private func detectPaceFlashes(in chips: [Chip], skipping: Set<String>) -> [String] {
        loadPaceHistory()
        if pacePending { return [] }
        let choices: [PaceBanner.Choice] = chips.compactMap { chip in
            guard !skipping.contains(chip.id) else { return nil }
            guard ChipActivity.isInUse(chip.id) else { return nil }
            guard let eta = chip.paceRunout, let reset = chip.resetAt else { return nil }
            return PaceBanner.Choice(id: chip.id, resetAt: reset, eta: eta)
        }
        guard let best = paceHistory.next(choices, now: Date()) else { return [] }
        pacePending = true
        paceChoice = best
        return [best.id]
    }

    private func loadPaceHistory() {
        guard !paceHistoryLoaded else { return }
        paceHistoryLoaded = true
        let defaults = UserDefaults.standard
        if let raw = defaults.dictionary(forKey: Self.paceFlashKey) {
            paceHistory = Self.history(from: raw)
            return
        }
        // The previous build stored only the reset time. Those sentences were
        // hour-scale, so treat them as already said until the estimate tightens.
        guard let legacy = defaults.dictionary(forKey: Self.paceFlashLegacyKey) else { return }
        let now = Date()
        var history = PaceBanner.History()
        history.lastAt = now
        for (id, value) in legacy {
            guard let stamp = value as? NSNumber else { continue }
            let reset = Date(timeIntervalSince1970: stamp.doubleValue)
            guard reset.timeIntervalSince(now) > -86_400 else { continue }
            history.chips[id] = PaceBanner.Record(resetAt: reset, firstAt: now, lastAt: now, band: .hours)
        }
        guard !history.chips.isEmpty else { return }
        paceHistory = history
        savePaceHistory()
        defaults.removeObject(forKey: Self.paceFlashLegacyKey)
    }

    private static func history(from raw: [String: Any]) -> PaceBanner.History {
        var history = PaceBanner.History()
        if let last = raw["last"] as? NSNumber {
            history.lastAt = Date(timeIntervalSince1970: last.doubleValue)
        }
        let now = Date()
        let chips = raw["chips"] as? [String: Any] ?? [:]
        for (id, value) in chips {
            guard let entry = value as? [String: Any],
                  let resetStamp = (entry["reset"] as? NSNumber)?.doubleValue,
                  let first = (entry["first"] as? NSNumber)?.doubleValue,
                  let last = (entry["last"] as? NSNumber)?.doubleValue,
                  let bandRaw = (entry["band"] as? NSNumber)?.doubleValue,
                  let band = PaceBanner.Band(rawValue: Int(bandRaw)) else { continue }
            let reset = Date(timeIntervalSince1970: resetStamp)
            guard reset.timeIntervalSince(now) > -86_400 else { continue }
            history.chips[id] = PaceBanner.Record(
                resetAt: reset,
                firstAt: Date(timeIntervalSince1970: first),
                lastAt: Date(timeIntervalSince1970: last),
                band: band
            )
        }
        return history
    }

    /// Called only after the sentence is actually on the strip.
    private func commitPaceFlash() {
        guard let choice = paceChoice else { return }
        paceHistory.remember(choice, now: Date())
        paceChoice = nil
        pacePending = false
        savePaceHistory()
    }

    private func savePaceHistory() {
        var chips: [String: [String: Double]] = [:]
        for (id, record) in paceHistory.chips {
            chips[id] = [
                "reset": record.resetAt.timeIntervalSince1970,
                "first": record.firstAt.timeIntervalSince1970,
                "last": record.lastAt.timeIntervalSince1970,
                "band": Double(record.band.rawValue),
            ]
        }
        var raw: [String: Any] = ["chips": chips]
        if let lastAt = paceHistory.lastAt {
            raw["last"] = lastAt.timeIntervalSince1970
        }
        UserDefaults.standard.set(raw, forKey: Self.paceFlashKey)
    }

    private func flashPace(_ ids: [String]) {
        guard let id = ids.first,
              let chip = chips.first(where: { $0.id == id }),
              let eta = chip.paceRunout,
              let reset = chip.resetAt else {
            pacePending = false
            paceChoice = nil
            return
        }
        paceChoice = PaceBanner.Choice(id: id, resetAt: reset, eta: eta)
        let text = PaceBanner.sentence(label: chip.label, percent: chip.percent, eta: eta)
        presentBanner(text)
    }

    private func presentBanner(_ text: String, attempt: Int = 0) {
        if isPinned { presentExpanded() }
        // A collapsed bar keeps its view. Saving then would burn the window
        // on a sentence that never appeared.
        if presented, let strip = stripView {
            commitPaceFlash()
            Log.line("pace banner: \(text)")
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            strip.showBanner(text) {}
            return
        }
        if !isPinned {
            pacePending = false
            paceChoice = nil
            return
        }
        guard attempt < 20 else {
            pacePending = false
            paceChoice = nil
            Log.line("pace banner missed, strip not ready")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.presentBanner(text, attempt: attempt + 1)
        }
    }
}
