import AppKit
import Carbon.HIToolbox

/// Everything the editor can change about a capture. One value of this is one undo step.
struct Document: Equatable, Sendable {
    var annotations: [Annotation] = []
    /// The part of the capture to keep, in image points. `nil` keeps all of it.
    var crop: CGRect?
}

/// Draws the capture with its annotations, and turns mouse and key input into edits.
final class CanvasView: NSView {
    static let margin: CGFloat = 24

    var tool: Tool = .arrow
    var color: RGBA = .defaultInk {
        didSet { restyleSelection("Change Color") { $0.color = color } }
    }
    var lineWidth: CGFloat = 4 {
        didSet { restyleSelection("Change Thickness") { $0.lineWidth = lineWidth } }
    }
    /// From 0 (no fill) to 1. Only rectangles and ellipses use it.
    var fillOpacity: CGFloat = 0 {
        didSet { restyleSelection("Change Fill") { $0.fillOpacity = fillOpacity } }
    }
    /// Called when a tool's letter key is pressed, so the toolbar can follow.
    var onToolShortcut: ((Tool) -> Void)?

    private let shot: Shot
    var document = Document() {
        didSet {
            if let selected, selected >= document.annotations.count { self.selected = nil }
            needsDisplay = true
        }
    }
    var selected: Int? { didSet { needsDisplay = true } }

    private enum Drag {
        case drawing
        case moving(Int, from: CGPoint)
        case resizing(Int, start: Bool)
        case cropping(from: CGPoint)
    }
    private var drag: Drag?
    private var beforeDrag = Document()

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
        // A soft shadow lifts the capture off the background, which is often the same light gray.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 14, color: CGColor(gray: 0, alpha: 0.28))
        context.draw(shot.image, in: rect)
        context.restoreGState()

        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: zoom, y: zoom)
        for annotation in document.annotations { annotation.draw(in: context, source: shot.image, scale: shot.scale) }
        if let crop = document.crop { drawCrop(crop, in: context) }
        if let selected { drawHandles(for: document.annotations[selected], in: context) }
        context.restoreGState()
    }

    /// Dims what the crop throws away. The capture itself is untouched until export.
    private func drawCrop(_ crop: CGRect, in context: CGContext) {
        context.addRect(CGRect(origin: .zero, size: natural))
        context.addRect(crop)
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(.white)
        context.setLineWidth(1 / zoom)
        context.stroke(crop)
    }

    private var handleRadius: CGFloat { 5 / zoom }

    private func drawHandles(for annotation: Annotation, in context: CGContext) {
        context.setFillColor(.white)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 / zoom)
        // A freehand stroke has no ends worth dragging, so it gets a dashed box and no handles.
        guard annotation.kind != .freehand else {
            let pad = annotation.lineWidth / 2 + 4 / zoom
            context.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
            context.stroke(annotation.bounds.insetBy(dx: -pad, dy: -pad))
            context.setLineDash(phase: 0, lengths: [])
            return
        }
        for point in [annotation.start, annotation.end] {
            let dot = CGRect(x: point.x - handleRadius, y: point.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2)
            context.fillEllipse(in: dot)
            context.strokeEllipse(in: dot)
        }
    }

    /// The capture with the annotations burned in and the crop applied, at full pixel size.
    func rendered() -> Shot {
        guard document != Document() else { return shot }
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
        for annotation in document.annotations { annotation.draw(in: context, source: shot.image, scale: shot.scale) }
        guard var image = context.makeImage() else { return shot }
        if let crop = document.crop {
            image = image.cropping(to: pixelRect(forCrop: crop, imageHeight: natural.height, scale: shot.scale)) ?? image
        }
        return Shot(image: image, scale: shot.scale)
    }

    // MARK: Undo

    /// Records the step from `old` to the current document. Undo and redo both come back here.
    private func commit(replacing old: Document, _ name: String) {
        guard document != old else { return }
        undoManager?.registerUndo(withTarget: self) { canvas in
            MainActor.assumeIsolated {
                let current = canvas.document
                canvas.document = old
                canvas.commit(replacing: current, name)
            }
        }
        undoManager?.setActionName(name)
    }

    // NOTE: dragging inside the color panel records one undo step per color it passes through.
    private func restyleSelection(_ name: String, _ change: (inout Annotation) -> Void) {
        guard let selected else { return }
        let old = document
        change(&document.annotations[selected])
        commit(replacing: old, name)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = imagePoint(event)
        let tolerance = 6 / zoom
        beforeDrag = document
        guard let shape = tool.shape else {
            // Cropping ignores the shapes under the cursor.
            selected = nil
            drag = .cropping(from: point)
            return
        }
        if let selected, document.annotations[selected].kind != .freehand {
            let current = document.annotations[selected]
            for (handle, isStart) in [(current.start, true), (current.end, false)]
            where hypot(point.x - handle.x, point.y - handle.y) <= handleRadius + tolerance / 2 {
                drag = .resizing(selected, start: isStart)
                return
            }
        }
        // Topmost first.
        if let hit = document.annotations.lastIndex(where: { $0.hitTest(point, tolerance: tolerance) }) {
            selected = hit
            drag = .moving(hit, from: point)
            return
        }
        // A redaction starts black whatever the ink color is. The color well can still change it.
        let ink = shape == .redact ? .black : color
        document.annotations.append(Annotation(
            kind: shape, start: point, end: point, color: ink, lineWidth: lineWidth,
            fillOpacity: fillOpacity, points: shape == .freehand ? [point] : []))
        selected = nil
        drag = .drawing
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event)
        switch drag {
        case .drawing:
            let index = document.annotations.count - 1
            if document.annotations[index].kind == .freehand { document.annotations[index].points.append(point) }
            document.annotations[index].end = locked(point, to: document.annotations[index].start, at: index, event)
        case .moving(let index, let from):
            document.annotations[index].translate(dx: point.x - from.x, dy: point.y - from.y)
            drag = .moving(index, from: point)
        case .resizing(let index, let start):
            let shape = document.annotations[index]
            if start {
                document.annotations[index].start = locked(point, to: shape.end, at: index, event)
            } else {
                document.annotations[index].end = locked(point, to: shape.start, at: index, event)
            }
        case .cropping(let from):
            let dragged = CGRect(x: min(from.x, point.x), y: min(from.y, point.y), width: abs(point.x - from.x), height: abs(point.y - from.y))
            // A drag that never touches the image intersects to the null rect.
            let inside = dragged.intersection(CGRect(origin: .zero, size: natural))
            document.crop = inside.isEmpty ? nil : inside.integral
        case nil:
            break
        }
    }

    /// With Shift held, a line or an arrow stays horizontal or vertical, and a box stays square,
    /// which makes an ellipse a circle. `anchor` is the end that is not moving.
    private func locked(_ point: CGPoint, to anchor: CGPoint, at index: Int, _ event: NSEvent) -> CGPoint {
        let kind = document.annotations[index].kind
        guard event.modifierFlags.contains(.shift), kind != .freehand else { return point }
        return kind.isStraight ? axisLocked(point, from: anchor) : squared(point, from: anchor)
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        switch drag {
        case .drawing:
            // A click without a drag draws nothing and clears the selection.
            guard let drawn = document.annotations.last, max(drawn.bounds.width, drawn.bounds.height) * zoom >= 3 else {
                document = beforeDrag
                return
            }
            selected = document.annotations.count - 1
            commit(replacing: beforeDrag, "Draw")
        case .moving:
            commit(replacing: beforeDrag, "Move")
        case .resizing:
            commit(replacing: beforeDrag, "Resize")
        case .cropping:
            // A click without a drag, or a sliver, removes the crop.
            if let crop = document.crop, crop == beforeDrag.crop || crop.width * zoom < 4 || crop.height * zoom < 4 {
                document.crop = nil
            }
            commit(replacing: beforeDrag, "Crop")
        case nil:
            break
        }
    }

    // MARK: Keys and menu actions

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        let shortcuts: [String: Tool] = [
            "a": .arrow, "l": .line, "r": .rectangle, "o": .ellipse, "d": .brush,
            "b": .blur, "p": .pixelate, "x": .redact, "c": .crop,
        ]
        if [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)), let selected {
            let old = document
            document.annotations.remove(at: selected)
            self.selected = nil
            commit(replacing: old, "Delete")
        } else if plain, let picked = shortcuts[event.charactersIgnoringModifiers?.lowercased() ?? ""] {
            tool = picked
            onToolShortcut?(picked)
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { Output.copy(rendered()) }

    @objc func saveDocument(_ sender: Any?) {
        do { try Output.save(rendered()) } catch { NSApp.presentError(error) }
    }
}
