import AppKit
import ServiceManagement

/// One settings window. The menu stays the live control for the Touch Bar.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var restoreAccessory = false
    private let root = SettingsRootController()
    private let general = GeneralSettingsPane()
    private let touch = TouchBarSettingsPane()
    private let sources = SourcesSettingsPane()
    private let about = AboutSettingsPane()
    private var touchBar: TouchBarController?
    private var onRefresh: () -> Void = {}
    private var onVisibilityChange: () -> Void = {}

    func configure(
        touchBar: TouchBarController,
        onRefresh: @escaping () -> Void,
        onVisibilityChange: @escaping () -> Void
    ) {
        self.touchBar = touchBar
        self.onRefresh = onRefresh
        self.onVisibilityChange = onVisibilityChange
        wire()
    }

    func update(chips: [Chip], today: TodayUsage?, offline: Bool, error: String?) {
        var tracker = ChipSources.names(chips.filter { $0.source == .tokenTracker })
        if today != nil { tracker.insert("Today", at: 0) }
        let fallback = ChipSources.names(chips.filter { $0.source == .fallback })
        var current = Set(chips.map(\.id))
        if today != nil { current.formUnion(ChipPreferences.todayMetricIDs) }
        let leftovers = ChipPreferences.hiddenIDs.subtracting(current).sorted()
        general.apply(offline: offline, error: error)
        touch.apply(bounce: touchBar?.bounceStripBot ?? true, leftovers: leftovers)
        sources.apply(fallbacks: ChipPreferences.fallbacksEnabled, tracker: tracker, fallback: fallback)
    }

    func show(chips: [Chip], today: TodayUsage?, offline: Bool, error: String?) {
        if window == nil {
            window = makeWindow()
            window?.center()
        }
        update(chips: chips, today: today, offline: offline, error: error)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            restoreAccessory = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard restoreAccessory else { return }
        NSApp.setActivationPolicy(.accessory)
        restoreAccessory = false
    }

    private func wire() {
        general.onLogin = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        }
        general.onPort = { [weak self] port in
            guard port != LimitsClient.discoverPort() else { return }
            LimitsClient.setTrackerPort(port)
            self?.onRefresh()
        }
        touch.onBounce = { [weak self] enabled in
            self?.touchBar?.bounceStripBot = enabled
            self?.onVisibilityChange()
        }
        touch.onShowHidden = { [weak self] id in
            ChipPreferences.setVisible(id, true)
            self?.onVisibilityChange()
        }
        sources.onFallbacks = { [weak self] enabled in
            ChipPreferences.fallbacksEnabled = enabled
            if enabled { LimitsClient.refreshFallbacksNow = true }
            self?.onRefresh()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            general.applyLoginFailure(nil)
        } catch {
            Log.line("launch at login failed: \(error)")
            general.applyLoginFailure(error.localizedDescription)
        }
    }

    private func makeWindow() -> NSWindow {
        root.panes = [
            ("General", general),
            ("Touch Bar", touch),
            ("Sources", sources),
            ("About", about),
        ]
        root.preferredContentSize = NSSize(width: 720, height: 500)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 440)
        window.contentViewController = root
        window.setContentSize(NSSize(width: 720, height: 500))
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

@MainActor
private final class SettingsRootController: NSViewController {
    var panes: [(title: String, controller: NSViewController)] = []
    private let pills = PillBar()
    private let detail = NSView()

    override func loadView() {
        let header = SettingsChrome.header()
        pills.titles = panes.map(\.title)
        pills.onPick = { [weak self] index in
            self?.select(index)
        }
        pills.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(pills)
        root.addSubview(detail)
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),

            pills.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            pills.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            pills.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -22),

            detail.topAnchor.constraint(equalTo: pills.bottomAnchor, constant: 18),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        pills.reload()
        select(0)
    }

    private func select(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        pills.select(index)
        detail.subviews.forEach { $0.removeFromSuperview() }
        let pane = panes[index].controller
        if pane.parent == nil { addChild(pane) }
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            pane.view.topAnchor.constraint(equalTo: detail.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
    }
}

@MainActor
private final class GeneralSettingsPane: NSViewController, NSTextFieldDelegate {
    var onLogin: (Bool) -> Void = { _ in }
    var onPort: (Int) -> Void = { _ in }

    private let login = NSSwitch()
    private let loginFailure = NSTextField(wrappingLabelWithString: "")
    private let portField = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var applying = false

    override func loadView() {
        login.target = self
        login.action = #selector(loginChanged)
        login.setContentHuggingPriority(.required, for: .horizontal)

        loginFailure.font = .systemFont(ofSize: 12)
        loginFailure.textColor = .systemRed
        loginFailure.preferredMaxLayoutWidth = 460
        loginFailure.isHidden = true

        portField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        portField.alignment = .center
        portField.usesSingleLineMode = true
        portField.delegate = self
        portField.placeholderString = String(LimitsClient.defaultPort)
        portField.bezelStyle = .roundedBezel
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 420
        status.maximumNumberOfLines = 2

        let launch = SettingsChrome.optionRow(
            symbol: "power",
            title: "Launch at Login",
            subtitle: "Opens TokenBar when you sign in to this Mac.",
            trailing: login
        )
        let tracker = SettingsChrome.optionRow(
            symbol: "dot.radiowaves.left.and.right",
            title: "TokenTracker",
            subtitleView: status,
            trailing: portField
        )
        let card = SettingsChrome.listCard([launch, loginFailure, tracker])
        view = SettingsChrome.page([card])
        apply(offline: true, error: nil)
    }

    func apply(offline: Bool, error: String?) {
        guard isViewLoaded else { return }
        applying = true
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        if portField.currentEditor() == nil {
            portField.stringValue = String(LimitsClient.discoverPort())
        }
        if offline {
            status.stringValue = error ?? "TokenTracker is not running"
            status.textColor = .systemRed
        } else {
            status.stringValue = "Running on port \(LimitsClient.discoverPort())"
            status.textColor = .secondaryLabelColor
        }
        applying = false
    }

    func applyLoginFailure(_ message: String?) {
        guard isViewLoaded else { return }
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        loginFailure.stringValue = message ?? ""
        loginFailure.isHidden = message == nil
    }

    @objc private func loginChanged() {
        onLogin(login.state == .on)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !applying else { return }
        let raw = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(raw), (1...65_535).contains(port) else {
            portField.stringValue = String(LimitsClient.discoverPort())
            return
        }
        onPort(port)
    }
}

@MainActor
private final class TouchBarSettingsPane: NSViewController {
    var onBounce: (Bool) -> Void = { _ in }
    var onShowHidden: (String) -> Void = { _ in }

    private let bounce = NSSwitch()
    private let hiddenCard = NSView()
    private let hiddenRows = NSStackView()
    private let hiddenHeading = SettingsChrome.section("Still hidden")
    private var applying = false

    override func loadView() {
        bounce.target = self
        bounce.action = #selector(bounceChanged)
        bounce.setContentHuggingPriority(.required, for: .horizontal)

        let row = SettingsChrome.optionRow(
            symbol: "figure.wave",
            title: "Bounce Icon",
            subtitle: "The strip mascot bounces while the bar is up. Pin stays in the menu.",
            trailing: bounce
        )
        let card = SettingsChrome.listCard([row])

        hiddenRows.orientation = .vertical
        hiddenRows.alignment = .leading
        hiddenRows.spacing = 8
        hiddenRows.translatesAutoresizingMaskIntoConstraints = false
        hiddenCard.addSubview(hiddenRows)
        NSLayoutConstraint.activate([
            hiddenRows.topAnchor.constraint(equalTo: hiddenCard.topAnchor),
            hiddenRows.leadingAnchor.constraint(equalTo: hiddenCard.leadingAnchor),
            hiddenRows.trailingAnchor.constraint(equalTo: hiddenCard.trailingAnchor),
            hiddenRows.bottomAnchor.constraint(equalTo: hiddenCard.bottomAnchor),
        ])
        hiddenHeading.isHidden = true
        hiddenCard.isHidden = true

        let hint = SettingsChrome.wrap("These were hidden and are not in the current feed. Show All cannot clear them.", size: 12, color: .tertiaryLabelColor)
        let stack = NSStackView(views: [card, hiddenHeading, hint, hiddenCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        hint.isHidden = true
        stack.setCustomSpacing(6, after: hiddenHeading)
        self.hint = hint
        view = SettingsChrome.page(stack)
    }

    private var hint: NSTextField?

    func apply(bounce enabled: Bool, leftovers ids: [String]) {
        guard isViewLoaded else { return }
        applying = true
        bounce.state = enabled ? .on : .off
        hiddenRows.arrangedSubviews.forEach {
            hiddenRows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let show = !ids.isEmpty
        hiddenHeading.isHidden = !show
        hint?.isHidden = !show
        hiddenCard.isHidden = !show
        for id in ids {
            let title = NSTextField(labelWithString: id)
            title.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingMiddle
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let button = NSButton(title: "Show", target: self, action: #selector(showHidden(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.setContentHuggingPriority(.required, for: .horizontal)
            let line = NSStackView(views: [title, button])
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 12
            hiddenRows.addArrangedSubview(line)
            line.trailingAnchor.constraint(equalTo: hiddenRows.trailingAnchor).isActive = true
        }
        applying = false
    }

    @objc private func bounceChanged() {
        guard !applying else { return }
        onBounce(bounce.state == .on)
    }

    @objc private func showHidden(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onShowHidden(id)
    }
}

@MainActor
private final class SourcesSettingsPane: NSViewController {
    var onFallbacks: (Bool) -> Void = { _ in }

    private let fallbacks = NSSwitch()
    private let trackerHeading = SettingsChrome.section("TokenTracker")
    private let trackerPills = PillFlow()
    private let fallbackHeading = SettingsChrome.section("Fallback")
    private let fallbackPills = PillFlow()
    private let empty = SettingsChrome.wrap("Nothing loaded yet", size: 13, color: .secondaryLabelColor)
    private var applying = false

    override func loadView() {
        fallbacks.target = self
        fallbacks.action = #selector(fallbacksChanged)
        fallbacks.setContentHuggingPriority(.required, for: .horizontal)

        let row = SettingsChrome.optionRow(
            symbol: "arrow.triangle.2.circlepath",
            title: "Use fallbacks",
            subtitle: "When a tool’s windows are missing, TokenBar asks that tool itself. It owns every window for that tool and checks again after five minutes.",
            trailing: fallbacks
        )
        let card = SettingsChrome.listCard([row])
        let stack = NSStackView(views: [card, trackerHeading, trackerPills, fallbackHeading, fallbackPills, empty])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(8, after: trackerHeading)
        stack.setCustomSpacing(8, after: fallbackHeading)
        trackerPills.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fallbackPills.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view = SettingsChrome.page(stack)
    }

    func apply(fallbacks enabled: Bool, tracker: [String], fallback: [String]) {
        guard isViewLoaded else { return }
        applying = true
        fallbacks.state = enabled ? .on : .off
        trackerPills.setNames(tracker)
        fallbackPills.setNames(fallback)
        let nothing = tracker.isEmpty && fallback.isEmpty
        empty.isHidden = !nothing
        trackerHeading.isHidden = tracker.isEmpty
        trackerPills.isHidden = tracker.isEmpty
        fallbackHeading.isHidden = fallback.isEmpty
        fallbackPills.isHidden = fallback.isEmpty
        applying = false
    }

    @objc private func fallbacksChanged() {
        guard !applying else { return }
        onFallbacks(fallbacks.state == .on)
    }
}

@MainActor
private final class AboutSettingsPane: NSViewController {
    override func loadView() {
        let icon = NSImageView()
        icon.image = StripBotView.logoImage(size: 160)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 88),
            icon.heightAnchor.constraint(equalToConstant: 88),
        ])

        let version = OutlinePill(text: "v\(AppInfo.version)")
        let build = SettingsChrome.label(AppInfo.buildLine, size: 13, weight: .medium, color: .secondaryLabelColor)
        let meta = NSStackView(views: [version, build])
        meta.orientation = .horizontal
        meta.alignment = .centerY
        meta.spacing = 10

        let text = NSStackView(views: [
            SettingsChrome.label(AppInfo.name, size: 28, weight: .bold, color: .labelColor),
            meta,
            SettingsChrome.label(AppInfo.creditLine, size: 14, weight: .medium, color: .labelColor),
            SettingsChrome.label("Requires TokenTracker", size: 13, weight: .regular, color: .secondaryLabelColor),
        ])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        view = SettingsChrome.page([SettingsChrome.listCard([row])])
    }
}

private enum SettingsChrome {
    static func header() -> NSView {
        let icon = NSImageView()
        icon.image = StripBotView.logoImage(size: 64)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
        ])
        let name = label("TokenBar", size: 15, weight: .semibold, color: .labelColor)
        let version = OutlinePill(text: "v\(AppInfo.version)")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, name, spacer, version])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func page(_ stack: NSStackView) -> NSView {
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews {
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22),
        ])
        return root
    }

    static func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return page(stack)
    }

    static func listCard(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            stack.addArrangedSubview(row)
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        let card = RoundCard()
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
    }

    static func optionRow(symbol: String, title: String, subtitle: String, trailing: NSView) -> NSView {
        let subtitleView = wrap(subtitle, size: 12, color: .secondaryLabelColor)
        subtitleView.preferredMaxLayoutWidth = 460
        return optionRow(symbol: symbol, title: title, subtitleView: subtitleView, trailing: trailing)
    }

    static func optionRow(symbol: String, title: String, subtitleView: NSTextField, trailing: NSView) -> NSView {
        let icon = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = StripBotView.mascotFill(offline: false)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        let well = RoundWell()
        well.addSubview(icon)
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 36),
            well.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])

        let titleField = label(title, size: 13, weight: .semibold, color: .labelColor)
        let text = NSStackView(views: [titleField, subtitleView])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [well, text, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    static func section(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 1.1,
        ])
        return field
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func wrap(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        field.preferredMaxLayoutWidth = 520
        return field
    }
}

private final class RoundCard: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 18
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill = dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.045)
        layer?.backgroundColor = fill.cgColor
    }
}

private final class RoundWell: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        let fill = StripBotView.mascotFill(offline: false).withAlphaComponent(0.16)
        layer?.backgroundColor = fill.cgColor
    }
}

private final class OutlinePill: NSView {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: Self.attrs).width
        return NSSize(width: width + 16, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let size = (text as NSString).size(withAttributes: Self.attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: Self.attrs)
    }

    private static let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
}

private final class PillBar: NSView {
    var titles: [String] = []
    var onPick: (Int) -> Void = { _ in }
    private var buttons: [CapsuleButton] = []
    private var selected = 0

    func reload() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = titles.enumerated().map { index, title in
            let button = CapsuleButton(title: title)
            button.tag = index
            button.target = self
            button.action = #selector(picked(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        select(selected)
    }

    func select(_ index: Int) {
        selected = index
        for (i, button) in buttons.enumerated() {
            button.isOn = i == index
        }
    }

    @objc private func picked(_ sender: NSButton) {
        onPick(sender.tag)
    }
}

private final class CapsuleButton: NSButton {
    var isOn = false {
        didSet { needsDisplay = true }
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        return NSSize(width: width + 28, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if isOn {
            StripBotView.mascotFill(offline: false).setFill()
        } else {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)).setFill()
        }
        path.fill()
        let color: NSColor = isOn
            ? NSColor(srgbRed: 0.05, green: 0.16, blue: 0.08, alpha: 1)
            : .secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isOn ? .semibold : .medium),
            .foregroundColor: color,
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 1)
        (title as NSString).draw(at: origin, withAttributes: attrs)
    }
}

private final class PillFlow: NSView {
    private var names: [String] = []
    private var lastHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    func setNames(_ names: [String]) {
        guard names != self.names else { return }
        self.names = names
        subviews.forEach { $0.removeFromSuperview() }
        for name in names {
            addSubview(NamePill(text: name))
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        let width = bounds.width
        guard width > 1 else { return }
        let gap: CGFloat = 6
        let height: CGFloat = 26
        var x: CGFloat = 0
        var y: CGFloat = 0
        for pill in subviews {
            var pillWidth = pill.intrinsicContentSize.width
            pillWidth = min(pillWidth, width)
            if x > 0, x + pillWidth > width {
                x = 0
                y += height + gap
            }
            pill.frame = NSRect(x: x, y: y, width: pillWidth, height: height)
            x += pillWidth + gap
        }
        let needed = subviews.isEmpty ? 0 : y + height
        if abs(needed - lastHeight) > 0.5 {
            lastHeight = needed
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(lastHeight, names.isEmpty ? 0 : 26))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - bounds.width) > 0.5
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }
}

private final class NamePill: NSView {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let width = (text as NSString).size(withAttributes: Self.attrs).width
        return NSSize(width: width + 18, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)).setFill()
        path.fill()
        let size = (text as NSString).size(withAttributes: Self.attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 0.5)
        (text as NSString).draw(at: origin, withAttributes: Self.attrs)
    }

    private static let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.labelColor,
    ]
}
