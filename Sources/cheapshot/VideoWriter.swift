import Accelerate
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
    /// What the Mac is playing. cheapshot's own sounds are left out.
    var systemAudio = false
    var microphone = false
    /// Multipliers applied to each source before encoding. 1 leaves the level as captured.
    var systemGain: Float = 1
    var microphoneGain: Float = 1

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

enum AudioSource: Sendable { case system, microphone }

/// Writes video frames and audio to an MP4 file. It is not thread-safe: call it from one serial queue.
final class VideoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    /// One track per source that is switched on. `mixAudioTracks` merges them after the recording.
    private var audio: [AudioSource: AVAssetWriterInput] = [:]
    private let gains: [AudioSource: Float]
    private var levels: [AudioSource: AudioLevels] = [:]
    /// One line per track, filled in by `finish`. It says what each source delivered and whether
    /// its gain was applied, which is the first thing to look at when the audio sounds wrong.
    private(set) var summary: [String] = []
    private var lastTime = CMTime.invalid
    private(set) var frameCount = 0

    /// `width` and `height` are in pixels and must be even, which both codecs require.
    init(url: URL, width: Int, height: Int, settings: VideoSettings) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        gains = [.system: settings.systemGain, .microphone: settings.microphoneGain]
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

        // The writer converts whatever sample rate and layout the device delivers.
        var sources: [(AudioSource, channels: Int, bitrate: Int)] = []
        if settings.systemAudio { sources.append((.system, 2, 128_000)) }
        if settings.microphone { sources.append((.microphone, 1, 96_000)) }
        for (source, channels, bitrate) in sources {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecordingError.cannotConfigure }
            writer.add(input)
            audio[source] = input
        }
    }

    /// Appends audio. Anything that arrives before the first video frame is dropped, because the
    /// file's timeline starts with the picture.
    func append(_ samples: CMSampleBuffer, from source: AudioSource) {
        guard writer.status == .writing, let input = audio[source], input.isReadyForMoreMediaData else { return }
        let gain = gains[source] ?? 1
        let output = amplified(samples, by: gain)
        levels[source, default: AudioLevels(format: describe(samples.formatDescription))].add(input: samples, output: output)
        input.append(output)
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
        for input in audio.values { input.markAsFinished() }
        summary = ["video: \(frameCount) frames"] + levels.map { source, level in
            // Peaks go from 0 to 1.
            "audio \(source): \(level.format), \(level.buffers) buffers, gain \(gains[source] ?? 1), "
                + "peak in \(level.peakIn) out \(level.peakOut), amplified \(level.amplified)"
        }
        writer.endSession(atSourceTime: lastTime)
        writer.finishWriting { [self] in
            completion(writer.status == .completed ? nil : writer.error ?? RecordingError.cannotFinish)
        }
    }
}

/// Rewrites the file at `url` so that its audio tracks become one. The video is copied, not
/// re-encoded. A file with one audio track or none is left alone.
///
/// Many players and most upload sites read only the first audio track, so a recording with the
/// system sound and the microphone on separate tracks would lose one of them there.
func mixAudioTracks(of url: URL) async throws {
    let asset = AVURLAsset(url: url)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard audioTracks.count > 1, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }

    let reader = try AVAssetReader(asset: asset)
    // `nil` settings hand over the compressed video samples untouched.
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(videoOutput)
    reader.add(audioOutput)

    let mixedURL = url.deletingLastPathComponent().appendingPathComponent("mixed-" + url.lastPathComponent)
    let writer = try AVAssetWriter(outputURL: mixedURL, fileType: .mp4)
    let videoInput = AVAssetWriterInput(
        mediaType: .video, outputSettings: nil, sourceFormatHint: try await videoTrack.load(.formatDescriptions).first)
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 160_000,
    ])
    writer.add(videoInput)
    writer.add(audioInput)

    guard reader.startReading(), writer.startWriting() else {
        throw reader.error ?? writer.error ?? RecordingError.cannotFinish
    }
    writer.startSession(atSourceTime: .zero)

    // Each pump moves one track on its own queue. AVFoundation objects are not Sendable, but
    // each pair is only ever touched from its pump.
    let pumps: [Pump] = [Pump(videoOutput, videoInput), Pump(audioOutput, audioInput)]
    await withTaskGroup(of: Void.self) { group in
        for pump in pumps { group.addTask { await pump.run() } }
    }
    await writer.finishWriting()
    guard reader.status == .completed, writer.status == .completed else {
        try? FileManager.default.removeItem(at: mixedURL)
        throw reader.error ?? writer.error ?? RecordingError.cannotFinish
    }
    _ = try FileManager.default.replaceItemAt(url, withItemAt: mixedURL)
}

/// Copies every sample from a reader output to a writer input.
private final class Pump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "cheapshot.mixdown")

    init(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    func run() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }
}

/// A copy of `samples` with every value multiplied by `gain`. Returns the input itself at a gain
/// of 1, or when the audio is neither 32-bit float nor 16-bit integer PCM. ScreenCaptureKit
/// delivers the system sound as float, and a microphone as whatever the device produces, which
/// is often 16-bit integers.
// NOTE: values past full scale are clipped flat. A limiter would sound better on heavy boosts.
func amplified(_ samples: CMSampleBuffer, by gain: Float) -> CMSampleBuffer {
    guard gain != 1, let description = samples.formatDescription, let buffer = pcmCopy(of: samples) else { return samples }

    // One buffer per channel, or one buffer with the channels interleaved. Either way a run of numbers.
    for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        guard let data = channel.mData else { continue }
        var factor = gain
        if buffer.format.commonFormat == .pcmFormatFloat32 {
            let values = data.assumingMemoryBound(to: Float.self)
            let count = vDSP_Length(Int(channel.mDataByteSize) / MemoryLayout<Float>.size)
            var low: Float = -1
            var high: Float = 1
            vDSP_vsmul(values, 1, &factor, values, 1, count)
            vDSP_vclip(values, 1, &low, &high, values, 1, count)
        } else {
            let values = data.assumingMemoryBound(to: Int16.self)
            let count = vDSP_Length(Int(channel.mDataByteSize) / MemoryLayout<Int16>.size)
            var scaled = [Float](repeating: 0, count: Int(count))
            var low = Float(Int16.min)
            var high = Float(Int16.max)
            vDSP_vflt16(values, 1, &scaled, 1, count)
            vDSP_vsmul(scaled, 1, &factor, &scaled, 1, count)
            vDSP_vclip(scaled, 1, &low, &high, &scaled, 1, count)
            vDSP_vfix16(scaled, 1, values, 1, count)
        }
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
        presentationTimeStamp: samples.presentationTimeStamp, decodeTimeStamp: .invalid)
    var created: CMSampleBuffer?
    CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: description, sampleCount: samples.numSamples, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &created)
    guard let created,
          CMSampleBufferSetDataBufferFromAudioBufferList(
              created, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: buffer.audioBufferList) == noErr
    else { return samples }
    return created
}

/// The samples of a float or 16-bit integer PCM buffer, copied out so they can be read or
/// changed. Nil for any other format.
private func pcmCopy(of samples: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let description = samples.formatDescription else { return nil }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    let frames = samples.numSamples
    guard [.pcmFormatFloat32, .pcmFormatInt16].contains(format.commonFormat), frames > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(samples, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr
    else { return nil }
    return buffer
}

/// The loudest value in a PCM buffer, from 0 to 1 whatever the sample type. Nil when the format
/// cannot be read.
func peak(of samples: CMSampleBuffer) -> Float? {
    guard let buffer = pcmCopy(of: samples) else { return nil }
    var loudest: Float = 0
    for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        guard let data = channel.mData else { continue }
        var channelPeak: Float = 0
        if buffer.format.commonFormat == .pcmFormatFloat32 {
            vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &channelPeak, vDSP_Length(Int(channel.mDataByteSize) / MemoryLayout<Float>.size))
        } else {
            let count = vDSP_Length(Int(channel.mDataByteSize) / MemoryLayout<Int16>.size)
            var floats = [Float](repeating: 0, count: Int(count))
            vDSP_vflt16(data.assumingMemoryBound(to: Int16.self), 1, &floats, 1, count)
            vDSP_maxmgv(floats, 1, &channelPeak, count)
            channelPeak /= -Float(Int16.min)
        }
        loudest = max(loudest, channelPeak)
    }
    return loudest
}

/// "lpcm 48000 Hz 2 ch 32 bit flags 41", enough to tell what a device delivered.
private func describe(_ description: CMFormatDescription?) -> String {
    guard let description, let stream = description.audioStreamBasicDescription else { return "unknown format" }
    let id = stream.mFormatID
    let code = String(bytes: [24, 16, 8, 0].map { UInt8((id >> $0) & 0xff) }, encoding: .ascii) ?? "\(id)"
    return "\(code) \(Int(stream.mSampleRate)) Hz \(stream.mChannelsPerFrame) ch \(stream.mBitsPerChannel) bit flags \(stream.mFormatFlags)"
}

private struct AudioLevels {
    let format: String
    var buffers = 0
    var peakIn: Float = 0
    var peakOut: Float = 0
    /// True once a buffer came back from `amplified` as a new one.
    var amplified = false

    mutating func add(input: CMSampleBuffer, output: CMSampleBuffer) {
        buffers += 1
        peakIn = max(peakIn, peak(of: input) ?? 0)
        peakOut = max(peakOut, peak(of: output) ?? 0)
        if input !== output { amplified = true }
    }
}

/// Appends lines to ~/Library/Logs/cheapshot.log. The unified system log is not always readable,
/// and a plain file is easy to send along with a bug report.
enum RecordingLog {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/cheapshot.log")

    static func write(_ lines: [String]) {
        let stamp = Date.now.formatted(.iso8601)
        let text = Data(lines.map { "\(stamp) \($0)\n" }.joined().utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: text)
        } else {
            try? text.write(to: url)
        }
    }
}
