import AVFoundation

struct VideoSettings: Equatable, Sendable {
    enum Codec: String, Sendable { case hevc, h264 }
    enum Quality: String, Sendable { case low, medium, high }

    var codec: Codec = .hevc
    var framesPerSecond = 30
    var quality: Quality = .medium
    /// True records every pixel of a Retina screen. False records one pixel per point, which is
    /// a quarter of the pixels and the single biggest cut in file size.
    var nativeResolution = false

    /// The average bitrate to aim for, in bits per second.
    func bitrate(width: Int, height: Int) -> Int {
        // Bits per pixel per frame. Screen content is mostly flat, so these sit far below camera video.
        let perPixel: Double = switch quality {
        case .low: 0.03
        case .medium: 0.06
        case .high: 0.12
        }
        // H.264 needs more bits than HEVC for the same picture.
        let codecCost = codec == .hevc ? 1.0 : 1.6
        return max(Int(Double(width * height * framesPerSecond) * perPixel * codecCost), 200_000)
    }
}

enum RecordingError: LocalizedError {
    case cannotConfigure
    case noFrames
    case cannotFinish

    var errorDescription: String? {
        switch self {
        case .cannotConfigure: "The video file could not be set up."
        case .noFrames: "The recording stopped before any frame arrived."
        case .cannotFinish: "The video file could not be finished."
        }
    }
}

/// Writes video frames to an MP4 file. It is not thread-safe: call it from one serial queue.
final class VideoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private var lastTime = CMTime.invalid
    private(set) var frameCount = 0

    /// `width` and `height` are in pixels and must be even, which both codecs require.
    init(url: URL, width: Int, height: Int, settings: VideoSettings) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.bitrate(width: width, height: height),
                AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
                // A keyframe at least every 2 seconds keeps seeking quick.
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecordingError.cannotConfigure }
        writer.add(video)
    }

    /// Appends a frame. The first one starts the file's timeline at its timestamp.
    func append(_ frame: CMSampleBuffer) {
        let time = frame.presentationTimeStamp
        if writer.status == .unknown {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
        }
        // A busy encoder drops the frame. The next one covers for it.
        guard writer.status == .writing, video.isReadyForMoreMediaData, video.append(frame) else { return }
        frameCount += 1
        lastTime = time
    }

    /// Holds the last frame on screen until `time`. For the moments when nothing on screen changed.
    func extend(to time: CMTime) {
        if frameCount > 0, time > lastTime { lastTime = time }
    }

    func finish(_ completion: @escaping @Sendable (Error?) -> Void) {
        guard frameCount > 0 else {
            writer.cancelWriting()
            return completion(RecordingError.noFrames)
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: lastTime)
        writer.finishWriting { [self] in
            completion(writer.status == .completed ? nil : writer.error ?? RecordingError.cannotFinish)
        }
    }
}
