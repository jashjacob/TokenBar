import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let touchBar: TouchBarController
    private let onRefresh: () -> Void
    private let onVisibilityChange: () -> Void
    private var chips: [Chip] = []
    private var today: TodayUsage?
    private var offline = true
    private var lastError: String?
    private var menuOpen = false
    private var menuDirty = false

    init(
        touchBar: TouchBarController,
        onRefresh: @escaping () -> Void,
        onVisibilityChange: @escaping () -> Void
    ) {
        self.item = NSStatusBar.system.statusItem(withLength: 24)
        self.touchBar = touchBar
        self.onRefresh = onRefresh
        self.onVisibilityChange = onVisibilityChange
        super.init()
        SettingsWindow.shared.configure(
            touchBar: touchBar,
            onRefresh: onRefresh,
            onVisibilityChange: onVisibilityChange
        )
        applyIcon(offline: false)
    }

    func update(chips: [Chip], today: TodayUsage?, offline: Bool, error: String?) {
        self.chips = chips
        self.today = today
        self.offline = offline
        self.lastError = error
        applyIcon(offline: offline)
        if let button = item.button {
            var lines: [String] = []
            if let today {
                if ChipPreferences.isVisible(ChipPreferences.todayTokensID) {
                    lines.append(today.tokenMenuTitle)
                }
                if ChipPreferences.isVisible(ChipPreferences.todayCostID) {
                    lines.append(today.costMenuTitle)
                }
            }
            lines.append(contentsOf: chips.filter { ChipPreferences.isVisible($0.id) }.map(\.tooltipTitle))
            button.toolTip = error ?? (lines.isEmpty ? "TokenBar" : lines.joined(separator: "\n"))
        }
        if menuOpen {
            menuDirty = true
            SettingsWindow.shared.update(chips: chips, today: today, offline: offline, error: lastError)
            return
        }
        installMenu()
    }

    func reloadMenu() {
        if menuOpen {
            menuDirty = true
            SettingsWindow.shared.update(chips: chips, today: today, offline: offline, error: lastError)
            return
        }
        installMenu()
    }

    private func installMenu() {
        menuDirty = false
        let menu = buildMenu(chips: chips, today: today, offline: offline, error: lastError)
        menu.delegate = self
        item.menu = menu
        SettingsWindow.shared.update(chips: chips, today: today, offline: offline, error: lastError)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        guard menuDirty else { return }
        installMenu()
    }

    private func refreshOpenMenu() {
        guard let menu = item.menu else { return }
        for row in menu.items {
            if let id = row.representedObject as? String {
                row.state = ChipPreferences.isVisible(id) ? .on : .off
            } else if row.title == "Pin Touch Bar" {
                row.state = touchBar.isPinned ? .on : .off
            }
        }
    }

    private func applyIcon(offline: Bool) {
        guard let button = item.button else { return }
        button.title = ""
        button.image = StripBotView.statusItemImage(offline: offline)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.appearsDisabled = offline
    }

    private func buildMenu(chips: [Chip], today: TodayUsage?, offline: Bool, error: String?) -> NSMenu {
        let menu = NSMenu()
        if let error, offline {
            menu.addItem(disabled(error))
        } else if chips.isEmpty, today == nil {
            menu.addItem(disabled("No quota windows yet"))
        } else {
            menu.addItem(disabled("Touch Bar"))
            if let today {
                let tokens = NSMenuItem(title: today.tokenMenuTitle, action: #selector(toggleChip(_:)), keyEquivalent: "")
                tokens.target = self
                tokens.representedObject = ChipPreferences.todayTokensID
                tokens.state = ChipPreferences.isVisible(ChipPreferences.todayTokensID) ? .on : .off
                menu.addItem(tokens)

                let cost = NSMenuItem(title: today.costMenuTitle, action: #selector(toggleChip(_:)), keyEquivalent: "")
                cost.target = self
                cost.representedObject = ChipPreferences.todayCostID
                cost.state = ChipPreferences.isVisible(ChipPreferences.todayCostID) ? .on : .off
                menu.addItem(cost)
            }
            for chip in chips {
                let row = NSMenuItem(title: chip.menuTitle, action: #selector(toggleChip(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = chip.id
                row.state = ChipPreferences.isVisible(chip.id) ? .on : .off
                row.toolTip = chip.rowTip
                menu.addItem(row)
            }
            let showAll = NSMenuItem(title: "Show All", action: #selector(showAllClicked), keyEquivalent: "")
            showAll.target = self
            menu.addItem(showAll)
            let hideAll = NSMenuItem(title: "Hide All", action: #selector(hideAllClicked), keyEquivalent: "")
            hideAll.target = self
            menu.addItem(hideAll)
        }
        menu.addItem(.separator())

        let pin = NSMenuItem(title: "Pin Touch Bar", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = touchBar.isPinned ? .on : .off
        menu.addItem(pin)

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let dash = NSMenuItem(title: "Open TokenTracker Limits", action: #selector(openDashboard), keyEquivalent: "o")
        dash.target = self
        menu.addItem(dash)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit TokenBar", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func allIDs() -> [String] {
        (ChipPreferences.todayMetricIDs + chips.map(\.id))
    }

    @objc private func toggleChip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ChipPreferences.toggle(id)
        refreshOpenMenu()
        onVisibilityChange()
    }

    @objc private func showAllClicked() {
        ChipPreferences.setAllVisible(allIDs(), true)
        refreshOpenMenu()
        onVisibilityChange()
    }

    @objc private func hideAllClicked() {
        ChipPreferences.setAllVisible(allIDs(), false)
        refreshOpenMenu()
        onVisibilityChange()
    }

    @objc private func refreshClicked() {
        LimitsClient.refreshFallbacksNow = true
        onRefresh()
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(LimitsClient.dashboardURL())
    }

    @objc private func togglePin() {
        touchBar.isPinned.toggle()
        refreshOpenMenu()
        onRefresh()
    }

    @objc private func settingsClicked() {
        SettingsWindow.shared.show(chips: chips, today: today, offline: offline, error: lastError)
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
