import AppKit
import ImageIO

/// Draws the pet plus an optional speech bubble, and handles drag / click.
///
/// Two render modes:
/// 1. The vector cat from `CatSprite`, animated in code (default).
/// 2. Sprite frames from `~/Library/Application Support/rex-pet/Assets/<state>/*.png`,
///    played at 12 fps. If a state has frames on disk they win, so generated art
///    can be dropped in later without touching this file.
final class PetView: NSView {
    var petState: PetState = .idle {
        didSet {
            guard petState != oldValue else { return }
            loadFrames()
            needsDisplay = true
        }
    }

    var bubbleText: String? {
        didSet { needsDisplay = true }
    }

    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?

    private let petSide: CGFloat = 160
    private let bubbleHeight: CGFloat = 64
    private let frameInterval: CFTimeInterval = 1.0 / 12.0

    private var frames: [CGImage] = []
    private var frameIndex = 0
    private var lastFrameSwap: CFTimeInterval = 0
    private var ticker: Timer?
    private let bornAt = CACurrentMediaTime()

    private var dragStart: NSPoint = .zero
    private var windowOriginAtDrag: NSPoint = .zero
    private var didDrag = false
    private(set) var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        startTicking()
        loadFrames()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { ticker?.invalidate() }

    private func startTicking() {
        // .common mode keeps the animation alive while a drag tracking loop runs.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: - Layout

    private var petRect: NSRect {
        NSRect(x: (bounds.width - petSide) / 2, y: 0, width: petSide, height: petSide)
    }

    private var bubbleRect: NSRect {
        NSRect(x: 8, y: bounds.height - bubbleHeight, width: bounds.width - 16, height: bubbleHeight - 10)
    }

    private var hitRegion: NSRect {
        var region = petRect.insetBy(dx: 18, dy: 18)
        if bubbleText != nil { region = region.union(bubbleRect) }
        return region
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawPet()
        if let text = bubbleText { drawBubble(text) }
    }

    private func drawPet() {
        if !frames.isEmpty {
            drawSprite()
            return
        }
        CatSprite.draw(in: petRect, state: petState, time: CACurrentMediaTime() - bornAt)
    }

    private func drawSprite() {
        let now = CACurrentMediaTime()
        if now - lastFrameSwap > frameInterval {
            lastFrameSwap = now
            frameIndex = (frameIndex + 1) % frames.count
        }
        guard let image = frames[safe: frameIndex],
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        let rect = petRect
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h))
    }

    private func drawBubble(_ text: String) {
        let rect = bubbleRect
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor(white: 1.0, alpha: 0.94).setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.15, alpha: 1),
        ]
        let inset = rect.insetBy(dx: 8, dy: 6)
        (text as NSString).draw(
            with: inset,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs
        )
    }

    // MARK: - Assets

    private func loadFrames() {
        frames = []
        frameIndex = 0

        let base = ("~/Library/Application Support/rex-pet/Assets" as NSString).expandingTildeInPath
        let dir = URL(fileURLWithPath: base).appendingPathComponent(petState.rawValue)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        let pngs = files
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        frames = pngs.compactMap { url in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
    }

    // MARK: - Mouse

    /// Hit test in screen coordinates, used by the click-through monitor.
    func isInteractive(screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return hitRegion.contains(local)
    }

    /// Screen-space rect the reply panel should dock to.
    var screenAnchor: NSRect {
        guard let window else { return .zero }
        let origin = window.convertPoint(toScreen: NSPoint(x: petRect.midX, y: petRect.maxY))
        return NSRect(x: origin.x - 1, y: origin.y, width: 2, height: 1)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return hitRegion.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        isDragging = false
        dragStart = NSEvent.mouseLocation
        windowOriginAtDrag = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStart.x
        let dy = now.y - dragStart.y
        if abs(dx) > 2 || abs(dy) > 2 {
            didDrag = true
            isDragging = true
        }
        window.setFrameOrigin(NSPoint(x: windowOriginAtDrag.x + dx, y: windowOriginAtDrag.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if didDrag {
            onDragEnd?(window?.frame.origin ?? .zero)
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
