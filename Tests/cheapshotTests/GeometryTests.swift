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
