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
}
