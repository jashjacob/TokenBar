import AppKit

/// Control Strip mascot. Subclasses NSButton so the system tray item still receives taps.
final class StripBotView: NSButton {
    var percent: Double = 0 {
        didSet { updateChrome() }
    }
    var offline: Bool = false {
        didSet { updateChrome() }
    }
    var bounceEnabled: Bool = true {
        didSet { syncTimer() }
    }

    private var timer: Timer?
    private var celebratingUntil: Date?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 30))
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = true
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        isEnabled = true
        updateChrome()
        syncTimer()
    }

    deinit {
        timer?.invalidate()
    }

    func playReset() {
        guard bounceEnabled else { return }
        celebratingUntil = Date().addingTimeInterval(2.4)
        syncTimer()
        renderFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 30) }

    private var celebrating: Bool {
        celebratingUntil.map { $0 > Date() } ?? false
    }

    private func updateChrome() {
        if offline {
            toolTip = "TokenTracker offline"
        } else {
            toolTip = String(format: "Hottest window %.0f%% — tap to expand", percent)
        }
        renderFrame()
    }

    private func fillColor() -> NSColor {
        if celebrating { return NSColor(srgbRed: 0.18, green: 0.78, blue: 0.42, alpha: 1) }
        if offline { return NSColor.systemRed }
        switch ChipColor.band(percent) {
        case "red": return NSColor.systemRed
        case "amber": return NSColor.systemOrange
        default: return NSColor.systemGreen
        }
    }

    private func syncTimer() {
        let shouldRun = bounceEnabled || celebrating
        if shouldRun {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if !self.bounceEnabled, !self.celebrating {
                    self.syncTimer()
                    return
                }
                self.renderFrame()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            renderFrame()
        }
    }

    private func renderFrame() {
        bezelColor = fillColor()
        let now = Date().timeIntervalSince1970
        let still = offline || !bounceEnabled
        let hop = Self.hop(at: now, celebrating: celebrating && bounceEnabled, idle: still)
        let celebrating = celebrating
        let offline = offline
        let size = NSSize(width: 36, height: 30)
        image = NSImage(size: size, flipped: true) { rect in
            Self.drawBot(
                in: rect,
                hop: hop,
                celebrating: celebrating,
                offline: offline,
                at: now,
                template: false,
                animated: !still
            )
            return true
        }
    }

    static func statusItemImage(offline: Bool) -> NSImage {
        let hop = hop(at: 0, celebrating: false, idle: true)
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: true) { rect in
            Self.drawBot(
                in: rect.insetBy(dx: 1, dy: 1),
                hop: hop,
                celebrating: false,
                offline: offline,
                at: 0,
                template: true,
                animated: false
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    static func mascotFill(offline: Bool) -> NSColor {
        if offline {
            return NSColor(srgbRed: 0.90, green: 0.22, blue: 0.22, alpha: 1)
        }
        return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.42, alpha: 1)
    }

    static func logoImage(size: CGFloat = 96, offline: Bool = false) -> NSImage {
        let hop = hop(at: 0, celebrating: false, idle: true)
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let pad = rect.insetBy(dx: 0.5, dy: 0.5)
            let badge = NSBezierPath(roundedRect: pad, xRadius: pad.width / 2, yRadius: pad.height / 2)
            mascotFill(offline: offline).setFill()
            badge.fill()
            let botRect = pad.insetBy(dx: pad.width * 0.18, dy: pad.height * 0.14)
            Self.drawBot(
                in: botRect,
                hop: hop,
                celebrating: false,
                offline: offline,
                at: 0,
                template: false,
                animated: false
            )
            return true
        }
    }

    /// Full-bleed square for the Finder / Dock icns. macOS applies the squircle mask.
    static func drawAppIcon(in rect: NSRect) {
        mascotFill(offline: false).setFill()
        rect.fill()

        let inset: CGFloat
        if rect.width <= 16 { inset = 0.04 }
        else if rect.width <= 32 { inset = 0.06 }
        else { inset = 0.10 }
        let botRect = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        // No ground shadow — it reads as a smudge on a flat app icon.
        let pose = Hop(lift: 0, squashX: 1, squashY: 1, shadow: 0)
        drawBot(
            in: botRect,
            hop: pose,
            celebrating: false,
            offline: false,
            at: 0,
            template: false,
            animated: false
        )
    }

    private static func drawBot(
        in rect: NSRect,
        hop: Hop,
        celebrating: Bool,
        offline: Bool,
        at time: TimeInterval,
        template: Bool,
        animated: Bool
    ) {
        let design = NSSize(width: 28, height: 30)
        let scale = min(rect.width / design.width, rect.height / design.height)
        NSGraphicsContext.saveGraphicsState()
        let fit = NSAffineTransform()
        fit.translateX(by: rect.midX - design.width * scale / 2, yBy: rect.midY - design.height * scale / 2)
        fit.scale(by: scale)
        fit.concat()
        drawBotDesign(
            hop: hop,
            celebrating: celebrating,
            offline: offline,
            at: time,
            template: template,
            animated: animated
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBotDesign(
        hop: Hop,
        celebrating: Bool,
        offline: Bool,
        at time: TimeInterval,
        template: Bool,
        animated: Bool
    ) {
        let rect = NSRect(x: 0, y: 0, width: 28, height: 30)
        let cx = rect.midX
        let ground = rect.height - 3
        let y = ground - hop.lift

        if !template {
            let shadow = NSBezierPath(ovalIn: NSRect(
                x: cx - 6.5 * hop.squashX,
                y: ground - 1,
                width: 13 * hop.squashX,
                height: 2.6
            ))
            NSColor.black.withAlphaComponent(0.22 * hop.shadow).setFill()
            shadow.fill()
        }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: cx, yBy: y)
        transform.scaleX(by: hop.squashX, yBy: hop.squashY)
        if celebrating {
            transform.rotate(byDegrees: CGFloat(sin(time * 14) * 12))
        }
        transform.concat()

        let body = template ? NSColor.black : NSColor.white
        let ink = NSColor.black.withAlphaComponent(template ? 1 : 0.82)

        ink.setStroke()
        let antenna = NSBezierPath()
        antenna.move(to: NSPoint(x: 0, y: -13.2))
        antenna.line(to: NSPoint(x: 0, y: -15.6))
        antenna.lineWidth = 1.15
        antenna.lineCapStyle = .round
        antenna.stroke()
        let bead = NSBezierPath(ovalIn: NSRect(x: -1.45, y: -18.4, width: 2.9, height: 2.9))
        body.setFill()
        bead.fill()
        ink.setStroke()
        bead.lineWidth = 0.8
        bead.stroke()

        let torso = NSBezierPath(roundedRect: NSRect(x: -4.2, y: -5.4, width: 8.4, height: 5.4), xRadius: 2.1, yRadius: 2.1)
        body.setFill()
        torso.fill()

        // Rounder head so menu bar and Touch Bar read as the same character.
        let head = NSBezierPath(ovalIn: NSRect(x: -5.6, y: -14.8, width: 11.2, height: 11.0))
        body.setFill()
        head.fill()

        let blink = animated && !offline && time.truncatingRemainder(dividingBy: 3.4) < 0.11
        let look: CGFloat = hop.lift > 0.4 ? -0.55 : 0.22
        if blink || offline {
            ink.setStroke()
            for sign: CGFloat in [-1, 1] {
                let lid = NSBezierPath()
                lid.move(to: NSPoint(x: sign * 1.6, y: -9.6))
                lid.line(to: NSPoint(x: sign * 3.7, y: -9.6))
                lid.lineWidth = 1.2
                lid.lineCapStyle = .round
                lid.stroke()
            }
        } else if template {
            let left = NSBezierPath(ovalIn: NSRect(x: -3.9, y: -10.6 + look, width: 3.0, height: 3.5))
            let right = NSBezierPath(ovalIn: NSRect(x: 0.9, y: -10.6 + look, width: 3.0, height: 3.5))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            left.fill()
            right.fill()
            NSGraphicsContext.restoreGraphicsState()
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: -3.2, y: -10.1 + look, width: 1.6, height: 2.0)).fill()
            NSBezierPath(ovalIn: NSRect(x: 1.6, y: -10.1 + look, width: 1.6, height: 2.0)).fill()
        } else {
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: -3.9, y: -10.6 + look, width: 3.0, height: 3.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 0.9, y: -10.6 + look, width: 3.0, height: 3.5)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: -3.15, y: -10.25 + look, width: 1.15, height: 1.15)).fill()
            NSBezierPath(ovalIn: NSRect(x: 1.65, y: -10.25 + look, width: 1.15, height: 1.15)).fill()
        }

        let mouth = NSBezierPath()
        if offline {
            mouth.move(to: NSPoint(x: -1.4, y: -6.8))
            mouth.line(to: NSPoint(x: 1.4, y: -6.8))
        } else {
            mouth.move(to: NSPoint(x: -1.9, y: -6.9))
            mouth.curve(
                to: NSPoint(x: 1.9, y: -6.9),
                controlPoint1: NSPoint(x: -0.6, y: celebrating ? -5.1 : -5.6),
                controlPoint2: NSPoint(x: 0.6, y: celebrating ? -5.1 : -5.6)
            )
        }
        mouth.lineWidth = template ? 1.4 : 1.15
        mouth.lineCapStyle = .round
        if template {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            NSColor.black.setStroke()
            mouth.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            ink.setStroke()
            mouth.stroke()
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private struct Hop {
        var lift: CGFloat
        var squashX: CGFloat
        var squashY: CGFloat
        var shadow: CGFloat
    }

    private static func hop(at time: TimeInterval, celebrating: Bool, idle: Bool) -> Hop {
        if idle {
            return Hop(lift: 0, squashX: 1, squashY: 1, shadow: 1)
        }
        let period = celebrating ? 0.42 : 0.78
        let height: CGFloat = celebrating ? 6.5 : 4.0
        let p = CGFloat(time.truncatingRemainder(dividingBy: period) / period)
        if p < 0.58 {
            let u = p / 0.58
            let lift = 4 * u * (1 - u) * height
            let stretch: CGFloat = 1 + 0.08 * (lift / height)
            return Hop(lift: lift, squashX: 2 - stretch, squashY: stretch, shadow: 1 - 0.7 * (lift / height))
        }
        let u = (p - 0.58) / 0.42
        let squashY: CGFloat = 1 - 0.16 * sin(u * .pi)
        return Hop(lift: 0, squashX: 2 - squashY, squashY: squashY, shadow: 1)
    }
}
