import AppKit

/// Several chips at once, over the last day or the last week.
@MainActor
final class InsightsSettingsPane: NSViewController {
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let spanControl = NSSegmentedControl(labels: ["24 hours", "7 days"], trackingMode: .selectOne, target: nil, action: nil)
    private let checks = NSStackView()
    private let graphs = NSStackView()
    private var chips: [Chip] = []
    private var selectedIDs = Set<String>()
    private var spanIsDay = true
    private var checkIDs: [String] = []
    private var cards: [Card] = []

    private struct Card {
        var id: String
        var timeline: UsageGraphView
        var windows: UsageGraphView?
    }

    override func loadView() {
        summary.font = .systemFont(ofSize: 13)
        summary.textColor = .labelColor
        summary.preferredMaxLayoutWidth = 640

        spanControl.target = self
        spanControl.action = #selector(spanPicked)
        spanControl.selectedSegment = 0
        spanControl.segmentStyle = .rounded
        spanControl.setContentHuggingPriority(.required, for: .horizontal)

        checks.orientation = .vertical
        checks.alignment = .leading
        checks.spacing = 4

        graphs.orientation = .vertical
        graphs.alignment = .leading
        graphs.spacing = 8

        let stack = NSStackView(views: [summary, spanControl, checks, graphs])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        graphs.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        view = scroll
        reload()
    }

    func apply(chips: [Chip]) {
        self.chips = chips
        guard isViewLoaded else { return }
        reload()
    }

    @objc private func spanPicked() {
        spanIsDay = spanControl.selectedSegment == 0
        cards = []
        reload()
    }

    @objc private func chipToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var hidden = ChipPreferences.insightHiddenIDs
        if sender.state == .on {
            hidden.remove(id)
        } else {
            hidden.insert(id)
        }
        ChipPreferences.insightHiddenIDs = hidden
        cards = []
        reload()
    }

    private func reload() {
        UsageLog.prepare()
        let stored = UsageLog.stored()
        let notes = UsageInsight.notes(chips: chips, samples: stored)
        if notes.isEmpty, stored.values.allSatisfy({ $0.points.isEmpty }) {
            summary.stringValue = "The log starts with the next poll and keeps 7 days. A 5h chip needs a few windows before the pace means anything."
        } else if notes.isEmpty {
            summary.stringValue = "Nothing is running ahead of its window yet. A 5h chip needs a few finished windows before the pace means anything. The log keeps 7 days."
        } else {
            summary.stringValue = notes.map(\.text).joined(separator: "\n\n")
        }

        let known = listedChips(stored: stored)
        let hidden = ChipPreferences.insightHiddenIDs
        selectedIDs = Set(known.map(\.id)).subtracting(hidden)
        if known.map(\.id) != checkIDs {
            rebuildChecks(known)
            checkIDs = known.map(\.id)
        }
        refreshGraphs(known, stored: stored)
    }

    private func listedChips(stored: [String: UsageLog.Series]) -> [(id: String, label: String)] {
        var items: [(id: String, label: String)] = []
        var seen = Set<String>()
        for chip in chips where seen.insert(chip.id).inserted {
            items.append((chip.id, chip.label))
        }
        let extra = stored.keys.filter { !seen.contains($0) }.sorted {
            (stored[$0]?.label ?? $0) < (stored[$1]?.label ?? $1)
        }
        for id in extra {
            items.append((id, stored[id]?.label ?? id))
        }
        return items
    }

    private func rebuildChecks(_ items: [(id: String, label: String)]) {
        checks.arrangedSubviews.forEach {
            checks.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        var rowItems: [NSView] = []
        func flush() {
            guard !rowItems.isEmpty else { return }
            let row = NSStackView(views: rowItems)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 14
            checks.addArrangedSubview(row)
            rowItems = []
        }
        for item in items {
            let box = NSButton(checkboxWithTitle: item.label, target: self, action: #selector(chipToggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(item.id)
            box.state = selectedIDs.contains(item.id) ? .on : .off
            box.font = .systemFont(ofSize: 12)
            rowItems.append(box)
            if rowItems.count == 4 { flush() }
        }
        flush()
    }

    private func refreshGraphs(_ items: [(id: String, label: String)], stored: [String: UsageLog.Series]) {
        let shown = items.filter { selectedIDs.contains($0.id) }
        if shown.map(\.id) != cards.map(\.id) {
            rebuildGraphs(shown, stored: stored)
        }
        let now = Date()
        let span: TimeInterval = spanIsDay ? UsagePlot.day : UsageLog.horizon
        let since = spanIsDay ? now.addingTimeInterval(-UsagePlot.day) : nil
        for card in cards {
            let points = stored[card.id]?.points ?? []
            card.timeline.plot = UsagePlot.timeline(points, span: span, now: now)
            if let windows = card.windows {
                let runs = UsageLog.runs(points)
                windows.plot = UsagePlot.sessionWindows(runs, since: since)
            }
        }
    }

    private func rebuildGraphs(_ shown: [(id: String, label: String)], stored: [String: UsageLog.Series]) {
        graphs.arrangedSubviews.forEach {
            graphs.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cards = []
        if shown.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Pick a chip and its graph shows up here.")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            graphs.addArrangedSubview(empty)
            return
        }
        for item in shown {
            let title = NSTextField(labelWithString: item.label)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.textColor = .labelColor
            graphs.addArrangedSubview(title)

            let timeline = UsageGraphView()
            timeline.translatesAutoresizingMaskIntoConstraints = false
            timeline.heightAnchor.constraint(equalToConstant: 150).isActive = true
            graphs.addArrangedSubview(timeline)
            timeline.widthAnchor.constraint(equalTo: graphs.widthAnchor).isActive = true

            let chip = chips.first { $0.id == item.id }
            let label = stored[item.id]?.label ?? item.label
            let isSession = chip?.windowTag == "5h" || label.hasSuffix("5h")
            var windows: UsageGraphView?
            if isSession {
                let caption = NSTextField(wrappingLabelWithString: spanIsDay
                    ? "5h windows in the last day, from the start. Each window has its own color. The newest is the strong line."
                    : "Each 5h window, from the start. Each window has its own color. The newest is the strong line.")
                caption.font = .systemFont(ofSize: 12, weight: .medium)
                caption.textColor = .secondaryLabelColor
                caption.preferredMaxLayoutWidth = 640
                graphs.addArrangedSubview(caption)
                let pace = UsageGraphView()
                pace.translatesAutoresizingMaskIntoConstraints = false
                pace.heightAnchor.constraint(equalToConstant: 120).isActive = true
                graphs.addArrangedSubview(pace)
                pace.widthAnchor.constraint(equalTo: graphs.widthAnchor).isActive = true
                windows = pace
            }
            cards.append(Card(id: item.id, timeline: timeline, windows: windows))
        }
    }
}

struct UsagePlot {
    struct Run {
        var points: [(x: CGFloat, y: CGFloat)]
        var emphasis: CGFloat
        /// Same window, same color, on the day graph and the overlay. Nil stays blue.
        var tint: Int?
    }

    static func color(tint: Int?) -> NSColor {
        guard let tint else { return .systemBlue }
        let colors: [NSColor] = [
            .systemBlue, .systemOrange, .systemGreen, .systemPink,
            .systemTeal, .systemPurple, .systemCyan, .systemRed,
        ]
        let count = colors.count
        let index = ((tint % count) + count) % count
        return colors[index]
    }

    static let day: TimeInterval = 24 * 3600

    var runs: [Run]
    var xMarks: [(x: CGFloat, title: String)]

    static func timeline(_ samples: [UsageLog.Sample], span: TimeInterval, now: Date) -> UsagePlot {
        let end = now.timeIntervalSince1970
        let start = end - span
        let marks = span <= day ? hourMarks(start: start, end: end) : dayMarks(start: start, end: end)
        var plot = UsagePlot(runs: [], xMarks: marks)
        for run in UsageLog.runs(samples) {
            let visible = run.filter { $0.t >= start - 60 }
            guard !visible.isEmpty else { continue }
            let points = visible.map { sample in
                (x: CGFloat((sample.t - start) / span), y: CGFloat(min(max(sample.p, 0), 100) / 100))
            }
            let reset = visible.compactMap(\.r).max()
            let slot = reset.map { Int(($0 / (5 * 3600)).rounded()) }
            plot.runs.append(Run(points: points, emphasis: 1, tint: slot))
        }
        return plot
    }

    static func sessionWindows(_ runs: [[UsageLog.Sample]], since: Date?) -> UsagePlot {
        let length: TimeInterval = 5 * 3600
        let filtered: [[UsageLog.Sample]]
        if let since {
            let t = since.timeIntervalSince1970
            filtered = runs.filter { run in run.contains { $0.t >= t } }
        } else {
            filtered = runs
        }
        let recent = Array(filtered.suffix(8))
        var plot = UsagePlot(runs: [], xMarks: [
            (0, "0h"),
            (0.5, "2.5h"),
            (1, "5h"),
        ])
        for (index, run) in recent.enumerated() {
            let newest = index == recent.count - 1
            var points: [(x: CGFloat, y: CGFloat)] = []
            for sample in run {
                guard let reset = sample.r else { continue }
                let into = (length - (reset - sample.t)) / length
                guard into > -0.05, into < 1.15 else { continue }
                points.append((x: CGFloat(into), y: CGFloat(min(max(sample.p, 0), 100) / 100)))
            }
            guard !points.isEmpty else { continue }
            let reset = run.compactMap(\.r).max() ?? 0
            let slot = Int((reset / length).rounded())
            plot.runs.append(Run(points: points, emphasis: newest ? 1 : 0.5, tint: slot))
        }
        return plot
    }

    private static func hourMarks(start: TimeInterval, end: TimeInterval) -> [(x: CGFloat, title: String)] {
        var marks: [(x: CGFloat, title: String)] = []
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        let span = end - start
        guard span > 0, var cursor = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: Date(timeIntervalSince1970: start)) else {
            return marks
        }
        while cursor.timeIntervalSince1970 < start {
            guard let next = calendar.date(byAdding: .hour, value: 4, to: cursor) else { return marks }
            cursor = next
        }
        while cursor.timeIntervalSince1970 <= end {
            let t = cursor.timeIntervalSince1970
            marks.append((x: CGFloat((t - start) / span), title: formatter.string(from: cursor)))
            guard let next = calendar.date(byAdding: .hour, value: 4, to: cursor) else { break }
            cursor = next
        }
        return marks
    }

    private static func dayMarks(start: TimeInterval, end: TimeInterval) -> [(x: CGFloat, title: String)] {
        var marks: [(x: CGFloat, title: String)] = []
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: start))
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EE")
        let span = end - start
        while day.timeIntervalSince1970 < end {
            let t = day.timeIntervalSince1970
            if t >= start {
                marks.append((x: CGFloat((t - start) / span), title: formatter.string(from: day)))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return marks
    }
}

final class UsageGraphView: NSView {
    var plot = UsagePlot(runs: [], xMarks: []) {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let plotRect = bounds.insetBy(dx: 0, dy: 0)
        let left: CGFloat = 32
        let bottom: CGFloat = 18
        let top: CGFloat = 8
        let right: CGFloat = 8
        let area = NSRect(
            x: plotRect.minX + left,
            y: plotRect.minY + top,
            width: max(1, plotRect.width - left - right),
            height: max(1, plotRect.height - top - bottom)
        )

        NSColor.quaternaryLabelColor.setStroke()
        for fraction in [0.0, 0.5, 1.0] as [CGFloat] {
            let y = area.maxY - area.height * fraction
            let line = NSBezierPath()
            line.move(to: NSPoint(x: area.minX, y: y))
            line.line(to: NSPoint(x: area.maxX, y: y))
            line.lineWidth = fraction == 1 ? 1 : 0.5
            line.stroke()
        }

        let yAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (fraction, title) in [(1.0, "100"), (0.5, "50"), (0.0, "0")] as [(CGFloat, String)] {
            let y = area.maxY - area.height * fraction
            (title as NSString).draw(at: NSPoint(x: 0, y: y - 6), withAttributes: yAttrs)
        }

        let xAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for mark in plot.xMarks {
            let x = area.minX + area.width * min(max(mark.x, 0), 1)
            let title = mark.title as NSString
            let size = title.size(withAttributes: xAttrs)
            title.draw(at: NSPoint(x: x - size.width / 2, y: area.maxY + 3), withAttributes: xAttrs)
        }

        for run in plot.runs {
            let path = NSBezierPath()
            var started = false
            for point in run.points {
                let spot = NSPoint(
                    x: area.minX + area.width * min(max(point.x, 0), 1),
                    y: area.maxY - area.height * min(max(point.y, 0), 1)
                )
                if started {
                    path.line(to: spot)
                } else {
                    path.move(to: spot)
                    started = true
                }
            }
            let color = UsagePlot.color(tint: run.tint)
            let alpha: CGFloat = run.tint == nil ? run.emphasis : 1
            color.withAlphaComponent(alpha).setStroke()
            path.lineWidth = run.emphasis > 0.9 ? 2.5 : 1.75
            path.lineJoinStyle = .round
            path.stroke()
            if run.points.count == 1 {
                let point = run.points[0]
                let spot = NSPoint(
                    x: area.minX + area.width * min(max(point.x, 0), 1),
                    y: area.maxY - area.height * min(max(point.y, 0), 1)
                )
                color.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: spot.x - 2.5, y: spot.y - 2.5, width: 5, height: 5)).fill()
            }
        }
    }
}
