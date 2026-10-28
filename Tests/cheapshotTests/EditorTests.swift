import AppKit
import Testing
@testable import cheapshot

/// Drives the canvas with synthetic mouse events in a window that is never shown.
@MainActor
@Test func typesTextAndBrushesOverStrokes() throws {
    _ = NSApplication.shared
    let context = try #require(CGContext(
        data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let editor = Editor(shot: Shot(image: try #require(context.makeImage()), scale: 2))
    let canvas = editor.canvas
    let window = editor.window
    window.makeFirstResponder(canvas)
    var clock: TimeInterval = 0
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
        clock += 1
        return NSEvent.mouseEvent(
            with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: clock,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    func drag(_ from: CGPoint, _ to: CGPoint, clicks: Int = 1) {
        canvas.mouseDown(with: mouse(.leftMouseDown, from, clicks: clicks))
        if from != to { canvas.mouseDragged(with: mouse(.leftMouseDragged, to)) }
        canvas.mouseUp(with: mouse(.leftMouseUp, to, clicks: clicks))
    }
    let middle = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
    let elsewhere = CGPoint(x: middle.x - 200, y: middle.y + 100)

    // A click with the text tool opens a box. Return finishes it as one undo step and leaves it selected.
    // Shift-Return is not covered: it needs NSApp.currentEvent, and posting one stops the test runner's run loop.
    canvas.tool = .text
    drag(middle, middle)
    let field = try #require(window.firstResponder as? NSTextView)
    field.insertText("Hello", replacementRange: NSRange(location: NSNotFound, length: 0))
    canvas.typeface = .mono
    field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(!canvas.isTyping && window.firstResponder === canvas && canvas.selected == 0)
    #expect(canvas.document.annotations.map(\.text) == ["Hello"])
    #expect(canvas.document.annotations[0].typeface == .mono)
    canvas.undoManager?.undo()
    #expect(canvas.document.annotations.isEmpty)
    canvas.undoManager?.redo()

    // A double click edits it. The text hangs down and to the right of where it was placed.
    let inside = CGPoint(x: middle.x + 5, y: middle.y - 5)
    drag(inside, inside)
    drag(inside, inside, clicks: 2)
    #expect((window.firstResponder as? NSTextView)?.string == "Hello")
    // A click elsewhere ends typing and opens the next box there.
    drag(elsewhere, elsewhere)
    #expect(canvas.isTyping && canvas.document.annotations.count == 2)
    #expect(canvas.document.annotations[0].text == "Hello")
    // A box left empty is dropped.
    try #require(window.firstResponder as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    #expect(!canvas.isTyping && canvas.document.annotations.count == 1)

    // A brush stroke stays unselected, and the next one can start on top of it.
    canvas.tool = .brush
    let start = CGPoint(x: middle.x - 150, y: middle.y - 100)
    let end = CGPoint(x: middle.x - 50, y: middle.y - 100)
    drag(start, end)
    #expect(canvas.document.annotations.count == 2 && canvas.selected == nil)
    drag(end, CGPoint(x: middle.x + 50, y: middle.y - 60))
    #expect(canvas.document.annotations.count == 3)
    #expect(canvas.document.annotations[1].points.last?.x == canvas.document.annotations[2].points.first?.x)
}
