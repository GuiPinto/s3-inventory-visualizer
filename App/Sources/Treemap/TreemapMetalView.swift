import MetalKit
import TreemapLayout

final class TreemapMetalView: MTKView {
    var onHover: ((LayoutHit?, CGPoint) -> Void)?
    var onClick: ((LayoutHit?, NSEvent) -> Void)?
    var onDoubleClick: ((LayoutHit?) -> Void)?
    var onViewportChange: ((CGSize) -> Void)?

    private(set) var renderer: TreemapRenderer?
    private var trackingArea: NSTrackingArea?
    private var lastHoveredInstance = -1
    private var transitionStart: CFTimeInterval = 0
    private var transitionSourceRect: CGRect?
    private var transitionTimer: Timer?

    var result: LayoutResult? {
        didSet {
            renderer?.update(result: result)
            lastHoveredInstance = -1
            renderer?.hoveredInstance = -1
            needsDisplay = true
        }
    }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        let background = TreemapPalette.canvasBackground.usingColorSpace(.sRGB) ?? TreemapPalette.canvasBackground
        clearColor = MTLClearColor(
            red: Double(background.redComponent),
            green: Double(background.greenComponent),
            blue: Double(background.blueComponent),
            alpha: 1
        )
        isPaused = true
        enableSetNeedsDisplay = true
        autoresizingMask = [.width, .height]

        if let device = self.device {
            renderer = TreemapRenderer(device: device)
        }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        reportViewport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportViewport()
    }

    private func reportViewport() {
        let backing = convertToBacking(bounds).size

        guard backing.width > 0, backing.height > 0 else { return }
        onViewportChange?(backing)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Converts a point event into layout coordinates: device pixels with a top-left origin.
    private func layoutPoint(_ event: NSEvent) -> CGPoint {
        let inView = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: inView.x, y: bounds.height - inView.y)
        return convertToBacking(flipped)
    }

    private func instanceIndex(of hit: LayoutHit?) -> Int {
        switch hit {
        case .file(_, let index, _): return index
        case .remainder(_, let index, _, _): return index
        case .directory(_, let index): return index ?? -1
        case nil: return -1
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = layoutPoint(event)
        let hit = result?.hitTest(x: point.x, y: point.y)
        let instance = instanceIndex(of: hit)

        if instance != lastHoveredInstance {
            lastHoveredInstance = instance
            renderer?.hoveredInstance = instance
            needsDisplay = true
        }

        onHover?(hit, convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        lastHoveredInstance = -1
        renderer?.hoveredInstance = -1
        needsDisplay = true
        onHover?(nil, .zero)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = layoutPoint(event)
        let hit = result?.hitTest(x: point.x, y: point.y)

        if event.clickCount >= 2 {
            onDoubleClick?(hit)
        } else {
            onClick?(hit, event)
        }
    }

    func setColorMode(_ mode: ColorMode) {
        renderer?.colorMode = mode
        needsDisplay = true
    }

    func setSelection(_ range: Range<UInt32>?, outlining rect: CGRect, showingGuides guides: Bool) {
        renderer?.selectedRange = range
        renderer?.selectionRect = rect
        renderer?.selectionShowsGuides = guides
        needsDisplay = true
    }

    func setHighlightCategory(_ category: Int) {
        renderer?.highlightCategory = category
        needsDisplay = true
    }

    /// Scales the previous layout out of `rect` while the new one fades in, over 180 ms.
    func animateZoom(from rect: CGRect) {
        guard let renderer else { return }
        transitionTimer?.invalidate()
        renderer.captureTransitionSource()
        transitionSourceRect = rect
        transitionStart = CACurrentMediaTime()
        renderer.previousResultOpacity = 1
        renderer.transitionOpacity = 0
        transitionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, let renderer = self.renderer, let sourceRect = self.transitionSourceRect else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - self.transitionStart
            let fraction = min(elapsed / 0.18, 1.0)
            let eased = Float(1 - pow(1 - fraction, 3))
            let backing = self.convertToBacking(self.bounds).size
            let targetScaleX = Float(backing.width / max(sourceRect.width, 1))
            let targetScaleY = Float(backing.height / max(sourceRect.height, 1))
            let scale = 1 + (min(targetScaleX, targetScaleY) - 1) * eased
            renderer.transitionScale = scale
            renderer.transitionTranslation = SIMD2<Float>(
                -Float(sourceRect.origin.x) * scale * eased,
                -Float(sourceRect.origin.y) * scale * eased
            )
            renderer.previousResultOpacity = 1 - eased
            renderer.transitionOpacity = eased
            self.needsDisplay = true

            if fraction >= 1 {
                renderer.previousResultOpacity = 0
                renderer.transitionOpacity = 1
                renderer.transitionScale = 1
                renderer.transitionTranslation = .zero
                self.transitionSourceRect = nil
                timer.invalidate()
                self.transitionTimer = nil
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        renderer?.draw(in: self)
    }
}
