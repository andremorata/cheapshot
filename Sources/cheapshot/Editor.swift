import AppKit

/// The annotation window. There is one at a time, and opening another capture replaces it.
@MainActor
final class Editor: NSObject, NSWindowDelegate {
    private static var current: Editor?

    static func open(_ shot: Shot) {
        if let current {
            // Detach first, so replacing the window does not flip the app back to menu-bar-only.
            current.window.delegate = nil
            current.window.close()
        }
        current = Editor(shot: shot)
    }

    private let window: NSWindow

    private init(shot: Shot) {
        let visible = NSScreen.underMouse?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let natural = CGSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        let limit = CGRect(x: 0, y: 0, width: visible.width * 0.8, height: visible.height * 0.8)
        let fitted = aspectFit(natural, in: limit, maxScale: 1).size
        let content = CGSize(
            width: max(fitted.width + CanvasView.margin * 2, 480),
            height: max(fitted.height + CanvasView.margin * 2, 320))

        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: content),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "cheapshot"
        window.isReleasedWhenClosed = false
        let canvas = CanvasView(shot: shot)
        window.contentView = canvas
        super.init()
        window.delegate = self
        window.center()

        // A Dock icon and a Cmd-Tab entry while the editor is open, so the window cannot get lost.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        Editor.current = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Draws the capture. Annotations will be drawn on top of it here.
final class CanvasView: NSView {
    static let margin: CGFloat = 16

    private let shot: Shot

    init(shot: Shot) {
        self.shot = shot
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    /// Where the image sits in the view. It never scales above its on-screen size.
    private var imageRect: CGRect {
        let natural = CGSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        return aspectFit(natural, in: bounds.insetBy(dx: Self.margin, dy: Self.margin), maxScale: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(shot.image, in: imageRect)
    }

    @objc func copy(_ sender: Any?) { Output.copy(shot) }

    @objc func saveDocument(_ sender: Any?) {
        do { try Output.save(shot) } catch { NSApp.presentError(error) }
    }

    // Esc.
    override func cancelOperation(_ sender: Any?) { window?.performClose(nil) }
}
