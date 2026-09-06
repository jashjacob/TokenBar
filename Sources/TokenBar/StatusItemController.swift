import AppKit
import ServiceManagement

@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let touchBar: TouchBarController
    private let onRefresh: () -> Void
    private let onVisibilityChange: () -> Void
    private var chips: [Chip] = []
    private var today: TodayUsage?
    private var offline = true
    private var lastError: String?

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
            lines.append(contentsOf: chips.filter { ChipPreferences.isVisible($0.id) }.map(\.menuTitle))
            button.toolTip = error ?? (lines.isEmpty ? "TokenBar" : lines.joined(separator: "\n"))
        }
        reloadMenu()
    }

    func reloadMenu() {
        item.menu = buildMenu(chips: chips, today: today, offline: offline, error: lastError)
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

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let dash = NSMenuItem(title: "Open TokenTracker Limits", action: #selector(openDashboard), keyEquivalent: "o")
        dash.target = self
        menu.addItem(dash)

        let pin = NSMenuItem(title: "Pin Touch Bar", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = touchBar.isPinned ? .on : .off
        menu.addItem(pin)

        let bounce = NSMenuItem(title: "Bounce Icon", action: #selector(toggleBounce), keyEquivalent: "")
        bounce.target = self
        bounce.state = touchBar.bounceStripBot ? .on : .off
        menu.addItem(bounce)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = launchesAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About TokenBar", action: #selector(aboutClicked), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

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

    private var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func allIDs() -> [String] {
        (ChipPreferences.todayMetricIDs + chips.map(\.id))
    }

    @objc private func toggleChip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ChipPreferences.toggle(id)
        onVisibilityChange()
    }

    @objc private func showAllClicked() {
        ChipPreferences.setAllVisible(allIDs(), true)
        onVisibilityChange()
    }

    @objc private func hideAllClicked() {
        ChipPreferences.setAllVisible(allIDs(), false)
        onVisibilityChange()
    }

    @objc private func refreshClicked() { onRefresh() }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(LimitsClient.dashboardURL())
    }

    @objc private func togglePin() {
        touchBar.isPinned.toggle()
        onRefresh()
    }

    @objc private func toggleBounce() {
        touchBar.bounceStripBot.toggle()
        onRefresh()
    }

    @objc private func toggleLogin() {
        do {
            if launchesAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.line("launch at login failed: \(error)")
        }
        onRefresh()
    }

    @objc private func aboutClicked() {
        AboutPanel.shared.show()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
