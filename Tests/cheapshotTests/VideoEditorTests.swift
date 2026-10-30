import AppKit
import AVFoundation
import Testing
import UniformTypeIdentifiers
@testable import cheapshot

/// A solid gray frame. `shade` goes from 0 for dark to 1 for bright. With `split`, everything
/// right of that pixel is the opposite shade, and the bottom half too.
private func grayFrame(_ shade: Double, at time: CMTime, split: Int? = nil) throws -> CMSampleBuffer {
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(
        nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
    let buffer = try #require(pixels)
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), Int32(16 + shade * 219), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 240)
    memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 120)
    if let split, let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<240 where row >= 120 {
            memset(luma + row * stride, Int32(16 + (1 - shade) * 219), stride)
        }
        for row in 0..<120 {
            memset(luma + row * stride + split, Int32(16 + (1 - shade) * 219), 320 - split)
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: buffer, formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample)
    return try #require(sample)
}

/// A recording the way the app makes them: its timeline starts late, frames only arrive when
/// something changes, and the last one is held. `scenes` lists each frame's time and shade.
private func recording(_ scenes: [(seconds: Double, shade: Double)], end: Double, audio: Bool = false) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).mp4")
    var settings = VideoSettings()
    settings.microphone = audio
    let writer = try VideoWriter(url: url, width: 320, height: 240, settings: settings)
    let start = CMTime(seconds: 1000, preferredTimescale: 48_000)
    var nextTone = 0.0
    for scene in scenes {
        let time = start + CMTime(seconds: scene.seconds, preferredTimescale: 48_000)
        writer.append(try grayFrame(scene.shade, at: time))
        while audio, nextTone <= scene.seconds {
            writer.append(try tone(880, channels: 1, at: start + CMTime(seconds: nextTone, preferredTimescale: 48_000)), from: .microphone)
            nextTone += 0.1
        }
        try await Task.sleep(for: .milliseconds(30))
    }
    writer.extend(to: start + CMTime(seconds: end, preferredTimescale: 48_000))
    let failure: Error? = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    #expect(failure == nil)
    return url
}

/// One frame per tenth of a second for three seconds: dark, then gray, then bright.
private func threeScenes(audio: Bool = false) async throws -> URL {
    try await recording((0..<30).map { (Double($0) / 10, Double($0 / 10) / 2) }, end: 3, audio: audio)
}

/// Three seconds of video with sound, for the snapshots.
func sampleRecording() async throws -> URL { try await threeScenes(audio: true) }

private func range(_ start: Double, _ end: Double) -> CMTimeRange {
    CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
}

private func output(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).\(ext)")
}

/// How bright a picture is, from 0 to 1.
private func brightness(_ image: CGImage) throws -> Double {
    var pixel: UInt8 = 0
    let context = try #require(CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Double(pixel) / 255
}

private func brightness(of url: URL, at seconds: Double) async throws -> Double {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try brightness(try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image)
}

private func codec(of url: URL) async throws -> CMFormatDescription.MediaSubType {
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    return try #require(try await track.load(.formatDescriptions).first).mediaSubType
}

/// The picture has to start exactly at the cut, also when the codec is copied and the cut is between keyframes.
@Test(arguments: [VideoFormat.mp4HEVC, .mp4H264, .movHEVC, .movH264])
func trimsToTheExactRange(format: VideoFormat) async throws {
    let source = try await threeScenes()
    let target = output(try #require(format.contentType.preferredFilenameExtension))
    defer { for url in [source, target] { try? FileManager.default.removeItem(at: url) } }

    try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(0.5, 2.5), format: format))

    let duration = try await AVURLAsset(url: target).load(.duration).seconds
    #expect(abs(duration - 2) < 0.1)
    #expect(try await codec(of: target) == (format.codec == .hevc ? .hevc : .h264))
    // 0.5 s into the file is the second scene's first half, and the end is the third scene.
    #expect(try await brightness(of: target, at: 0.1) < 0.2)
    #expect(abs(try await brightness(of: target, at: 1) - 0.5) < 0.15)
    #expect(try await brightness(of: target, at: 1.8) > 0.8)
}

/// Nothing changed on screen at the cut, so the frame to show there arrived long before it.
@Test(arguments: [VideoFormat.mp4HEVC, .mp4H264])
func trimStartsInsideAHeldFrame(format: VideoFormat) async throws {
    let scenes = (0..<10).map { (Double($0) / 10, 0.0) } + (0..<5).map { (3 + Double($0) / 10, 1.0) }
    let source = try await recording(scenes, end: 3.5)
    let target = output("mp4")
    defer { for url in [source, target] { try? FileManager.default.removeItem(at: url) } }

    try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(2, 3.2), format: format))

    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 1.2) < 0.1)
    #expect(try await brightness(of: target, at: 0.2) < 0.2)
    #expect(try await brightness(of: target, at: 1.15) > 0.8)
}

@Test func changesTheVolumeInBothDirections() async throws {
    let source = try await threeScenes(audio: true)
    defer { try? FileManager.default.removeItem(at: source) }
    let original = try await peak(of: source)
    #expect(original > 0.2 && original < 0.4)

    for (volume, low, high) in [(Float(2), 0.45, 0.8), (0.5, 0.1, 0.2), (0, 0, 0.01)] as [(Float, Float, Float)] {
        let target = output("mp4")
        defer { try? FileManager.default.removeItem(at: target) }
        try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(0, 3), volume: volume, format: .mp4HEVC))
        let result = try await peak(of: target)
        #expect(result >= low && result <= high, "volume \(volume) gave peak \(result)")
    }
}

@Test func boostingPastFullScaleClipsInsteadOfWrapping() async throws {
    let source = try await threeScenes(audio: true)
    let target = output("mp4")
    defer { for url in [source, target] { try? FileManager.default.removeItem(at: url) } }
    try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(0, 3), volume: 4, format: .mp4HEVC))
    // Encoded audio overshoots a little around a clipped wave, so this only rules out wrapping.
    #expect(try await peak(of: target) > 0.9)
}

@Test func writesALoopingGIFOfTheRange() async throws {
    let source = try await threeScenes()
    let target = output("gif")
    defer { for url in [source, target] { try? FileManager.default.removeItem(at: url) } }

    try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(1, 2.5), format: .gif))

    let gif = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
    #expect(CGImageSourceGetType(gif) as String? == UTType.gif.identifier)
    #expect(CGImageSourceGetCount(gif) == 15)
    #expect(abs(try brightness(try #require(CGImageSourceCreateImageAtIndex(gif, 0, nil))) - 0.5) < 0.15)
    #expect(try brightness(try #require(CGImageSourceCreateImageAtIndex(gif, 14, nil))) > 0.8)
}

/// Saving an untouched recording moves the file, so it costs no time and no quality.
@MainActor
@Test func savingUntouchedMovesTheFile() async throws {
    let source = try await threeScenes(audio: true)
    let bytes = try Data(contentsOf: source)
    let target = output("mp4")
    defer { try? FileManager.default.removeItem(at: target) }

    let editor = try await VideoEditor(recording: source)
    #expect(editor.trimmedRange.duration.seconds == 3)
    try await editor.write(to: target)

    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try Data(contentsOf: target) == bytes)
}

/// Saving after a trim uses up the recording and writes the shorter file over what was there.
@MainActor
@Test func savingATrimReplacesTheDestination() async throws {
    let source = try await threeScenes()
    let target = output("mp4")
    defer { try? FileManager.default.removeItem(at: target) }
    try Data("old".utf8).write(to: target)

    let editor = try await VideoEditor(recording: source)
    editor.trimmedRange = range(1, 2)
    try await editor.write(to: target)

    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 1) < 0.1)
}

/// The top-left quarter dark and the rest bright, for 1.5 seconds with sound.
private func quarters(audio: Bool = false) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).mp4")
    var settings = VideoSettings()
    settings.microphone = audio
    let writer = try VideoWriter(url: url, width: 320, height: 240, settings: settings)
    let start = CMTime(seconds: 1000, preferredTimescale: 48_000)
    for tenth in 0..<15 {
        let time = start + CMTime(seconds: Double(tenth) / 10, preferredTimescale: 48_000)
        writer.append(try grayFrame(0, at: time, split: 160))
        if audio { writer.append(try tone(880, channels: 1, at: time), from: .microphone) }
        try await Task.sleep(for: .milliseconds(30))
    }
    let failure: Error? = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    #expect(failure == nil)
    return url
}

/// A crop keeps exactly that part of the picture, at that size, whatever the codec was.
@Test(arguments: [VideoFormat.mp4HEVC, .mp4H264])
func cropsTheVideo(format: VideoFormat) async throws {
    let source = try await quarters(audio: true)
    let target = output("mp4")
    defer { for url in [source, target] { try? FileManager.default.removeItem(at: url) } }

    // Only the dark quarter, away from the bright edges.
    let crop = CGRect(x: 20, y: 20, width: 100, height: 60)
    try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(0.2, 1.2), format: format, crop: crop))

    let asset = AVURLAsset(url: target)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == crop.size)
    #expect(abs(try await asset.load(.duration).seconds - 1) < 0.1)
    #expect(try await brightness(of: target, at: 0.5) < 0.2)
    #expect(try await codec(of: target) == (format.codec == .hevc ? .hevc : .h264))
    #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)

    // The bright corner the other way around, to rule out a crop from the wrong side.
    let other = output("mp4")
    defer { try? FileManager.default.removeItem(at: other) }
    let bright = CGRect(x: 180, y: 140, width: 100, height: 60)
    try await exportVideo(from: source, to: other, edit: VideoEdit(range: range(0.2, 1.2), format: format, crop: bright))
    #expect(try await brightness(of: other, at: 0.5) > 0.8)
}

@Test func cropsAGIF() async throws {
    let source = try await quarters()
    let target = output("gif")
    defer { for url in [source, target] { try? FileManager.default.removeItem(at: url) } }
    let crop = CGRect(x: 180, y: 140, width: 100, height: 60)
    try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(0, 1), format: .gif, crop: crop))
    let gif = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
    let frame = try #require(CGImageSourceCreateImageAtIndex(gif, 0, nil))
    #expect(frame.width == 100 && frame.height == 60)
    #expect(try brightness(frame) > 0.8)
}

/// An audio file with a tone at 0.3, the same level as the recordings above.
private func audioFile(seconds: Double) throws -> URL {
    let url = output("caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * 48_000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let data = try #require(buffer.floatChannelData)[0]
    for index in 0..<Int(frames) { data[index] = Float(sin(2 * .pi * 440 * Double(index) / 48_000)) * 0.3 }
    try file.write(from: buffer)
    return url
}

/// The loudest sample of the file's audio in a stretch of time, from 0 to 1.
private func peak(of url: URL, from start: Double, to end: Double) async throws -> Float {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = range(start, end)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    reader.startReading()
    return try await offThePool {
        var loudest: Float = 0
        while let sample = output.copyNextSampleBuffer() { loudest = max(loudest, cheapshot.peak(of: sample) ?? 0) }
        return loudest
    }
}

/// Added audio starts where it was placed, mixes with the recorded sound and stops with the video.
@Test func mixesAddedAudioIntoTheVideo() async throws {
    let source = try await threeScenes()
    let song = try audioFile(seconds: 10)
    let target = output("mp4")
    defer { for url in [source, song, target] { try? FileManager.default.removeItem(at: url) } }

    let added = try await AudioClip(file: song, start: CMTime(seconds: 1, preferredTimescale: 600), volume: 2)
    try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(0, 3), format: .mp4HEVC, clips: [added]))

    #expect(try await peak(of: target, from: 0, to: 0.8) < 0.01)
    let boosted = try await peak(of: target, from: 1.2, to: 2.8)
    #expect(boosted > 0.5 && boosted < 0.7, "got \(boosted)")
    // The file is much longer than the video, which keeps its own length.
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 3) < 0.1)
    #expect(try await !AVURLAsset(url: target).loadTracks(withMediaType: .video).isEmpty)
}

@Test func addedAudioPlaysOverTheRecordedSound() async throws {
    let source = try await threeScenes(audio: true)
    let song = try audioFile(seconds: 1)
    let target = output("mp4")
    defer { for url in [source, song, target] { try? FileManager.default.removeItem(at: url) } }

    // Silencing the recording leaves only the added file, which ends after a second.
    let added = try await AudioClip(file: song, start: .zero)
    try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(0, 3), volume: 0, format: .mp4HEVC, clips: [added]))
    #expect(try await peak(of: target, from: 0.2, to: 0.8) > 0.2)
    #expect(try await peak(of: target, from: 1.5, to: 2.8) < 0.01)
}

@Test func aFileWithoutAudioIsRefused() async throws {
    let source = try await threeScenes()
    defer { try? FileManager.default.removeItem(at: source) }
    await #expect(throws: VideoEditorError.self) { try await AudioClip(file: source, start: .zero) }
}

/// A clip plays only its cut part of the file, and clips on other rows play at the same time.
@Test func stacksCutClips() async throws {
    let source = try await threeScenes()
    let quiet = try audioFile(seconds: 2)
    let loud = try audioFile(seconds: 2)
    let target = output("mp4")
    defer { for url in [source, quiet, loud, target] { try? FileManager.default.removeItem(at: url) } }

    // From 0.5 to 1.5 s, one second cut out of the middle of the file.
    var first = try await AudioClip(file: quiet, start: CMTime(seconds: 0.5, preferredTimescale: 600), volume: 0.5)
    first.offset = CMTime(seconds: 0.5, preferredTimescale: 600)
    first.length = CMTime(seconds: 1, preferredTimescale: 600)
    // From 1 s to the end of the video, one second short of the whole file.
    let second = try await AudioClip(file: loud, start: CMTime(seconds: 1, preferredTimescale: 600))
    try await exportVideo(from: source, to: target, edit: VideoEdit(range: range(0, 3), format: .mp4HEVC, clips: [first, second]))

    #expect(try await peak(of: target, from: 0, to: 0.4) < 0.01)
    let alone = try await peak(of: target, from: 0.6, to: 0.9)
    #expect(alone > 0.1 && alone < 0.2, "got \(alone)")
    let together = try await peak(of: target, from: 1.1, to: 1.4)
    #expect(together > 0.35 && together < 0.55, "got \(together)")
    let after = try await peak(of: target, from: 1.7, to: 2.8)
    #expect(after > 0.2 && after < 0.35, "got \(after)")
}

@Test func readsAWaveform() async throws {
    let song = try audioFile(seconds: 2)
    defer { try? FileManager.default.removeItem(at: song) }
    let peaks = try await audioPeaks(of: song)
    #expect(abs(peaks.count - 100) <= 2)
    #expect(peaks.allSatisfy { abs($0 - 0.3) < 0.05 })
}

@Test func writesTimes() {
    #expect(timeText(62.5) == "1:02.5")
    #expect(timeText(3, tenths: false) == "0:03")
    #expect(timeText(59.96) == "1:00.0")
}

/// Mouse events for a view of `window`, in that view's coordinates.
@MainActor
private final class Mouse {
    private let view: NSView
    private var clock: TimeInterval = 0
    init(_ view: NSView) { self.view = view }

    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        clock += 1
        return NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: clock,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func click(_ point: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, point))
        view.mouseUp(with: event(.leftMouseUp, point))
    }

    func drag(_ from: CGPoint, _ to: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, from))
        view.mouseDragged(with: event(.leftMouseDragged, to))
        view.mouseUp(with: event(.leftMouseUp, to))
    }
}

/// The timeline's own path: its video row trims, a clip moves and gets cut, and saving applies it all.
@MainActor
@Test func editsOnTheTimeline() async throws {
    _ = NSApplication.shared
    let source = try await threeScenes(audio: true)
    let song = try audioFile(seconds: 2)
    let target = output("mp4")
    defer { for url in [song, target] { try? FileManager.default.removeItem(at: url) } }
    let editor = try await VideoEditor(recording: source)
    let timeline = editor.timelineView
    editor.window.contentView?.layoutSubtreeIfNeeded()
    let mouse = Mouse(timeline)
    let rows = timeline.idealHeight

    await editor.useClips([try await AudioClip(file: song, start: .zero)])
    #expect(timeline.idealHeight == rows + 44)
    timeline.layoutSubtreeIfNeeded()

    // A click on the video row moves the playhead.
    mouse.click(timeline.point(at: 1))
    #expect(abs(timeline.time - 1) < 0.05)

    // Its ends trim everything, and the playhead stays inside what is kept.
    mouse.drag(timeline.point(at: 0), timeline.point(at: 0.5))
    mouse.drag(timeline.point(at: 3), timeline.point(at: 2.5))
    #expect(abs(editor.trimmedRange.start.seconds - 0.5) < 0.05)
    #expect(abs(editor.trimmedRange.end.seconds - 2.5) < 0.05)
    mouse.drag(timeline.point(at: 1), timeline.point(at: 0.1))
    #expect(abs(timeline.time - 0.5) < 0.05)

    // Inside a clip moves it, and the audio keeps its length.
    let waiting = try #require(timeline.onClipsEdited)
    var edited: [[AudioClip]] = []
    timeline.onClipsEdited = { edited.append($0); waiting($0) }
    mouse.drag(timeline.point(at: 1, clip: 0), timeline.point(at: 1.5, clip: 0))
    var clip = try #require(timeline.clips.first)
    #expect(abs(clip.start.seconds - 0.5) < 0.05 && abs(clip.length.seconds - 2) < 0.01)

    // The left end cuts the start of the file, and the right end its tail.
    mouse.drag(timeline.point(at: 0.5, clip: 0), timeline.point(at: 1, clip: 0))
    clip = try #require(timeline.clips.first)
    #expect(abs(clip.start.seconds - 1) < 0.05 && abs(clip.offset.seconds - 0.5) < 0.05 && abs(clip.length.seconds - 1.5) < 0.05)
    mouse.drag(timeline.point(at: 2.5, clip: 0), timeline.point(at: 2, clip: 0))
    clip = try #require(timeline.clips.first)
    #expect(abs(clip.length.seconds - 1) < 0.05)
    #expect(edited.count == 3)

    // A click does not touch the clip, and moves the playhead like anywhere else.
    mouse.click(timeline.point(at: 1.5, clip: 0))
    #expect(edited.count == 3)
    #expect(abs(timeline.time - 1.5) < 0.05)

    // The player moved to the last timeline, so saving is what shows on screen.
    for _ in 0..<100 where editor.clips.first != clip { try await Task.sleep(for: .milliseconds(20)) }
    #expect(editor.clips.first == clip)
    try await editor.write(to: target)
    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 2) < 0.1)
    // 1.5 s on the recording's timeline is 1 s into the saved file.
    #expect(try await peak(of: target, from: 0.9, to: 1.2) > 0.3)
}

/// The editor's own path: a drag draws the crop, a shape replaces it, and saving applies both.
@MainActor
@Test func cropsThroughTheEditor() async throws {
    _ = NSApplication.shared
    let source = try await quarters()
    let target = output("mp4")
    defer { try? FileManager.default.removeItem(at: target) }
    let editor = try await VideoEditor(recording: source)
    let overlay = editor.overlay
    editor.window.contentView?.layoutSubtreeIfNeeded()
    #expect(overlay.superview != nil && overlay.frame.width > 0)

    let mouse = Mouse(overlay)
    func drag(_ from: CGPoint, _ to: CGPoint) { mouse.drag(from, to) }
    // From view points to video pixels and back.
    let fit = overlay.videoRect
    let zoom = fit.width / 320
    func view(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: fit.minX + x * zoom, y: fit.minY + y * zoom) }

    // The picture stays clear of the edges of the window, where macOS takes the mouse to resize it.
    #expect(fit.minX >= 20 && fit.minY >= 20 && overlay.bounds.maxX - fit.maxX >= 20 && overlay.bounds.maxY - fit.maxY >= 20)

    #expect(overlay.hitTest(view(100, 100)) == nil)
    overlay.isEditing = true
    #expect(overlay.hitTest(view(100, 100)) === overlay)

    // Fresh in Free mode, the corners and sides of the whole picture already resize it.
    drag(view(320, 240), view(280, 200))
    let fromCorner = try #require(overlay.crop)
    #expect(abs(fromCorner.maxX - 280) <= 1 && abs(fromCorner.maxY - 200) <= 1 && fromCorner.origin == .zero)
    drag(view(0, 100), view(40, 100))
    let fromSide = try #require(overlay.crop)
    #expect(abs(fromSide.minX - 40) <= 1 && abs(fromSide.maxX - 280) <= 1 && fromSide.minY == 0 && abs(fromSide.maxY - 200) <= 1)
    overlay.crop = nil

    // Drawing, past the edge and backward.
    drag(view(120, 100), view(20, 20))
    let drawn = try #require(overlay.crop)
    #expect(abs(drawn.minX - 20) <= 1 && abs(drawn.maxX - 120) <= 1 && abs(drawn.minY - 20) <= 1 && abs(drawn.maxY - 100) <= 1)
    #expect(Int(drawn.width) % 2 == 0 && Int(drawn.height) % 2 == 0)

    // Moving from inside, stopped by the edge of the picture.
    drag(view(70, 60), view(-200, 60))
    #expect(overlay.crop?.minX == 0 && overlay.crop?.width == drawn.width)

    // Resizing from a corner keeps the opposite one.
    let moved = try #require(overlay.crop)
    drag(view(moved.maxX, moved.maxY), view(150, 110))
    #expect(overlay.crop?.origin == moved.origin)
    #expect(abs(try #require(overlay.crop).maxX - 150) <= 1)

    // With a fixed shape, a drag keeps it. The size gets rounded to even pixels at the end.
    overlay.ratio = 16.0 / 9
    drag(view(10, 10), view(170, 40))
    let shaped = try #require(overlay.crop)
    #expect(abs(shaped.width / shaped.height - 16.0 / 9) < 0.05)

    // The whole picture is no crop.
    overlay.ratio = nil
    overlay.crop = CGRect(x: 0, y: 0, width: 100, height: 100)
    drag(view(100, 100), view(320, 240))
    #expect(overlay.crop == nil)

    overlay.crop = CGRect(x: 180, y: 140, width: 100, height: 60)
    try await editor.write(to: target)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    let track = try #require(try await AVURLAsset(url: target).loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 100, height: 60))
    #expect(try await brightness(of: target, at: 0.5) > 0.8)
}

/// Adding audio switches the player to a new timeline, and that must not lose the trim.
@MainActor
@Test func addingAudioKeepsTheTrim() async throws {
    let source = try await threeScenes()
    let song = try audioFile(seconds: 1)
    let target = output("mp4")
    defer { for url in [song, target] { try? FileManager.default.removeItem(at: url) } }
    let editor = try await VideoEditor(recording: source)
    editor.trimmedRange = range(1, 2)

    await editor.useClips([try await AudioClip(file: song, start: CMTime(seconds: 1, preferredTimescale: 600))])
    #expect(!editor.clips.isEmpty)
    #expect(abs(editor.trimmedRange.start.seconds - 1) < 0.01 && abs(editor.trimmedRange.end.seconds - 2) < 0.01)
    try await editor.write(to: target)

    #expect(abs(try await AVURLAsset(url: target).load(.duration).seconds - 1) < 0.1)
    #expect(try await peak(of: target, from: 0.2, to: 0.8) > 0.2)
}

/// A narration is a temporary file. Removing it deletes it, and an imported file is never touched.
@MainActor
@Test func removingANarrationDeletesItsFile() async throws {
    let source = try await threeScenes()
    let narration = try audioFile(seconds: 1)
    let song = try audioFile(seconds: 1)
    defer { for url in [source, narration, song] { try? FileManager.default.removeItem(at: url) } }
    let editor = try await VideoEditor(recording: source)

    let voice = try await AudioClip(file: narration, start: .zero, isNarration: true)
    let music = try await AudioClip(file: song, start: .zero)
    await editor.useClips([voice, music])
    #expect(FileManager.default.fileExists(atPath: narration.path))
    await editor.useClips([music])
    #expect(!FileManager.default.fileExists(atPath: narration.path))
    await editor.useClips([])
    #expect(FileManager.default.fileExists(atPath: song.path))
    #expect(editor.clips.isEmpty)
}

@Test func cropGeometry() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
    func box(_ anchor: (CGFloat, CGFloat), _ point: (CGFloat, CGFloat), ratio: CGFloat? = nil) -> CGRect {
        cropRect(from: CGPoint(x: anchor.0, y: anchor.1), to: CGPoint(x: point.0, y: point.1), ratio: ratio, in: bounds, minimum: 32)
    }
    #expect(box((100, 100), (300, 200)) == CGRect(x: 100, y: 100, width: 200, height: 100))
    #expect(box((300, 200), (100, 100)) == CGRect(x: 100, y: 100, width: 200, height: 100))
    // Too small grows to the minimum, the way the drag went.
    #expect(box((100, 100), (101, 101)) == CGRect(x: 100, y: 100, width: 32, height: 32))
    #expect(box((100, 100), (99, 99)) == CGRect(x: 68, y: 68, width: 32, height: 32))
    // Against an edge there is only room the other way.
    #expect(box((990, 490), (995, 495)) == CGRect(x: 958, y: 458, width: 32, height: 32))
    // A shape follows the longer side of the drag and stops at the bounds.
    #expect(box((0, 0), (160, 10), ratio: 16.0 / 9) == CGRect(x: 0, y: 0, width: 160, height: 90))
    #expect(box((0, 0), (1000, 500), ratio: 1) == CGRect(x: 0, y: 0, width: 500, height: 500))
    #expect(box((1000, 500), (0, 0), ratio: 4.0 / 3).maxX == 1000)
    #expect(box((1000, 500), (0, 0), ratio: 4.0 / 3).height == 500)

    #expect(evenPixelRect(CGRect(x: 9.6, y: 0.4, width: 90.4, height: 101)) == CGRect(x: 10, y: 0, width: 90, height: 100))
    #expect(evenPixelRect(CGRect(x: 0.6, y: 0, width: 99.4, height: 2)).maxX <= 100)
}
