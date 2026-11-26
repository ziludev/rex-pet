// Cat pet style candidates, all pure vector so any frame can be generated.
// Usage: swift tools/style-cat.swift [out.png]
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/cat-styles.png"

let tile = NSSize(width: 240, height: 300)
let canvas = NSSize(width: tile.width * 5, height: tile.height)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let bg = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
bg.setFill()
NSRect(origin: .zero, size: canvas).fill()

// A fake terminal window edge, to judge how the pet sits on real chrome
NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.17, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: canvas.width, height: 46).fill()
NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.26, alpha: 1).setFill()
NSRect(x: 0, y: 44, width: canvas.width, height: 2).fill()

func label(_ text: String, at point: NSPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.82, alpha: 1),
    ]
    NSAttributedString(string: text, attributes: attrs).draw(at: point)
}

let rowsY = tile.height * 0.52

creamCat(center: NSPoint(x: tile.width * 0.5, y: rowsY), scale: 1.0, blink: false, state: .idle)
label("1  奶白团子猫", at: NSPoint(x: 16, y: 14))

silhouetteCat(center: NSPoint(x: tile.width * 1.5, y: rowsY - 6), scale: 1.0)
label("2  黑猫剪影", at: NSPoint(x: tile.width + 16, y: 14))

lineArtCat(center: NSPoint(x: tile.width * 2.5, y: rowsY), scale: 1.0)
label("3  线稿猫", at: NSPoint(x: tile.width * 2 + 16, y: 14))

pixelCat(center: NSPoint(x: tile.width * 3.5, y: rowsY), scale: 7.0)
label("4  像素猫", at: NSPoint(x: tile.width * 3 + 16, y: 14))

// 5: the recommended one, at real sizes and in the blocked state
let base = NSPoint(x: tile.width * 4.5, y: rowsY)
creamCat(center: NSPoint(x: base.x - 34, y: base.y + 40), scale: 0.80, blink: false, state: .idle)
creamCat(center: NSPoint(x: base.x + 52, y: base.y - 6), scale: 0.62, blink: true, state: .working)
creamCat(center: NSPoint(x: base.x - 14, y: base.y - 62), scale: 0.45, blink: false, state: .blocked)
label("5  实际尺寸 + 状态", at: NSPoint(x: tile.width * 4 + 16, y: 14))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

// MARK: - Shared helpers

enum CatState { case idle, working, blocked }
enum Style { case filled, line, silhouette }

func softShadow(_ size: CGFloat, alpha: CGFloat = 0.45) {
    let s = NSShadow()
    s.shadowBlurRadius = size * 0.10
    s.shadowOffset = NSSize(width: 0, height: -size * 0.04)
    s.shadowColor = NSColor(calibratedWhite: 0, alpha: alpha)
    s.set()
}

func halo(_ state: CatState, path: NSBezierPath, scale: CGFloat) {
    let color: NSColor
    switch state {
    case .idle: return
    case .working: color = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.30, alpha: 0.9)
    case .blocked: color = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.44, alpha: 0.95)
    }
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowBlurRadius = 24 * scale
    s.shadowOffset = .zero
    s.shadowColor = color
    s.set()
    color.withAlphaComponent(0.95).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func tint(_ state: CatState) -> NSColor? {
    switch state {
    case .idle: return nil
    case .working: return NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.30, alpha: 1)
    case .blocked: return NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.47, alpha: 1)
    }
}

// MARK: - 1. Cream blob cat

struct CreamCat {
    static func head(center: NSPoint, scale: CGFloat) -> NSBezierPath {
        let p = NSBezierPath(ovalIn: NSRect(x: center.x - 56 * scale, y: center.y - 50 * scale,
                                            width: 112 * scale, height: 100 * scale))
        return p
    }

    /// Ears are round-cornered triangles grown out of the head outline.
    static func ear(center: NSPoint, scale: CGFloat, left: Bool) -> NSBezierPath {
        let s = scale
        let sign: CGFloat = left ? -1 : 1
        let p = NSBezierPath()
        p.move(to: NSPoint(x: center.x + sign * 40 * s, y: center.y + 20 * s))
        p.line(to: NSPoint(x: center.x + sign * 44 * s, y: center.y + 62 * s))
        p.line(to: NSPoint(x: center.x + sign * 8 * s, y: center.y + 44 * s))
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    static func innerEar(center: NSPoint, scale: CGFloat, left: Bool) -> NSBezierPath {
        let s = scale
        let sign: CGFloat = left ? -1 : 1
        let p = NSBezierPath()
        p.move(to: NSPoint(x: center.x + sign * 36 * s, y: center.y + 26 * s))
        p.line(to: NSPoint(x: center.x + sign * 38 * s, y: center.y + 52 * s))
        p.line(to: NSPoint(x: center.x + sign * 17 * s, y: center.y + 41 * s))
        p.close()
        p.lineJoinStyle = .round
        return p
    }
}

func earInner(center: NSPoint, scale: CGFloat) -> [NSBezierPath] {
    [CreamCat.innerEar(center: center, scale: scale, left: true),
     CreamCat.innerEar(center: center, scale: scale, left: false)]
}

func drawCreamBody(center: NSPoint, scale: CGFloat, style: Style, state: CatState) {
    let head = CreamCat.head(center: center, scale: scale)
    let ears = [CreamCat.ear(center: center, scale: scale, left: true),
                CreamCat.ear(center: center, scale: scale, left: false)]

    if style == .filled {
        if tint(state) != nil {
            ears.forEach { halo(state, path: $0, scale: scale) }
            halo(state, path: head, scale: scale)
        }
        // Ears first, then head on top so the seam disappears.
        NSGraphicsContext.saveGraphicsState()
        softShadow(110 * scale, alpha: 0.35)
        NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.87, alpha: 1).setFill()
        ears.forEach { $0.fill() }
        NSGraphicsContext.restoreGraphicsState()

        let body = NSGradient(
            starting: NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.95, alpha: 1),
            ending: NSColor(calibratedRed: 0.95, green: 0.86, blue: 0.78, alpha: 1)
        )!
        body.draw(in: head, angle: -80)

        // Soften ear corners with a round stroke
        NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.87, alpha: 1).setStroke()
        ears.forEach { $0.lineWidth = 9 * scale; $0.stroke() }

        NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.74, alpha: 0.85).setFill()
        earInner(center: center, scale: scale).forEach { $0.fill() }
    } else {
        NSColor(calibratedRed: 0.99, green: 0.95, blue: 0.90, alpha: 0.95).setStroke()
        head.lineWidth = 2.4 * scale
        head.stroke()

        // Ear outlines only outside the head, otherwise the crossing lines read as a bow.
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: NSRect(x: center.x - 140 * scale, y: center.y - 140 * scale,
                                                width: 280 * scale, height: 280 * scale))
        outside.append(head)
        outside.windingRule = .evenOdd
        outside.addClip()
        ears.forEach { $0.lineWidth = 2.4 * scale; $0.stroke() }
        NSGraphicsContext.restoreGraphicsState()
    }
}

func drawCreamFace(center: NSPoint, scale: CGFloat, blink: Bool, style: Style) {
    let s = scale
    let ink = NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.18, alpha: 1)
    ink.setFill()
    ink.setStroke()

    for sign in [-1.0, 1.0] as [CGFloat] {
        let c = NSPoint(x: center.x + sign * 22 * s, y: center.y + 2 * s)
        if blink {
            let l = NSBezierPath()
            l.move(to: NSPoint(x: c.x - 8 * s, y: c.y))
            l.curve(to: NSPoint(x: c.x + 8 * s, y: c.y),
                    controlPoint1: NSPoint(x: c.x - 4 * s, y: c.y - 6 * s),
                    controlPoint2: NSPoint(x: c.x + 4 * s, y: c.y - 6 * s))
            l.lineWidth = 3.4 * s
            l.lineCapStyle = .round
            l.stroke()
        } else {
            NSBezierPath(ovalIn: NSRect(x: c.x - 6 * s, y: c.y - 9 * s, width: 12 * s, height: 18 * s)).fill()
        }
    }

    // Blush
    NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.64, alpha: 0.35).setFill()
    for sign in [-1.0, 1.0] as [CGFloat] {
        NSBezierPath(ovalIn: NSRect(x: center.x + sign * 40 * s - 9 * s, y: center.y - 20 * s,
                                    width: 18 * s, height: 11 * s)).fill()
    }

    // Nose
    let nose = NSBezierPath()
    nose.move(to: NSPoint(x: center.x - 5 * s, y: center.y - 14 * s))
    nose.line(to: NSPoint(x: center.x + 5 * s, y: center.y - 14 * s))
    nose.line(to: NSPoint(x: center.x, y: center.y - 21 * s))
    nose.close()
    nose.lineJoinStyle = .round
    NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.60, alpha: 1).setFill()
    nose.fill()

    // Mouth: two small arcs from the nose
    let mouth = NSBezierPath()
    mouth.move(to: NSPoint(x: center.x, y: center.y - 21 * s))
    mouth.line(to: NSPoint(x: center.x, y: center.y - 26 * s))
    for sign in [-1.0, 1.0] as [CGFloat] {
        let m = NSBezierPath()
        m.move(to: NSPoint(x: center.x, y: center.y - 26 * s))
        m.curve(to: NSPoint(x: center.x + sign * 14 * s, y: center.y - 27 * s),
                controlPoint1: NSPoint(x: center.x + sign * 4 * s, y: center.y - 34 * s),
                controlPoint2: NSPoint(x: center.x + sign * 11 * s, y: center.y - 34 * s))
        m.lineWidth = 2.6 * s
        m.lineCapStyle = .round
        m.stroke()
    }
    mouth.lineWidth = 2.2 * s
    mouth.stroke()

    // Whiskers
    let whisker = NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.18, alpha: 0.55)
    whisker.setStroke()
    for sign in [-1.0, 1.0] as [CGFloat] {
        for (i, dy) in [(-6.0), (-14.0), (-22.0)].enumerated() {
            let w = NSBezierPath()
            let y = center.y + CGFloat(dy) * s - 4 * s
            w.move(to: NSPoint(x: center.x + sign * 46 * s, y: y))
            w.curve(to: NSPoint(x: center.x + sign * 74 * s, y: y + CGFloat(4 - i * 4) * s),
                    controlPoint1: NSPoint(x: center.x + sign * 58 * s, y: y + 2 * s),
                    controlPoint2: NSPoint(x: center.x + sign * 68 * s, y: y + CGFloat(3 - i * 3) * s))
            w.lineWidth = 2.0 * s
            w.lineCapStyle = .round
            w.stroke()
        }
    }
}

func creamCat(center: NSPoint, scale: CGFloat, blink: Bool, state: CatState) {
    drawCreamBody(center: center, scale: scale, style: .filled, state: state)
    drawCreamFace(center: center, scale: scale, blink: blink, style: .filled)

    if state != .idle {
        let glyph = state == .blocked ? "!" : "~"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22 * scale, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.95),
        ]
        let text = NSAttributedString(string: glyph, attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: center.x + 58 * scale, y: center.y + 40 * scale - size.height / 2))
    }
}

// MARK: - 2. Silhouette cat

func silhouetteCat(center: NSPoint, scale: CGFloat) {
    let s = scale
    let ink = NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.15, alpha: 1)

    let body = NSBezierPath()
    body.move(to: NSPoint(x: center.x - 40 * s, y: center.y - 66 * s))
    body.curve(to: NSPoint(x: center.x - 38 * s, y: center.y + 8 * s),
               controlPoint1: NSPoint(x: center.x - 46 * s, y: center.y - 36 * s),
               controlPoint2: NSPoint(x: center.x - 46 * s, y: center.y - 12 * s))
    body.curve(to: NSPoint(x: center.x + 38 * s, y: center.y + 8 * s),
               controlPoint1: NSPoint(x: center.x - 18 * s, y: center.y + 24 * s),
               controlPoint2: NSPoint(x: center.x + 18 * s, y: center.y + 24 * s))
    body.curve(to: NSPoint(x: center.x + 40 * s, y: center.y - 66 * s),
               controlPoint1: NSPoint(x: center.x + 46 * s, y: center.y - 12 * s),
               controlPoint2: NSPoint(x: center.x + 46 * s, y: center.y - 36 * s))
    body.close()

    // Tail curled along the ground beside the body
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: center.x + 34 * s, y: center.y - 52 * s))
    tail.curve(to: NSPoint(x: center.x + 76 * s, y: center.y - 60 * s),
               controlPoint1: NSPoint(x: center.x + 66 * s, y: center.y - 44 * s),
               controlPoint2: NSPoint(x: center.x + 78 * s, y: center.y - 46 * s))

    let head = NSBezierPath(ovalIn: NSRect(x: center.x - 46 * s, y: center.y - 2 * s,
                                           width: 92 * s, height: 84 * s))

    func ear(left: Bool) -> NSBezierPath {
        let sign: CGFloat = left ? -1 : 1
        let p = NSBezierPath()
        p.move(to: NSPoint(x: center.x + sign * 40 * s, y: center.y + 46 * s))
        p.line(to: NSPoint(x: center.x + sign * 44 * s, y: center.y + 88 * s))
        p.line(to: NSPoint(x: center.x + sign * 6 * s, y: center.y + 66 * s))
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    NSGraphicsContext.saveGraphicsState()
    softShadow(150 * s, alpha: 0.5)
    ink.setFill()
    body.fill()
    tail.lineWidth = 15 * s
    tail.lineCapStyle = .round
    ink.setStroke()
    tail.stroke()
    [ear(left: true), ear(left: false), head].forEach { $0.fill() }
    NSGraphicsContext.restoreGraphicsState()

    // Rim light so the black cat separates from a dark desktop
    NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.85, alpha: 0.55).setStroke()
    [ear(left: true), ear(left: false), head].forEach { $0.lineWidth = 2.2 * s; $0.stroke() }

    let eye = NSColor(calibratedRed: 0.70, green: 0.94, blue: 0.55, alpha: 1)
    eye.setFill()
    for sign in [-1.0, 1.0] as [CGFloat] {
        let c = NSPoint(x: center.x + sign * 19 * s, y: center.y + 34 * s)
        let almond = NSBezierPath(ovalIn: NSRect(x: c.x - 11 * s, y: c.y - 12 * s,
                                                width: 22 * s, height: 24 * s))
        almond.fill()
        NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 3 * s, y: c.y - 11 * s, width: 6 * s, height: 22 * s)).fill()
        eye.setFill()
    }
}

// MARK: - 3. Line-art cat

func lineArtCat(center: NSPoint, scale: CGFloat) {
    drawCreamBody(center: center, scale: scale, style: .line, state: .idle)

    let ink = NSColor(calibratedRed: 0.97, green: 0.93, blue: 0.88, alpha: 0.9)
    ink.setStroke()
    ink.setFill()

    for sign in [-1.0, 1.0] as [CGFloat] {
        let c = NSPoint(x: center.x + sign * 22 * scale, y: center.y + 2 * scale)
        let e = NSBezierPath(ovalIn: NSRect(x: c.x - 6 * scale, y: c.y - 9 * scale,
                                            width: 12 * scale, height: 18 * scale))
        e.lineWidth = 2.4 * scale
        e.stroke()
    }
    let noseMouth = NSBezierPath()
    noseMouth.move(to: NSPoint(x: center.x, y: center.y - 12 * scale))
    noseMouth.line(to: NSPoint(x: center.x, y: center.y - 26 * scale))
    for sign in [-1.0, 1.0] as [CGFloat] {
        noseMouth.move(to: NSPoint(x: center.x, y: center.y - 26 * scale))
        noseMouth.curve(to: NSPoint(x: center.x + sign * 14 * scale, y: center.y - 28 * scale),
                        controlPoint1: NSPoint(x: center.x + sign * 4 * scale, y: center.y - 35 * scale),
                        controlPoint2: NSPoint(x: center.x + sign * 11 * scale, y: center.y - 35 * scale))
    }
    noseMouth.lineWidth = 2.2 * scale
    noseMouth.lineCapStyle = .round
    noseMouth.stroke()

    for sign in [-1.0, 1.0] as [CGFloat] {
        for (i, dy) in [(-8.0), (-16.0), (-24.0)].enumerated() {
            let w = NSBezierPath()
            let y = center.y + CGFloat(dy) * scale - 2 * scale
            w.move(to: NSPoint(x: center.x + sign * 46 * scale, y: y))
            w.line(to: NSPoint(x: center.x + sign * 74 * scale, y: y + CGFloat(2 - i * 4) * scale))
            w.lineWidth = 1.8 * scale
            w.lineCapStyle = .round
            w.stroke()
        }
    }
}

// MARK: - 4. Pixel cat


func pixelCat(center: NSPoint, scale: CGFloat) {
    let pixelPattern: [String] = [
        "................",
        "..BB........BB..",
        "..BBBB....BBBB..",
        "..BBBBBBBBBBBB..",
        "..BBBBBBBBBBBB..",
        "..BBBBBBBBBBBB..",
        "..BBGGBBBBGGBB..",
        "..BBGGBBBBGGBB..",
        "..BBBBBBBBBBBB..",
        "..BBBBPPPPBBBB..",
        "...BBBBBBBBBB...",
        "....BBBBBBBB....",
        "....BBBBBBBB....",
        "...BBBBBBBBBB...",
        "................",
        "................",
    ]
    let cols = CGFloat(pixelPattern[0].count)
    let rows = CGFloat(pixelPattern.count)
    let dark = NSColor(calibratedRed: 0.93, green: 0.91, blue: 0.96, alpha: 1)
    let eye = NSColor(calibratedRed: 0.35, green: 0.88, blue: 0.72, alpha: 1)
    let pink = NSColor(calibratedRed: 0.96, green: 0.58, blue: 0.66, alpha: 1)
    let origin = NSPoint(x: center.x - cols * scale / 2, y: center.y - rows * scale / 2)
    NSGraphicsContext.saveGraphicsState()
    softShadow(cols * scale, alpha: 0.35)
    for (r, line) in pixelPattern.enumerated() {
            for (c, ch) in line.enumerated() where ch != "." {
            let color: NSColor
            switch ch {
            case "G": color = eye
            case "P": color = pink
            default: color = dark
            }
            color.setFill()
            NSRect(x: origin.x + CGFloat(c) * scale,
                   y: origin.y + (rows - CGFloat(r) - 1) * scale,
                   width: scale, height: scale).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}
