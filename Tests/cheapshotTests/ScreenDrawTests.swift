import AppKit
import Carbon.HIToolbox
import Testing
@testable import cheapshot

/// Drives the screen pen with synthetic events in a window that is never shown.
@MainActor
@Test func screenPenDrawsShapesFromModifiersAndKeys() throws {
    _ = NSApplication.shared
    let view = DrawView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.contentView = view
    var ended = false
    view.onEnd = { ended = true }
    var clock: TimeInterval = 0
    func drag(_ from: CGPoint, _ to: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            clock += 1
            return NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: clock,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, from))
        if from != to { view.mouseDragged(with: mouse(.leftMouseDragged, to)) }
        view.mouseUp(with: mouse(.leftMouseUp, to))
    }
    func key(_ characters: String, code: Int) {
        view.keyDown(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: UInt16(code))!)
    }

    // The pen by default, then a shape for each modifier, whatever the tool.
    drag(CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 80))
    drag(CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 80), .shift)
    drag(CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 80), .command)
    drag(CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 80), .option)
    #expect(view.strokes.map(\.kind) == [.freehand, .arrow, .rectangle, .ellipse])
    #expect(view.strokes[2].frame == CGRect(x: 10, y: 10, width: 90, height: 70))

    // A click with a shape tool leaves nothing.
    view.tool = .rectangle
    drag(CGPoint(x: 300, y: 300), CGPoint(x: 300, y: 300))
    #expect(view.strokes.count == 4)

    // G turns the ink green for the next stroke. Undo takes the last stroke back, E clears.
    key("g", code: kVK_ANSI_G)
    drag(CGPoint(x: 200, y: 200), CGPoint(x: 260, y: 240))
    #expect(view.strokes.last?.color == DrawView.palette[1].color)
    view.undo(nil)
    #expect(view.strokes.count == 4)
    key("e", code: kVK_ANSI_E)
    #expect(view.strokes.isEmpty)

    // The thickness applies to the next stroke.
    view.lineWidth = 12
    drag(CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50))
    #expect(view.strokes.last?.lineWidth == 12)

    // The text tool opens a text view. Return finishes it as a text stroke, and empty text is dropped.
    view.tool = .text
    drag(CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 300))
    let field = try #require(window.firstResponder as? NSTextView)
    field.insertText("Olá", replacementRange: NSRange(location: NSNotFound, length: 0))
    field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    #expect(!view.isTyping && window.firstResponder === view)
    #expect(view.strokes.last?.kind == .text && view.strokes.last?.text == "Olá")
    drag(CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 100))
    #expect(view.isTyping)
    view.clear()
    #expect(!view.isTyping && view.strokes.isEmpty)

    key("\u{1b}", code: kVK_Escape)
    #expect(ended)
}
