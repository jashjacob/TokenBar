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
    private var dimmed = false
    private var tokenView: TodayBarView?
    private var costView: TodayBarView?
    private var chipViews: [String: ChipBarView] = [:]
    private let overflowBadge = OverflowBadge()

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 680, height: 30) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        overflowBadge.isHidden = true
        addSubview(overflowBadge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(chips: [Chip], today: TodayUsage?, showTokens: Bool, showCost: Bool, dimmed: Bool = false) {
        self.chips = chips
        self.today = today
        self.showTokens = showTokens
        self.showCost = showCost
        self.dimmed = dimmed
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

    func playPace(_ labels: [String: String]) {
        for (id, label) in labels {
            chipViews[id]?.playPace(label: label)
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
        overflowBadge.isHidden = true
        let n = chips.count
        guard n > 0, bounds.width > 1 else { return }
        let gaps = CGFloat(max(0, n - 1)) * spacing
        let budget = max(0, bounds.width - x - gaps)
        let widths = ChipLayout.sized(chips, budget: budget)
        let fit = fittedCount(widths: widths, start: x, limit: bounds.width)
        for chip in chips.prefix(fit) {
            let w = widths[chip.id] ?? 0
            guard w >= 1, let view = chipViews[chip.id] else { continue }
            view.isHidden = false
            view.layoutWidth = w
            view.frame = NSRect(x: x, y: 0, width: w, height: height)
            x += w + spacing
        }
        let hidden = n - fit
        guard hidden > 0 else { return }
        if fit > 0 { x -= spacing }
        let badgeW = OverflowBadge.width(for: hidden)
        let badgeX = min(x + (fit > 0 ? spacing : 0), max(x, bounds.width - badgeW))
        overflowBadge.count = hidden
        overflowBadge.names = chips.dropFirst(fit).map(\.label)
        overflowBadge.alphaValue = dimmed ? 0.4 : 1
        overflowBadge.isHidden = false
        overflowBadge.frame = NSRect(x: badgeX, y: 0, width: min(badgeW, bounds.width - badgeX), height: height)
        addSubview(overflowBadge)
    }

    /// How many leading chips fit at full width, leaving room for a +N badge when some do not.
    private func fittedCount(widths: [String: CGFloat], start: CGFloat, limit: CGFloat) -> Int {
        func rowWidth(_ count: Int) -> CGFloat {
            guard count > 0 else { return 0 }
            let sum = chips.prefix(count).reduce(CGFloat(0)) { $0 + (widths[$1.id] ?? 0) }
            return sum + CGFloat(count - 1) * ChipLayout.spacing
        }
        if start + rowWidth(chips.count) <= limit + 0.5 { return chips.count }
        for count in stride(from: chips.count - 1, through: 0, by: -1) {
            let hidden = chips.count - count
            let gap: CGFloat = count > 0 ? ChipLayout.spacing : 0
            if start + rowWidth(count) + gap + OverflowBadge.width(for: hidden) <= limit + 0.5 {
                return count
            }
        }
        return 0
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
                view.alphaValue = dimmed ? 0.4 : 1
            } else {
                let view = ChipBarView(chip: chip, layoutWidth: ChipLayout.contentWidth(for: chip))
                view.alphaValue = dimmed ? 0.4 : 1
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

/// "+N" when the strip cannot show every card at full width. Not a button.
private final class OverflowBadge: NSView {
    var count = 0 {
        didSet {
            guard oldValue != count else { return }
            needsDisplay = true
        }
    }

    var names: [String] = [] {
        didSet { toolTip = names.isEmpty ? nil : names.joined(separator: "\n") }
    }

    override var isFlipped: Bool { true }

    static func width(for count: Int) -> CGFloat {
        let text = "+\(count)" as NSString
        return ceil(text.size(withAttributes: textAttrs).width + 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: 0, dy: 6)
        guard pill.width > 1, pill.height > 1 else { return }
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()

        let text = "+\(count)" as NSString
        let size = text.size(withAttributes: Self.textAttrs)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: ceil(size.width),
            height: ceil(size.height)
        )
        text.draw(in: rect, withAttributes: Self.textAttrs)
    }

    private static let textAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]
}
