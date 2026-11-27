import AppKit
import AVFoundation
import ImageIO

/// Draws the pet plus an optional speech bubble, and handles drag / click.
///
/// Three render modes, resolved per asset root (`~/Library/Application Support/rex-pet/Assets`
/// before the bundled `Assets/`):
/// 1. An HEVC-with-alpha clip at `<root>/<state>.mov` (what `tools/make-pet.sh` produces),
///    looped by AVPlayer.
/// 2. Sprite frames from `<root>/<state>/*.png`, played at 12 fps.
/// 3. The vector cat from `CatSprite`, animated in code (default).
///
/// Any custom clip or PNG frame folder in the user's Assets folder therefore overrides
/// the bundled clips without modifying the app bundle.
final class PetView: NSView {
    enum AssetSource: Equatable {
        case movie(URL, Date?)
        case frames(URL, Date?)
        case vector
    }

    enum PetSize: String, CaseIterable {
        case small
        case medium
        case large

        var petSide: CGFloat {
            switch self {
            case .small: return 140
            case .medium: return 180
            case .large: return 220
            }
        }

        var panelSize: NSSize {
            NSSize(width: petSide + 60, height: petSide + 84)
        }

        var label: String {
            switch self {
            case .small: return L10n.t("Small (140 pt)", "小 (140 pt)")
            case .medium: return L10n.t("Medium (180 pt)", "中 (180 pt)")
            case .large: return L10n.t("Large (220 pt)", "大 (220 pt)")
            }
        }
    }

    static let defaultThemeID = "default"
    static let vectorThemeID = "vector"
    static let whaleThemeID = "whale-girl"

    var petSize: PetSize = .medium {
        didSet {
            guard petSize != oldValue else { return }
            artCache.removeAll()
            needsLayout = true
            needsDisplay = true
        }
    }

    var selectedTheme: String = PetView.defaultThemeID {
        didSet {
            guard selectedTheme != oldValue else { return }
            reloadAssets()
        }
    }

    var petState: PetState = .idle {
        didSet {
            guard petState != oldValue else { return }
            loadAsset()
            needsDisplay = true
        }
    }

    var bubbleText: String? {
        didSet {
            guard bubbleText != oldValue else { return }
            needsDisplay = true
        }
    }

    var onLog: ((String) -> Void)?
    var onClick: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?

    private var petSide: CGFloat { petSize.petSide }
    private let bubbleHeight: CGFloat = 64
    private let frameInterval: CFTimeInterval = 1.0 / 12.0

    private var frames: [CGImage] = []
    private var framesCache: [URL: (mtime: Date?, images: [CGImage])] = [:]
    /// Clips AVPlayer refuses to open are remembered, so a bad file in Assets
    /// falls back to PNG frames or the drawn cat instead of retrying on every state change.
    private var failedMovies: Set<URL> = []
    private var itemObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?
    private var moviePlayer: AVQueuePlayer?
    private var movieLooper: AVPlayerLooper?
    private var movieLayer: AVPlayerLayer?
    private var outgoingPlayer: AVQueuePlayer?
    private var outgoingLooper: AVPlayerLooper?
    private var outgoingLayer: AVPlayerLayer?
    private var loadedMovieURL: URL?
    private var loadedMovieMtime: Date?
    private var frameIndex = 0
    private var lastFrameSwap: CFTimeInterval = 0
    private var ticker: Timer?
    private var tickerInterval: CFTimeInterval = 0
    private let bornAt = CACurrentMediaTime()

    private var dragStart: NSPoint = .zero
    private var windowOriginAtDrag: NSPoint = .zero
    private var didDrag = false
    private(set) var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        loadAsset()
        startTicking()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        ticker?.invalidate()
        itemObservation = nil
        readyObservation = nil
        moviePlayer?.pause()
        outgoingPlayer?.pause()
    }

    func reloadAssets() {
        failedMovies.removeAll()
        framesCache.removeAll()
        artCache.removeAll()
        loadedMovieURL = nil
        loadedMovieMtime = nil
        loadAsset()
        needsDisplay = true
    }

    private var activeFrameInterval: CFTimeInterval {
        frames.count >= 20 ? (1.0 / 18.0) : frameInterval
    }

    private func desiredTickInterval() -> CFTimeInterval {
        if movieLayer != nil { return 1.0 }
        if !frames.isEmpty { return activeFrameInterval }
        return CatSprite.frameInterval(state: petState)
    }

    private func startTicking() {
        let interval = desiredTickInterval()
        if ticker != nil, abs(tickerInterval - interval) < 0.001 { return }

        ticker?.invalidate()
        tickerInterval = interval
        // .common mode keeps the animation alive while a drag tracking loop runs.
        // A playing .mov is composited by AVPlayerLayer, so waking only once per second
        // for stall detection avoids unnecessary 30 Hz repaints.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.movieLayer == nil { self.needsDisplay = true }
            self.reportPlayback()
        }
        timer.tolerance = interval >= 1.0 ? 0.25 : interval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private var lastPlaybackReport: CFTimeInterval = 0
    private var lastMovieTime: Double = -1
    private var stalledReports = 0

    /// Samples playback periodically to log activity and catch clips that stall after opening.
    private func reportPlayback() {
        guard let player = moviePlayer else { return }
        let now = CACurrentMediaTime()
        guard now - lastPlaybackReport > 2 else { return }
        lastPlaybackReport = now
        let time = player.currentTime().seconds
        onLog?("movie rate=\(player.rate) t=\(String(format: "%.2f", time))")

        // A file can open and still never advance — a truncated download or a
        // codec macOS has no decoder for. Two reports without progress is enough
        // to stop trusting it; fallback covers the state from then on.
        if time.isNaN || time == lastMovieTime {
            stalledReports += 1
        } else {
            stalledReports = 0
        }
        lastMovieTime = time
        if stalledReports >= 2, let url = loadedMovieURL {
            onLog?("clip \(url.lastPathComponent) is not playing; falling back")
            failedMovies.insert(url)
            stalledReports = 0
            teardownMovie()
            loadAsset()
            needsDisplay = true
        }
    }

    // MARK: - Layout

    private var petRect: NSRect {
        NSRect(x: (bounds.width - petSide) / 2, y: 0, width: petSide, height: petSide)
    }

    private var currentBubbleRect: NSRect {
        let maxW = bounds.width - 20
        let tailH: CGFloat = 6
        let horizontalChrome: CGFloat = 34 // left pad + status dot + gap + right pad
        let bodyW: CGFloat
        let bodyH: CGFloat
        if let text = bubbleText {
            let measured = attributedBubbleText(text).boundingRect(
                with: NSSize(width: maxW - horizontalChrome, height: 42),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
            bodyW = min(maxW, max(64, ceil(measured.width) + horizontalChrome))
            bodyH = min(54, max(28, ceil(measured.height) + 12))
        } else {
            bodyW = 96
            bodyH = 30
        }
        let x = round((bounds.width - bodyW) / 2)
        let y = petRect.maxY - 8 + tailH
        return NSRect(x: x, y: y, width: bodyW, height: bodyH)
    }

    private var hitRegion: NSRect {
        // Generated clips and PNG packs carry their own empty margin, so be forgiving.
        let inset: CGFloat = (movieLayer == nil && frames.isEmpty) ? 18 : 24
        var region = petRect.insetBy(dx: inset, dy: inset)
        if bubbleText != nil {
            let bubbleWithTail = currentBubbleRect.insetBy(dx: 0, dy: -6)
            region = region.union(bubbleWithTail)
        }
        return region
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawPet()
        if let text = bubbleText { drawBubble(text) }
    }

    private func drawPet() {
        // The movie draws itself through its layer; anything here would paint over it.
        if movieLayer != nil { return }
        if !frames.isEmpty {
            drawSprite()
            return
        }
        let time = CACurrentMediaTime() - bornAt
        let blink = CatSprite.blinkPhase(state: petState, time: time)
        guard let image = art(for: petState, blink: blink) else { return }
        let bob = CatSprite.bob(state: petState, time: time)
        image.draw(in: petRect.offsetBy(dx: 0, dy: bob), from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawSprite() {
        let now = CACurrentMediaTime()
        if now - lastFrameSwap >= activeFrameInterval * 0.9 {
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

    private func bubbleAccentColor() -> NSColor {
        switch petState {
        case .idle: return NSColor(calibratedRed: 0.48, green: 0.86, blue: 0.96, alpha: 1)
        case .working: return NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.30, alpha: 1)
        case .blocked: return NSColor(calibratedRed: 1.0, green: 0.44, blue: 0.46, alpha: 1)
        case .done: return NSColor(calibratedRed: 0.42, green: 0.90, blue: 0.58, alpha: 1)
        case .error: return NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.98, alpha: 1)
        }
    }

    private func attributedBubbleText(_ text: String) -> NSAttributedString {
        let primary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
        ]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.74, alpha: 1),
        ]
        let out = NSMutableAttributedString()
        if let range = text.range(of: " · ") {
            out.append(NSAttributedString(string: String(text[..<range.lowerBound]), attributes: primary))
            out.append(NSAttributedString(string: String(text[range.lowerBound...]), attributes: secondary))
        } else {
            out.append(NSAttributedString(string: text, attributes: primary))
        }
        return out
    }

    private func bubblePath(body rect: NSRect) -> NSBezierPath {
        let r = min(13, rect.height / 2)
        let tailHalfW: CGFloat = 5.5
        let tailH: CGFloat = 6
        let midX = rect.midX

        let p = NSBezierPath()
        // Start right of the bottom-center tail and trace counter-clockwise in Cocoa coords
        p.move(to: NSPoint(x: midX + tailHalfW, y: rect.minY))
        p.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
        p.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 270, endAngle: 0)
        p.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
        p.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))
        p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: rect.minX, y: rect.minY + r))
        p.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: 180, endAngle: 270)
        p.line(to: NSPoint(x: midX - tailHalfW, y: rect.minY))
        p.line(to: NSPoint(x: midX, y: rect.minY - tailH))
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    private func drawBubble(_ text: String) {
        let rect = currentBubbleRect
        let path = bubblePath(body: rect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.38)
        shadow.set()
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.92).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 1.0, alpha: 0.15).setStroke()
        path.lineWidth = 1
        path.stroke()

        // State accent dot on the left of the text
        let dotSize: CGFloat = 7
        let dotY = rect.midY - dotSize / 2
        let dotRect = NSRect(x: rect.minX + 11, y: dotY, width: dotSize, height: dotSize)
        bubbleAccentColor().setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let attrText = attributedBubbleText(text)
        let textInset = NSRect(x: rect.minX + 24, y: rect.minY + 5, width: rect.width - 34, height: rect.height - 10)
        let measured = attrText.boundingRect(with: textInset.size, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let centeredY = rect.minY + (rect.height - ceil(measured.height)) / 2
        let drawRect = NSRect(x: textInset.minX, y: centeredY, width: textInset.width, height: ceil(measured.height) + 2)
        attrText.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: - Assets

    /// The drawn cat costs ~5 ms a frame, so render once per (state, blink) pose and
    /// animate only the vertical offset.
    private var artCache: [String: NSImage] = [:]

    private func art(for state: PetState, blink: Bool) -> NSImage? {
        let key = "\(state.rawValue)-\(blink)"
        if let cached = artCache[key] { return cached }

        let side = petSide
        let pixels = Int(side * 2) // retina; the cache is blitted 1:1 otherwise
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            // The glow is frozen at one phase: it is decoration, and animating it
            // was most of the per-frame cost.
            CatSprite.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                           state: state, bob: 0, blink: blink, pulse: 0.9)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        artCache[key] = image
        return image
    }

    /// Where art is looked up: for `"default"`, user `Assets/` then bundled `Assets/`;
    /// for a named theme, user `Themes/<name>/` then bundled `Themes/<name>/`.
    private var assetRoots: [URL] {
        Self.assetRoots(forTheme: selectedTheme,
                        appSupport: URL(fileURLWithPath: ("~/Library/Application Support/rex-pet" as NSString).expandingTildeInPath),
                        bundleResources: Bundle.main.resourceURL)
    }

    static func assetRoots(forTheme theme: String, appSupport: URL, bundleResources: URL?) -> [URL] {
        if theme == vectorThemeID { return [] }
        if theme == whaleThemeID {
            if let bundled = bundleResources?.appendingPathComponent("Assets") {
                return [bundled]
            }
            return []
        }
        if theme != defaultThemeID {
            var roots = [appSupport.appendingPathComponent("Themes").appendingPathComponent(theme)]
            if let bundled = bundleResources?.appendingPathComponent("Themes").appendingPathComponent(theme) {
                roots.append(bundled)
            }
            return roots
        }
        // Default uses user-dropped Assets/ if present, otherwise falls back to the built-in vector cat.
        return [appSupport.appendingPathComponent("Assets")]
    }

    static func availableThemes(appSupport: URL = URL(fileURLWithPath: ("~/Library/Application Support/rex-pet" as NSString).expandingTildeInPath),
                                bundleResources: URL? = Bundle.main.resourceURL) -> [String] {
        let fm = FileManager.default
        var names = Set<String>()
        for base in [appSupport.appendingPathComponent("Themes"), bundleResources?.appendingPathComponent("Themes")].compactMap({ $0 }) {
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for item in items {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { names.insert(item.lastPathComponent) }
            }
        }
        if let assets = bundleResources?.appendingPathComponent("Assets"),
           fm.fileExists(atPath: assets.appendingPathComponent("idle.mov").path) {
            names.insert(whaleThemeID)
        }
        return names.sorted()
    }

    /// Resolves the highest-priority asset per root (`mov` before `png` within the same root,
    /// and user root before bundled root). Tested by `--selftest`.
    static func resolveAsset(for state: PetState, in roots: [URL], failedMovies: Set<URL> = []) -> AssetSource {
        let fm = FileManager.default
        let stateName = state.rawValue
        let movieCandidates = ["\(stateName).mov", "mov/\(stateName).mov", "\(stateName)/loop.mov"]

        for root in roots {
            for rel in movieCandidates {
                let candidate = root.appendingPathComponent(rel)
                if !failedMovies.contains(candidate), fm.fileExists(atPath: candidate.path) {
                    return .movie(candidate, modificationDate(of: candidate))
                }
            }
            let dir = root.appendingPathComponent(stateName)
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
               files.contains(where: { $0.pathExtension.lowercased() == "png" }) {
                return .frames(dir, modificationDate(of: dir))
            }
        }
        return .vector
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func loadAsset() {
        switch Self.resolveAsset(for: petState, in: assetRoots, failedMovies: failedMovies) {
        case .movie(let url, let mtime):
            frames = []
            frameIndex = 0
            loadMovie(url: url, mtime: mtime)
        case .frames(let dir, let mtime):
            teardownMovie()
            loadFrames(from: dir, mtime: mtime)
        case .vector:
            teardownMovie()
            frames = []
            frameIndex = 0
        }
        startTicking()
    }

    private func loadMovie(url: URL, mtime: Date?) {
        if url == loadedMovieURL && mtime == loadedMovieMtime { return }

        // Keep the previous layer alive until the new player renders its first frame
        // so switching states never flashes invisible.
        promoteMovieToOutgoing()

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: item)

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false
        layer.frame = petRect
        layer.opacity = outgoingLayer == nil ? 1 : 0
        self.layer?.addSublayer(layer)

        readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] observed, _ in
            guard observed.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                guard let self, self.movieLayer === observed else { return }
                observed.opacity = 1
                self.teardownOutgoingMovie()
            }
        }

        // A clip can be present and still unplayable (truncated download, a codec
        // this Mac has no decoder for). Say so and let fallback take over.
        itemObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                guard let self, self.loadedMovieURL == url else { return }
                self.onLog?("cannot play \(url.lastPathComponent): \(item.error?.localizedDescription ?? "unknown")")
                self.failedMovies.insert(url)
                self.teardownMovie()
                self.loadAsset()
                self.needsDisplay = true
            }
        }

        moviePlayer = player
        movieLooper = looper
        movieLayer = layer
        loadedMovieURL = url
        loadedMovieMtime = mtime
        stalledReports = 0
        lastMovieTime = -1
        player.play()
        onLog?("movie \(url.lastPathComponent) at \(layer.frame.size)")
    }

    private func promoteMovieToOutgoing() {
        teardownOutgoingMovie()
        itemObservation = nil
        readyObservation = nil
        outgoingPlayer = moviePlayer
        outgoingLooper = movieLooper
        outgoingLayer = movieLayer
        moviePlayer = nil
        movieLooper = nil
        movieLayer = nil
        loadedMovieURL = nil
        loadedMovieMtime = nil
    }

    private func teardownOutgoingMovie() {
        outgoingPlayer?.pause()
        outgoingLayer?.removeFromSuperlayer()
        outgoingPlayer = nil
        outgoingLooper = nil
        outgoingLayer = nil
    }

    private func teardownMovie() {
        itemObservation = nil
        readyObservation = nil
        teardownOutgoingMovie()
        moviePlayer?.pause()
        movieLayer?.removeFromSuperlayer()
        moviePlayer = nil
        movieLooper = nil
        movieLayer = nil
        loadedMovieURL = nil
        loadedMovieMtime = nil
    }

    override func layout() {
        super.layout()
        movieLayer?.frame = petRect
        outgoingLayer?.frame = petRect
    }

    private func loadFrames(from dir: URL, mtime: Date?) {
        frameIndex = 0
        lastFrameSwap = CACurrentMediaTime()

        if let cached = framesCache[dir], cached.mtime == mtime {
            frames = cached.images
            return
        }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            frames = []
            return
        }

        let pngs = files
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoded: [CGImage] = pngs.compactMap { url in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        framesCache[dir] = (mtime: mtime, images: decoded)
        frames = decoded
    }

    // MARK: - Mouse

    /// Hit test in screen coordinates, used by the click-through monitor.
    func isInteractive(screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return hitRegion.contains(local)
    }

    /// Screen-space rect of the pet itself, used to dock the reply panel above or below it.
    var screenAnchor: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(petRect, to: nil))
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
        } else if event.modifierFlags.contains(.option) || (petState != .blocked && event.clickCount >= 2) {
            onReveal?()
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
