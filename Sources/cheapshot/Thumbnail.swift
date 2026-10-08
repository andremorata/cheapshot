import AppKit

/// A small preview that floats in the corner after a capture. A click opens the editor.
@MainActor
final class Thumbnail {
    private static var current: Thumbnail?

    static func show(_ shot: Shot, onClick: @escaping @MainActor () -> Void) {
        current?.dismiss()
        current = Thumbnail(shot: shot, onClick: onClick)
    }

    private let panel: NSPanel
    private var dismissal: Task<Void, Never>?

    private init(shot: Shot, onClick: @escaping @MainActor () -> Void) {
        let natural = CGSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        var size = aspectFit(natural, in: CGRect(x: 0, y: 0, width: 220, height: 160), maxScale: 1).size
        // A sliver of a capture still needs to be big enough to click.
        size = CGSize(width: max(size.width, 64), height: max(size.height, 48))
        let visible = NSScreen.underMouse?.visibleFrame ?? .zero
        let frame = CGRect(x: visible.maxX - size.width - 20, y: visible.minY + 20, width: size.width, height: size.height)

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = ThumbnailView(
            image: shot.image,
            onClick: { [weak self] in
                self?.dismiss()
                onClick()
            },
            onHover: { [weak self] inside in
                if inside { self?.dismissal?.cancel() } else { self?.scheduleDismissal() }
            })
        panel.orderFrontRegardless()
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        dismissal?.cancel()
        panel.orderOut(nil)
        if Thumbnail.current === self { Thumbnail.current = nil }
    }
}

private final class ThumbnailView: NSView {
    private let onClick: () -> Void
    private let onHover: (Bool) -> Void

    init(image: CGImage, onClick: @escaping () -> Void, onHover: @escaping (Bool) -> Void) {
        self.onClick = onClick
        self.onHover = onHover
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseUp(with event: NSEvent) { onClick() }
}
