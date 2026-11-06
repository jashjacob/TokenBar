import AppKit
import QuartzCore

/// One Touch Bar item that owns Today + every selected chip and lays them
/// out from the real item width, so macOS cannot hide the last card.
final class TouchBarStripView: NSView {
    var onChipTap: ((String) -> Void)?
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
    /// Stays set after the pan ends, so the finger-up that follows a slide is not a tap.
    private var rowMoved = false
    private var laidOutIDs: [String] = []
    private var loggedHidden = -1
    /// A reorder in progress. Core Animation moves the cached chips.
    private var trade: Trade?
    private var tradeGeneration = 0

    /// Long enough to follow a chip coming from the far end.
    private static let tradeDuration: TimeInterval = 1.0

    private struct Trade {
        let ids: [String]
        var toX: [String: CGFloat]
        var toW: [String: CGFloat]
    }

    override var isFlipped: Bool { true }
    /// Width comes from the Touch Bar slot. A fixed 680 makes macOS scroll the
    /// whole bar and draw its own chevron over the system controls.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

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
    func showBanner(_ text: String, tone: BannerTone = .pace, completion: @escaping () -> Void) {
        marqueeUp = true
        addSubview(marquee)
        marquee.show(text, tone: tone) { [weak self] in
            guard let self else { return }
            self.marqueeUp = false
            self.marquee.isHidden = true
            self.needsLayout = true
            completion()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if marqueeUp {
            if trade != nil { stopTrade(atEnd: false) }
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
    /// A reorder slides the already-drawn chips. A finger-drag, a row already
    /// slid off the left edge, or a second reorder cuts to the new slots.
    private func layoutChips(in clipW: CGFloat, height: CGFloat, spacing: CGFloat) {
        let ids = chips.map(\.id)
        guard !chips.isEmpty, clipW > 1 else {
            leadingHint.isHidden = true
            trailingHint.isHidden = true
            if trade != nil { stopTrade(atEnd: false) }
            return
        }
        let widths = ChipLayout.sized(chips, budget: clipW)
        let row = chips.reduce(CGFloat(0)) { $0 + (widths[$1.id] ?? 0) }
            + CGFloat(max(0, chips.count - 1)) * spacing
        let overflow = row - clipW
        let canScroll = overflow > 12

        if var trade, trade.ids == ids {
            let frames = chipFrames(widths: widths, spacing: spacing, height: height)
            for (id, frame) in frames {
                trade.toX[id] = frame.minX
                trade.toW[id] = frame.width
            }
            self.trade = trade
            for chip in chips { chipViews[chip.id]?.isHidden = false }
            updateEdges(clipW: clipW, height: height, spacing: spacing, overflow: overflow, canScroll: canScroll, widths: widths)
            return
        }

        let orderChanged = !laidOutIDs.isEmpty && ids != laidOutIDs
        let interrupting = trade != nil
        if interrupting { stopTrade(atEnd: false) }
        let scrolled = chipOffset > 0.5
        let glide = orderChanged && !dragActive && !scrolled && !interrupting
        if orderChanged && !glide { chipOffset = 0 }
        chipOffset = canScroll ? min(max(0, chipOffset), overflow) : 0

        let frames = chipFrames(widths: widths, spacing: spacing, height: height)
        if glide, startTrade(to: frames, ids: ids) {
            laidOutIDs = ids
            for chip in chips { chipViews[chip.id]?.isHidden = false }
            updateEdges(clipW: clipW, height: height, spacing: spacing, overflow: overflow, canScroll: canScroll, widths: widths)
            return
        }

        laidOutIDs = ids
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, frame) in frames {
            guard let view = chipViews[id] else { continue }
            view.isHidden = false
            view.layoutWidth = frame.width
            view.frame = frame
        }
        CATransaction.commit()
        updateEdges(clipW: clipW, height: height, spacing: spacing, overflow: overflow, canScroll: canScroll, widths: widths)
    }

    private func chipFrames(widths: [String: CGFloat], spacing: CGFloat, height: CGFloat) -> [String: NSRect] {
        var cursor = -chipOffset
        var frames: [String: NSRect] = [:]
        for chip in chips {
            let w = widths[chip.id] ?? 0
            if w >= 1 {
                frames[chip.id] = NSRect(x: cursor, y: 0, width: w, height: height)
            }
            cursor += w + spacing
        }
        return frames
    }

    /// Slides chips that already have a slot. A chip that just appeared sits in its new slot.
    /// Width is applied once. The move itself is the cached picture, so the text is not redrawn each step.
    private func startTrade(to targets: [String: NSRect], ids: [String]) -> Bool {
        var fromX: [String: CGFloat] = [:]
        var toX: [String: CGFloat] = [:]
        var toW: [String: CGFloat] = [:]
        var moved = false
        var newcomers: [(ChipBarView, NSRect)] = []
        for id in ids {
            guard let target = targets[id], let view = chipViews[id] else { continue }
            let had = laidOutIDs.contains(id) && view.frame.width >= 1
            let source = had ? view.frame : target
            fromX[id] = source.minX
            toX[id] = target.minX
            toW[id] = target.width
            if had && abs(source.minX - target.minX) > 0.5 { moved = true }
            if !had { newcomers.append((view, target)) }
        }
        guard moved else { return false }
        tradeGeneration += 1
        trade = Trade(ids: ids, toX: toX, toW: toW)
        liftFrontRunner(fromX: fromX, toX: toX)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (view, target) in newcomers {
            view.layoutWidth = target.width
            view.frame = target
        }
        CATransaction.commit()
        let generation = tradeGeneration
        DispatchQueue.main.async { [weak self] in
            self?.runTradeAnimation(generation: generation)
        }
        Log.line("chips traded")
        return true
    }

    /// Moves each cached chip to its new x. Drawing happens only if the width changed.
    private func runTradeAnimation(generation: Int) {
        guard tradeGeneration == generation, let trade else { return }
        let height = chipClip.bounds.height > 1 ? chipClip.bounds.height : 30
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, view) in chipViews {
            guard let w = trade.toW[id], w >= 1 else { continue }
            guard abs(view.frame.width - w) > 0.5 else { continue }
            view.layoutWidth = w
            view.frame = NSRect(x: view.frame.minX, y: 0, width: w, height: height)
            view.needsDisplay = true
        }
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.tradeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (id, view) in chipViews {
                guard let tx = trade.toX[id], abs(view.frame.minX - tx) > 0.5 else { continue }
                view.animator().setFrameOrigin(NSPoint(x: tx, y: 0))
            }
        }, completionHandler: { [weak self] in
            guard let self, self.tradeGeneration == generation else { return }
            self.stopTrade(atEnd: true)
            self.needsLayout = true
        })
    }

    /// The chip heading furthest toward the front draws above the ones it passes.
    private func liftFrontRunner(fromX: [String: CGFloat], toX: [String: CGFloat]) {
        let ranked = chips.sorted { lhs, rhs in
            let dl = (toX[lhs.id] ?? 0) - (fromX[lhs.id] ?? 0)
            let dr = (toX[rhs.id] ?? 0) - (fromX[rhs.id] ?? 0)
            return dl > dr
        }
        for chip in ranked {
            guard let view = chipViews[chip.id] else { continue }
            chipClip.addSubview(view)
        }
    }

    private func stopTrade(atEnd: Bool) {
        tradeGeneration += 1
        let snapshot = trade
        trade = nil
        let height = chipClip.bounds.height > 1 ? chipClip.bounds.height : 30
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, view) in chipViews {
            view.layer?.removeAllAnimations()
            guard atEnd, let snapshot, let x = snapshot.toX[id], let w = snapshot.toW[id], w >= 1 else { continue }
            view.layoutWidth = w
            view.frame = NSRect(x: x, y: 0, width: w, height: height)
        }
        CATransaction.commit()
    }

    private func updateEdges(
        clipW: CGFloat,
        height: CGFloat,
        spacing: CGFloat,
        overflow: CGFloat,
        canScroll: Bool,
        widths: [String: CGFloat]
    ) {
        var cursor = -chipOffset
        var hiddenNames: [String] = []
        if canScroll {
            for chip in chips {
                let w = widths[chip.id] ?? 0
                if cursor + w > clipW + 1 {
                    hiddenNames.append(chip.label)
                }
                cursor += w + spacing
            }
        }

        let moreOnRight = overflow - chipOffset > 12
        trailingHint.count = hiddenNames.count
        trailingHint.names = hiddenNames
        trailingHint.alphaValue = dimmed ? 0.4 : 1
        trailingHint.isHidden = !moreOnRight
        trailingHint.frame = NSRect(
            x: bounds.width - EdgeHint.arrowWidth,
            y: 0,
            width: EdgeHint.arrowWidth,
            height: height
        )

        let canSlideBack = chipOffset > 0.5
        leadingHint.alphaValue = dimmed ? 0.4 : 1
        leadingHint.isHidden = !canSlideBack
        leadingHint.frame = NSRect(x: chipClip.frame.minX, y: 0, width: EdgeHint.arrowWidth, height: height)
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
        rowMoved = false
    }

    private func dragMoved(to x: CGFloat, chip: ChipBarView?) {
        let dx = x - dragOriginX
        if abs(dx) > 8 {
            if trade != nil { stopTrade(atEnd: true) }
            dragPastSlop = true
            rowMoved = true
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
        } else if phase == 3 {
            // The finger slid off the chip. The drag continues, and this is not a tap.
            chip?.suppressNextClick()
            if !dragPastSlop {
                dragActive = false
            }
        } else {
            let open = !dragPastSlop && !rowMoved
            dragPastSlop = false
            dragActive = false
            if open, let chip {
                chip.suppressNextClick()
                onChipTap?(chip.chip.id)
            }
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

    static let arrowWidth: CGFloat = 22

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
            NSColor.black.withAlphaComponent(0.15),
            NSColor.black.withAlphaComponent(0.88),
        ])
        gradient?.draw(from: from, to: to, options: [])

        let text = (side == .leading ? "‹" : "›") as NSString
        let size = text.size(withAttributes: Self.textAttrs)
        let rect = NSRect(
            x: side == .leading ? 2 : bounds.width - size.width - 2,
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

enum BannerTone {
    case pace
    case leftover
}

/// One sentence scrolling across the full Touch Bar, then the chips come back.
private final class MarqueeBanner: NSView {
    private var message = ""
    private var tone: BannerTone = .pace
    private var onFinished: (() -> Void)?
    private var timer: Timer?
    private var began: Date?
    private var runDuration: TimeInterval = 8

    override var isFlipped: Bool { true }

    func show(_ text: String, tone: BannerTone = .pace, completion: @escaping () -> Void) {
        message = text
        self.tone = tone
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
                let speed: CGFloat = self.tone == .leftover ? 60 : 85
                let seconds = min(14, max(7, distance / speed))
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
        fill.setFill()
        bounds.fill()
        accent.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: tone == .leftover ? 1 : 2).fill()

        guard began != nil else { return }
        let elapsed = Date().timeIntervalSince(began ?? Date())
        let progress = min(1, elapsed / runDuration)
        let width = textWidth
        let travel = bounds.width + width
        let x = bounds.width - travel * CGFloat(progress)
        let text = message as NSString
        let size = text.size(withAttributes: attrs)
        let rect = NSRect(
            x: x,
            y: (bounds.height - size.height) / 2,
            width: ceil(size.width),
            height: ceil(size.height)
        )
        text.draw(in: rect, withAttributes: attrs)
    }

    private var textWidth: CGFloat {
        ceil((message as NSString).size(withAttributes: attrs).width)
    }

    private var fill: NSColor {
        switch tone {
        case .pace:
            return NSColor(srgbRed: 0.16, green: 0.09, blue: 0.02, alpha: 1)
        case .leftover:
            return NSColor(srgbRed: 0.20, green: 0.08, blue: 0.16, alpha: 1)
        }
    }

    private var accent: NSColor {
        switch tone {
        case .pace:
            return NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)
        case .leftover:
            return NSColor(srgbRed: 0.93, green: 0.55, blue: 0.74, alpha: 0.85)
        }
    }

    private var attrs: [NSAttributedString.Key: Any] {
        switch tone {
        case .pace:
            return [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: 1.0, green: 0.86, blue: 0.55, alpha: 1),
            ]
        case .leftover:
            return [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.98, green: 0.84, blue: 0.92, alpha: 1),
            ]
        }
    }
}
