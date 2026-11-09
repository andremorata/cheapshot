import AppKit
import Carbon.HIToolbox

/// Joins frames of a region that scrolls down into one tall image. Each new frame is matched
/// against the last one by its vertical shift, and only the rows that scrolled into view are kept.
/// Rows that stay put at the top or the bottom, like a sticky header or footer, are left out of
/// the match and show once in the result.
struct Stitcher {
    enum Step: Equatable {
        /// Nothing scrolled.
        case still
        /// New rows were added.
        case moved
        /// No shift fits. The frame is dropped, and the next one is matched against the last good one.
        case lost
    }

    /// Frames are shrunk to this many columns of gray before matching. Rows keep full resolution,
    /// so the shift is exact to the pixel.
    private static let columns = 128
    /// Mean difference per gray sample, out of 255, under which two runs of rows count as the same.
    private static let sameTolerance = 2.0
    private static let matchTolerance = 6.0

    let width: Int
    /// The height of one frame.
    let rows: Int
    /// Finished parts of the result, top to bottom. Each one is a copy, so old frames are freed.
    private var strips: [CGImage] = []
    private var reference: CGImage
    private var referenceGray: [UInt8]
    /// How many rows of `reference`, from its top, are already in `strips`.
    private var covered = 0

    init(first: CGImage) {
        width = first.width
        rows = first.height
        reference = first
        referenceGray = Self.gray(first)
    }

    /// The height of the result so far, in pixels.
    var height: Int { strips.reduce(0) { $0 + $1.height } + rows - covered }

    mutating func add(_ frame: CGImage) -> Step {
        guard frame.width == width, frame.height == rows else { return .lost }
        let gray = Self.gray(frame)
        // ponytail: a third at each end at most, so a page with wide blank margins still has rows to match.
        let limit = rows / 3
        let top = (0..<limit).first { !sameRow(gray, $0) } ?? limit
        let bottom = (0..<limit).first { !sameRow(gray, rows - 1 - $0) } ?? limit
        let band = top..<(rows - bottom)
        if difference(gray, shift: 0, band: band) <= Self.sameTolerance { return .still }
        guard let shift = bestShift(gray, band: band) else { return .lost }

        // Rows of the old frame above the footer are final now. The new frame shows them `shift` rows higher.
        let end = max(covered, band.upperBound)
        if end > covered, let strip = Self.copy(reference, rows: covered..<end) { strips.append(strip) }
        covered = end - shift
        reference = frame
        referenceGray = gray
        return .moved
    }

    /// Everything so far, with the rest of the last frame, footer included, at the bottom.
    func image() -> CGImage? {
        let parts = strips + [Self.copy(reference, rows: covered..<rows)].compactMap { $0 }
        let total = parts.reduce(0) { $0 + $1.height }
        guard let context = Self.context(width: width, height: total, like: reference) else { return nil }
        var y = total
        for part in parts {
            y -= part.height
            context.draw(part, in: CGRect(x: 0, y: y, width: width, height: part.height))
        }
        return context.makeImage()
    }

    /// The shift with the smallest difference over the band, if it is close enough. The two frames
    /// must share at least a quarter of the band, so a scroll of most of the region at once is lost.
    private func bestShift(_ gray: [UInt8], band: Range<Int>) -> Int? {
        let largest = band.count - max(band.count / 4, 8)
        guard largest >= 1 else { return nil }
        var best: (shift: Int, score: Double)?
        // NOTE: the first of equal scores wins, so the smallest shift is taken when content repeats.
        for shift in 1...largest {
            let score = difference(gray, shift: shift, band: band, giveUpAbove: best?.score ?? Self.matchTolerance)
            if score < (best?.score ?? .infinity) { best = (shift, score) }
        }
        guard let best, best.score <= Self.matchTolerance else { return nil }
        return best.shift
    }

    private func sameRow(_ gray: [UInt8], _ row: Int) -> Bool {
        Self.meanDifference(referenceGray, from: row, gray, from: row, rows: 1) <= Self.sameTolerance
    }

    /// How far row `y + shift` of the reference is from row `y` of the new frame, over the band.
    private func difference(_ gray: [UInt8], shift: Int, band: Range<Int>, giveUpAbove limit: Double = .infinity) -> Double {
        Self.meanDifference(referenceGray, from: band.lowerBound + shift, gray, from: band.lowerBound,
                            rows: band.count - shift, giveUpAbove: limit)
    }

    /// The mean difference per sample between `count` rows of `a` and of `b`. At most 160 rows are
    /// sampled, evenly spread. Stops early, returning infinity, once the mean must pass `limit`.
    private static func meanDifference(
        _ a: [UInt8], from aRow: Int, _ b: [UInt8], from bRow: Int, rows count: Int, giveUpAbove limit: Double = .infinity
    ) -> Double {
        guard count > 0 else { return .infinity }
        let step = max(1, count / 160)
        let samples = (count + step - 1) / step * columns
        let budget = limit.isFinite ? Int(limit * Double(samples)) : Int.max
        var sum = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for row in stride(from: 0, to: count, by: step) {
                    let i = (aRow + row) * columns, j = (bRow + row) * columns
                    for column in 0..<columns { sum += abs(Int(a[i + column]) - Int(b[j + column])) }
                    if sum > budget { return }
                }
            }
        }
        return sum > budget ? .infinity : Double(sum) / Double(samples)
    }

    /// The frame in gray, `columns` wide and full height, top row first.
    private static func gray(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: columns * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: columns, height: image.height, bitsPerComponent: 8, bytesPerRow: columns,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.interpolationQuality = .medium
            context?.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: image.height))
        }
        return pixels
    }

    /// The rows in their own memory. A plain crop would keep the whole frame alive.
    private static func copy(_ image: CGImage, rows: Range<Int>) -> CGImage? {
        guard !rows.isEmpty,
              let crop = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)),
              let context = context(width: crop.width, height: crop.height, like: image)
        else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage()
    }

    private static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
}

/// A capture of a region while the user scrolls it. It reads the region about ten times a second
/// and stitches the frames until Return, the shortcut again, or Esc to cancel.
@MainActor
final class ScrollCapture {
    private static var current: ScrollCapture?
    /// ponytail: a hard cap keeps memory in check. A taller page needs a tiled result.
    private static let maxHeight = 40_000

    static var isRunning: Bool { current != nil }

    /// Ends the running capture and keeps what it has.
    static func finish() { current?.state = .done }

    private enum State { case running, done, cancelled }
    private var state = State.running

    /// `region` is the target's rect in AppKit screen coordinates, for the outline and the hint.
    /// Returns `nil` when cancelled.
    static func run(_ target: Capture.Target, around region: CGRect) async throws -> Shot? {
        guard current == nil else { return nil }
        let session = ScrollCapture()
        current = session
        defer { current = nil }
        return try await session.run(target, around: region)
    }

    private func run(_ target: Capture.Target, around region: CGRect) async throws -> Shot? {
        let source = try await Capture.source(for: target)
        RecordingFrame.show(around: region)
        let hint = Hint(near: region)
        // Hotkeys, so the app being scrolled keeps the focus. Return in that app does nothing meanwhile.
        let keys = [
            HotKey.register(keyCode: kVK_Return, modifiers: 0) { [weak self] in self?.state = .done },
            HotKey.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.state = .cancelled },
        ]
        defer {
            keys.compactMap { $0 }.forEach(HotKey.unregister)
            hint.close()
            RecordingFrame.hide()
        }

        let first = try await Capture.shot(from: source)
        var stitcher = Stitcher(first: first.image)
        hint.show(height: stitcher.height, lost: false)
        while state == .running, stitcher.height < Self.maxHeight {
            try? await Task.sleep(for: .milliseconds(100))
            guard state == .running else { break }
            let step = stitcher.add(try await Capture.shot(from: source).image)
            if step != .still { hint.show(height: stitcher.height, lost: step == .lost) }
        }
        guard state != .cancelled, let image = stitcher.image() else { return nil }
        return Shot(image: image, scale: first.scale)
    }

    /// The instructions in a dark bubble under the region, or above it, or inside when neither fits.
    /// It ignores the mouse, so scrolling over it reaches the app below.
    @MainActor private final class Hint {
        private let panel: NSPanel
        private let label = NSTextField(labelWithString: "")
        private let size = CGSize(width: 380, height: 58)

        init(near region: CGRect) {
            let screen = NSScreen.screens.first { $0.frame.intersects(region) }?.visibleFrame ?? region
            let gap: CGFloat = 12
            let y = region.minY - gap - size.height >= screen.minY ? region.minY - gap - size.height
                : region.maxY + gap + size.height <= screen.maxY ? region.maxY + gap
                : region.minY + gap
            let x = min(max(region.midX - size.width / 2, screen.minX), screen.maxX - size.width)
            panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: x, y: y), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let bubble = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
            bubble.material = .hudWindow
            bubble.state = .active
            bubble.wantsLayer = true
            bubble.layer?.cornerRadius = 12
            bubble.layer?.masksToBounds = true
            label.font = .systemFont(ofSize: 13)
            label.textColor = .white
            label.alignment = .center
            label.maximumNumberOfLines = 2
            label.frame = bubble.bounds.insetBy(dx: 12, dy: 10)
            bubble.addSubview(label)
            panel.contentView = bubble
            panel.orderFrontRegardless()
        }

        func show(height: Int, lost: Bool) {
            label.stringValue = lost
                ? "Lost the place. Scroll back up a little, then go slower.\n\(height) px so far"
                : "Scroll down slowly. Return finishes, Esc cancels.\n\(height) px so far"
        }

        func close() { panel.orderOut(nil) }
    }
}
