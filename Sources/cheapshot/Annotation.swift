import AppKit
import CoreImage

/// A color that can cross actors and be compared, which `NSColor` cannot promise.
struct RGBA: Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    static let defaultInk = RGBA(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let black = RGBA(red: 0, green: 0, blue: 0, alpha: 1)

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

/// A shape or an effect drawn over the capture. Coordinates are in image points, which are
/// capture pixels divided by the capture's scale, with the origin at the bottom-left.
struct Annotation: Equatable, Sendable {
    enum Kind: Sendable {
        case arrow, line, rectangle, ellipse, freehand
        /// Area effects. Blur and pixelate hide things from a casual look, but text under them
        /// can sometimes be recovered. Redact paints a solid block and cannot be undone by a reader.
        case blur, pixelate, redact

        var coversItsArea: Bool { [.blur, .pixelate, .redact].contains(self) }
        var isStraight: Bool { self == .arrow || self == .line }
        var canBeFilled: Bool { self == .rectangle || self == .ellipse }
    }

    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: RGBA
    var lineWidth: CGFloat
    /// How solid the inside of a rectangle or ellipse is, from 0 (empty) to 1. The fill uses `color`.
    var fillOpacity: CGFloat = 0
    /// The path of a freehand stroke. Other kinds leave it empty and use `start` and `end`.
    var points: [CGPoint] = []

    var frame: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var length: CGFloat { hypot(end.x - start.x, end.y - start.y) }

    /// The box around everything the annotation draws, stroke width aside.
    var bounds: CGRect { kind == .freehand ? outline.boundingBoxOfPath : frame }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx
        start.y += dy
        end.x += dx
        end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// The shape's skeleton with no stroke width.
    var outline: CGPath {
        switch kind {
        case .arrow, .line:
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            return path
        case .rectangle, .blur, .pixelate, .redact:
            return CGPath(rect: frame, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: frame, transform: nil)
        case .freehand:
            // Curves through the midpoints, with the recorded points as controls. It rounds off
            // the corners that raw mouse samples leave.
            let path = CGMutablePath()
            guard let first = points.first else { return path }
            path.move(to: first)
            for (point, next) in zip(points.dropFirst(), points.dropFirst(2)) {
                path.addQuadCurve(to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
            }
            path.addLine(to: points[points.count - 1])
            return path
        }
    }

    /// True when `point` is on the stroke, give or take `tolerance`. The inside of an unfilled
    /// rectangle or ellipse does not count, so shapes drawn inside it stay reachable. An effect
    /// or a filled shape is hit anywhere in its area.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if kind.coversItsArea { return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        if kind.canBeFilled, fillOpacity > 0, outline.contains(point) { return true }
        return outline.copy(strokingWithWidth: lineWidth + tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            .contains(point)
    }

    /// `source` is the untouched capture and `scale` its pixels per point. Effects read from it.
    func draw(in context: CGContext, source: CGImage, scale: CGFloat) {
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        switch kind {
        case .redact: return context.fill(frame)
        case .blur, .pixelate: return drawEffect(in: context, source: source, scale: scale)
        case .arrow, .line, .rectangle, .ellipse, .freehand: break
        }
        if kind.canBeFilled, fillOpacity > 0 {
            context.setFillColor(color.cgColor.copy(alpha: color.alpha * fillOpacity) ?? color.cgColor)
            context.addPath(outline)
            context.fillPath()
            context.setFillColor(color.cgColor)
        }
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

    private static let filters = CIContext()

    /// Filters the piece of the capture under the frame and paints it back in place. The
    /// thickness setting doubles as strength.
    // NOTE: the filter runs again on every redraw. Cache the result per annotation if dragging gets slow.
    private func drawEffect(in context: CGContext, source: CGImage, scale: CGFloat) {
        let imageHeight = CGFloat(source.height) / scale
        let pixels = pixelRect(forCrop: frame, imageHeight: imageHeight, scale: scale)
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !pixels.isEmpty, let patch = source.cropping(to: pixels) else { return }
        // Clamping repeats the edge pixels outward, so the blur does not fade to clear at the borders.
        let input = CIImage(cgImage: patch)
        let strength = lineWidth * scale
        let filtered = kind == .blur
            ? input.clampedToExtent().applyingGaussianBlur(sigma: strength * 2)
            : input.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(strength * 2.5, 2),
                kCIInputCenterKey: CIVector(x: 0, y: 0),
            ])
        guard let output = Self.filters.createCGImage(filtered, from: input.extent) else { return }
        let target = CGRect(
            x: pixels.minX / scale, y: imageHeight - pixels.maxY / scale,
            width: pixels.width / scale, height: pixels.height / scale)
        context.draw(output, in: target)
    }
}

/// What a drag on the canvas does.
enum Tool: Sendable {
    case arrow, line, rectangle, ellipse, brush, blur, pixelate, redact, crop

    /// The annotation this tool draws, or nil for a tool that draws none.
    var shape: Annotation.Kind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .brush: .freehand
        case .blur: .blur
        case .pixelate: .pixelate
        case .redact: .redact
        case .crop: nil
        }
    }
}
