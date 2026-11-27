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

    static let defaultThemeID = "default"
    static let vectorThemeID = "vector"

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
    var onRightClick: (() -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?

    private let petSide: CGFloat = 180
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
        let maxW = bounds.width - 16
        let height: CGFloat
        if let text = bubbleText {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
            let measured = (text as NSString).boundingRect(
                with: NSSize(width: maxW - 16, height: bubbleHeight - 10),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attrs
            )
            height = min(bubbleHeight - 8, max(30, ceil(measured.height) + 14))
        } else {
            height = bubbleHeight - 10
        }
        return NSRect(x: 8, y: bounds.height - height - 8, width: maxW, height: height)
    }

    private var hitRegion: NSRect {
        // Generated clips and PNG packs carry their own empty margin, so be forgiving.
        let inset: CGFloat = (movieLayer == nil && frames.isEmpty) ? 18 : 24
        var region = petRect.insetBy(dx: inset, dy: inset)
        if bubbleText != nil { region = region.union(currentBubbleRect) }
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

    private func drawBubble(_ text: String) {
        let rect = currentBubbleRect
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.18)
        shadow.set()
        NSColor(white: 1.0, alpha: 0.95).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 0.0, alpha: 0.14).setStroke()
        path.lineWidth = 1
        path.stroke()

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
        if theme != defaultThemeID {
            var roots = [appSupport.appendingPathComponent("Themes").appendingPathComponent(theme)]
            if let bundled = bundleResources?.appendingPathComponent("Themes").appendingPathComponent(theme) {
                roots.append(bundled)
            }
            return roots
        }
        var roots = [appSupport.appendingPathComponent("Assets")]
        if let bundled = bundleResources?.appendingPathComponent("Assets") {
            roots.append(bundled)
        }
        return roots
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
