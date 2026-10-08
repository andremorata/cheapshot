import AppKit
import Carbon.HIToolbox

/// Dims every screen and lets the user drag a region or click a window. Escape or right click cancels.
@MainActor
final class SelectionOverlay {
    enum Mode { case region, window }

    private static var current: SelectionOverlay?

    /// Returns `nil` when the user cancels or another pick is already on screen.
    static func pick(_ mode: Mode) async -> Capture.Target? {
        guard current == nil else { return nil }
        let overlay = SelectionOverlay(mode: mode)
        current = overlay
        defer { current = nil }
        return await overlay.run()
    }

    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<Capture.Target?, Never>?
    private var escapeKey: UInt32?

    private init(mode: Mode) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let candidates = mode == .window ? WindowCandidate.onScreen() : []
        panels = NSScreen.screens.map { screen in
            let view = OverlayView(
                mode: mode, screen: screen,
                origin: flipY(screen.frame, primaryHeight: primaryHeight).origin,
                candidates: candidates,
                onFinish: { [weak self] in self?.finish($0) })
            return OverlayPanel(screen: screen, view: view)
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
    init(screen: NSScreen, view: NSView) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Set explicitly: by default a window lets clicks fall through its fully transparent pixels,
        // and the selection is drawn as a transparent hole.
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = view
    }
}

private final class OverlayView: NSView {
    private let mode: SelectionOverlay.Mode
    private let screen: NSScreen
    /// This screen's top-left corner in global top-left coordinates.
    private let origin: CGPoint
    private let candidates: [WindowCandidate]
    private let onFinish: (Capture.Target?) -> Void

    private var dragStart: CGPoint?
    private var hovered: WindowCandidate?
    private var selection: CGRect? { didSet { needsDisplay = true } }

    init(mode: SelectionOverlay.Mode, screen: NSScreen, origin: CGPoint, candidates: [WindowCandidate], onFinish: @escaping (Capture.Target?) -> Void) {
        self.mode = mode
        self.screen = screen
        self.origin = origin
        self.candidates = candidates
        self.onFinish = onFinish
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
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
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard let selection else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        switch mode {
        case .region: dragStart = convert(event.locationInWindow, from: nil)
        case .window: onFinish(hovered.map { .window($0.id) })
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
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
        guard mode == .window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let global = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        hovered = candidates.first { $0.bounds.contains(global) }
        selection = hovered.map {
            displayLocal($0.bounds, displayFrame: CGRect(origin: origin, size: bounds.size)).intersection(bounds)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard mode == .window else { return }
        hovered = nil
        selection = nil
    }

    override func rightMouseDown(with event: NSEvent) { onFinish(nil) }
}
