import AppKit

/// A color that can cross actors and be compared, which `NSColor` cannot promise.
struct RGBA: Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    static let defaultInk = RGBA(red: 1, green: 0.23, blue: 0.19, alpha: 1)

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            self = .defaultInk
            return
        }
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// A shape drawn over the capture. Coordinates are in image points, which are capture pixels
/// divided by the capture's scale, with the origin at the bottom-left.
struct Annotation: Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case arrow, line, rectangle, ellipse
    }

    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: RGBA
    var lineWidth: CGFloat

    var frame: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var length: CGFloat { hypot(end.x - start.x, end.y - start.y) }

    /// The shape's skeleton with no stroke width.
    var outline: CGPath {
        switch kind {
        case .arrow, .line:
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            return path
        case .rectangle:
            return CGPath(rect: frame, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: frame, transform: nil)
        }
    }

    /// True when `point` is on the stroke, give or take `tolerance`. The inside of a rectangle
    /// or ellipse does not count, so shapes drawn inside it stay reachable.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        outline.copy(strokingWithWidth: lineWidth + tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            .contains(point)
    }

    func draw(in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        guard kind == .arrow, length > 0 else {
            context.addPath(outline)
            context.strokePath()
            return
        }
        // The head grows with the stroke, and shrinks to fit a very short arrow.
        let head = min(max(lineWidth * 4, 12), length)
        let dx = (end.x - start.x) / length
        let dy = (end.y - start.y) / length
        let base = CGPoint(x: end.x - dx * head, y: end.y - dy * head)
        context.move(to: start)
        context.addLine(to: base)
        context.strokePath()
        context.move(to: end)
        context.addLine(to: CGPoint(x: base.x - dy * head / 2, y: base.y + dx * head / 2))
        context.addLine(to: CGPoint(x: base.x + dy * head / 2, y: base.y - dx * head / 2))
        context.closePath()
        context.fillPath()
    }
}
