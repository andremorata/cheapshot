import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// What the video editor can save a recording as.
enum VideoFormat: CaseIterable, Sendable {
    case mp4HEVC, mp4H264, movHEVC, movH264, gif

    var title: String {
        switch self {
        case .mp4HEVC: "MP4 (HEVC)"
        case .mp4H264: "MP4 (H.264)"
        case .movHEVC: "MOV (HEVC)"
        case .movH264: "MOV (H.264)"
        case .gif: "GIF"
        }
    }

    var contentType: UTType {
        switch self {
        case .mp4HEVC, .mp4H264: .mpeg4Movie
        case .movHEVC, .movH264: .quickTimeMovie
        case .gif: .gif
        }
    }

    /// Nil for GIF, which is written frame by frame and has no video codec.
    var codec: VideoSettings.Codec? {
        switch self {
        case .mp4HEVC, .movHEVC: .hevc
        case .mp4H264, .movH264: .h264
        case .gif: nil
        }
    }
}

/// A stretch of an audio file on its own row of the timeline. It plays from `start` on the
/// recording's timeline, and what it plays is `length` of the file from `offset` on.
struct AudioClip: Equatable, Identifiable, Sendable {
    let id = UUID()
    let file: URL
    let fileLength: CMTime
    /// True for a narration recorded in the editor. That file is temporary and the editor deletes it.
    let isNarration: Bool
    var start: CMTime
    var offset = CMTime.zero
    var length: CMTime
    var volume: Float

    /// Throws when the file has no audio in it.
    init(file: URL, start: CMTime, volume: Float = 1, isNarration: Bool = false) async throws {
        guard let track = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio).first else { throw VideoEditorError.noAudio }
        self.file = file
        self.start = start
        self.volume = volume
        self.isNarration = isNarration
        fileLength = try await track.load(.timeRange).duration
        length = fileLength
    }

    var title: String { isNarration ? "Voice-over" : file.lastPathComponent }
}

/// Everything the editor changes about a recording.
struct VideoEdit: Sendable {
    var range: CMTimeRange
    var volume: Float = 1
    var format: VideoFormat
    /// The part of the picture to keep, in pixels from the top-left. Nil keeps all of it.
    var crop: CGRect?
    var clips: [AudioClip] = []
}

/// The recording and the audio clips on one timeline. The preview plays it and the export reads
/// it, so what plays is what gets saved.
struct VideoTimeline: @unchecked Sendable {
    let composition = AVMutableComposition()
    /// The video as stored in the recording, for its format and its size.
    let source: AVAssetTrack
    let video: AVCompositionTrack
    private let original: AVCompositionTrack?
    private let clipTracks: [UUID: AVCompositionTrack]
    /// Held for as long as the timeline. A track only points weakly at its asset, and reading
    /// from a track whose asset is gone fails.
    private let assets: [AVURLAsset]

    init(recording: AVURLAsset, clips: [AudioClip]) async throws {
        guard let source = try await recording.loadTracks(withMediaType: .video).first else { throw RecordingError.cannotFinish }
        self.source = source
        let composition = composition
        func add(_ track: AVAssetTrack, _ range: CMTimeRange, at start: CMTime) throws -> AVCompositionTrack {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RecordingError.cannotFinish
            }
            try copy.insertTimeRange(range, of: track, at: start)
            return copy
        }
        let videoRange = try await source.load(.timeRange)
        video = try add(source, videoRange, at: videoRange.start)
        if let track = try await recording.loadTracks(withMediaType: .audio).first {
            let range = try await track.load(.timeRange)
            original = try add(track, range, at: range.start)
        } else {
            original = nil
        }
        let videoLength = try await recording.load(.duration)
        var clipTracks: [UUID: AVCompositionTrack] = [:]
        var assets = [recording]
        for clip in clips {
            let asset = AVURLAsset(url: clip.file)
            assets.append(asset)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw VideoEditorError.noAudio }
            // Audio that runs past the end of the video is cut there.
            let kept = min(clip.length, videoLength - clip.start)
            guard kept > .zero else { continue }
            clipTracks[clip.id] = try add(track, CMTimeRange(start: clip.offset, duration: kept), at: clip.start)
        }
        self.clipTracks = clipTracks
        self.assets = assets
    }

    var audioTracks: [AVCompositionTrack] { [original].compactMap { $0 } + clipTracks.values }

    func audioMix(volume: Float, clips: [AudioClip]) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        let levels = [(original, volume)] + clips.map { (clipTracks[$0.id], $0.volume) }
        mix.inputParameters = levels.compactMap { track, level in
            guard let track else { return nil }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            // 1 keeps the level as it is, and above 1 boosts it.
            parameters.setVolume(level, at: .zero)
            return parameters
        }
        return mix
    }

    /// Cuts the picture to `crop`, in pixels from the top-left. It renders a steady stream of
    /// frames, so a crop always encodes the video again.
    func cropping(to crop: CGRect) -> AVVideoComposition {
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(CGAffineTransform(translationX: -crop.minX, y: -crop.minY), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.layerInstructions = [layer]
        let result = AVMutableVideoComposition()
        result.renderSize = crop.size
        result.frameDuration = CMTime(value: 1, timescale: CMTimeScale(VideoSettings.load().framesPerSecond))
        result.instructions = [instruction]
        return result
    }

    /// Exact stills of the timeline, with the crop applied.
    func imageGenerator(crop: CGRect?) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: composition)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.videoComposition = crop.map(cropping)
        return generator
    }
}

enum VideoEditorError: LocalizedError {
    case noAudio
    case cannotRecordMicrophone

    var errorDescription: String? {
        switch self {
        case .noAudio: "That file has no audio in it."
        case .cannotRecordMicrophone: "The microphone could not start recording."
        }
    }
}

/// Writes `edit` of the recording at `source` to `destination`, which must not exist yet. The
/// video is copied without re-encoding when the codec stays the same and nothing is cropped. The
/// audio is always encoded again.
func exportVideo(from source: URL, to destination: URL, edit: VideoEdit) async throws {
    let timeline = try await VideoTimeline(recording: AVURLAsset(url: source), clips: edit.clips)
    guard let codec = edit.format.codec else { return try await exportGIF(timeline, to: destination, edit: edit) }
    let hint = try await timeline.source.load(.formatDescriptions).first
    let keepsCodec = hint?.mediaSubType == (codec == .hevc ? .hevc : .h264)

    let reader = try AVAssetReader(asset: timeline.composition)
    reader.timeRange = edit.range
    // AVFileType values are the same identifiers as UTType.
    let writer = try AVAssetWriter(outputURL: destination, fileType: AVFileType(edit.format.contentType.identifier))

    let videoOutput: AVAssetReaderOutput
    let videoInput: AVAssetWriterInput
    if keepsCodec, edit.crop == nil {
        // `nil` settings hand over the compressed video samples untouched.
        videoOutput = AVAssetReaderTrackOutput(track: timeline.video, outputSettings: nil)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
    } else {
        let pixels: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        var size = try await timeline.source.load(.naturalSize)
        if let crop = edit.crop {
            let cropped = AVAssetReaderVideoCompositionOutput(videoTracks: [timeline.video], videoSettings: pixels)
            cropped.videoComposition = timeline.cropping(to: crop)
            videoOutput = cropped
            size = crop.size
        } else {
            videoOutput = AVAssetReaderTrackOutput(track: timeline.video, outputSettings: pixels)
        }
        var settings = VideoSettings.load()
        settings.codec = codec
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.outputSettings(width: Int(size.width), height: Int(size.height)))
    }
    reader.add(videoOutput)
    writer.add(videoInput)
    var tracks: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]

    if !timeline.audioTracks.isEmpty {
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: timeline.audioTracks, audioSettings: mixedPCMSettings)
        audioOutput.audioMix = timeline.audioMix(volume: edit.volume, clips: edit.clips)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: mixedAACSettings)
        reader.add(audioOutput)
        writer.add(audioInput)
        tracks.append((audioOutput, audioInput))
    }
    // The end is explicit because the last frame of a recording can stay on screen for a while.
    try await copySamples(from: reader, to: writer, tracks: tracks, from: edit.range.start, to: edit.range.end)
}

/// Writes the edit as a looping GIF without sound, ten frames per second and at most 960 px wide.
// ponytail: the encoder keeps every frame until it finishes, up to about 1.2 GB per minute of
// 16:9 GIF. Fine for the short clips GIFs are for. Downscale by length if long ones show up.
private func exportGIF(_ timeline: VideoTimeline, to destination: URL, edit: VideoEdit) async throws {
    let times = stride(from: edit.range.start.seconds, to: edit.range.end.seconds, by: 0.1).map {
        CMTime(seconds: $0, preferredTimescale: 600)
    }
    guard let gif = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
        throw RecordingError.cannotFinish
    }
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary

    let generator = timeline.imageGenerator(crop: edit.crop)
    generator.maximumSize = CGSize(width: 960, height: 960)
    for await frame in generator.images(for: times) {
        CGImageDestinationAddImage(gif, try frame.image, delay)
    }
    guard CGImageDestinationFinalize(gif) else { throw RecordingError.cannotFinish }
}

/// The rectangle to keep, drawn over the video. It dims what the crop throws away. It only takes
/// the mouse while `isEditing`, and otherwise the views below it get every click.
@MainActor
final class CropOverlay: NSView {
    /// The sides of a crop are never shorter than this, in video pixels.
    private static let minimum: CGFloat = 32
    /// Room around the picture, so its corners are never against the window's resize area.
    private static let margin: CGFloat = 24

    /// The video's size in pixels. The crop is in these pixels, from the top-left.
    private let videoSize: CGSize
    /// Width over height for a fixed shape. Nil is a free crop.
    var ratio: CGFloat? { didSet { refreshCursors() } }
    /// A crop of the whole picture is no crop, so the video can keep its codec without re-encoding.
    var crop: CGRect? {
        didSet {
            if crop == whole { crop = nil }
            needsDisplay = true
            refreshCursors()
            onChange?()
        }
    }
    var isEditing = false {
        didSet {
            needsDisplay = true
            refreshCursors()
        }
    }
    var onChange: (() -> Void)?

    private enum Drag {
        case moving(from: CGPoint)
        /// A side only moves one way, so the other axis stays at `x` or `y`.
        case sizing(anchor: CGPoint, x: CGFloat? = nil, y: CGFloat? = nil)
    }
    private var drag: Drag?

    init(videoSize: CGSize) {
        self.videoSize = videoSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { isEditing ? super.hitTest(point) : nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var whole: CGRect { CGRect(origin: .zero, size: videoSize) }
    /// Where the picture plays in this view.
    var videoRect: CGRect { aspectFit(videoSize, in: bounds.insetBy(dx: Self.margin, dy: Self.margin)) }
    /// View points per video pixel.
    private var zoom: CGFloat { videoSize.width > 0 && videoRect.width > 0 ? videoRect.width / videoSize.width : 1 }

    private func onScreen(_ rect: CGRect) -> CGRect {
        CGRect(x: videoRect.minX + rect.minX * zoom, y: videoRect.minY + rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
    }

    /// Where an event lands in the video. A drag past its edge counts as the edge.
    private func videoPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max((point.x - videoRect.minX) / zoom, 0), videoSize.width),
            y: min(max((point.y - videoRect.minY) / zoom, 0), videoSize.height))
    }

    /// The middle of each side, in the same order as `corners`: top, right, bottom and left. A
    /// fixed shape only resizes from its corners.
    private func sides(of rect: CGRect) -> [CGPoint] {
        guard ratio == nil else { return [] }
        return [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, crop != nil || isEditing else { return }
        let kept = onScreen(crop ?? whole)
        context.addRect(videoRect)
        context.addRect(kept)
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(.white)
        context.setLineWidth(1)
        context.stroke(kept)
        guard isEditing else { return }
        context.setFillColor(.white)
        for corner in kept.corners {
            context.fill(CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10))
        }
        for side in sides(of: kept) {
            context.fill(CGRect(x: side.x - 4, y: side.y - 4, width: 8, height: 8))
        }
    }

    private func refreshCursors() { window?.invalidateCursorRects(for: self) }

    override func resetCursorRects() {
        guard isEditing else { return }
        addCursorRect(videoRect, cursor: .crosshair)
        let kept = onScreen(crop ?? whole)
        if crop != nil { addCursorRect(kept, cursor: .openHand) }
        for (index, side) in sides(of: kept).enumerated() {
            let zone = CGRect(x: side.x - 10, y: side.y - 10, width: 20, height: 20)
            addCursorRect(zone, cursor: index % 2 == 0 ? .resizeUpDown : .resizeLeftRight)
        }
        for corner in kept.corners {
            addCursorRect(CGRect(x: corner.x - 12, y: corner.y - 12, width: 24, height: 24), cursor: .crosshair)
        }
    }

    /// A corner or a side resizes, inside the crop moves it, and anywhere else draws a new one.
    override func mouseDown(with event: NSEvent) {
        let view = convert(event.locationInWindow, from: nil)
        let point = videoPoint(event)
        let current = crop ?? whole
        let kept = onScreen(current)
        func near(_ spot: CGPoint, _ reach: CGFloat) -> Bool { hypot(spot.x - view.x, spot.y - view.y) <= reach }
        if let index = kept.corners.firstIndex(where: { near($0, 12) }) {
            // The corner across from the one in hand stays put.
            drag = .sizing(anchor: current.corners[(index + 2) % 4])
        } else if let index = sides(of: kept).firstIndex(where: { near($0, 10) }) {
            drag = switch index {
            case 0: .sizing(anchor: CGPoint(x: current.minX, y: current.maxY), x: current.maxX)
            case 1: .sizing(anchor: CGPoint(x: current.minX, y: current.minY), y: current.maxY)
            case 2: .sizing(anchor: CGPoint(x: current.minX, y: current.minY), x: current.maxX)
            default: .sizing(anchor: CGPoint(x: current.maxX, y: current.minY), y: current.maxY)
            }
        } else if crop != nil, current.contains(point) {
            drag = .moving(from: point)
        } else {
            drag = .sizing(anchor: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = videoPoint(event)
        switch drag {
        case .sizing(let anchor, let x, let y):
            crop = cropRect(from: anchor, to: CGPoint(x: x ?? point.x, y: y ?? point.y), ratio: ratio, in: whole, minimum: Self.minimum)
        case .moving(let from):
            guard let current = crop else { return }
            crop = CGRect(
                x: min(max(current.minX + point.x - from.x, 0), videoSize.width - current.width),
                y: min(max(current.minY + point.y - from.y, 0), videoSize.height - current.height),
                width: current.width, height: current.height)
            drag = .moving(from: point)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        crop = crop.map(evenPixelRect)
    }
}

private extension CGRect {
    /// Going around the rect, so the opposite of corner `i` is `(i + 2) % 4`.
    var corners: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }
}

/// The dark area the video plays in, with the crop on top of the picture.
@MainActor
private final class VideoStage: NSView {
    private let picture = NSView()
    private let overlay: CropOverlay

    init(player: AVPlayer, overlay: CropOverlay) {
        self.overlay = overlay
        super.init(frame: .zero)
        // A view that hosts this layer, so AppKit keeps it under the crop.
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resize
        layer.backgroundColor = .black
        picture.layer = layer
        picture.wantsLayer = true
        addSubview(picture)
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 1).setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        picture.frame = overlay.videoRect
    }
}

/// Opens after a recording stops: plays it on a timeline with a row for the video, one for its
/// sound and one for each audio clip. It trims the ends, crops the picture, sets every volume and
/// picks the format. There is one at a time, and it owns the temporary file until the user saves
/// or discards it.
@MainActor
final class VideoEditor: NSObject, NSWindowDelegate {
    private(set) static var current: VideoEditor?
    private static let barHeight: CGFloat = 52
    private static let transportHeight: CGFloat = 44
    private static let minStageHeight: CGFloat = 240
    /// Wide enough for every control in the top bar.
    private static let minWidth: CGFloat = 760
    /// The crop shapes in the menu, as width over height. Nil is a free crop.
    private static let cropShapes: [(title: String, ratio: CGFloat?)] = [
        ("Free", nil), ("16:9", 16.0 / 9), ("4:3", 4.0 / 3), ("1:1", 1), ("4:5", 4.0 / 5), ("9:16", 9.0 / 16),
    ]

    static func open(_ recording: URL) async throws {
        let editor = try await VideoEditor(recording: recording)
        current = editor
        editor.present()
    }

    let window: NSWindow
    let overlay: CropOverlay
    let timelineView: TimelineView
    private let recording: URL
    private let recordingAsset: AVURLAsset
    let player: AVPlayer
    private var timeline: VideoTimeline
    private let duration: CMTime
    private let videoSize: CGSize
    /// The format that needs no work, so saving an untouched recording only moves the file.
    private let originalFormat: VideoFormat
    private var timelineHeight: NSLayoutConstraint?
    private var timeObserver: Any?
    /// The first pictures and waveform for the timeline, which fill in once they are read.
    private(set) var loading: Task<Void, Never>?

    private let cropButton = NSButton(title: "Crop", target: nil, action: nil)
    private let cropShape = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cropSize = NSTextField(labelWithString: "")
    private let cropReset = NSButton(title: "Reset", target: nil, action: nil)
    private let formats = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let save = NSButton(title: "Save…", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    private let play = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private let importAudio = NSButton(title: "Import Audio…", target: nil, action: nil)
    private let narrate = NSButton(title: "Record Voice-over", target: nil, action: nil)

    private var isCropping = false { didSet { refreshControls() } }
    private var isSaving = false { didSet { refreshControls() } }
    /// How many changes to the clips are still on their way to the player.
    private var audioLoads = 0 { didSet { refreshControls() } }
    private var isLoadingAudio: Bool { audioLoads > 0 }
    /// The last change to the clips asked for. An older one that finishes late is dropped.
    private var clipBuild = 0
    private var narration: AVAudioRecorder? { didSet { refreshControls() } }
    private var narrationStart = CMTime.zero
    private var narrationEnd: Task<Void, Never>?

    /// What the trim keeps. Playback stops at its end.
    var trimmedRange: CMTimeRange {
        didSet {
            timelineView.range = trimmedRange.start.seconds...trimmedRange.end.seconds
            player.currentItem?.forwardPlaybackEndTime = trimmedRange.end
            showTime()
        }
    }

    var originalVolume: Float = 1 {
        didSet {
            timelineView.originalVolume = timelineView.originalVolume == nil ? nil : originalVolume
            applyMix()
        }
    }

    /// A narration taken off the timeline is deleted, because nothing else points at its file.
    private(set) var clips: [AudioClip] = [] {
        didSet {
            for clip in oldValue where clip.isNarration && !clips.contains(where: { $0.file == clip.file }) {
                try? FileManager.default.removeItem(at: clip.file)
            }
            timelineView.clips = clips
            for clip in clips where timelineView.peaks[clip.file] == nil {
                Task { await loadPeaks(of: clip.file) }
            }
            fitTimeline()
            refreshControls()
        }
    }

    /// Builds the window without showing it. `open` is the way in for the app.
    init(recording: URL) async throws {
        let asset = AVURLAsset(url: recording)
        let timeline = try await VideoTimeline(recording: asset, clips: [])
        let natural = try await timeline.source.load(.naturalSize)
        let isH264 = try await timeline.source.load(.formatDescriptions).first?.mediaSubType == .h264
        let hasOriginalAudio = !timeline.audioTracks.isEmpty
        let duration = try await asset.load(.duration)
        self.duration = duration
        originalFormat = isH264 ? .mp4H264 : .mp4HEVC
        self.recording = recording
        self.timeline = timeline
        recordingAsset = asset
        videoSize = natural
        trimmedRange = CMTimeRange(start: .zero, duration: duration)
        overlay = CropOverlay(videoSize: natural)
        player = AVPlayer(playerItem: AVPlayerItem(asset: timeline.composition))
        timelineView = TimelineView(duration: duration.seconds, videoSize: natural, recording: recording, hasOriginalAudio: hasOriginalAudio)

        let visible = NSScreen.underMouse?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let barsHeight = Self.barHeight + Self.transportHeight + timelineView.idealHeight
        let limit = CGRect(x: 0, y: 0, width: visible.width * 0.8 - 48, height: visible.height * 0.85 - barsHeight - 48)
        let fitted = aspectFit(natural, in: limit, maxScale: 1).size
        let contentSize = CGSize(
            width: max(fitted.width + 48, Self.minWidth),
            height: max(fitted.height + 48, Self.minStageHeight) + barsHeight)
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()

        player.currentItem?.forwardPlaybackEndTime = duration

        func button(_ button: NSButton, _ action: Selector, symbol: String?, tip: String?, size: NSControl.ControlSize) {
            button.target = self
            button.action = action
            if let symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
            }
            button.controlSize = size
            button.toolTip = tip
        }
        button(cropButton, #selector(toggleCrop), symbol: "crop", tip: "Keep only a part of the picture", size: .large)
        for shape in Self.cropShapes { cropShape.addItem(withTitle: shape.title) }
        cropShape.target = self
        cropShape.action = #selector(cropShapeChanged)
        cropShape.toolTip = "Shape of the crop"
        cropSize.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        cropSize.textColor = .secondaryLabelColor
        cropSize.toolTip = "Size of the saved video"
        button(cropReset, #selector(resetCrop), symbol: nil, tip: "Keep the whole picture", size: .regular)
        for format in VideoFormat.allCases { formats.addItem(withTitle: format.title) }
        formats.selectItem(at: VideoFormat.allCases.firstIndex(of: originalFormat) ?? 0)
        formats.target = self
        formats.action = #selector(formatChanged)
        formats.toolTip = "Format of the saved file. GIF has no sound"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        // Standard dialog keys: Return triggers the default button, Esc triggers Cancel.
        button(cancel, #selector(close), symbol: nil, tip: nil, size: .large)
        cancel.keyEquivalent = "\u{1b}"
        button(save, #selector(saveDocument), symbol: nil, tip: nil, size: .large)
        save.keyEquivalent = "\r"

        button(play, #selector(togglePlay), symbol: "play.fill", tip: "Play or pause (Space)", size: .large)
        play.keyEquivalent = " "
        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        button(importAudio, #selector(pickAudioFile), symbol: "music.note", tip: "Add an audio file on a new row, from where the playhead is", size: .regular)
        button(narrate, #selector(toggleNarration), symbol: "mic", tip: "Record the microphone on a new row, from where the playhead is", size: .regular)

        func row(leading: [NSView], trailing: [NSView]) -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            stack.setViews(leading, in: .leading)
            stack.setViews(trailing, in: .trailing)
            return stack
        }
        let bar = row(leading: [cropButton, cropShape, cropSize, cropReset], trailing: [formats, spinner, cancel, save])
        let transport = row(leading: [play, timeLabel], trailing: [importAudio, narrate])
        let stage = VideoStage(player: player, overlay: overlay)

        // The bars keep their height and the stage takes the rest.
        let content = NSView(frame: CGRect(origin: .zero, size: contentSize))
        let column = [bar, stage, transport, timelineView]
        for view in column {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor).isActive = true
        }
        let timelineHeight = timelineView.heightAnchor.constraint(equalToConstant: timelineView.idealHeight)
        self.timelineHeight = timelineHeight
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            stage.topAnchor.constraint(equalTo: bar.bottomAnchor),
            transport.topAnchor.constraint(equalTo: stage.bottomAnchor),
            transport.heightAnchor.constraint(equalToConstant: Self.transportHeight),
            timelineView.topAnchor.constraint(equalTo: transport.bottomAnchor),
            timelineView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            timelineHeight,
        ])
        overlay.onChange = { [weak self] in self?.showCropSize() }

        timelineView.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        timelineView.onTrim = { [weak self] range, edge in
            guard let self else { return }
            let seconds = { CMTime(seconds: $0, preferredTimescale: 600) }
            trimmedRange = CMTimeRange(
                start: range.lowerBound == 0 ? .zero : seconds(range.lowerBound),
                end: range.upperBound == duration.seconds ? duration : seconds(range.upperBound))
            seek(to: edge)
        }
        timelineView.onClipsEdited = { [weak self] edited in
            guard let self else { return }
            Task { await self.useClips(edited) }
        }
        timelineView.onVolume = { [weak self] id, volume in
            guard let self else { return }
            guard let id else { originalVolume = volume; return }
            if let index = clips.firstIndex(where: { $0.id == id }) { clips[index].volume = volume }
            applyMix()
        }
        timelineView.onRemove = { [weak self] id in self?.removeClip(id) }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerMoved(to: time) }
        }

        window.title = "cheapshot"
        window.subtitle = "\(Int(natural.width)) × \(Int(natural.height)) px"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self
        window.contentMinSize = minimumContentSize
        window.center()
        showCropSize()
        showTime()
        refreshControls()
        loading = Task { [weak self] in
            await self?.loadThumbnails()
            if hasOriginalAudio { await self?.loadPeaks(of: recording) }
        }
    }

    func present() {
        // A Dock icon and a Cmd-Tab entry while the editor is open, so the window cannot get lost.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private var format: VideoFormat { VideoFormat.allCases[max(formats.indexOfSelectedItem, 0)] }

    private var minimumContentSize: CGSize {
        CGSize(width: Self.minWidth, height: Self.barHeight + Self.minStageHeight + Self.transportHeight + timelineView.idealHeight)
    }

    private func refreshControls() {
        let isNarrating = narration != nil
        let busy = isSaving || isNarrating || isLoadingAudio
        // Each of these takes over the file, or the player, for as long as it lasts.
        for control in [formats, cancel, save] as [NSControl] { control.isEnabled = !busy && !isCropping }
        cropButton.isEnabled = !busy
        play.isEnabled = !busy
        importAudio.isEnabled = !busy && clips.count < TimelineView.maxClips
        narrate.isEnabled = isNarrating || (!busy && clips.count < TimelineView.maxClips)
        narrate.title = isNarrating ? "Stop" : "Record Voice-over"
        narrate.contentTintColor = isNarrating ? .systemRed : nil
        timelineView.isEnabled = !busy
        timelineView.audioEnabled = format != .gif

        // The crop's tools only show while they do something.
        cropShape.isHidden = !isCropping
        cropReset.isHidden = !isCropping
        cropSize.isHidden = !isCropping && overlay.crop == nil
        if isSaving { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: Playing

    @objc private func togglePlay() {
        if player.rate != 0 { return player.pause() }
        // From the end, or from a part the trim threw away, it starts over.
        let time = player.currentTime()
        if time >= trimmedRange.end || time < trimmedRange.start {
            player.seek(to: trimmedRange.start, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    private func seek(to seconds: Double) {
        timelineView.time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        showTime()
    }

    private func playerMoved(to time: CMTime) {
        if time.isNumeric { timelineView.time = time.seconds }
        play.image = NSImage(systemSymbolName: player.rate != 0 ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        showTime()
    }

    private func showTime() {
        var text = "\(timeText(timelineView.time)) / \(timeText(duration.seconds))"
        if trimmedRange.duration != duration { text += ", keeps \(timeText(trimmedRange.duration.seconds))" }
        timeLabel.stringValue = text
    }

    // MARK: Crop

    @objc private func toggleCrop() {
        isCropping.toggle()
        overlay.isEditing = isCropping
        cropButton.title = isCropping ? "Done" : "Crop"
        cropButton.keyEquivalent = isCropping ? "\r" : ""
    }

    @objc private func cropShapeChanged() {
        let ratio = Self.cropShapes[max(cropShape.indexOfSelectedItem, 0)].ratio
        overlay.ratio = ratio
        // A new shape starts as the biggest one that fits, in the middle of the picture.
        if let ratio {
            overlay.crop = evenPixelRect(aspectFit(CGSize(width: ratio, height: 1), in: CGRect(origin: .zero, size: videoSize)))
        }
    }

    @objc private func resetCrop() {
        overlay.crop = nil
        overlay.ratio = nil
        cropShape.selectItem(at: 0)
    }

    private func showCropSize() {
        let size = overlay.crop?.size ?? videoSize
        cropSize.stringValue = "\(Int(size.width)) × \(Int(size.height)) px"
        cropSize.isHidden = !isCropping && overlay.crop == nil
    }

    // MARK: Audio

    private func applyMix() {
        player.currentItem?.audioMix = timeline.audioMix(volume: originalVolume, clips: clips)
    }

    /// Grows or shrinks the window with the timeline, so a new row does not take room from the video.
    private func fitTimeline() {
        guard let timelineHeight, timelineHeight.constant != timelineView.idealHeight else { return }
        let change = timelineView.idealHeight - timelineHeight.constant
        timelineHeight.constant = timelineView.idealHeight
        window.contentMinSize = minimumContentSize
        var frame = window.frame
        frame.origin.y -= change
        frame.size.height += change
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
    }

    private func loadThumbnails() async {
        let generator = AVAssetImageGenerator(asset: recordingAsset)
        generator.maximumSize = CGSize(width: 0, height: 96)
        // Without a limit it hands back the nearest keyframe, which can be a whole scene away.
        let tolerance = CMTime(seconds: duration.seconds / Double(TimelineView.thumbnailCount) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<TimelineView.thumbnailCount).map {
            CMTime(seconds: duration.seconds * (Double($0) + 0.5) / Double(TimelineView.thumbnailCount), preferredTimescale: 600)
        }
        var pictures: [NSImage] = []
        for await frame in generator.images(for: times) {
            if let image = try? frame.image { pictures.append(NSImage(cgImage: image, size: .zero)) }
        }
        timelineView.thumbnails = pictures
    }

    /// Reads the waveform of `file` for its row. A row just stays empty when that fails.
    func loadPeaks(of file: URL) async {
        timelineView.peaks[file] = (try? await audioPeaks(of: file)) ?? []
    }

    @objc private func pickAudioFile() {
        player.pause()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "The audio starts where the playhead is now"
        NSApp.activate()
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task { await addClip(file: file, start: player.currentTime()) }
    }

    private func removeClip(_ id: UUID) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        player.pause()
        // A narration exists nowhere else, and a music file can just be imported again.
        if clip.isNarration {
            let alert = NSAlert()
            alert.messageText = "Delete this voice-over?"
            alert.informativeText = "This take cannot be brought back."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Keep")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await useClips(clips.filter { $0.id != id }) }
    }

    private func addClip(file: URL, start: CMTime, isNarration: Bool = false) async {
        audioLoads += 1
        defer { audioLoads -= 1 }
        do {
            await useClips(clips + [try await AudioClip(file: file, start: start, isNarration: isNarration)])
        } catch {
            if isNarration { try? FileManager.default.removeItem(at: file) }
            showFailure("The audio could not be added", error)
        }
    }

    /// Puts `new` on the timeline and has the player switch to it, at the same place and with the
    /// same trim. On a failure, the clips stay as they were.
    func useClips(_ new: [AudioClip]) async {
        audioLoads += 1
        defer { audioLoads -= 1 }
        clipBuild += 1
        let build = clipBuild
        do {
            let newTimeline = try await VideoTimeline(recording: recordingAsset, clips: new)
            guard build == clipBuild else { return }
            let time = player.currentTime()
            let item = AVPlayerItem(asset: newTimeline.composition)
            item.forwardPlaybackEndTime = trimmedRange.end
            timeline = newTimeline
            clips = new
            player.replaceCurrentItem(with: item)
            applyMix()
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } catch {
            for clip in new where clip.isNarration && !clips.contains(where: { $0.file == clip.file }) {
                try? FileManager.default.removeItem(at: clip.file)
            }
            timelineView.clips = clips
            showFailure("The audio could not be added", error)
        }
    }

    /// Plays the video silently and records the microphone over it, until Stop or the end of the video.
    @objc private func toggleNarration() {
        if narration != nil { return stopNarration() }
        Task {
            guard await AppDelegate.hasMicrophoneAccess() else { return }
            do {
                try await startNarration()
            } catch {
                showFailure("The narration could not start", error)
            }
        }
    }

    private func startNarration() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-narration-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(url: file, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        guard recorder.prepareToRecord() else { throw VideoEditorError.cannotRecordMicrophone }
        // From the end there is nothing left to narrate over, so it starts over.
        if player.currentTime() >= trimmedRange.end {
            await player.seek(to: trimmedRange.start, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // The speakers would end up in the microphone.
        player.isMuted = true
        narrationStart = player.currentTime()
        guard recorder.record() else {
            player.isMuted = false
            throw VideoEditorError.cannotRecordMicrophone
        }
        // The timeline stops taking the mouse, because moving the video would leave the voice out of step with it.
        player.play()
        narration = recorder
        narrationEnd = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification) {
                self?.stopNarration()
                return
            }
        }
    }

    private func stopNarration() {
        guard let recorder = narration else { return }
        narrationEnd?.cancel()
        recorder.stop()
        player.pause()
        player.isMuted = false
        // Counted before the narration ends, so nothing can be saved without it.
        audioLoads += 1
        narration = nil
        Task {
            await addClip(file: recorder.url, start: narrationStart, isNarration: true)
            audioLoads -= 1
        }
    }

    // MARK: Saving

    @objc private func formatChanged() { refreshControls() }

    @objc private func close() { window.performClose(nil) }

    /// The Save button, ⌘S and Return. Asks where to save, and keeps the editor open on a cancel.
    @objc func saveDocument(_ sender: Any?) {
        guard !isSaving, !isCropping, !isLoadingAudio, narration == nil else { return }
        player.pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = Output.fileName(format.contentType.preferredFilenameExtension ?? "mp4")
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await write(to: destination)
                window.close()
            } catch {
                // The recording is still in place, so another try can succeed.
                showFailure("The video could not be saved", error)
            }
        }
    }

    private func showFailure(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window) { _ in }
    }

    /// Writes the result to `destination`, replacing what is there, and uses up the recording.
    func write(to destination: URL) async throws {
        let edit = VideoEdit(range: trimmedRange, volume: originalVolume, format: format, crop: overlay.crop, clips: clips)
        let firstFrame = try? await timeline.imageGenerator(crop: edit.crop).image(at: edit.range.start).image

        let manager = FileManager.default
        if edit.range == CMTimeRange(start: .zero, duration: duration), edit.volume == 1, edit.format == originalFormat,
           edit.crop == nil, edit.clips.isEmpty {
            // The panel already asked about replacing an existing file.
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: recording, to: destination)
        } else {
            // Written aside first, so a failure leaves any file already at the destination alone.
            let temporary = manager.temporaryDirectory.appendingPathComponent("cheapshot-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: temporary) }
            try await exportVideo(from: recording, to: temporary, edit: edit)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: temporary, to: destination)
            try? manager.removeItem(at: recording)
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([destination as NSURL])
        if let firstFrame {
            Thumbnail.show(Shot(image: firstFrame, scale: 1)) { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        }
    }

    /// Cancel, the close button and quitting all come through here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isSaving, !isLoadingAudio else { return false }
        // The first try only ends the narration, which still has to reach the timeline.
        if narration != nil {
            stopNarration()
            return false
        }
        player.pause()
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "It has not been saved anywhere yet."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertFirstButtonReturn {
            if isCropping { toggleCrop() }
            saveDocument(nil)
            return false
        }
        try? FileManager.default.removeItem(at: recording)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
        // Deletes every narration, which only the saved file needed. The window keeps its size on the way out.
        timelineHeight = nil
        clips = []
        VideoEditor.current = nil
        if Editor.current == nil { NSApp.setActivationPolicy(.accessory) }
    }
}
