import AppKit

/// Compact Touch Bar chip: name + 5h/7d tag, countdown, colored usage line.
final class ChipBarView: NSButton {
    var chip: Chip {
        didSet { needsDisplay = true }
    }
    var layoutWidth: CGFloat = 128 {
        didSet {
            guard oldValue != layoutWidth else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var celebratingUntil: Date?
    private var pacingUntil: Date?
    private var paceLabel = ""
    private var pulse: CGFloat = 1
    private var pulseTimer: Timer?

    var isCelebrating: Bool {
        celebratingUntil.map { $0 > Date() } ?? false
    }

    var isPacing: Bool {
        pacingUntil.map { $0 > Date() } ?? false
    }

    init(chip: Chip, layoutWidth: CGFloat = 128) {
        self.chip = chip
        self.layoutWidth = layoutWidth
        super.init(frame: NSRect(x: 0, y: 0, width: layoutWidth, height: 30))
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        isEnabled = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    func playReset() {
        celebratingUntil = Date().addingTimeInterval(2.5)
        startPulse()
    }

    /// Amber repaint for five seconds. The countdown slot shows `label` (the run-out estimate).
    func playPace(label: String) {
        paceLabel = label
        pacingUntil = Date().addingTimeInterval(5)
        startPulse()
    }

    private func startPulse() {
        pulseTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.isCelebrating || self.isPacing else {
                timer.invalidate()
                self.pulseTimer = nil
                self.needsDisplay = true
                return
            }
            self.pulse = 0.55 + 0.45 * abs(sin(Date().timeIntervalSince1970 * 9))
            self.needsDisplay = true
        }
        pulseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: layoutWidth, height: 30) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let celebrating = isCelebrating
        let pacing = isPacing && !celebrating
        let tint: NSColor
        if celebrating {
            tint = NSColor(srgbRed: 0.22, green: 0.95, blue: 0.52, alpha: 1)
        } else if pacing {
            tint = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)
        } else {
            tint = Self.tint(percent: chip.percent)
        }
        let pad = bounds.insetBy(dx: 5, dy: 3)

        if celebrating || pacing {
            let glow = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            let alpha = celebrating ? (0.18 + 0.22 * pulse) : (0.34 + 0.28 * pulse)
            tint.withAlphaComponent(alpha).setFill()
            glow.fill()
        }

        if chip.showsStackedFull, !celebrating, !pacing {
            drawStackedFull(in: pad, tint: tint)
            return
        }
        drawHeader(in: pad, tint: tint, celebrating: celebrating, pacing: pacing)
        drawBar(in: pad, tint: tint, celebrating: celebrating, pacing: pacing)
    }

    /// Full 5h card: `Kimi 5h` on top, the countdown under it. No bar, no 100%.
    private func drawStackedFull(in pad: NSRect, tint: NSColor) {
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: tint,
        ]
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: tint,
        ]
        let tag = chip.windowTag.map { $0 as NSString }
        let tagSize = tag?.size(withAttributes: tagAttrs) ?? .zero
        let tagReserve: CGFloat = tag == nil ? 0 : tagSize.width + 8
        let shown = Self.name(for: chip, budget: max(0, pad.width - tagReserve), attrs: nameAttrs)
        let shownW = shown.size(withAttributes: nameAttrs).width
        var x = pad.minX
        if shownW >= 1 {
            shown.draw(in: NSRect(x: x, y: pad.minY, width: min(shownW, pad.width - tagReserve), height: 12), withAttributes: nameAttrs)
            x += min(shownW, pad.width - tagReserve) + 3
        }
        if let tag {
            let pill = NSRect(x: x - 1, y: pad.minY, width: tagSize.width + 6, height: 12)
            tint.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
            tag.draw(at: NSPoint(x: pill.minX + 3, y: pad.minY), withAttributes: tagAttrs)
        }
        let time = chip.countdownText as NSString
        let timeW = time.size(withAttributes: timeAttrs).width
        time.draw(at: NSPoint(x: pad.midX - timeW / 2, y: pad.minY + 13), withAttributes: timeAttrs)
    }

    /// Name (truncated) + tag on the left, countdown on the right. Time stays;
    /// the name yields first, then the countdown shortens to `5h` / `3d`.
    /// Full name if it fits; CmdCode/OpenCode become CmdC/OC. Claude and friends stay whole.
    private static func name(for chip: Chip, budget: CGFloat, attrs: [NSAttributedString.Key: Any]) -> NSString {
        let full = chip.shortName as NSString
        if full.size(withAttributes: attrs).width <= budget { return full }
        if let compact = chip.compactName { return compact as NSString }
        return full
    }

    private func drawHeader(in pad: NSRect, tint: NSColor, celebrating: Bool, pacing: Bool) {
        let tag = chip.windowTag.map { $0 as NSString }
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: tint,
        ]
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: celebrating || pacing ? .bold : .medium),
            .foregroundColor: celebrating || pacing ? tint : NSColor.white.withAlphaComponent(0.92),
        ]

        let tagSize = tag?.size(withAttributes: tagAttrs) ?? .zero
        let tagReserve: CGFloat = tag == nil ? 0 : tagSize.width + 8
        let shownTime = celebrating ? "RESET" : (pacing ? paceLabel : chip.countdownText)
        let shownCompact = celebrating ? "RESET" : (pacing ? paceLabel : chip.compactCountdownText)
        let fullTime = shownTime as NSString
        let compactTime = shownCompact as NSString
        let fullTimeW = fullTime.size(withAttributes: timeAttrs).width
        let compactTimeW = compactTime.size(withAttributes: timeAttrs).width

        let fullNameW = (chip.shortName as NSString).size(withAttributes: nameAttrs).width
        let minName: CGFloat = chip.compactName == nil ? fullNameW : 16
        let gap: CGFloat = 4
        let time: NSString
        let timeW: CGFloat
        if celebrating || pacing || pad.width >= tagReserve + gap + fullTimeW + minName {
            time = fullTime
            timeW = fullTimeW
        } else {
            time = compactTime
            timeW = compactTimeW
        }

        var x = pad.minX
        let nameBudget = max(0, pad.width - tagReserve - gap - timeW)
        let shown = Self.name(for: chip, budget: nameBudget, attrs: nameAttrs)
        let shownW = shown.size(withAttributes: nameAttrs).width
        let drawW = chip.compactName == nil ? shownW : min(shownW, nameBudget)
        if drawW >= 1 {
            var attrs = nameAttrs
            if chip.compactName != nil {
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byTruncatingTail
                attrs[.paragraphStyle] = para
            }
            shown.draw(in: NSRect(x: x, y: pad.minY + 1, width: drawW, height: 13), withAttributes: attrs)
            x += drawW + 3
        }

        if let tag {
            let pill = NSRect(x: x - 1, y: pad.minY, width: tagSize.width + 6, height: 13)
            tint.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
            tag.draw(at: NSPoint(x: pill.minX + 3, y: pad.minY + 1), withAttributes: tagAttrs)
        }

        time.draw(at: NSPoint(x: pad.maxX - timeW, y: pad.minY + 1), withAttributes: timeAttrs)
    }

    private func drawBar(in pad: NSRect, tint: NSColor, celebrating: Bool, pacing: Bool) {
        let percentText = (celebrating ? "" : String(format: "%.0f%%", chip.percent)) as NSString
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: tint,
        ]
        let percentSize = percentText.size(withAttributes: percentAttrs)
        let percentGap: CGFloat = percentSize.width > 0 ? 4 : 0
        let barHeight: CGFloat = 4
        let barRect = NSRect(
            x: pad.minX,
            y: pad.maxY - barHeight - 1,
            width: max(16, pad.width - percentSize.width - percentGap),
            height: barHeight
        )
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()

        let fillFraction = celebrating ? CGFloat(pulse) : CGFloat(min(max(chip.percent, 0), 100) / 100)
        let fillWidth = max(barHeight, barRect.width * fillFraction)
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height), xRadius: 2, yRadius: 2).fill()

        if percentSize.width > 0 {
            percentText.draw(
                at: NSPoint(x: pad.maxX - percentSize.width, y: barRect.minY - 4),
                withAttributes: percentAttrs
            )
        }

        if !celebrating, !pacing, chip.percent >= 5, let pace = chip.paceFraction {
            let tickX = barRect.minX + barRect.width * CGFloat(pace)
            tint.setFill()
            NSBezierPath(rect: NSRect(x: tickX - 0.75, y: barRect.minY - 2.5, width: 1.5, height: barHeight + 5)).fill()
        }
    }

    static func tint(percent: Double) -> NSColor {
        switch ChipColor.band(percent) {
        case "red":
            return NSColor(srgbRed: 1.0, green: 0.33, blue: 0.33, alpha: 1)
        case "amber":
            return NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)
        default:
            return NSColor(srgbRed: 0.22, green: 0.84, blue: 0.50, alpha: 1)
        }
    }
}
