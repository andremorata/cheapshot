import AppKit

/// The annotation window. There is one at a time, and opening another capture replaces it.
@MainActor
final class Editor: NSObject, NSWindowDelegate {
    private static var current: Editor?
    private static let barHeight: CGFloat = 40
    /// Wide enough for the tools on the left and the two buttons on the right.
    private static let minWidth: CGFloat = 560

    static func open(_ shot: Shot) {
        if let current {
            // Detach first, so replacing the window does not flip the app back to menu-bar-only.
            current.window.delegate = nil
            current.window.close()
        }
        current = Editor(shot: shot)
    }

    private let window: NSWindow
    private let canvas: CanvasView
    private let tools: NSSegmentedControl

    private init(shot: Shot) {
        let visible = NSScreen.underMouse?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let natural = CGSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        let limit = CGRect(x: 0, y: 0, width: visible.width * 0.8, height: visible.height * 0.8 - Self.barHeight)
        let fitted = aspectFit(natural, in: limit, maxScale: 1).size
        let canvasSize = CGSize(
            width: max(fitted.width + CanvasView.margin * 2, Self.minWidth),
            height: max(fitted.height + CanvasView.margin * 2, 320))
        let contentSize = CGSize(width: canvasSize.width, height: canvasSize.height + Self.barHeight)

        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        canvas = CanvasView(shot: shot)
        let symbols = [("arrow.up.right", "Arrow (A)"), ("line.diagonal", "Line (L)"), ("rectangle", "Rectangle (R)"), ("circle", "Ellipse (O)"), ("crop", "Crop (C)")]
        tools = NSSegmentedControl(
            images: symbols.map { NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1) ?? NSImage() },
            trackingMode: .selectOne, target: nil, action: #selector(toolPicked))
        super.init()

        for (index, symbol) in symbols.enumerated() { tools.setToolTip(symbol.1, forSegment: index) }
        tools.selectedSegment = canvas.tool.rawValue
        tools.target = self

        let well = NSColorWell(style: .minimal)
        well.color = canvas.color.nsColor
        well.target = self
        well.action = #selector(colorPicked)
        well.toolTip = "Color"
        well.widthAnchor.constraint(equalToConstant: 40).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let slider = NSSlider(value: canvas.lineWidth, minValue: 2, maxValue: 16, target: self, action: #selector(widthPicked))
        // Applies on release, so one drag is one undo step.
        slider.isContinuous = false
        slider.controlSize = .small
        slider.toolTip = "Thickness"
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true

        // Plain frames with autoresizing: the bar keeps its height at the top, the canvas takes the rest.
        let bar = NSStackView(frame: CGRect(x: 0, y: canvasSize.height, width: contentSize.width, height: Self.barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.orientation = .horizontal
        bar.spacing = 14
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        bar.setViews([tools, well, slider], in: .leading)

        // Standard dialog keys: Return triggers the default button, Esc triggers Cancel.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyAndClose))
        copy.keyEquivalent = "\r"
        copy.toolTip = "Copy the annotated capture and close"
        bar.setViews([cancel, copy], in: .trailing)
        canvas.frame = CGRect(origin: .zero, size: canvasSize)
        canvas.autoresizingMask = [.width, .height]
        let content = NSView(frame: CGRect(origin: .zero, size: contentSize))
        content.addSubview(canvas)
        content.addSubview(bar)

        canvas.onToolShortcut = { [weak self] kind in self?.tools.selectedSegment = kind.rawValue }

        window.title = "cheapshot"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: Self.minWidth, height: 320 + Self.barHeight)
        window.contentView = content
        window.delegate = self
        window.center()

        // A Dock icon and a Cmd-Tab entry while the editor is open, so the window cannot get lost.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    @objc private func toolPicked() {
        canvas.tool = Tool(rawValue: tools.selectedSegment) ?? .arrow
        window.makeFirstResponder(canvas)
    }

    @objc private func copyAndClose() {
        Output.copy(canvas.rendered())
        close()
    }

    @objc private func close() { window.performClose(nil) }

    @objc private func colorPicked(_ sender: NSColorWell) { canvas.color = RGBA(sender.color) }

    @objc private func widthPicked(_ sender: NSSlider) { canvas.lineWidth = sender.doubleValue }

    func windowWillClose(_ notification: Notification) {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        Editor.current = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
