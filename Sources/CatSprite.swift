import AppKit

/// Vector cream cat, drawn in code.
///
/// Design space is 210 pt wide (head 112, whiskers out to ±74), so every dimension
/// below is multiplied by a single scale factor. No image assets are required, and
/// every state animates from the same geometry — `PetView` falls back to this
/// drawing whenever no generated frame set exists for the current state.
enum CatSprite {

    // MARK: - Palette

    private static let ink = NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.18, alpha: 1)
    private static let furLight = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.95, alpha: 1)
    private static let furDark = NSColor(calibratedRed: 0.95, green: 0.86, blue: 0.78, alpha: 1)
    private static let furFlat = NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.87, alpha: 1)
    private static let blush = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.64, alpha: 0.35)
    private static let nose = NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.60, alpha: 1)

    /// Halo colour carries the state; the cat itself is never re-tinted, so it
    /// stays recognisable as a cat in every state.
    private static func haloColor(_ state: PetState) -> NSColor? {
        switch state {
        case .idle: return nil
        case .working: return NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.30, alpha: 0.9)
        case .blocked: return NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.44, alpha: 0.95)
        case .done: return NSColor(calibratedRed: 0.42, green: 0.90, blue: 0.55, alpha: 0.9)
        case .error: return NSColor(calibratedRed: 0.80, green: 0.40, blue: 0.95, alpha: 0.95)
        }
    }

    private static func badge(_ state: PetState) -> String? {
        switch state {
        case .idle: return nil
        case .working: return "~"
        case .blocked: return "!"
        case .done: return "✓"
        case .error: return "×"
        }
    }

    // MARK: - Animation

    /// Blocked and error states stare without blinking: a fixed gaze reads as
    /// "I am stuck on you".
    private static func isBlinking(state: PetState, time: TimeInterval) -> Bool {
        switch state {
        case .blocked, .error: return false
        case .working: return time.truncatingRemainder(dividingBy: 3.2) < 0.10
        default: return time.truncatingRemainder(dividingBy: 4.6) < 0.12
        }
    }

    // MARK: - Entry point

    static func draw(in rect: NSRect, state: PetState, time: TimeInterval) {
        draw(in: rect, state: state, bob: bob(state: state, time: time),
             blink: isBlinking(state: state, time: time), pulse: haloPulse(state: state, time: time))
    }

    /// Same picture with the animation inputs supplied, so a caller can cache the
    /// rendering and animate only the offset instead of repainting every frame.
    static func draw(in rect: NSRect, state: PetState, bob: CGFloat, blink: Bool, pulse: CGFloat) {
        let scale = min(rect.width, rect.height) / 210
        let center = NSPoint(x: rect.midX, y: rect.midY + 6 * scale + bob)

        drawHalo(state: state, center: center, scale: scale, pulse: pulse)
        drawBody(center: center, scale: scale)
        drawFace(center: center, scale: scale, blink: blink)
        drawBadge(state: state, center: center, scale: scale)
    }

    /// Vertical offset of the whole cat: what makes a still drawing breathe.
    static func bob(state: PetState, time: TimeInterval) -> CGFloat {
        let t = time
        switch state {
        case .idle: return CGFloat(sin(t * 2.2) * 2)
        case .working: return CGFloat(sin(t * 4) * 3)
        case .blocked: return CGFloat(sin(t * 6) * 1.4)
        case .done: return CGFloat(sin(t * 3) * 2)
        case .error: return CGFloat(sin(t * 5) * 1.2)
        }
    }

    static func blinkPhase(state: PetState, time: TimeInterval) -> Bool {
        isBlinking(state: state, time: time)
    }

    /// How often the bob cycle repeats, so a cache stays smooth without a 30 Hz repaint.
    static func frameInterval(state: PetState) -> CFTimeInterval {
        1.0 / 24.0
    }

    /// Pace of the glow, quantised: a cached rendering only needs a few steps.
    static func haloPulse(state: PetState, time: TimeInterval) -> CGFloat {
        let speed: Double = state == .blocked ? 3.4 : 1.8
        return CGFloat(0.85 + 0.15 * (sin(time * speed) * 0.5 + 0.5))
    }

    // MARK: - Icon and menu bar

    /// App icon: the cat on a warm rounded square, no halo or badge.
    static func icon(size: CGFloat) -> NSImage {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let image = NSImage(size: rect.size)
        image.lockFocus()

        let radius = size * 0.22
        let plate = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.055, dy: size * 0.055),
                                 xRadius: radius, yRadius: radius)
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.24, alpha: 1),
                   ending: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1))?
            .draw(in: plate, angle: -90)

        let scale = size / 210
        let center = NSPoint(x: rect.midX, y: rect.midY - 4 * scale)
        drawBody(center: center, scale: scale)
        drawFace(center: center, scale: scale, blink: false)

        image.unlockFocus()
        return image
    }

    /// Menu bar image: template (alpha only) so macOS tints it for light and dark bars.
    static func menuBarImage(height: CGFloat, blocked: Bool = false) -> NSImage {
        let rect = NSRect(x: 0, y: 0, width: height * 1.25, height: height)
        let image = NSImage(size: rect.size)
        image.lockFocus()

        NSColor.black.setFill()
        let scale = height / 130
        let center = NSPoint(x: height * 1.15 * 0.5, y: rect.midY - 6 * scale)

        for left in [true, false] {
            earPath(center: center, scale: scale, left: left).fill()
        }
        headPath(center: center, scale: scale).fill()

        // Punch the eyes out so the glyph still reads as a face at menu bar size.
        NSGraphicsContext.current?.compositingOperation = .clear
        for sign in [CGFloat(-1), 1] {
            NSBezierPath(ovalIn: NSRect(x: center.x + sign * 22 * scale - 6 * scale,
                                        y: center.y - 2 * scale,
                                        width: 12 * scale, height: 18 * scale)).fill()
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        if blocked {
            let dotR = height * 0.16
            let dotRect = NSRect(x: rect.maxX - dotR * 2 - 0.5, y: rect.maxY - dotR * 2 - 0.5,
                                 width: dotR * 2, height: dotR * 2)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Parts

    private static func headPath(center: NSPoint, scale: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - 56 * scale, y: center.y - 50 * scale,
                                    width: 112 * scale, height: 100 * scale))
    }

    private static func earPath(center: NSPoint, scale: CGFloat, left: Bool) -> NSBezierPath {
        let sign: CGFloat = left ? -1 : 1
        let p = NSBezierPath()
        p.move(to: NSPoint(x: center.x + sign * 40 * scale, y: center.y + 20 * scale))
        p.line(to: NSPoint(x: center.x + sign * 44 * scale, y: center.y + 62 * scale))
        p.line(to: NSPoint(x: center.x + sign * 8 * scale, y: center.y + 44 * scale))
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    private static func innerEarPath(center: NSPoint, scale: CGFloat, left: Bool) -> NSBezierPath {
        let sign: CGFloat = left ? -1 : 1
        let p = NSBezierPath()
        p.move(to: NSPoint(x: center.x + sign * 36 * scale, y: center.y + 26 * scale))
        p.line(to: NSPoint(x: center.x + sign * 38 * scale, y: center.y + 52 * scale))
        p.line(to: NSPoint(x: center.x + sign * 17 * scale, y: center.y + 41 * scale))
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    private static func drawHalo(state: PetState, center: NSPoint, scale: CGFloat, pulse: CGFloat) {
        guard let color = haloColor(state) else { return }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24 * scale * pulse
        shadow.shadowOffset = .zero
        shadow.shadowColor = color
        shadow.set()
        color.withAlphaComponent(0.95).setFill()
        headPath(center: center, scale: scale).fill()
        earPath(center: center, scale: scale, left: true).fill()
        earPath(center: center, scale: scale, left: false).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBody(center: NSPoint, scale: CGFloat) {
        let ears = [earPath(center: center, scale: scale, left: true),
                    earPath(center: center, scale: scale, left: false)]

        // Ears first, then the head on top, so the seam between them disappears.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 11 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -4 * scale)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
        shadow.set()
        furFlat.setFill()
        ears.forEach { $0.fill() }
        NSGraphicsContext.restoreGraphicsState()

        // The head carries its own shadow: on a photo wallpaper a flat cream blob
        // otherwise has no separation from the background.
        NSGraphicsContext.saveGraphicsState()
        let headShadow = NSShadow()
        headShadow.shadowBlurRadius = 0 * scale
        headShadow.shadowOffset = NSSize(width: 0, height: -5 * scale)
        headShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.32)
        headShadow.set()
        if let gradient = NSGradient(starting: furLight, ending: furDark) {
            gradient.draw(in: headPath(center: center, scale: scale), angle: -80)
        } else {
            furLight.setFill()
            headPath(center: center, scale: scale).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Hairline rim: on a bright wallpaper a cream blob has no edge otherwise.
        furDark.withAlphaComponent(0.55).setStroke()
        let rim = headPath(center: center, scale: scale)
        rim.lineWidth = 1.2 * scale
        rim.stroke()

        // A round stroke in the fur colour softens the ear corners.
        furFlat.setStroke()
        ears.forEach { $0.lineWidth = 9 * scale; $0.stroke() }

        NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.74, alpha: 0.85).setFill()
        innerEarPath(center: center, scale: scale, left: true).fill()
        innerEarPath(center: center, scale: scale, left: false).fill()
    }

    private static func drawFace(center: NSPoint, scale: CGFloat, blink: Bool) {
        // Eyes
        ink.setFill()
        ink.setStroke()
        for sign in [-1.0, 1.0] as [CGFloat] {
            let c = NSPoint(x: center.x + sign * 22 * scale, y: center.y + 2 * scale)
            if blink {
                let lid = NSBezierPath()
                lid.move(to: NSPoint(x: c.x - 8 * scale, y: c.y))
                lid.curve(to: NSPoint(x: c.x + 8 * scale, y: c.y),
                          controlPoint1: NSPoint(x: c.x - 4 * scale, y: c.y - 6 * scale),
                          controlPoint2: NSPoint(x: c.x + 4 * scale, y: c.y - 6 * scale))
                lid.lineWidth = 3.4 * scale
                lid.lineCapStyle = .round
                lid.stroke()
            } else {
                NSBezierPath(ovalIn: NSRect(x: c.x - 6 * scale, y: c.y - 9 * scale,
                                            width: 12 * scale, height: 18 * scale)).fill()
            }
        }

        // Blush
        blush.setFill()
        for sign in [-1.0, 1.0] as [CGFloat] {
            NSBezierPath(ovalIn: NSRect(x: center.x + sign * 40 * scale - 9 * scale,
                                        y: center.y - 20 * scale,
                                        width: 18 * scale, height: 11 * scale)).fill()
        }

        // Nose
        let nosePath = NSBezierPath()
        nosePath.move(to: NSPoint(x: center.x - 5 * scale, y: center.y - 14 * scale))
        nosePath.line(to: NSPoint(x: center.x + 5 * scale, y: center.y - 14 * scale))
        nosePath.line(to: NSPoint(x: center.x, y: center.y - 21 * scale))
        nosePath.close()
        nosePath.lineJoinStyle = .round
        nose.setFill()
        nosePath.fill()

        // Mouth: a short stem plus two arcs off the bottom of the nose
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: center.x, y: center.y - 20 * scale))
        stem.line(to: NSPoint(x: center.x, y: center.y - 26 * scale))
        stem.lineWidth = 2.2 * scale
        stem.lineCapStyle = .round
        stem.stroke()

        ink.setStroke()
        for sign in [-1.0, 1.0] as [CGFloat] {
            let m = NSBezierPath()
            m.move(to: NSPoint(x: center.x, y: center.y - 26 * scale))
            m.curve(to: NSPoint(x: center.x + sign * 14 * scale, y: center.y - 27 * scale),
                    controlPoint1: NSPoint(x: center.x + sign * 4 * scale, y: center.y - 34 * scale),
                    controlPoint2: NSPoint(x: center.x + sign * 11 * scale, y: center.y - 34 * scale))
            m.lineWidth = 2.6 * scale
            m.lineCapStyle = .round
            m.stroke()
        }

        // Whiskers
        // Start outside the blush so the whiskers never scratch across it.
        ink.withAlphaComponent(0.5).setStroke()
        for sign in [-1.0, 1.0] as [CGFloat] {
            for (i, dy) in [(-6.0), (-14.0), (-22.0)].enumerated() {
                let y = center.y + CGFloat(dy) * scale - 4 * scale
                let w = NSBezierPath()
                w.move(to: NSPoint(x: center.x + sign * 50 * scale, y: y))
                w.curve(to: NSPoint(x: center.x + sign * 74 * scale, y: y + CGFloat(4 - i * 4) * scale),
                        controlPoint1: NSPoint(x: center.x + sign * 58 * scale, y: y + 2 * scale),
                        controlPoint2: NSPoint(x: center.x + sign * 68 * scale, y: y + CGFloat(3 - i * 3) * scale))
                w.lineWidth = 2.0 * scale
                w.lineCapStyle = .round
                w.stroke()
            }
        }
    }

    /// A small filled disc with the state glyph: reads as a UI badge rather than
    /// a marking on the cat, and stays legible on any wallpaper.
    private static func drawBadge(state: PetState, center: NSPoint, scale: CGFloat) {
        guard let glyph = badge(state), let color = haloColor(state) else { return }

        let radius = 12 * scale
        let badgeCenter = NSPoint(x: center.x + 58 * scale, y: center.y + 40 * scale)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -1.5 * scale)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.30)
        shadow.set()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - radius, y: badgeCenter.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15 * scale, weight: .heavy),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 1),
        ]
        let text = NSAttributedString(string: glyph, attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: badgeCenter.x - size.width / 2,
                              y: badgeCenter.y - size.height / 2 + 1 * scale))
    }
}
