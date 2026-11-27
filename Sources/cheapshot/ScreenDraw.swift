import AppKit
import Carbon.HIToolbox

/// A pen over the live screen, for presenting. It covers the screen under the mouse, and clicks
/// go to the drawing until it ends. Captures and recordings show the drawing but not its toolbar.
@MainActor
final class ScreenDraw: NSObject {
    private(set) static var current: ScreenDraw?

    /// The drawing layer's window, which captures keep although they leave the rest of cheapshot out.
    static var drawingWindowID: CGWindowID? { current.map { CGWindowID($0.panel.windowNumber) } }

    static func toggle() {
        if let current { current.end() } else { start() }
    }

    private static func start() {
        guard let screen = NSScreen.underMouse else { return }
        let draw = ScreenDraw(screen: screen)
        current = draw
        draw.show()
    }

    let view: DrawView
    private let panel: DrawPanel
    private let toolbar: NSPanel
    private let tools: NSSegmentedControl
    private let colors: NSSegmentedControl
    /// Gets the focus back when the drawing ends.
    private var previousApp: NSRunningApplication?

    private init(screen: NSScreen) {
        view = DrawView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel = DrawPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tools = NSSegmentedControl(
            images: DrawView.Tool.allCases.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) ?? NSImage() },
            trackingMode: .selectOne, target: nil, action: nil)
        colors = NSSegmentedControl(
            images: DrawView.palette.map { Self.swatch($0.color) }, trackingMode: .selectOne, target: nil, action: nil)
        super.init()

        // Just under the capture overlays, so a region can still be picked while drawing.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Clicks must not fall through the transparent parts to the apps underneath.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        view.onEnd = { [weak self] in self?.end() }
        view.onChange = { [weak self] in self?.syncToolbar() }

        tools.controlSize = .large
        for (index, tool) in DrawView.Tool.allCases.enumerated() {
            tools.setToolTip(tool.tip, forSegment: index)
            tools.setWidth(42, forSegment: index)
        }
        tools.target = self
        tools.action = #selector(toolPicked)
        for (index, entry) in DrawView.palette.enumerated() {
            colors.setToolTip("\(entry.name) (\(entry.key.uppercased()))", forSegment: index)
            colors.setWidth(34, forSegment: index)
        }
        colors.controlSize = .large
        colors.target = self
        colors.action = #selector(colorPicked)
        let weight = NSImageView(image: NSImage(systemSymbolName: "lineweight", accessibilityDescription: "Thickness") ?? NSImage())
        weight.contentTintColor = .secondaryLabelColor
        let thickness = NSSlider(value: view.lineWidth, minValue: 2, maxValue: 30, target: self, action: #selector(thicknessPicked))
        thickness.controlSize = .large
        thickness.toolTip = "Thickness. For text, size"
        thickness.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let undo = button("arrow.uturn.backward", "Undo (⌘Z)", #selector(undo))
        let clear = button("trash", "Clear (E)", #selector(clear))
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.controlSize = .large
        done.toolTip = "Stop drawing (Esc)"

        let stack = NSStackView(views: [tools, colors, weight, thickness, undo, clear, done])
        stack.spacing = 14
        stack.setCustomSpacing(6, after: weight)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.addSubview(stack)
        stack.frame.size = stack.fittingSize
        background.frame.size = stack.fittingSize
        toolbar.contentView = background
        toolbar.setContentSize(stack.fittingSize)
        toolbar.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        toolbar.isOpaque = false
        toolbar.backgroundColor = .clear
        toolbar.hasShadow = true
        toolbar.isMovableByWindowBackground = true
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Top middle, clear of the menu bar.
        let visible = screen.visibleFrame
        toolbar.setFrameOrigin(CGPoint(x: visible.midX - toolbar.frame.width / 2, y: visible.maxY - toolbar.frame.height - 12))
        syncToolbar()
    }

    private func show() {
        if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        toolbar.orderFront(nil)
    }

    private func end() {
        toolbar.orderOut(nil)
        panel.orderOut(nil)
        Self.current = nil
        previousApp?.activate()
    }

    private func syncToolbar() {
        tools.selectedSegment = DrawView.Tool.allCases.firstIndex(of: view.tool) ?? 0
        colors.selectedSegment = DrawView.palette.firstIndex { $0.color == view.color } ?? -1
    }

    // The toolbar never becomes key, so after each click the keys still reach the drawing.
    @objc private func toolPicked(_ sender: NSSegmentedControl) { view.tool = DrawView.Tool.allCases[sender.selectedSegment] }
    @objc private func colorPicked(_ sender: NSSegmentedControl) { view.color = DrawView.palette[sender.selectedSegment].color }
    @objc private func thicknessPicked(_ sender: NSSlider) { view.lineWidth = sender.doubleValue }
    @objc private func undo() { view.undo(nil) }
    @objc private func clear() { view.clear() }
    @objc private func done() { end() }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
        button.controlSize = .large
        button.toolTip = tip
        return button
    }

    private static func swatch(_ color: RGBA) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}

/// Borderless windows refuse the keyboard unless told otherwise, and the drawing needs its keys.
private final class DrawPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The strokes over the screen, in the view's own points.
final class DrawView: NSView, NSTextViewDelegate {
    enum Tool: CaseIterable {
        case pen, arrow, rectangle, ellipse, text

        var kind: Annotation.Kind {
            switch self {
            case .pen: .freehand
            case .arrow: .arrow
            case .rectangle: .rectangle
            case .ellipse: .ellipse
            case .text: .text
            }
        }
        var title: String {
            switch self {
            case .pen: "Pen"
            case .arrow: "Arrow"
            case .rectangle: "Rectangle"
            case .ellipse: "Ellipse"
            case .text: "Text"
            }
        }
        /// Shapes also come from a modifier held while dragging, so the pen never has to be put down.
        var tip: String {
            switch self {
            case .pen: "Pen"
            case .arrow: "Arrow. Or Shift-drag with any tool"
            case .rectangle: "Rectangle. Or Command-drag with any tool"
            case .ellipse: "Ellipse. Or Option-drag with any tool"
            case .text: "Text. Return finishes, Shift-Return starts a new line"
            }
        }
        var symbol: String {
            switch self {
            case .pen: "scribble"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .text: "textformat"
            }
        }
    }

    /// The colors and their keys, as in Microsoft's ZoomIt.
    static let palette: [(name: String, key: String, color: RGBA)] = [
        ("Red", "r", .defaultInk),
        ("Green", "g", RGBA(red: 0.2, green: 0.78, blue: 0.35, alpha: 1)),
        ("Blue", "b", RGBA(red: 0.04, green: 0.52, blue: 1, alpha: 1)),
        ("Yellow", "y", RGBA(red: 1, green: 0.84, blue: 0.04, alpha: 1)),
        ("Orange", "o", RGBA(red: 1, green: 0.58, blue: 0, alpha: 1)),
    ]
    /// `Annotation.draw` reads its source only for blur and pixelate, which the screen pen does not have.
    private static let noSource = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!

    var tool: Tool = .pen { didSet { onChange?() } }
    var color: RGBA = .defaultInk { didSet { onChange?() } }
    /// Stroke width in points. Text is five times as tall, as in the editor.
    var lineWidth: CGFloat = 5
    private(set) var strokes: [Annotation] = [] { didSet { needsDisplay = true } }
    /// The text being typed and the view that edits it. The stroke is drawn by that view until typing ends.
    private var typing: (index: Int, view: NSTextView)?
    var isTyping: Bool { typing != nil }
    var onEnd: (() -> Void)?
    /// The tool or the color changed, so the toolbar follows.
    var onChange: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, stroke) in strokes.enumerated() where index != typing?.index {
            stroke.draw(in: context, source: Self.noSource, scale: 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A click while typing only finishes the text.
        if isTyping { window?.makeFirstResponder(self); return }
        let point = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        // A modifier picks a shape for one drag, so the pen never has to be put down.
        let kind: Annotation.Kind =
            flags.contains(.shift) ? .arrow
            : flags.contains(.command) ? .rectangle
            : flags.contains(.option) ? .ellipse
            : tool.kind
        strokes.append(Annotation(
            kind: kind, start: point, end: point, color: color, lineWidth: lineWidth,
            points: kind == .freehand ? [point] : []))
        if kind == .text { startTyping() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty, !isTyping else { return }
        let point = convert(event.locationInWindow, from: nil)
        let last = strokes.count - 1
        if strokes[last].kind == .freehand { strokes[last].points.append(point) }
        strokes[last].end = point
    }

    override func mouseUp(with event: NSEvent) {
        // A click with a shape tool draws nothing worth keeping. A click with the pen leaves a dot.
        guard !isTyping, let last = strokes.last, last.kind != .freehand else { return }
        if max(last.frame.width, last.frame.height) < 3 { strokes.removeLast() }
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        let pressed = event.charactersIgnoringModifiers?.lowercased()
        if Int(event.keyCode) == kVK_Escape {
            onEnd?()
        } else if plain, pressed == "e" {
            clear()
        } else if plain, let entry = Self.palette.first(where: { $0.key == pressed }) {
            color = entry.color
        } else {
            super.keyDown(with: event)
        }
    }

    /// Edit > Undo and Command-Z land here through the responder chain.
    @objc func undo(_ sender: Any?) {
        if isTyping { window?.makeFirstResponder(self) }
        if !strokes.isEmpty { strokes.removeLast() }
    }

    func clear() {
        if isTyping { window?.makeFirstResponder(self) }
        strokes.removeAll()
    }

    // MARK: Typing

    /// A text view over the last stroke, as in the editor, so accents and input methods work.
    private func startTyping() {
        let view = NSTextView()
        view.drawsBackground = false
        view.isRichText = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.delegate = self
        addSubview(view)
        typing = (strokes.count - 1, view)
        syncTyping()
        window?.makeFirstResponder(view)
    }

    private func syncTyping() {
        guard let typing else { return }
        let text = strokes[typing.index]
        typing.view.font = text.font()
        typing.view.textColor = text.color.nsColor
        typing.view.insertionPointColor = text.color.nsColor
        // A little extra width keeps the caret visible at the end of the line.
        let box = text.bounds
        typing.view.frame = CGRect(x: box.minX, y: box.minY, width: box.width + 4, height: box.height)
    }

    func textDidChange(_ notification: Notification) {
        guard let typing else { return }
        strokes[typing.index].text = typing.view.string
        syncTyping()
    }

    /// Return and Esc finish the text. Shift-Return starts a new line.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        guard [#selector(insertNewline(_:)), #selector(cancelOperation(_:))].contains(selector) else { return false }
        window?.makeFirstResponder(self)
        return true
    }

    /// Every way out of typing comes here, because the text view always gives up first responder. Empty text is dropped.
    func textDidEndEditing(_ notification: Notification) {
        guard let typing else { return }
        self.typing = nil
        if strokes[typing.index].text.isEmpty { strokes.remove(at: typing.index) }
        needsDisplay = true
        // Removing the view while it resigns first responder is not safe, so it goes on the next turn.
        DispatchQueue.main.async { typing.view.removeFromSuperview() }
    }
}
