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
    private let chipClip = ChipClip(frame: .zero)
    private let leadingHint = EdgeHint(side: .leading)
    private let trailingHint = EdgeHint(side: .trailing)
    private let marquee = MarqueeBanner()
    private var marqueeUp = false
    private var chipOffset: CGFloat = 0
    private var dragOriginX: CGFloat = 0
    private var dragOriginOffset: CGFloat = 0
    private var dragPastSlop = false
    private var dragActive = false
    private var laidOutIDs: [String] = []
    private var loggedHidden = -1

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 680, height: 30) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        allowedTouchTypes = [.direct]
        let pan = NSPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [.direct]
        pan.delaysPrimaryMouseButtonEvents = true
        addGestureRecognizer(pan)
        chipClip.wantsLayer = true
        chipClip.layer?.masksToBounds = true
        addSubview(chipClip)
        leadingHint.isHidden = true
        trailingHint.isHidden = true
        addSubview(leadingHint)
        addSubview(trailingHint)
        marquee.isHidden = true
        addSubview(marquee)
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

    /// Covers the whole strip with one scrolling sentence, then returns to the chips.
    func showBanner(_ text: String, completion: @escaping () -> Void) {
        marqueeUp = true
        addSubview(marquee)
        marquee.show(text) { [weak self] in
            guard let self else { return }
            self.marqueeUp = false
            self.marquee.isHidden = true
            self.needsLayout = true
            completion()
        }
        needsLayout = true
    }

    @discardableResult
    func playPace(_ labels: [String: String]) -> Bool {
        var painted = false
        for (id, label) in labels {
            guard let view = chipViews[id] else { continue }
            view.isHidden = false
            view.playPace(label: label)
            painted = true
        }
        return painted
    }

    override func layout() {
        super.layout()
        if marqueeUp {
            for view in chipViews.values { view.isHidden = true }
            tokenView?.isHidden = true
            costView?.isHidden = true
            chipClip.isHidden = true
            leadingHint.isHidden = true
            trailingHint.isHidden = true
            marquee.isHidden = false
            marquee.frame = bounds
            return
        }
        chipClip.isHidden = false
        tokenView?.isHidden = false
        costView?.isHidden = false
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

        let clipW = max(0, bounds.width - x)
        chipClip.frame = NSRect(x: x, y: 0, width: clipW, height: height)
        layoutChips(in: clipW, height: height, spacing: spacing)
    }

    /// Every checked chip stays in one row. Today stays put. A finger drag
    /// slides the row, and an arrow stays on the edge while any chip is past it.
    private func layoutChips(in clipW: CGFloat, height: CGFloat, spacing: CGFloat) {
        let ids = chips.map(\.id)
        if ids != laidOutIDs {
            laidOutIDs = ids
            chipOffset = 0
        }
        guard !chips.isEmpty, clipW > 1 else {
            leadingHint.isHidden = true
            trailingHint.isHidden = true
            return
        }
        let widths = ChipLayout.sized(chips, budget: clipW)
        let row = chips.reduce(CGFloat(0)) { $0 + (widths[$1.id] ?? 0) }
            + CGFloat(max(0, chips.count - 1)) * spacing
        let overflow = row - clipW
        let canScroll = overflow > 12
        chipOffset = canScroll ? min(max(0, chipOffset), overflow) : 0

        var cursor = -chipOffset
        var hiddenNames: [String] = []
        for chip in chips {
            let w = widths[chip.id] ?? 0
            guard w >= 1, let view = chipViews[chip.id] else { continue }
            view.isHidden = false
            view.layoutWidth = w
            view.frame = NSRect(x: cursor, y: 0, width: w, height: height)
            if canScroll, cursor + w > clipW + 1 {
                hiddenNames.append(chip.label)
            }
            cursor += w + spacing
        }

        let trailingW = EdgeHint.width(count: hiddenNames.count, side: .trailing)
        trailingHint.count = hiddenNames.count
        trailingHint.names = hiddenNames
        trailingHint.alphaValue = dimmed ? 0.4 : 1
        trailingHint.isHidden = hiddenNames.isEmpty
        trailingHint.frame = NSRect(
            x: bounds.width - trailingW,
            y: 0,
            width: trailingW,
            height: height
        )

        let canSlideBack = chipOffset > 0.5
        leadingHint.alphaValue = dimmed ? 0.4 : 1
        leadingHint.isHidden = !canSlideBack
        leadingHint.frame = NSRect(x: chipClip.frame.minX, y: 0, width: EdgeHint.leadingWidth, height: height)
        addSubview(leadingHint)
        addSubview(trailingHint)

        if hiddenNames.count != loggedHidden {
            loggedHidden = hiddenNames.count
            if hiddenNames.isEmpty {
                Log.line("strip fits")
            } else {
                Log.line("strip scrolls, \(hiddenNames.count) past the right edge: \(hiddenNames.joined(separator: ", "))")
            }
        }
    }

    private func dragBegan(at x: CGFloat) {
        guard !dragActive else { return }
        dragActive = true
        dragOriginX = x
        dragOriginOffset = chipOffset
        dragPastSlop = false
    }

    private func dragMoved(to x: CGFloat, chip: ChipBarView?) {
        let dx = x - dragOriginX
        if abs(dx) > 8 {
            dragPastSlop = true
            chip?.suppressNextClick()
        }
        guard dragPastSlop else { return }
        chipOffset = dragOriginOffset - dx
        needsLayout = true
    }

    private func handleTouch(_ event: NSEvent, in view: NSView, phase: Int, chip: ChipBarView?) {
        guard let touch = event.touches(for: view).first else { return }
        let x = view.convert(touch.location(in: view), to: self).x
        if phase == 0 {
            dragBegan(at: x)
        } else if phase == 1 {
            dragMoved(to: x, chip: chip)
        } else {
            dragPastSlop = false
            dragActive = false
        }
    }

    override func touchesBegan(with event: NSEvent) {
        handleTouch(event, in: self, phase: 0, chip: nil)
    }

    override func touchesMoved(with event: NSEvent) {
        handleTouch(event, in: self, phase: 1, chip: nil)
    }

    override func touchesEnded(with event: NSEvent) {
        handleTouch(event, in: self, phase: 2, chip: nil)
    }

    override func touchesCancelled(with event: NSEvent) {
        handleTouch(event, in: self, phase: 3, chip: nil)
    }

    func relayTouch(_ event: NSEvent, phase: Int) {
        handleTouch(event, in: chipClip, phase: phase, chip: nil)
    }

    @objc private func panned(_ pan: NSPanGestureRecognizer) {
        let x = pan.location(in: self).x
        switch pan.state {
        case .began:
            dragBegan(at: x)
        case .changed:
            let hit = chipViews.values.first { view in
                let local = view.convert(pan.location(in: self), from: self)
                return view.bounds.contains(local)
            }
            dragMoved(to: x, chip: hit)
        default:
            dragPastSlop = false
            dragActive = false
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
                view.alphaValue = dimmed ? 0.4 : 1
            } else {
                let view = ChipBarView(chip: chip, layoutWidth: ChipLayout.contentWidth(for: chip))
                view.alphaValue = dimmed ? 0.4 : 1
                view.target = self
                view.action = #selector(chipTapped)
                view.onStripTouch = { [weak self, weak view] event, phase in
                    guard let self, let view else { return }
                    self.handleTouch(event, in: view, phase: phase, chip: view)
                }
                chipClip.addSubview(view)
                chipViews[chip.id] = view
            }
            if let view = chipViews[chip.id], view.superview !== chipClip {
                view.removeFromSuperview()
                chipClip.addSubview(view)
            }
        }
    }

    @objc private func chipTapped() { onChipTap?() }
    @objc private func todayTapped() { onTodayTap?() }
}

/// Clips the chip row and forwards a finger drag to the strip.
private final class ChipClip: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.direct]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func touchesBegan(with event: NSEvent) {
        (superview as? TouchBarStripView)?.relayTouch(event, phase: 0)
    }

    override func touchesMoved(with event: NSEvent) {
        (superview as? TouchBarStripView)?.relayTouch(event, phase: 1)
    }

    override func touchesEnded(with event: NSEvent) {
        (superview as? TouchBarStripView)?.relayTouch(event, phase: 2)
    }

    override func touchesCancelled(with event: NSEvent) {
        (superview as? TouchBarStripView)?.relayTouch(event, phase: 3)
    }
}

/// Arrow on the end of the chip row while sliding would reveal more.
private final class EdgeHint: NSView {
    enum Side { case leading, trailing }

    static let leadingWidth: CGFloat = 18

    let side: Side
    var count = 0 {
        didSet {
            guard oldValue != count else { return }
            toolTip = names.isEmpty ? nil : names.joined(separator: "\n")
            needsDisplay = true
        }
    }
    var names: [String] = [] {
        didSet { toolTip = names.isEmpty ? nil : names.joined(separator: "\n") }
    }

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Touches pass through to the chip underneath so the row still slides.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func width(count: Int, side: Side) -> CGFloat {
        if side == .leading { return leadingWidth }
        let text = "\(count)›" as NSString
        return ceil(text.size(withAttributes: Self.textAttrs).width + 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let from: NSPoint
        let to: NSPoint
        if side == .trailing {
            from = NSPoint(x: bounds.minX, y: bounds.midY)
            to = NSPoint(x: bounds.maxX, y: bounds.midY)
        } else {
            from = NSPoint(x: bounds.maxX, y: bounds.midY)
            to = NSPoint(x: bounds.minX, y: bounds.midY)
        }
        let gradient = NSGradient(colors: [
            NSColor.black.withAlphaComponent(0),
            NSColor.black.withAlphaComponent(0.78),
        ])
        gradient?.draw(from: from, to: to, options: [])

        let text = (side == .leading ? "‹" : "\(count)›") as NSString
        let size = text.size(withAttributes: Self.textAttrs)
        let rect = NSRect(
            x: side == .leading ? 1 : bounds.width - size.width - 3,
            y: (bounds.height - size.height) / 2,
            width: ceil(size.width),
            height: ceil(size.height)
        )
        text.draw(in: rect, withAttributes: Self.textAttrs)
    }

    private static let textAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
}

/// One sentence scrolling across the full Touch Bar, then the chips come back.
private final class MarqueeBanner: NSView {
    private var message = ""
    private var onFinished: (() -> Void)?
    private var timer: Timer?
    private var began: Date?
    private var runDuration: TimeInterval = 8

    override var isFlipped: Bool { true }

    func show(_ text: String, completion: @escaping () -> Void) {
        message = text
        onFinished = completion
        began = nil
        isHidden = false
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.bounds.width > 1 else { return }
            if self.began == nil {
                self.began = Date()
                let distance = self.bounds.width + self.textWidth
                let seconds = min(11, max(6, distance / 85))
                self.runDuration = seconds
            }
            if Date().timeIntervalSince(self.began ?? Date()) >= self.runDuration {
                timer.invalidate()
                self.timer = nil
                let done = self.onFinished
                self.onFinished = nil
                done?()
                return
            }
            self.needsDisplay = true
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.16, green: 0.09, blue: 0.02, alpha: 1).setFill()
        bounds.fill()
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()

        guard began != nil else { return }
        let elapsed = Date().timeIntervalSince(began ?? Date())
        let progress = min(1, elapsed / runDuration)
        let width = textWidth
        let travel = bounds.width + width
        let x = bounds.width - travel * CGFloat(progress)
        let text = message as NSString
        let size = text.size(withAttributes: Self.attrs)
        let rect = NSRect(
            x: x,
            y: (bounds.height - size.height) / 2,
            width: ceil(size.width),
            height: ceil(size.height)
        )
        text.draw(in: rect, withAttributes: Self.attrs)
    }

    private var textWidth: CGFloat {
        ceil((message as NSString).size(withAttributes: Self.attrs).width)
    }

    private static let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 1.0, green: 0.86, blue: 0.55, alpha: 1),
    ]
}
