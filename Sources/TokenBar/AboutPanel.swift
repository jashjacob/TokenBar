import AppKit

@MainActor
final class AboutPanel: NSObject, NSWindowDelegate {
    static let shared = AboutPanel()

    private var window: NSWindow?
    private var restoreAccessory = false
    private var tracker: [String] = []
    private var fallback: [String] = []

    func show(tracker: [String], fallback: [String]) {
        self.tracker = tracker
        self.fallback = fallback
        if window == nil {
            window = makeWindow()
        }
        window?.contentView = makeContent()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            restoreAccessory = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if restoreAccessory {
            NSApp.setActivationPolicy(.accessory)
            restoreAccessory = false
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About \(AppInfo.name)"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.contentView = makeContent()
        return window
    }

    private func makeContent() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 460))

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = StripBotView.logoImage(size: 128)
        icon.imageScaling = .scaleProportionallyUpOrDown

        let name = label(AppInfo.name, font: .systemFont(ofSize: 22, weight: .semibold), color: .labelColor)
        let version = label(AppInfo.versionLine, font: .systemFont(ofSize: 13, weight: .regular), color: .secondaryLabelColor)
        let build = label(
            AppInfo.buildLine,
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            color: .tertiaryLabelColor
        )
        let credit = label(AppInfo.creditLine, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
        let requires = label("Requires TokenTracker", font: .systemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
        let data = dataList()

        let stack = NSStackView(views: [icon, name, version, build, credit, requires, data])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(4, after: name)
        stack.setCustomSpacing(2, after: version)
        stack.setCustomSpacing(16, after: build)
        stack.setCustomSpacing(10, after: credit)
        stack.setCustomSpacing(18, after: requires)
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 80),
            icon.heightAnchor.constraint(equalToConstant: 80),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -4),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])
        return root
    }

    private func dataList() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.addArrangedSubview(heading("Data"))
        if tracker.isEmpty && fallback.isEmpty {
            stack.addArrangedSubview(row("Nothing loaded yet"))
            return stack
        }
        if !tracker.isEmpty {
            stack.addArrangedSubview(heading("TokenTracker"))
            for name in tracker {
                stack.addArrangedSubview(row(name))
            }
        }
        if !fallback.isEmpty {
            stack.addArrangedSubview(heading("Fallback"))
            for name in fallback {
                stack.addArrangedSubview(row(name))
            }
        }
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let field = label(text, font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)
        field.alignment = .left
        return field
    }

    private func row(_ text: String) -> NSTextField {
        let field = label(text, font: .systemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
        field.alignment = .left
        return field
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}
