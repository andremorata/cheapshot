import CoreGraphics
import Testing
@testable import cheapshot

/// A page taller than the region, scrolled under a fixed header and footer, comes back whole.
@Test func stitchesScrolledFramesIntoThePage() throws {
    let width = 160, header = 20, footer = 14, view = 240, pageHeight = 900
    let page = try #require(blocks(width: width, height: pageHeight, seed: 1))
    let chrome = try #require(blocks(width: width, height: header + footer, seed: 2))

    let top = try #require(chrome.cropping(to: CGRect(x: 0, y: 0, width: width, height: header)))
    let bottom = try #require(chrome.cropping(to: CGRect(x: 0, y: header, width: width, height: footer)))

    /// What the region shows with the page scrolled `offset` rows down. CoreGraphics counts up
    /// from the bottom, so the page is placed with row `offset` right under the header.
    func frame(_ offset: Int) throws -> CGImage {
        let total = header + view + footer
        let context = try #require(rgbContext(width: width, height: total))
        context.draw(page, in: CGRect(x: 0, y: total - header + offset - pageHeight, width: width, height: pageHeight))
        context.draw(top, in: CGRect(x: 0, y: total - header, width: width, height: header))
        context.draw(bottom, in: CGRect(x: 0, y: 0, width: width, height: footer))
        return try #require(context.makeImage())
    }

    var stitcher = Stitcher(first: try frame(0))
    #expect(stitcher.add(try frame(0)) == .still)
    #expect(stitcher.add(try frame(37)) == .moved)
    #expect(stitcher.add(try frame(150)) == .moved)
    // Too far at once: no overlap left. The next frame is matched against the one at 150.
    #expect(stitcher.add(try frame(500)) == .lost)
    #expect(stitcher.add(try frame(320)) == .moved)
    #expect(stitcher.add(try frame(480)) == .moved)
    #expect(stitcher.add(try frame(pageHeight - view)) == .moved)

    let result = try #require(stitcher.image())
    #expect(result.height == header + pageHeight + footer)
    #expect(stitcher.height == result.height)

    // Header, the whole page, then the footer.
    let expected = try #require(rgbContext(width: width, height: header + pageHeight + footer))
    expected.draw(page, in: CGRect(x: 0, y: footer, width: width, height: pageHeight))
    expected.draw(top, in: CGRect(x: 0, y: footer + pageHeight, width: width, height: header))
    expected.draw(bottom, in: CGRect(x: 0, y: 0, width: width, height: footer))
    #expect(try pixels(result) == pixels(try #require(expected.makeImage())))
}

/// Random gray 4×4 blocks, the same for the same seed.
private func blocks(width: Int, height: Int, seed: UInt64) -> CGImage? {
    guard let context = rgbContext(width: width, height: height) else { return nil }
    var state = seed
    for y in stride(from: 0, to: height, by: 4) {
        for x in stride(from: 0, to: width, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let level = CGFloat(state >> 56) / 255
            context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
    }
    return context.makeImage()
}

private func rgbContext(width: Int, height: Int) -> CGContext? {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
}

private func pixels(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(rgbContext(width: image.width, height: image.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
}
