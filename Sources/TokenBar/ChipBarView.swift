import AppKit

/// Compact Touch Bar chip: name + 5h/7d tag, countdown, colored usage line.
final class ChipBarView: NSButton {
    var chip: Chip {
        didSet { needsDisplay = true }
    }

    private var celebratingUntil: Date?
    private var pulse: CGFloat = 1
    private var pulseTimer: Timer?

    var isCelebrating: Bool {
        celebratingUntil.map { $0 > Date() } ?? false
    }

    init(chip: Chip) {
        self.chip = chip
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 30))
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        isEnabled = true
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

    override var intrinsicContentSize: NSSize { NSSize(width: 128, height: 30) }
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

        let name = chip.shortName as NSString
        let tag = chip.windowTag
        let time = (celebrating ? "RESET" : chip.countdownText) as NSString

        let nameFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let tagFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: NSColor.white,
        ]
        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: tagFont,
            .foregroundColor: tint,
        ]
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: celebrating ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold) : timeFont,
            .foregroundColor: celebrating ? tint : NSColor.white.withAlphaComponent(0.92),
        ]

        let timeSize = time.size(withAttributes: timeAttrs)
        let timePoint = NSPoint(x: pad.maxX - timeSize.width, y: pad.minY + 1)
        time.draw(at: timePoint, withAttributes: timeAttrs)

        var x = pad.minX
        let nameSize = name.size(withAttributes: nameAttrs)
        name.draw(at: NSPoint(x: x, y: pad.minY + 1), withAttributes: nameAttrs)
        x += nameSize.width + 4

        if let tag {
            let tagString = tag as NSString
            let tagSize = tagString.size(withAttributes: tagAttrs)
            let pill = NSRect(
                x: x - 1,
                y: pad.minY,
                width: tagSize.width + 6,
                height: 13
            )
            let pillPath = NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3)
            tint.withAlphaComponent(0.22).setFill()
            pillPath.fill()
            tagString.draw(
                at: NSPoint(x: pill.minX + 3, y: pad.minY + 1),
                withAttributes: tagAttrs
            )
        }

        let percentText = (celebrating ? "" : String(format: "%.0f%%", chip.percent)) as NSString
        let percentAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: tint,
        ]
        let percentSize = percentText.size(withAttributes: percentAttrs)
        let percentGap: CGFloat = percentSize.width > 0 ? 5 : 0

        let barHeight: CGFloat = 4
        let barRect = NSRect(
            x: pad.minX,
            y: pad.maxY - barHeight - 1,
            width: max(20, pad.width - percentSize.width - percentGap),
            height: barHeight
        )
        let track = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
        NSColor.white.withAlphaComponent(0.16).setFill()
        track.fill()

        let fillFraction = celebrating ? CGFloat(pulse) : CGFloat(min(max(chip.percent, 0), 100) / 100)
        let fillWidth = max(barHeight, barRect.width * fillFraction)
        let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
        tint.setFill()
        fill.fill()

        if percentSize.width > 0 {
            percentText.draw(
                at: NSPoint(
                    x: pad.maxX - percentSize.width,
                    y: barRect.minY - 4
                ),
                withAttributes: percentAttrs
            )
        }

        // TokenTracker "how much can be used by now" tick (even-burn pace).
        if !celebrating, chip.percent >= 5, let pace = chip.paceFraction {
            let x = barRect.minX + barRect.width * CGFloat(pace)
            let tick = NSRect(
                x: x - 0.75,
                y: barRect.minY - 2.5,
                width: 1.5,
                height: barHeight + 5
            )
            tint.setFill()
            NSBezierPath(rect: tick).fill()
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
