import AppKit
import Carbon.HIToolbox

/// Dims every screen and lets the user drag a region or click a window. Escape or right click cancels.
/// Given stills of the displays, it shows those instead of the live screen.
/// A region pick has guides through the pointer and a label with the size in pixels. Over a still
/// it also has a loupe, and the scroll wheel changes how much the loupe enlarges.
@MainActor
final class SelectionOverlay {
    enum Mode { case region, window }

    private static var current: SelectionOverlay?

    /// Returns `nil` when the user cancels or another pick is already on screen.
    static func pick(_ mode: Mode, over stills: [CGDirectDisplayID: Shot] = [:]) async -> Capture.Target? {
        guard current == nil else { return nil }
        let overlay = SelectionOverlay(mode: mode, stills: stills)
        current = overlay
        defer { current = nil }
        return await overlay.run()
    }

    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<Capture.Target?, Never>?
    private var escapeKey: UInt32?

    private init(mode: Mode, stills: [CGDirectDisplayID: Shot]) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let candidates = mode == .window ? WindowCandidate.onScreen() : []
        panels = NSScreen.screens.map { screen in
            let still = screen.displayID.flatMap { stills[$0] }?.image
            let view = OverlayView(
                mode: mode, screen: screen, still: still,
                origin: flipY(screen.frame, primaryHeight: primaryHeight).origin,
                candidates: candidates,
                onFinish: { [weak self] in self?.finish($0) })
            return OverlayPanel(screen: screen, view: view, still: still)
        }
    }

    private func run() async -> Capture.Target? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for panel in panels { panel.orderFrontRegardless() }
            // A hotkey, not keyDown: the panels never take key focus, so the app being captured keeps it.
            escapeKey = HotKey.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.finish(nil) }
        }
    }

    private func finish(_ pick: Capture.Target?) {
        if let escapeKey { HotKey.unregister(escapeKey) }
        escapeKey = nil
        for panel in panels { panel.orderOut(nil) }
        continuation?.resume(returning: pick)
        continuation = nil
    }
}

/// A window the user can pick, with bounds in global top-left coordinates.
private struct WindowCandidate {
    let id: CGWindowID
    let bounds: CGRect

    /// Front to back, which is the order CGWindowList documents.
    static func onScreen() -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let ourPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != ourPID,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { return nil }
            return WindowCandidate(id: id, bounds: bounds)
        }
    }
}

/// Non-activating and never key, so the app under the overlay keeps its active look in the capture.
private final class OverlayPanel: NSPanel {
    init(screen: NSScreen, view: NSView, still: CGImage?) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Set explicitly: by default a window lets clicks fall through its fully transparent pixels,
        // and the selection is drawn as a transparent hole.
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard let still else {
            contentView = view
            return
        }
        // The still sits in its own view under the overlay, so a drag redraws the dimming and not the picture.
        let picture = NSImageView(image: NSImage(cgImage: still, size: screen.frame.size))
        picture.imageScaling = .scaleAxesIndependently
        let container = NSView(frame: view.frame)
        container.wantsLayer = true
        for layer in [picture, view] {
            layer.frame = container.bounds
            container.addSubview(layer)
        }
        contentView = container
    }
}

/// Not private, and neither are `selection` and `pointer`, so the snapshots can draw it.
final class OverlayView: NSView {
    private static let loupeSize: CGFloat = 128
    /// How many times the loupe enlarges the screen. Kept between captures until the app quits.
    private static var magnification: CGFloat = 8

    private let mode: SelectionOverlay.Mode
    private let screen: NSScreen
    /// The display's still when the pick runs over one. The loupe reads from it.
    private let still: CGImage?
    /// This screen's top-left corner in global top-left coordinates.
    private let origin: CGPoint
    private let candidates: [WindowCandidate]
    private let onFinish: (Capture.Target?) -> Void

    private var dragStart: CGPoint?
    private var hovered: WindowCandidate?
    var selection: CGRect? { didSet { needsDisplay = true } }
    /// Where the pointer is in this view. `nil` while it is on another screen.
    var pointer: CGPoint? { didSet { needsDisplay = true } }

    fileprivate init(
        mode: SelectionOverlay.Mode, screen: NSScreen, still: CGImage?, origin: CGPoint,
        candidates: [WindowCandidate], onFinish: @escaping (Capture.Target?) -> Void
    ) {
        self.mode = mode
        self.screen = screen
        self.still = still
        self.origin = origin
        self.candidates = candidates
        self.onFinish = onFinish
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        // The guides show at once, before the first mouse move.
        let mouse = NSEvent.mouseLocation
        if screen.frame.contains(mouse) {
            pointer = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
        }
    }

    /// A region pick over `still`, for the snapshots.
    convenience init(still: CGImage, screen: NSScreen) {
        self.init(mode: .region, screen: screen, still: still, origin: .zero, candidates: [], onFinish: { _ in })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // Flipped, so view coordinates are already the top-left point space ScreenCaptureKit expects.
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func draw(_ dirtyRect: NSRect) {
        // Dims everything but the selection. Nothing is painted there, so what is under the overlay shows through.
        let dim = NSBezierPath(rect: bounds)
        dim.windingRule = .evenOdd
        if let selection { dim.appendRect(selection) }
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()
        if let selection {
            NSColor.white.setStroke()
            NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        guard mode == .region, let pointer else { return }
        drawGuides(through: pointer)
        let text = sizeLabel(at: pointer)
        let padded = CGSize(width: ceil(text.size().width) + 12, height: ceil(text.size().height) + 6)
        let place = pointerCompanions(at: pointer, label: padded, loupe: still == nil ? 0 : Self.loupeSize, in: bounds)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: place.label, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: place.label.minX + 6, y: place.label.minY + 3))
        if let still { drawLoupe(of: still, at: pointer, in: place.loupe) }
    }

    /// Read from the still when there is one, so the label always matches the size of the result.
    private var pixelsPerPoint: CGFloat {
        still.map { CGFloat($0.width) / bounds.width } ?? screen.backingScaleFactor
    }

    /// A light line with a dark one beside it, so the guides show on any background.
    private func drawGuides(through point: CGPoint) {
        for (offset, color) in [(CGFloat(0), NSColor.white), (1, NSColor.black)] {
            color.withAlphaComponent(0.45).setFill()
            CGRect(x: 0, y: floor(point.y) + offset, width: bounds.width, height: 1).fill(using: .sourceOver)
            CGRect(x: floor(point.x) + offset, y: 0, width: 1, height: bounds.height).fill(using: .sourceOver)
        }
    }

    /// The selection's size in pixels while dragging. Before the drag, the pointer's position in pixels.
    private func sizeLabel(at point: CGPoint) -> NSAttributedString {
        let scale = pixelsPerPoint
        let text = if let size = selection?.integral.size {
            "\(Int(size.width * scale)) × \(Int(size.height * scale))"
        } else {
            "\(Int(point.x * scale)), \(Int(point.y * scale))"
        }
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
    }

    /// Enlarges the pixels around the pointer inside a circle, with the pixel under it outlined.
    private func drawLoupe(of still: CGImage, at point: CGPoint, in frame: CGRect) {
        guard let context = NSGraphicsContext.current else { return }
        let scale = pixelsPerPoint
        // The square of pixels the loupe shows, centered on the middle of the pixel under the pointer.
        let side = frame.width / Self.magnification * scale
        let center = CGPoint(x: floor(point.x * scale) + 0.5, y: floor(point.y * scale) + 0.5)
        let source = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        // Near a screen edge part of that square is off the picture, so only the rest is drawn.
        let pixels = source.intersection(CGRect(x: 0, y: 0, width: still.width, height: still.height)).integral

        context.saveGraphicsState()
        NSBezierPath(ovalIn: frame).addClip()
        // Square pixels, not a smooth blend.
        context.imageInterpolation = .none
        NSColor.black.setFill()
        frame.fill()
        if !pixels.isEmpty, let patch = still.cropping(to: pixels) {
            let unit = frame.width / side
            let target = CGRect(
                x: frame.minX + (pixels.minX - source.minX) * unit, y: frame.minY + (pixels.minY - source.minY) * unit,
                width: pixels.width * unit, height: pixels.height * unit)
            NSImage(cgImage: patch, size: target.size)
                .draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let pixel = Self.magnification / scale
        let middle = CGRect(x: frame.midX - pixel / 2, y: frame.midY - pixel / 2, width: pixel, height: pixel)
        NSColor.black.setStroke()
        NSBezierPath(rect: middle.insetBy(dx: -1.5, dy: -1.5)).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: middle.insetBy(dx: -0.5, dy: -0.5)).stroke()
        context.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.5).setStroke()
        NSBezierPath(ovalIn: frame.insetBy(dx: -0.5, dy: -0.5)).stroke()
        NSColor.white.setStroke()
        let rim = NSBezierPath(ovalIn: frame.insetBy(dx: 1, dy: 1))
        rim.lineWidth = 2
        rim.stroke()
    }

    /// One notch of a wheel, or a short swipe, changes the loupe by a quarter.
    override func scrollWheel(with event: NSEvent) {
        guard mode == .region, still != nil else { return }
        let notches = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        Self.magnification = min(max(Self.magnification * pow(1.25, notches), 2), 32)
        needsDisplay = true
    }

    /// Kept inside the view, so a drag past the edge leaves the guides and the loupe on screen.
    private func track(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        pointer = CGPoint(x: min(max(point.x, 0), bounds.width - 1), y: min(max(point.y, 0), bounds.height - 1))
        return point
    }

    override func mouseDown(with event: NSEvent) {
        switch mode {
        case .region: dragStart = convert(event.locationInWindow, from: nil)
        case .window: onFinish(hovered.map { .window($0.id) })
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = track(event)
        guard let dragStart else { return }
        selection = CGRect(
            x: min(dragStart.x, point.x), y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x), height: abs(point.y - dragStart.y)
        ).intersection(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .region else { return }
        // A click without a drag cancels.
        guard let selection, selection.width >= 2, selection.height >= 2 else { return onFinish(nil) }
        guard let displayID = screen.displayID else { return onFinish(nil) }
        onFinish(.display(displayID, region: selection.integral))
    }

    override func mouseMoved(with event: NSEvent) {
        // The panel never activates the app, so cursor rects alone do not hold the crosshair.
        NSCursor.crosshair.set()
        let point = track(event)
        guard mode == .window else { return }
        let global = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        hovered = candidates.first { $0.bounds.contains(global) }
        selection = hovered.map {
            displayLocal($0.bounds, displayFrame: CGRect(origin: origin, size: bounds.size)).intersection(bounds)
        }
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        guard mode == .window else { return }
        hovered = nil
        selection = nil
    }

    override func rightMouseDown(with event: NSEvent) { onFinish(nil) }
}
