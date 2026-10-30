import AppKit
import AVFoundation

/// "1:02.5", or "1:02" without `tenths`.
func timeText(_ seconds: Double, tenths: Bool = true) -> String {
    let total = Int((seconds * 10).rounded())
    let whole = String(format: "%d:%02d", total / 600, total / 10 % 60)
    return tenths ? "\(whole).\(total % 10)" : whole
}

private let peaksPerSecond = 50

/// The loudest sample of each 50th of a second of the file's first audio track, from 0 to 1.
func audioPeaks(of file: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: file)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw VideoEditorError.noAudio }
    let reader = try AVAssetReader(asset: asset)
    // A waveform needs little detail, and this rate keeps a long song quick to read.
    let rate = 8_000
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? RecordingError.cannotFinish }
    return try await offThePool {
        var peaks: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = sample.dataBuffer else { continue }
            let first = Int(sample.presentationTimeStamp.seconds * Double(rate))
            try block.dataBytes().withUnsafeBytes { bytes in
                for (index, value) in bytes.bindMemory(to: Float.self).enumerated() {
                    let bucket = (first + index) * peaksPerSecond / rate
                    if bucket >= peaks.count { peaks.append(contentsOf: repeatElement(0, count: bucket - peaks.count + 1)) }
                    peaks[bucket] = max(peaks[bucket], abs(value))
                }
            }
        }
        return peaks
    }
}

/// The left end of a row: what it is, how loud it plays, and a way to remove it.
@MainActor
private final class TrackHeader: NSView {
    private let slider = NSSlider()
    private let percent = NSTextField(labelWithString: "")
    var onVolume: ((Float) -> Void)?
    var onRemove: (() -> Void)?

    /// A nil `volume` leaves the slider out, and `onRemove` adds the button that calls it.
    init(title: String, symbol: String, color: NSColor, volume: Float?, removable: Bool) {
        super.init(frame: CGRect(x: 0, y: 0, width: TimelineView.headerWidth, height: 44))
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.frame = CGRect(x: 10, y: 6, width: 16, height: 16)
        icon.contentTintColor = color
        addSubview(icon)

        let name = NSTextField(labelWithString: title)
        name.frame = CGRect(x: 30, y: 6, width: frame.width - (removable ? 58 : 38), height: 16)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = title
        addSubview(name)

        if removable {
            let remove = NSButton(title: "", target: self, action: #selector(removeClicked))
            remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")
            remove.imagePosition = .imageOnly
            remove.isBordered = false
            remove.contentTintColor = .secondaryLabelColor
            remove.toolTip = "Remove this row"
            remove.frame = CGRect(x: frame.width - 24, y: 5, width: 18, height: 18)
            addSubview(remove)
        }
        guard let volume else { return }
        // The slider moves over the square root of the volume. That gives the quiet levels a
        // background track needs as much room as everything from 100% to 400%.
        slider.minValue = 0
        slider.maxValue = RecordOptions.volumeRange.upperBound.squareRoot()
        slider.doubleValue = Double(volume).squareRoot()
        slider.controlSize = .small
        slider.numberOfTickMarks = 3
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(volumeMoved)
        slider.toolTip = "Volume of this row. 100% is the middle and keeps it as it is"
        slider.frame = CGRect(x: 10, y: 23, width: frame.width - 66, height: 18)
        addSubview(slider)
        percent.frame = CGRect(x: frame.width - 54, y: 24, width: 48, height: 16)
        percent.alignment = .right
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        percent.textColor = .secondaryLabelColor
        addSubview(percent)
        showPercent(volume)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var isSliderEnabled: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue }
    }

    private func showPercent(_ volume: Float) { percent.stringValue = "\(Int((volume * 100).rounded()))%" }

    @objc private func volumeMoved() {
        let volume = Float(slider.doubleValue * slider.doubleValue)
        showPercent(volume)
        onVolume?(volume)
    }

    @objc private func removeClicked() { onRemove?() }
}

/// The line that marks where the video is. It has its own layer, so moving it 30 times per second
/// does not draw the waveforms again.
@MainActor
private final class Playhead: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        CGRect(x: bounds.midX - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        let tip = NSBezierPath()
        tip.move(to: .zero)
        tip.line(to: CGPoint(x: bounds.maxX, y: 0))
        tip.line(to: CGPoint(x: bounds.midX, y: 9))
        tip.close()
        tip.fill()
    }
}

/// The stack of rows under the video: a ruler, the video, its sound and one row for each audio
/// clip. Drag the ends of the video row to trim everything, a clip to move it, the ends of a clip
/// to cut it, and anywhere else to move the playhead.
@MainActor
final class TimelineView: NSView {
    // ponytail: a fixed limit, so the rows never need to scroll. Add an NSScrollView if six is too few.
    static let maxClips = 6
    static let thumbnailCount = 30
    fileprivate static let headerWidth: CGFloat = 196
    private static let rulerHeight: CGFloat = 24
    private static let videoHeight: CGFloat = 48
    private static let audioHeight: CGFloat = 44
    private static let leadingRoom: CGFloat = 10
    private static let trailingRoom: CGFloat = 18
    /// How far from an edge the mouse can grab it, in points.
    private static let grab: CGFloat = 7
    /// The shortest trim or clip, in seconds.
    private static let shortest = 0.1

    private let duration: Double
    private let videoSize: CGSize
    private let recording: URL
    private let playhead = Playhead()
    private var videoHeader: TrackHeader?
    private var originalHeader: TrackHeader?
    private var clipHeaders: [TrackHeader] = []
    private var clipHeaderIDs: [UUID] = []

    var thumbnails: [NSImage] = [] { didSet { needsDisplay = true } }
    var peaks: [URL: [Float]] = [:] { didSet { needsDisplay = true } }
    var time = 0.0 { didSet { placePlayhead() } }
    var range: ClosedRange<Double> {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Nil when the recording has no sound.
    var originalVolume: Float? { didSet { needsDisplay = true } }
    var clips: [AudioClip] = [] {
        didSet {
            if clips.map(\.id) != clipHeaderIDs { rebuildClipHeaders() }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var isEnabled = true
    /// False for a format without sound.
    var audioEnabled = true {
        didSet {
            originalHeader?.isSliderEnabled = audioEnabled
            for header in clipHeaders { header.isSliderEnabled = audioEnabled }
        }
    }

    var onSeek: ((Double) -> Void)?
    var onTrim: ((ClosedRange<Double>, Double) -> Void)?
    /// Called when a drag has finished moving or cutting a clip.
    var onClipsEdited: (([AudioClip]) -> Void)?
    /// The id is nil for the recording's own sound.
    var onVolume: ((UUID?, Float) -> Void)?
    var onRemove: ((UUID) -> Void)?

    private enum Drag {
        case scrub, trimStart, trimEnd
        case move(index: Int, grabbed: Double, clip: AudioClip)
        case cutStart(index: Int, clip: AudioClip)
        case cutEnd(index: Int, clip: AudioClip)
    }
    private var drag: Drag?
    private var moved = false

    init(duration: Double, videoSize: CGSize, recording: URL, hasOriginalAudio: Bool) {
        self.duration = duration
        self.videoSize = videoSize
        self.recording = recording
        range = 0...duration
        originalVolume = hasOriginalAudio ? 1 : nil
        super.init(frame: .zero)
        wantsLayer = true

        let video = TrackHeader(title: "Video", symbol: "film", color: .secondaryLabelColor, volume: nil, removable: false)
        addSubview(video)
        videoHeader = video
        if hasOriginalAudio {
            let original = TrackHeader(title: "Recorded sound", symbol: "waveform", color: .systemBlue, volume: 1, removable: false)
            original.onVolume = { [weak self] volume in self?.onVolume?(nil, volume) }
            addSubview(original)
            originalHeader = original
        }
        addSubview(playhead)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { isEnabled ? super.hitTest(point) : nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var audioRowCount: Int { (originalVolume == nil ? 0 : 1) + clips.count }

    /// The height that shows every row.
    var idealHeight: CGFloat {
        Self.rulerHeight + Self.videoHeight + CGFloat(audioRowCount) * Self.audioHeight
    }

    private func rebuildClipHeaders() {
        for header in clipHeaders { header.removeFromSuperview() }
        clipHeaderIDs = clips.map(\.id)
        clipHeaders = clips.map { clip in
            let header = TrackHeader(
                title: clip.title, symbol: clip.isNarration ? "mic.fill" : "music.note", color: color(of: clip),
                volume: clip.volume, removable: true)
            header.isSliderEnabled = audioEnabled
            let id = clip.id
            header.onVolume = { [weak self] volume in self?.onVolume?(id, volume) }
            header.onRemove = { [weak self] in self?.onRemove?(id) }
            addSubview(header, positioned: .below, relativeTo: playhead)
            return header
        }
        needsLayout = true
    }

    private func color(of clip: AudioClip) -> NSColor { clip.isNarration ? .systemOrange : .systemTeal }

    // MARK: Geometry

    private var trackLeft: CGFloat { Self.headerWidth + Self.leadingRoom }
    private var trackWidth: CGFloat { max(bounds.width - trackLeft - Self.trailingRoom, 1) }

    private func x(_ seconds: Double) -> CGFloat {
        trackLeft + CGFloat(duration > 0 ? seconds / duration : 0) * trackWidth
    }

    private func seconds(atX x: CGFloat) -> Double {
        min(max(Double((x - trackLeft) / trackWidth) * duration, 0), duration)
    }

    private var videoRow: CGRect {
        CGRect(x: Self.headerWidth, y: Self.rulerHeight, width: bounds.width - Self.headerWidth, height: Self.videoHeight)
    }

    private func audioRow(_ index: Int) -> CGRect {
        CGRect(
            x: Self.headerWidth, y: Self.rulerHeight + Self.videoHeight + CGFloat(index) * Self.audioHeight,
            width: bounds.width - Self.headerWidth, height: Self.audioHeight)
    }

    private func clipRow(_ index: Int) -> CGRect { audioRow(index + (originalVolume == nil ? 0 : 1)) }

    /// Where the clip shows in its row. A clip that runs past the video stops at the video's end.
    private func box(of clip: AudioClip, index: Int) -> CGRect {
        let row = clipRow(index)
        let left = x(clip.start.seconds)
        let right = x(min(clip.start.seconds + clip.length.seconds, duration))
        return CGRect(x: left, y: row.minY + 3, width: max(right - left, 2), height: row.height - 6)
    }

    /// A point on the row of clip `index`, or on the video row for nil. Tests drive the mouse with it.
    func point(at seconds: Double, clip index: Int? = nil) -> CGPoint {
        CGPoint(x: x(seconds), y: index.map { clipRow($0).midY } ?? videoRow.midY)
    }

    override func layout() {
        super.layout()
        videoHeader?.frame = CGRect(x: 0, y: Self.rulerHeight, width: Self.headerWidth, height: Self.videoHeight)
        originalHeader?.frame = CGRect(x: 0, y: audioRow(0).minY, width: Self.headerWidth, height: Self.audioHeight)
        for (index, header) in clipHeaders.enumerated() {
            header.frame = CGRect(x: 0, y: clipRow(index).minY, width: Self.headerWidth, height: Self.audioHeight)
        }
        placePlayhead()
    }

    private func placePlayhead() {
        playhead.frame = CGRect(x: x(time) - 5.5, y: 0, width: 11, height: bounds.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.underPageBackgroundColor.setFill()
        CGRect(x: Self.headerWidth, y: Self.rulerHeight, width: bounds.width - Self.headerWidth, height: bounds.height - Self.rulerHeight).fill()

        drawRuler()
        drawThumbnails()
        if let originalVolume {
            drawWave(
                peaks[recording] ?? [], in: audioRow(0).insetBy(dx: 0, dy: 3), left: x(0), right: x(duration),
                from: 0, volume: originalVolume, color: .systemBlue)
        }
        for (index, clip) in clips.enumerated() { drawClip(clip, index: index) }

        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        for row in 0...audioRowCount {
            CGRect(x: 0, y: audioRow(row).minY, width: bounds.width, height: 1).fill()
        }
        CGRect(x: 0, y: Self.rulerHeight, width: bounds.width, height: 1).fill()
        CGRect(x: Self.headerWidth, y: 0, width: 1, height: bounds.height).fill()

        drawTrim()
    }

    private func drawRuler() {
        let perSecond = trackWidth / CGFloat(max(duration, 0.001))
        let step = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800].first { CGFloat($0) * perSecond >= 64 } ?? 3600
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        NSColor.tertiaryLabelColor.setFill()
        for mark in stride(from: 0, through: duration, by: step) {
            CGRect(x: x(mark), y: Self.rulerHeight - 6, width: 1, height: 6).fill()
            let label = timeText(mark, tenths: step < 1) as NSString
            // The last label goes left of its mark when the window's edge is in the way.
            let width = label.size(withAttributes: attributes).width
            let left = x(mark) + 3 + width > bounds.maxX ? x(mark) - 3 - width : x(mark) + 3
            label.draw(at: CGPoint(x: left, y: 5), withAttributes: attributes)
        }
    }

    private func drawThumbnails() {
        let row = videoRow.insetBy(dx: 0, dy: 3)
        let strip = CGRect(x: x(0), y: row.minY, width: trackWidth, height: row.height)
        guard !thumbnails.isEmpty else {
            NSColor.quaternaryLabelColor.setFill()
            strip.fill()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        strip.clip()
        let tile = videoSize.height > 0 ? row.height * videoSize.width / videoSize.height : row.height
        for left in stride(from: strip.minX, to: strip.maxX, by: max(tile, 1)) {
            let share = Double((left + tile / 2 - strip.minX) / strip.width)
            let image = thumbnails[min(max(Int(share * Double(thumbnails.count)), 0), thumbnails.count - 1)]
            image.draw(
                in: CGRect(x: left, y: row.minY, width: tile, height: row.height), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws `peaks` between `left` and `right`, starting from `from` seconds into its file.
    private func drawWave(_ peaks: [Float], in row: CGRect, left: CGFloat, right: CGFloat, from: Double, volume: Float, color: NSColor) {
        guard !peaks.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let secondsPerPoint = duration / Double(trackWidth)
        var bars: [CGRect] = []
        for bar in stride(from: left, to: right, by: 2) {
            let start = from + Double(bar - left) * secondsPerPoint
            let first = Int(start * Double(peaksPerSecond))
            let last = Int((start + 2 * secondsPerPoint) * Double(peaksPerSecond))
            guard first < peaks.count else { break }
            let loudest = peaks[first...min(max(last, first), peaks.count - 1)].max() ?? 0
            // The root makes quiet audio easy to see, and the volume shows on the row.
            let height = max(CGFloat(min(loudest * volume, 1).squareRoot()) * row.height, 1)
            bars.append(CGRect(x: bar, y: row.midY - height / 2, width: 1, height: height))
        }
        context.setFillColor(color.cgColor)
        context.fill(bars)
    }

    private func drawClip(_ clip: AudioClip, index: Int) {
        let rect = box(of: clip, index: index)
        let tint = color(of: clip)
        tint.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        drawWave(
            peaks[clip.file] ?? [], in: rect.insetBy(dx: 0, dy: 2), left: rect.minX, right: rect.maxX,
            from: clip.offset.seconds, volume: clip.volume, color: tint)
        // The ends, which cut the clip when dragged.
        tint.setFill()
        CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
        CGRect(x: rect.maxX - 3, y: rect.minY, width: 3, height: rect.height).fill()
    }

    private func drawTrim() {
        let left = x(range.lowerBound)
        let right = x(range.upperBound)
        let rows = Self.rulerHeight
        let height = bounds.height - rows
        NSColor.black.withAlphaComponent(0.5).setFill()
        CGRect(x: Self.headerWidth + 1, y: rows, width: max(left - Self.headerWidth - 1, 0), height: height).fill()
        CGRect(x: right, y: rows, width: max(bounds.maxX - right, 0), height: height).fill()

        NSColor.systemYellow.setFill()
        CGRect(x: left - 0.75, y: rows, width: 1.5, height: height).fill()
        CGRect(x: right - 0.75, y: rows, width: 1.5, height: height).fill()
        let row = videoRow
        CGRect(x: left, y: row.minY + 1, width: right - left, height: 2).fill()
        CGRect(x: left, y: row.maxY - 2, width: right - left, height: 2).fill()
        for edge in [left, right] {
            NSBezierPath(roundedRect: CGRect(x: edge - 4, y: row.minY + 1, width: 8, height: row.height - 2), xRadius: 2, yRadius: 2).fill()
        }
        NSColor.black.withAlphaComponent(0.6).setFill()
        for edge in [left, right] {
            CGRect(x: edge - 0.75, y: row.midY - 8, width: 1.5, height: 16).fill()
        }
    }

    // MARK: Mouse

    override func resetCursorRects() {
        let row = videoRow
        for edge in [x(range.lowerBound), x(range.upperBound)] {
            addCursorRect(CGRect(x: edge - Self.grab, y: 0, width: Self.grab * 2, height: row.maxY), cursor: .resizeLeftRight)
        }
        for (index, clip) in clips.enumerated() {
            let rect = box(of: clip, index: index)
            addCursorRect(rect, cursor: .openHand)
            for edge in [rect.minX, rect.maxX] {
                addCursorRect(CGRect(x: edge - Self.grab, y: rect.minY, width: Self.grab * 2, height: rect.height), cursor: .resizeLeftRight)
            }
        }
    }

    private func grabbed(at point: CGPoint) -> Drag {
        if point.y < videoRow.maxY {
            let toStart = abs(point.x - x(range.lowerBound))
            let toEnd = abs(point.x - x(range.upperBound))
            if min(toStart, toEnd) <= Self.grab { return toStart <= toEnd ? .trimStart : .trimEnd }
            return .scrub
        }
        for (index, clip) in clips.enumerated() where clipRow(index).contains(point) {
            let rect = box(of: clip, index: index)
            if abs(point.x - rect.minX) <= Self.grab { return .cutStart(index: index, clip: clip) }
            if abs(point.x - rect.maxX) <= Self.grab { return .cutEnd(index: index, clip: clip) }
            if rect.contains(point) { return .move(index: index, grabbed: seconds(atX: point.x), clip: clip) }
        }
        return .scrub
    }

    private func scrub(to seconds: Double) {
        onSeek?(min(max(seconds, range.lowerBound), range.upperBound))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= Self.headerWidth else { return }
        moved = false
        drag = grabbed(at: point)
        if case .scrub = drag { scrub(to: seconds(atX: point.x)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        moved = true
        let now = seconds(atX: convert(event.locationInWindow, from: nil).x)
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        switch drag {
        case .scrub:
            scrub(to: now)
        case .trimStart:
            let start = min(now, range.upperBound - Self.shortest)
            range = start...range.upperBound
            onTrim?(range, start)
        case .trimEnd:
            let end = max(now, range.lowerBound + Self.shortest)
            range = range.lowerBound...end
            onTrim?(range, end)
        case .move(let index, let grabbed, let clip):
            clips[index].start = time(min(max(clip.start.seconds + now - grabbed, 0), duration - Self.shortest))
        case .cutStart(let index, let clip):
            // It cannot start before the file does, or before the video does.
            let earliest = max(clip.start.seconds - clip.offset.seconds, 0)
            let latest = max(clip.start.seconds + clip.length.seconds - Self.shortest, clip.start.seconds)
            let cut = min(max(now, earliest), latest) - clip.start.seconds
            clips[index].start = time(clip.start.seconds + cut)
            clips[index].offset = time(clip.offset.seconds + cut)
            clips[index].length = time(clip.length.seconds - cut)
        case .cutEnd(let index, let clip):
            let left = clip.fileLength.seconds - clip.offset.seconds
            clips[index].length = time(min(max(now - clip.start.seconds, Self.shortest), left))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        switch drag {
        case .move, .cutStart, .cutEnd:
            // A click on a clip moves the playhead, the same as anywhere else.
            if moved { onClipsEdited?(clips) } else { scrub(to: seconds(atX: convert(event.locationInWindow, from: nil).x)) }
        default:
            break
        }
    }
}
