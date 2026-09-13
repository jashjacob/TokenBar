import AppKit

enum TodayMetric {
    case tokens
    case cost

    var caption: String {
        switch self {
        case .tokens: return "Today"
        case .cost: return "Cost"
        }
    }

    var preferenceID: String {
        switch self {
        case .tokens: return ChipPreferences.todayTokensID
        case .cost: return ChipPreferences.todayCostID
        }
    }

    var itemID: NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("com.jashjacob.TokenBar.\(preferenceID)")
    }
}

/// Compact Touch Bar chip for one today metric: tokens or dollars.
final class TodayBarView: NSButton {
    var usage: TodayUsage {
        didSet { needsDisplay = true }
    }
    let metric: TodayMetric
    var layoutWidth: CGFloat = 76 {
        didSet {
            guard oldValue != layoutWidth else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    init(usage: TodayUsage, metric: TodayMetric, layoutWidth: CGFloat = 76) {
        self.usage = usage
        self.metric = metric
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: layoutWidth, height: 30) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let pad = bounds.insetBy(dx: 4, dy: 3)
        let accent = NSColor(srgbRed: 0.55, green: 0.82, blue: 1.0, alpha: 1)
        let valueColor: NSColor = metric == .cost ? accent : .white
        let value = (metric == .tokens ? usage.tokenText : usage.costText) as NSString

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: valueColor,
        ]

        (metric.caption as NSString).draw(
            at: NSPoint(x: pad.minX, y: 2),
            withAttributes: nameAttrs
        )
        value.draw(at: NSPoint(x: pad.minX, y: 17), withAttributes: valueAttrs)
    }
}
