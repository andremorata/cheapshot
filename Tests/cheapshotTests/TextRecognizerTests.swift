import AppKit
import Testing
@testable import cheapshot

/// Draws two lines into an image and reads them back through Vision, accents and digits included.
@Test func readsRenderedText() async throws {
    let lines = ["Captura rápida não custa nada", "cheapshot 2026, invoice #4821"]
    let context = try #require(CGContext(
        data: nil, width: 900, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: 900, height: 240))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
    (lines[0] as NSString).draw(at: CGPoint(x: 30, y: 140), withAttributes: style)
    (lines[1] as NSString).draw(at: CGPoint(x: 30, y: 50), withAttributes: style)
    NSGraphicsContext.current = nil

    #expect(try await TextRecognizer.read(try #require(context.makeImage())) == lines.joined(separator: "\n"))
}

@Test func blankImageReadsAsEmpty() async throws {
    let context = try #require(CGContext(
        data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    #expect(try await TextRecognizer.read(try #require(context.makeImage())) == "")
}
