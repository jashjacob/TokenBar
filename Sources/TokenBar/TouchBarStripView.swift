import AppKit

/// One Touch Bar item that owns Today + every selected chip and lays them
/// out from the real item width, so macOS cannot hide the last card.
final class TouchBarStripView: NSView {
    var onChipTap: (() -> Void)?
    var onTodayTap: (() -> Void)?

    private var chips: [Chip] = []
    private var today: TodayUsage?
    private var showTokens = false
    private var showCost = false
    private var tokenView: TodayBarView?
    private var costView: TodayBarView?
    private var chipViews: [String: ChipBarView] = [:]

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 680, height: 30) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(chips: [Chip], today: TodayUsage?, showTokens: Bool, showCost: Bool) {
        self.chips = chips
        self.today = today
        self.showTokens = showTokens
        self.showCost = showCost
        syncToday()
        syncChips()
        needsLayout = true
    }

    func tick(chips: [Chip], today: TodayUsage?) {
        self.chips = chips
        self.today = today
        if let today {
            tokenView?.usage = today
            costView?.usage = today
        }
        for chip in chips {
            chipViews[chip.id]?.chip = chip
        }
        needsLayout = true
    }

    func playReset(_ ids: [String]) {
        for id in ids {
            chipViews[id]?.playReset()
        }
    }

    override func layout() {
        super.layout()
        let spacing = ChipLayout.spacing
        let height = bounds.height
        var x: CGFloat = 0

        if showTokens, let today {
            let w = ChipLayout.todayWidth(metric: .tokens, usage: today)
            tokenView?.layoutWidth = w
            tokenView?.frame = NSRect(x: x, y: 0, width: w, height: height)
            x += w + spacing
        }
        if showCost, let today {
            let w = ChipLayout.todayWidth(metric: .cost, usage: today)
            costView?.layoutWidth = w
            costView?.frame = NSRect(x: x, y: 0, width: w, height: height)
            x += w + spacing
        }

        for view in chipViews.values { view.isHidden = true }
        let n = chips.count
        guard n > 0, bounds.width > 1 else { return }
        let gaps = CGFloat(n - 1) * spacing
        let budget = max(0, bounds.width - x - gaps)
        let widths = ChipLayout.sized(chips, budget: budget)
        for chip in chips {
            guard x < bounds.width else { break }
            var w = widths[chip.id] ?? 0
            if x + w > bounds.width {
                w = bounds.width - x
            }
            guard w >= 1, let view = chipViews[chip.id] else { continue }
            view.isHidden = false
            view.layoutWidth = w
            view.frame = NSRect(x: x, y: 0, width: w, height: height)
            x += w + spacing
        }
    }

    private func syncToday() {
        if showTokens, let today {
            if tokenView == nil {
                let view = TodayBarView(usage: today, metric: .tokens)
                view.target = self
                view.action = #selector(todayTapped)
                addSubview(view)
                tokenView = view
            } else {
                tokenView?.usage = today
            }
        } else {
            tokenView?.removeFromSuperview()
            tokenView = nil
        }
        if showCost, let today {
            if costView == nil {
                let view = TodayBarView(usage: today, metric: .cost)
                view.target = self
                view.action = #selector(todayTapped)
                addSubview(view)
                costView = view
            } else {
                costView?.usage = today
            }
        } else {
            costView?.removeFromSuperview()
            costView = nil
        }
    }

    private func syncChips() {
        let ids = Set(chips.map(\.id))
        for (id, view) in chipViews where !ids.contains(id) {
            view.removeFromSuperview()
            chipViews.removeValue(forKey: id)
        }
        for chip in chips {
            if let view = chipViews[chip.id] {
                view.chip = chip
            } else {
                let view = ChipBarView(chip: chip, layoutWidth: ChipLayout.contentWidth(for: chip))
                view.target = self
                view.action = #selector(chipTapped)
                addSubview(view)
                chipViews[chip.id] = view
            }
        }
    }

    @objc private func chipTapped() { onChipTap?() }
    @objc private func todayTapped() { onTodayTap?() }
}
