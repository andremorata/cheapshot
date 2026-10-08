import AppKit
import Carbon.HIToolbox

/// Draws the capture with its annotations, and turns mouse and key input into annotations.
final class CanvasView: NSView {
    static let margin: CGFloat = 16

    var tool: Annotation.Kind = .arrow
    var color: RGBA = .defaultInk {
        didSet { restyleSelection("Change Color") { $0.color = color } }
    }
    var lineWidth: CGFloat = 4 {
        didSet { restyleSelection("Change Thickness") { $0.lineWidth = lineWidth } }
    }
    /// Called when a tool's letter key is pressed, so the toolbar can follow.
    var onToolShortcut: ((Annotation.Kind) -> Void)?

    private let shot: Shot
    private var annotations: [Annotation] = [] {
        didSet {
            if let selected, selected >= annotations.count { self.selected = nil }
            needsDisplay = true
        }
    }
    private var selected: Int? { didSet { needsDisplay = true } }

    private enum Drag {
        case drawing
        case moving(Int, from: CGPoint)
        case resizing(Int, start: Bool)
    }
    private var drag: Drag?
    private var beforeDrag: [Annotation] = []

    init(shot: Shot) {
        self.shot = shot
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    /// The capture's size in points.
    private var natural: CGSize {
        CGSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
    }

    /// Where the image sits in the view. It never scales above its on-screen size.
    private var imageRect: CGRect {
        aspectFit(natural, in: bounds.insetBy(dx: Self.margin, dy: Self.margin), maxScale: 1)
    }

    /// View points per image point.
    private var zoom: CGFloat { natural.width > 0 ? imageRect.width / natural.width : 1 }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard zoom > 0 else { return .zero }
        return CGPoint(x: (point.x - rect.minX) / zoom, y: (point.y - rect.minY) / zoom)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        let rect = imageRect
        guard let context = NSGraphicsContext.current?.cgContext, rect.width > 0 else { return }
        context.interpolationQuality = .high
        context.draw(shot.image, in: rect)

        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: zoom, y: zoom)
        for annotation in annotations { annotation.draw(in: context) }
        if let selected { drawHandles(for: annotations[selected], in: context) }
        context.restoreGState()
    }

    private var handleRadius: CGFloat { 5 / zoom }

    private func drawHandles(for annotation: Annotation, in context: CGContext) {
        context.setFillColor(.white)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 / zoom)
        for point in [annotation.start, annotation.end] {
            let dot = CGRect(x: point.x - handleRadius, y: point.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2)
            context.fillEllipse(in: dot)
            context.strokeEllipse(in: dot)
        }
    }

    /// The capture with the annotations burned in, at full pixel size.
    func rendered() -> Shot {
        guard !annotations.isEmpty else { return shot }
        let width = shot.image.width
        let height = shot.image.height
        let spaces = [shot.image.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        // Not every color space can back a bitmap context, so sRGB is the fallback.
        let context = spaces.lazy.compactMap {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: $0,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }.first
        guard let context else { return shot }
        context.draw(shot.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: shot.scale, y: shot.scale)
        for annotation in annotations { annotation.draw(in: context) }
        return context.makeImage().map { Shot(image: $0, scale: shot.scale) } ?? shot
    }

    // MARK: Undo

    /// Records the step from `old` to the current annotations. Undo and redo both come back here.
    private func commit(replacing old: [Annotation], _ name: String) {
        guard annotations != old else { return }
        undoManager?.registerUndo(withTarget: self) { canvas in
            MainActor.assumeIsolated {
                let current = canvas.annotations
                canvas.annotations = old
                canvas.commit(replacing: current, name)
            }
        }
        undoManager?.setActionName(name)
    }

    // NOTE: dragging inside the color panel records one undo step per color it passes through.
    private func restyleSelection(_ name: String, _ change: (inout Annotation) -> Void) {
        guard let selected else { return }
        let old = annotations
        change(&annotations[selected])
        commit(replacing: old, name)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = imagePoint(event)
        let tolerance = 6 / zoom
        beforeDrag = annotations
        if let selected {
            let shape = annotations[selected]
            for (handle, isStart) in [(shape.start, true), (shape.end, false)]
            where hypot(point.x - handle.x, point.y - handle.y) <= handleRadius + tolerance / 2 {
                drag = .resizing(selected, start: isStart)
                return
            }
        }
        // Topmost first.
        if let hit = annotations.lastIndex(where: { $0.hitTest(point, tolerance: tolerance) }) {
            selected = hit
            drag = .moving(hit, from: point)
            return
        }
        annotations.append(Annotation(kind: tool, start: point, end: point, color: color, lineWidth: lineWidth))
        selected = nil
        drag = .drawing
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event)
        switch drag {
        case .drawing:
            annotations[annotations.count - 1].end = point
        case .moving(let index, let from):
            let dx = point.x - from.x
            let dy = point.y - from.y
            annotations[index].start.x += dx
            annotations[index].start.y += dy
            annotations[index].end.x += dx
            annotations[index].end.y += dy
            drag = .moving(index, from: point)
        case .resizing(let index, let start):
            if start { annotations[index].start = point } else { annotations[index].end = point }
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        switch drag {
        case .drawing:
            // A click without a drag draws nothing and clears the selection.
            guard let drawn = annotations.last, drawn.length * zoom >= 3 else {
                annotations = beforeDrag
                return
            }
            selected = annotations.count - 1
            commit(replacing: beforeDrag, "Draw")
        case .moving:
            commit(replacing: beforeDrag, "Move")
        case .resizing:
            commit(replacing: beforeDrag, "Resize")
        case nil:
            break
        }
    }

    // MARK: Keys and menu actions

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        let shortcuts: [String: Annotation.Kind] = ["a": .arrow, "l": .line, "r": .rectangle, "o": .ellipse]
        if [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)), let selected {
            let old = annotations
            annotations.remove(at: selected)
            self.selected = nil
            commit(replacing: old, "Delete")
        } else if plain, let kind = shortcuts[event.charactersIgnoringModifiers?.lowercased() ?? ""] {
            tool = kind
            onToolShortcut?(kind)
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { Output.copy(rendered()) }

    @objc func saveDocument(_ sender: Any?) {
        do { try Output.save(rendered()) } catch { NSApp.presentError(error) }
    }

    // Esc.
    override func cancelOperation(_ sender: Any?) { window?.performClose(nil) }
}
