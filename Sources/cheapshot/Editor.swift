import AppKit

/// The annotation window. There is one at a time, and opening another capture replaces it.
@MainActor
final class Editor: NSObject, NSWindowDelegate {
    private static var current: Editor?
    private static let barHeight: CGFloat = 52
    /// Wide enough for the tools on the left and the two buttons on the right.
    private static let minWidth: CGFloat = 760

    /// Tools as they appear in the bar: shapes, then effects, then crop.
    private static let toolGroups: [[(tool: Tool, symbol: String, tip: String)]] = [
        [
            (.arrow, "arrow.up.right", "Arrow (A)"), (.line, "line.diagonal", "Line (L)"),
            (.rectangle, "rectangle", "Rectangle (R)"), (.ellipse, "circle", "Ellipse (O)"),
        ],
        [
            (.blur, "drop", "Blur (B)"), (.pixelate, "square.grid.3x3.fill", "Pixelate (P)"),
            (.redact, "rectangle.fill", "Redact (X). A solid block, the safe choice for sensitive text"),
        ],
        [(.crop, "crop", "Crop (C)")],
    ]

    static func open(_ shot: Shot) {
        if let current {
            // Detach first, so replacing the window does not flip the app back to menu-bar-only.
            current.window.delegate = nil
            current.window.close()
        }
        let editor = Editor(shot: shot)
        current = editor
        editor.present()
    }

    let window: NSWindow
    let canvas: CanvasView
    /// One segmented control per group in `toolGroups`. At most one segment is on across all of them.
    private let toolControls: [NSSegmentedControl]

    /// Builds the window without showing it. `open` is the way in for the app.
    init(shot: Shot) {
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
        let symbolStyle = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        toolControls = Self.toolGroups.map { group in
            let images = group.map {
                NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.tip)?.withSymbolConfiguration(symbolStyle) ?? NSImage()
            }
            let control = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: #selector(toolPicked))
            control.controlSize = .large
            for (index, entry) in group.enumerated() {
                control.setToolTip(entry.tip, forSegment: index)
                control.setWidth(38, forSegment: index)
            }
            return control
        }
        super.init()

        for control in toolControls { control.target = self }
        select(canvas.tool)

        let well = NSColorWell(style: .minimal)
        well.color = canvas.color.nsColor
        well.target = self
        well.action = #selector(colorPicked)
        well.toolTip = "Color"
        well.widthAnchor.constraint(equalToConstant: 38).isActive = true
        well.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let weight = NSImageView(image: NSImage(systemSymbolName: "lineweight", accessibilityDescription: "Thickness") ?? NSImage())
        weight.contentTintColor = .secondaryLabelColor
        let slider = NSSlider(value: canvas.lineWidth, minValue: 2, maxValue: 16, target: self, action: #selector(widthPicked))
        // Applies on release, so one drag is one undo step.
        slider.isContinuous = false
        slider.toolTip = "Thickness. For blur and pixelate, strength"
        slider.widthAnchor.constraint(equalToConstant: 100).isActive = true

        // Plain frames with autoresizing: the bar keeps its height at the top, the canvas takes the rest.
        let bar = NSStackView(frame: CGRect(x: 0, y: canvasSize.height, width: contentSize.width, height: Self.barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        bar.setViews(toolControls + [well, weight, slider], in: .leading)
        if let lastTools = toolControls.last { bar.setCustomSpacing(20, after: lastTools) }
        bar.setCustomSpacing(16, after: well)
        bar.setCustomSpacing(6, after: weight)

        // Standard dialog keys: Return triggers the default button, Esc triggers Cancel.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        cancel.controlSize = .large
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyAndClose))
        copy.keyEquivalent = "\r"
        copy.controlSize = .large
        copy.toolTip = "Copy the annotated capture and close"
        bar.setViews([cancel, copy], in: .trailing)

        let divider = NSBox(frame: CGRect(x: 0, y: canvasSize.height - 1, width: contentSize.width, height: 1))
        divider.boxType = .separator
        divider.autoresizingMask = [.width, .minYMargin]

        canvas.frame = CGRect(origin: .zero, size: canvasSize)
        canvas.autoresizingMask = [.width, .height]
        let content = NSView(frame: CGRect(origin: .zero, size: contentSize))
        content.addSubview(canvas)
        content.addSubview(divider)
        content.addSubview(bar)

        canvas.onToolShortcut = { [weak self] in self?.select($0) }

        window.title = "cheapshot"
        window.subtitle = "\(shot.image.width) × \(shot.image.height) px"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: Self.minWidth, height: 320 + Self.barHeight)
        window.contentView = content
        window.delegate = self
        window.center()
    }

    private func present() {
        // A Dock icon and a Cmd-Tab entry while the editor is open, so the window cannot get lost.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    @objc private func toolPicked(_ sender: NSSegmentedControl) {
        guard let group = toolControls.firstIndex(of: sender), sender.selectedSegment >= 0 else { return }
        select(Self.toolGroups[group][sender.selectedSegment].tool)
        window.makeFirstResponder(canvas)
    }

    /// Makes `tool` the active one and lights its segment, clearing the other groups.
    private func select(_ tool: Tool) {
        canvas.tool = tool
        for (control, group) in zip(toolControls, Self.toolGroups) {
            control.selectedSegment = group.firstIndex { $0.tool == tool } ?? -1
        }
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
