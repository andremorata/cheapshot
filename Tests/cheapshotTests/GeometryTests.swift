import CoreGraphics
import Testing
@testable import cheapshot

@Test func flipsBetweenAppKitAndTopLeftCoordinates() {
    // A rect resting on the bottom edge of a 1000 pt primary screen.
    #expect(flipY(CGRect(x: 10, y: 0, width: 50, height: 100), primaryHeight: 1000)
        == CGRect(x: 10, y: 900, width: 50, height: 100))
    // A second screen stacked above the primary lands at negative y.
    #expect(flipY(CGRect(x: 0, y: 1000, width: 800, height: 600), primaryHeight: 1000)
        == CGRect(x: 0, y: -600, width: 800, height: 600))
}

@Test func movesGlobalRectIntoDisplaySpace() {
    let display = CGRect(x: 1920, y: -600, width: 800, height: 600)
    #expect(displayLocal(CGRect(x: 2000, y: -500, width: 100, height: 50), displayFrame: display)
        == CGRect(x: 80, y: 100, width: 100, height: 50))
}

@Test func fitsAndCentersWithoutUpscalingPastTheCap() {
    let box = CGRect(x: 0, y: 0, width: 200, height: 100)
    // Wide image: limited by width, centered vertically.
    #expect(aspectFit(CGSize(width: 400, height: 100), in: box) == CGRect(x: 0, y: 25, width: 200, height: 50))
    // Small image with a cap of 1 keeps its size and sits in the middle.
    #expect(aspectFit(CGSize(width: 20, height: 10), in: box, maxScale: 1) == CGRect(x: 90, y: 45, width: 20, height: 10))
    // A view smaller than its margins insets to the null rect. That must not turn into NaN.
    let collapsed = CGRect(x: 0, y: 0, width: 10, height: 10).insetBy(dx: 16, dy: 16)
    #expect(aspectFit(CGSize(width: 20, height: 10), in: collapsed) == .zero)
}

@Test func hitsTheStrokeAndNotTheInside() {
    func shape(_ kind: Annotation.Kind) -> Annotation {
        Annotation(kind: kind, start: .zero, end: CGPoint(x: 100, y: 60), color: .defaultInk, lineWidth: 4)
    }
    // A line is hit near its path and missed away from it.
    #expect(shape(.line).hitTest(CGPoint(x: 50, y: 32), tolerance: 4))
    #expect(!shape(.line).hitTest(CGPoint(x: 50, y: 5), tolerance: 4))
    // A rectangle and an ellipse are hit on the border, not in the middle.
    #expect(shape(.rectangle).hitTest(CGPoint(x: 50, y: 1), tolerance: 4))
    #expect(!shape(.rectangle).hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
    #expect(shape(.ellipse).hitTest(CGPoint(x: 0, y: 30), tolerance: 4))
    #expect(!shape(.ellipse).hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
    // An effect covers its area, so its middle counts.
    #expect(shape(.redact).hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
    #expect(!shape(.redact).hitTest(CGPoint(x: 150, y: 30), tolerance: 4))
}

@Test func readsLabelsAndStoresShortcuts() throws {
    // Modifiers print in the macOS order, whatever order they were pressed in.
    let shortcut = try #require(Shortcut(keyCode: 21, flags: [.shift, .command, .option], character: "4"))
    #expect(shortcut.label == "⌥⇧⌘4")
    #expect(shortcut.cocoaModifiers == [.option, .shift, .command])
    // Shift alone would hijack normal typing, so it is refused.
    #expect(Shortcut(keyCode: 21, flags: [.shift], character: "4") == nil)
    // A named key shows its name and gives the menu no key equivalent.
    let space = try #require(Shortcut(keyCode: 49, flags: [.control], character: " "))
    #expect(space.label == "⌃Space")
    #expect(space.menuKeyEquivalent == "")
    // What goes into UserDefaults comes back the same.
    let restored = try #require(Shortcut(plist: shortcut.plist))
    #expect(restored.matches(shortcut) && restored.key == "4")
    #expect(Shortcut(plist: ["keyCode": "21"]) == nil)
}

@Test func cropFlipsToTopLeftPixels() {
    // 300x200 pt image at 2x. A 100x50 pt crop whose top edge is 30 pt below the image top.
    let crop = CGRect(x: 10, y: 120, width: 100, height: 50)
    #expect(pixelRect(forCrop: crop, imageHeight: 200, scale: 2) == CGRect(x: 20, y: 60, width: 200, height: 100))
}

/// Renders one effect over a 40x40 image whose left half is black and right half is white,
/// and returns the red channel of the pixel at `x` on the middle row.
private func redAfter(_ kind: Annotation.Kind, x: Int) throws -> UInt8 {
    func makeContext() throws -> CGContext {
        try #require(CGContext(
            data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
    let source = try makeContext()
    source.setFillColor(.black)
    source.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
    source.setFillColor(.white)
    source.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
    let image = try #require(source.makeImage())

    let output = try makeContext()
    output.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 40))
    let effect = Annotation(kind: kind, start: CGPoint(x: 5, y: 5), end: CGPoint(x: 35, y: 35), color: .black, lineWidth: 4)
    effect.draw(in: output, source: image, scale: 1)
    let bytes = try #require(output.data).assumingMemoryBound(to: UInt8.self)
    return bytes[20 * output.bytesPerRow + x * 4]
}

@Test func effectsChangeThePixelsTheyCover() throws {
    // Redact paints solid black over the white half.
    #expect(try redAfter(.redact, x: 30) == 0)
    // Blur and pixelate mix black and white near the edge, so a pure white pixel turns gray.
    #expect((1...254).contains(try redAfter(.blur, x: 22)))
    #expect((1...254).contains(try redAfter(.pixelate, x: 22)))
    // Outside the frame nothing changes.
    #expect(try redAfter(.blur, x: 38) == 255)
}

@Test func shiftLocksToTheCloserAxis() {
    let anchor = CGPoint(x: 100, y: 100)
    // Mostly sideways: keeps x, takes the anchor's y.
    #expect(axisLocked(CGPoint(x: 180, y: 112), from: anchor) == CGPoint(x: 180, y: 100))
    // Mostly up or down, in either direction: keeps y, takes the anchor's x.
    #expect(axisLocked(CGPoint(x: 95, y: 20), from: anchor) == CGPoint(x: 100, y: 20))
}

@Test func shiftSquaresABoxInTheDragDirection() {
    let anchor = CGPoint(x: 100, y: 100)
    #expect(squared(CGPoint(x: 160, y: 120), from: anchor) == CGPoint(x: 160, y: 160))
    // Dragging up and to the left keeps going up and to the left.
    #expect(squared(CGPoint(x: 90, y: 40), from: anchor) == CGPoint(x: 40, y: 40))
}

@Test func filledShapesAndBrushStrokes() {
    var box = Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 100, y: 60), color: .defaultInk, lineWidth: 4)
    #expect(!box.hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
    // Once filled, the middle is part of the shape.
    box.fillOpacity = 0.5
    #expect(box.hitTest(CGPoint(x: 50, y: 30), tolerance: 4))

    var stroke = Annotation(
        kind: .freehand, start: .zero, end: CGPoint(x: 40, y: 0), color: .defaultInk, lineWidth: 4,
        points: [.zero, CGPoint(x: 20, y: 30), CGPoint(x: 40, y: 0)])
    // The stroke bulges up to its middle point, which the start and end alone would miss.
    #expect(stroke.bounds.height > 10)
    #expect(stroke.hitTest(CGPoint(x: 20, y: 15), tolerance: 4))
    // Moving it carries every point along.
    stroke.translate(dx: 100, dy: 0)
    #expect(stroke.points.first == CGPoint(x: 100, y: 0) && stroke.end == CGPoint(x: 140, y: 0))
    #expect(!stroke.hitTest(CGPoint(x: 20, y: 15), tolerance: 4))
}
