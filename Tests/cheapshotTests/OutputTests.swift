import AppKit
import Testing
@testable import cheapshot

/// Saving to a folder creates it, writes a PNG of the right size, and never replaces an earlier capture.
@MainActor
@Test func writesScreenshotsIntoAFolder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString)/nested")
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    let context = try #require(CGContext(
        data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let shot = Shot(image: try #require(context.makeImage()), scale: 2)

    let first = try Output.write(shot, toFolder: folder)
    let second = try Output.write(shot, toFolder: folder)
    #expect(first != second)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    let saved = try #require(NSBitmapImageRep(data: try Data(contentsOf: first)))
    #expect(saved.pixelsWide == 40 && saved.pixelsHigh == 20)
    // A 2x capture is stored at half its pixel size in points, so it opens at its on-screen size.
    #expect(saved.size == CGSize(width: 20, height: 10))
}
