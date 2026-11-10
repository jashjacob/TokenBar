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
    /// Bundle of an app opened without activating, so a cold launch does not
    /// clear the strip before that app is actually up.
    private var awaitingLaunch: String?
    private var snapshots: [String: ChipSnapshot] = [:]
    private var snapshotsLoaded = false
    private var lastCelebratedAt: [String: Date] = [:]
    /// The reset worth a sentence this poll. The chip flash still runs for every id.
    private var resetNotice: ResetNotice?
    private var lastOrder: [String] = []
    /// When each window last spoke, and when any sentence last covered the strip.
    /// Saved once the sentence is actually on the bar.
    private var paceHistory = PaceBanner.History()
    private var paceHistoryLoaded = false
    private var pacePending = false
    private var paceChoice: PaceBanner.Choice?
    private var leftoverHistory = LeftoverBanner.History()
    private var leftoverHistoryLoaded = false
    private var leftoverPending = false
    private var leftoverChoice: LeftoverBanner.Choice?
    /// Set when the pending pink line is OpenCode's renewal, not a leftover.
    private var renewalSentence: String?
    /// Runs once the sentence is actually on the strip.
    private var bannerCommit: (() -> Void)?
    /// Bumped when a banner is dropped or replaced, so a late retry cannot show the old sentence.
    private var bannerGeneration = 0
    private static let paceFlashKey = "paceFlashes.v2"
    private static let paceFlashLegacyKey = "paceFlashedReset.v1"
    private static let leftoverFlashKey = "leftoverFlashes.v1"
    private static let snapshotKey = "chipSnapshots.v1"
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
        get { UserDefaults.standard.object(forKey: "bounceStripBot") as? Bool ?? false }
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        watchMenuTracking()
        if isPinned {
            presentExpanded()
        }
    }

    func stop() {
        reassertWork?.cancel()
        awaitingLaunch = nil
        DistributedNotificationCenter.default().removeObserver(self)
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
        loadSnapshots()
        let live = chips.map { $0.withClock(previousReset: snapshots[$0.id]?.resetAt) }
        let shown = live.filter { ChipPreferences.isVisible($0.id) && !Chip.heldOffStrip($0.id, among: live) }
        let onStrip = Set(shown.map(\.id))
        if !offline {
            ChipActivity.note(chips, onStrip: onStrip)
        }
        let visible = ChipLayout.ordered(
            shown,
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
        let resetIDs = offline ? [] : detectResets(in: chips, onStrip: onStrip)
        let paceIDs = offline ? [] : detectPaceFlashes(in: visible, skipping: Set(resetIDs))
        let skipping = Set(resetIDs)
        let leftoverIDs = offline || !paceIDs.isEmpty
            ? []
            : detectLeftovers(in: visible, skipping: skipping)
        let renewalIDs = offline || !paceIDs.isEmpty || !leftoverIDs.isEmpty
            ? []
            : detectRenewal(in: visible, skipping: skipping)
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
                guard let self else { return }
                let speaking = self.resetNotice != nil && self.isPinned
                self.celebrate(resetIDs, haptic: !speaking)
                if speaking { self.flashReset() }
            }
        }
        if !paceIDs.isEmpty {
            if isPinned, stripView == nil { presentExpanded() }
            DispatchQueue.main.async { [weak self] in
                self?.flashPace(paceIDs)
            }
        } else if !leftoverIDs.isEmpty || !renewalIDs.isEmpty {
            if isPinned, stripView == nil { presentExpanded() }
            let ids = leftoverIDs.isEmpty ? renewalIDs : leftoverIDs
            DispatchQueue.main.async { [weak self] in
                self?.flashLeftover(ids)
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
        view.onChipTap = { [weak self] id in self?.chipClicked(id) }
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

    private func chipClicked(_ id: String) {
        guard let bundle = Self.appBundle(for: id) else {
            Log.line("open \(id): no app")
            return
        }
        openApp(bundle)
    }

    /// GrokBot is a Cursor window, and it opens the Grok Bot app.
    private static func appBundle(for id: String) -> String? {
        if id == "cursor.quaternary_window" { return "com.anysphere.sand" }
        switch id.split(separator: ".").first.map(String.init) {
        case "claude": return "com.anthropic.claudefordesktop"
        case "codex": return "com.openai.codex"
        case "cursor": return "com.todesktop.230313mzl4w4u92"
        case "gemini": return "com.google.GeminiMacOS"
        case "kimi": return "com.kimi.code.desktop"
        case "antigravity": return "com.google.antigravity"
        case "opencodeGo": return "ai.opencode.desktop"
        case "commandCode": return "ai.commandcode.desktop"
        default: return nil
        }
    }

    private func openApp(_ bundle: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            Log.line("open \(bundle) failed: app not found")
            return
        }
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundle && $0.isFinishedLaunching
        }
        Log.line("open \(bundle)")
        let config = NSWorkspace.OpenConfiguration()
        // Activating a cold launch clears the system-modal strip until that
        // app is actually frontmost. Leave the current app in front until then.
        config.activates = running
        if running {
            if awaitingLaunch == bundle { awaitingLaunch = nil }
        } else {
            awaitingLaunch = bundle
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.bringForwardIfStillWaiting(bundle)
            }
        }
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            let failure = error.map(\.localizedDescription)
            Task { @MainActor in
                guard let self else { return }
                if let failure {
                    Log.line("open \(bundle) failed: \(failure)")
                    if self.awaitingLaunch == bundle { self.awaitingLaunch = nil }
                    return
                }
                guard self.awaitingLaunch == bundle, let app, app.isFinishedLaunching else { return }
                self.bringForward(app, bundle: bundle)
            }
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let awaitingLaunch,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == awaitingLaunch else { return }
        bringForward(app, bundle: awaitingLaunch)
    }

    /// An app that brings itself forward needs no second activation.
    private func bringForward(_ app: NSRunningApplication, bundle: String) {
        guard awaitingLaunch == bundle else { return }
        awaitingLaunch = nil
        guard !app.isActive else { return }
        activate(app)
    }

    private func bringForwardIfStillWaiting(_ bundle: String) {
        guard awaitingLaunch == bundle else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            awaitingLaunch = nil
            return
        }
        bringForward(app, bundle: bundle)
    }

    private func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate(from: .current, options: [.activateAllWindows])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
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

    /// A Dock menu takes the Touch Bar without activating an app. TokenBar is
    /// not the active app, so this registration has to be delivered anyway.
    private func watchMenuTracking() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(menuTrackingBegan),
            name: Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(menuTrackingEnded),
            name: Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func menuTrackingBegan() {
        reassertWork?.cancel()
    }

    @objc private func menuTrackingEnded() {
        scheduleReassert()
    }

    @objc private func appActivated(_ note: Notification) {
        scheduleReassert()
    }

    private func scheduleReassert() {
        guard isPinned else { return }
        reassertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.presentExpanded()
        }
        reassertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Compares the feed, not the locally rolled clock. A chip that is off the
    /// strip keeps a fresh snapshot and does not flash when it comes back.
    private func detectResets(in chips: [Chip], onStrip: Set<String>) -> [String] {
        loadSnapshots()
        // An empty feed is not a reset. Keep the last numbers for the next real poll.
        guard !chips.isEmpty else {
            resetNotice = nil
            return []
        }
        var fired: [String] = []
        var notice: ResetNotice?
        var next: [String: ChipSnapshot] = [:]
        for chip in chips {
            let snapshot = ChipSnapshot(
                percent: chip.percent,
                resetAt: chip.resetAt,
                remaining: chip.remaining,
                source: chip.source
            )
            next[chip.id] = snapshot
            guard onStrip.contains(chip.id), let old = snapshots[chip.id] else { continue }
            let last = lastCelebratedAt[chip.id] ?? .distantPast
            guard Date().timeIntervalSince(last) > 60 else { continue }
            // An unused window resetting does not flash. It was already free.
            guard let kind = ResetDetector.noticeKind(old: old, new: chip),
                  Int(old.percent.rounded()) > 0 else { continue }
            lastCelebratedAt[chip.id] = Date()
            fired.append(chip.id)
            let drop = old.percent - chip.percent
            let bestDrop = notice.map { $0.oldPercent - $0.newPercent } ?? -1
            guard drop > bestDrop else { continue }
            notice = ResetNotice(
                label: chip.label,
                oldPercent: old.percent,
                newPercent: chip.percent,
                kind: kind
            )
        }
        snapshots = next
        saveSnapshots()
        resetNotice = notice
        return fired
    }

    private func celebrate(_ ids: [String], haptic: Bool) {
        stripView?.playReset(ids)
        for id in ids {
            Log.line("reset effect: \(id)")
        }
        if haptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        stripBot?.playReset()
    }

    /// Saved after the sentence is on the strip would be too late: the next
    /// launch has to compare against the previous poll, not against itself.
    private func loadSnapshots() {
        guard !snapshotsLoaded else { return }
        snapshotsLoaded = true
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.snapshotKey) else { return }
        let percents = raw["percent"] as? [String: Any] ?? [:]
        let resets = raw["reset"] as? [String: Any] ?? [:]
        let remainings = raw["remaining"] as? [String: Any] ?? [:]
        let sources = raw["source"] as? [String: Any] ?? [:]
        var loaded: [String: ChipSnapshot] = [:]
        for (id, value) in percents {
            guard let percent = (value as? NSNumber)?.doubleValue else { continue }
            let reset = (resets[id] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let remaining = (remainings[id] as? NSNumber)?.doubleValue
            let source: ChipSource = (sources[id] as? String) == "fallback" ? .fallback : .tokenTracker
            loaded[id] = ChipSnapshot(percent: percent, resetAt: reset, remaining: remaining, source: source)
        }
        snapshots = loaded
    }

    private func saveSnapshots() {
        var percents: [String: Double] = [:]
        var resets: [String: Double] = [:]
        var remainings: [String: Double] = [:]
        var sources: [String: String] = [:]
        for (id, snap) in snapshots {
            percents[id] = snap.percent
            if let reset = snap.resetAt {
                resets[id] = reset.timeIntervalSince1970
            }
            if let remaining = snap.remaining {
                remainings[id] = remaining
            }
            sources[id] = snap.source == .fallback ? "fallback" : "tracker"
        }
        UserDefaults.standard.set(
            [
                "percent": percents,
                "reset": resets,
                "remaining": remainings,
                "source": sources,
            ],
            forKey: Self.snapshotKey
        )
    }

    private func flashReset() {
        guard let notice = resetNotice else { return }
        resetNotice = nil
        // Quiet the other lines for one gap. Do not mark this window as a leftover already said.
        bannerCommit = { [weak self] in self?.noteResetQuiet() }
        presentBanner(notice.sentence, tone: .reset)
    }

    private func noteResetQuiet() {
        let now = Date()
        loadPaceHistory()
        loadLeftoverHistory()
        paceHistory.lastAt = now
        leftoverHistory.lastAt = now
        savePaceHistory()
        saveLeftoverHistory()
    }

    /// At most one sentence. Only a chip in use, and only the tightest estimate
    /// that has not already been said at this severity.
    private func detectPaceFlashes(in chips: [Chip], skipping: Set<String>) -> [String] {
        loadPaceHistory()
        loadLeftoverHistory()
        if pacePending || leftoverPending { return [] }
        let choices: [PaceBanner.Choice] = chips.compactMap { chip in
            guard !skipping.contains(chip.id) else { return nil }
            guard ChipActivity.isInUse(chip.id) else { return nil }
            guard let eta = chip.paceRunout, let reset = chip.resetAt else { return nil }
            return PaceBanner.Choice(id: chip.id, resetAt: reset, eta: eta)
        }
        let now = Date()
        guard let best = paceHistory.next(choices, now: now) else { return [] }
        // A leftover sentence is not a pace escalation. The full quiet stretch still applies.
        if let quiet = leftoverHistory.lastAt, now.timeIntervalSince(quiet) < PaceBanner.gap {
            return []
        }
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
        bannerCommit = { [weak self] in self?.commitPaceFlash() }
        presentBanner(text, tone: .pace)
    }

    /// Soonest week or month that still has allowance left to mention.
    /// GrokBot counts as a week even though its label has no window tag.
    private func detectLeftovers(in chips: [Chip], skipping: Set<String>) -> [String] {
        loadLeftoverHistory()
        if pacePending || leftoverPending { return [] }
        let choices: [LeftoverBanner.Choice] = chips.compactMap { chip in
            guard !skipping.contains(chip.id), let remaining = chip.remaining, let reset = chip.resetAt else { return nil }
            guard LeftoverBanner.qualifies(id: chip.id, windowTag: chip.windowTag, percent: chip.percent, remaining: remaining) else { return nil }
            let unused = 100 - min(max(chip.percent, 0), 100)
            return LeftoverBanner.Choice(id: chip.id, resetAt: reset, remaining: remaining, unused: unused)
        }
        guard let best = leftoverHistory.next(choices, now: Date(), otherQuiet: paceHistory.lastAt) else { return [] }
        leftoverPending = true
        leftoverChoice = best
        renewalSentence = nil
        return [best.id]
    }

    /// OpenCode and Command Code renew on their monthly reset. Speak once on the last day
    /// when the leftover line has nothing left to mention. The sooner date goes first.
    private func detectRenewal(in chips: [Chip], skipping: Set<String>) -> [String] {
        loadPaceHistory()
        loadLeftoverHistory()
        if pacePending || leftoverPending { return [] }
        let ranked = chips.compactMap { chip -> (chip: Chip, remaining: TimeInterval, reset: Date)? in
            guard !skipping.contains(chip.id),
                  let remaining = chip.remaining,
                  let reset = chip.resetAt,
                  RenewalReminder.qualifies(id: chip.id, remaining: remaining)
            else { return nil }
            if let said = leftoverHistory.spoken[chip.id],
               abs(said.timeIntervalSince(reset)) < LeftoverBanner.sameWindow {
                return nil
            }
            return (chip, remaining, reset)
        }.sorted { lhs, rhs in
            if lhs.remaining != rhs.remaining { return lhs.remaining < rhs.remaining }
            return lhs.chip.id < rhs.chip.id
        }
        guard let best = ranked.first, let text = RenewalReminder.sentence(id: best.chip.id, remaining: best.remaining) else {
            return []
        }
        let now = Date()
        if let quiet = paceHistory.lastAt, now.timeIntervalSince(quiet) < PaceBanner.gap { return [] }
        if let lastAt = leftoverHistory.lastAt, now.timeIntervalSince(lastAt) < PaceBanner.gap { return [] }
        leftoverPending = true
        leftoverChoice = LeftoverBanner.Choice(id: best.chip.id, resetAt: best.reset, remaining: best.remaining, unused: 0)
        renewalSentence = text
        return [best.chip.id]
    }

    private func loadLeftoverHistory() {
        guard !leftoverHistoryLoaded else { return }
        leftoverHistoryLoaded = true
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.leftoverFlashKey) else { return }
        var history = LeftoverBanner.History()
        if let last = raw["last"] as? Double {
            history.lastAt = Date(timeIntervalSince1970: last)
        }
        let now = Date()
        let spoken = raw["chips"] as? [String: Double] ?? [:]
        for (id, stamp) in spoken {
            let reset = Date(timeIntervalSince1970: stamp)
            guard reset.timeIntervalSince(now) > -86_400 else { continue }
            history.spoken[id] = reset
        }
        let close = raw["close"] as? [String: Double] ?? [:]
        for (id, stamp) in close {
            let reset = Date(timeIntervalSince1970: stamp)
            guard reset.timeIntervalSince(now) > -86_400 else { continue }
            history.closeSpoken[id] = reset
        }
        leftoverHistory = history
    }

    private func commitLeftover() {
        guard let choice = leftoverChoice else { return }
        let now = Date()
        leftoverHistory.remember(choice, now: now)
        paceHistory.lastAt = now
        leftoverChoice = nil
        leftoverPending = false
        saveLeftoverHistory()
        savePaceHistory()
    }

    private func saveLeftoverHistory() {
        var chips: [String: Double] = [:]
        for (id, reset) in leftoverHistory.spoken {
            chips[id] = reset.timeIntervalSince1970
        }
        var close: [String: Double] = [:]
        for (id, reset) in leftoverHistory.closeSpoken {
            close[id] = reset.timeIntervalSince1970
        }
        var raw: [String: Any] = ["chips": chips, "close": close]
        if let lastAt = leftoverHistory.lastAt {
            raw["last"] = lastAt.timeIntervalSince1970
        }
        UserDefaults.standard.set(raw, forKey: Self.leftoverFlashKey)
    }

    private func flashLeftover(_ ids: [String]) {
        guard let id = ids.first,
              let chip = chips.first(where: { $0.id == id }),
              chip.resetAt != nil else {
            renewalSentence = nil
            leftoverPending = false
            leftoverChoice = nil
            return
        }
        let text: String
        if let renewalSentence {
            text = renewalSentence
            self.renewalSentence = nil
        } else if LeftoverBanner.qualifies(id: chip.id, windowTag: chip.windowTag, percent: chip.percent, remaining: chip.remaining ?? 0) {
            text = LeftoverBanner.sentence(id: chip.id, label: chip.label, windowTag: chip.windowTag, percent: chip.percent, remaining: chip.remaining ?? 0)
        } else {
            leftoverPending = false
            leftoverChoice = nil
            return
        }
        bannerCommit = { [weak self] in self?.commitLeftover() }
        presentBanner(text, tone: .leftover)
    }

    private func presentBanner(_ text: String, tone: BannerTone, generation: Int? = nil, attempt: Int = 0) {
        let generation = generation ?? {
            bannerGeneration += 1
            return bannerGeneration
        }()
        guard generation == bannerGeneration else { return }
        if isPinned { presentExpanded() }
        // A collapsed bar keeps its view. Saving then would burn the window
        // on a sentence that never appeared.
        if presented, let strip = stripView {
            bannerCommit?()
            bannerCommit = nil
            Log.line("banner: \(text)")
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            strip.showBanner(text, tone: tone) {}
            return
        }
        if !isPinned {
            dropBanner()
            return
        }
        guard attempt < 20 else {
            dropBanner()
            Log.line("banner missed, strip not ready")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.presentBanner(text, tone: tone, generation: generation, attempt: attempt + 1)
        }
    }

    private func dropBanner() {
        bannerGeneration += 1
        bannerCommit = nil
        pacePending = false
        paceChoice = nil
        leftoverPending = false
        leftoverChoice = nil
        renewalSentence = nil
        resetNotice = nil
    }
}

private struct ResetNotice {
    var label: String
    var oldPercent: Double
    var newPercent: Double
    var kind: ResetDetector.Kind

    var sentence: String {
        ResetDetector.sentence(label: label, oldPercent: oldPercent, newPercent: newPercent, kind: kind)
    }
}
