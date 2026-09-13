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
    private var pulse: CGFloat = 1
    private var pulseTimer: Timer?

    var isCelebrating: Bool {
        celebratingUntil.map { $0 > Date() } ?? false
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
        pulseTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.isCelebrating else {
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
        let tint = celebrating
            ? NSColor(srgbRed: 0.22, green: 0.95, blue: 0.52, alpha: 1)
            : Self.tint(percent: chip.percent)
        let pad = bounds.insetBy(dx: 5, dy: 3)

        if celebrating {
            let glow = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            tint.withAlphaComponent(0.18 + 0.22 * pulse).setFill()
            glow.fill()
        }

        drawHeader(in: pad, tint: tint, celebrating: celebrating)
        drawBar(in: pad, tint: tint, celebrating: celebrating)
    }

    /// Name (truncated) + tag on the left, countdown on the right. Time stays;
    /// the name yields first, then the countdown shortens to `5h` / `3d`.
    private func drawHeader(in pad: NSRect, tint: NSColor, celebrating: Bool) {
        let name = chip.shortName as NSString
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: celebrating ? .bold : .medium),
            .foregroundColor: celebrating ? tint : NSColor.white.withAlphaComponent(0.92),
        ]

        let tagSize = tag?.size(withAttributes: tagAttrs) ?? .zero
        let tagReserve: CGFloat = tag == nil ? 0 : tagSize.width + 8
        let fullTime = (celebrating ? "RESET" : chip.countdownText) as NSString
        let compactTime = (celebrating ? "RESET" : chip.compactCountdownText) as NSString
        let fullTimeW = fullTime.size(withAttributes: timeAttrs).width
        let compactTimeW = compactTime.size(withAttributes: timeAttrs).width

        let minName: CGFloat = 20
        let gap: CGFloat = 4
        let time: NSString
        let timeW: CGFloat
        if celebrating || pad.width >= tagReserve + gap + fullTimeW + minName {
            time = fullTime
            timeW = fullTimeW
        } else {
            time = compactTime
            timeW = compactTimeW
        }

        var x = pad.minX
        let nameBudget = pad.width - tagReserve - gap - timeW
        if nameBudget >= 18 {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            var attrs = nameAttrs
            attrs[.paragraphStyle] = para
            let drawW = min(name.size(withAttributes: nameAttrs).width, nameBudget)
            name.draw(in: NSRect(x: x, y: pad.minY + 1, width: drawW, height: 13), withAttributes: attrs)
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

    private func drawBar(in pad: NSRect, tint: NSColor, celebrating: Bool) {
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

        if !celebrating, chip.percent >= 5, let pace = chip.paceFraction {
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
