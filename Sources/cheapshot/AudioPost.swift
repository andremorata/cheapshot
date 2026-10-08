import AudioToolbox
import AVFoundation

/// The microphone audio of a recording after voice isolation, and where it starts in the recording.
struct CleanedMicrophone {
    let file: URL
    let start: CMTime
}

/// Rewrites the file at `url` so that its audio becomes one track. The video is copied, not
/// re-encoded. With `cleaned`, that audio takes the place of the microphone track. A file with
/// one audio track or none, and nothing to swap in, is left alone.
///
/// Many players and most upload sites read only the first audio track, so a recording with the
/// system sound and the microphone on separate tracks would lose one of them there.
func mixAudioTracks(of url: URL, replacingMicrophoneWith cleaned: CleanedMicrophone? = nil) async throws {
    let asset = AVURLAsset(url: url)
    var audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
          audioTracks.count > 1 || (cleaned != nil && !audioTracks.isEmpty)
    else { return }

    // A composition lays the pieces on one timeline: the video, the tracks that stay, and the cleaned microphone.
    let composition = AVMutableComposition()
    func add(_ track: AVAssetTrack, at start: CMTime? = nil) async throws -> AVCompositionTrack {
        let range = try await track.load(.timeRange)
        guard let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.cannotFinish
        }
        try copy.insertTimeRange(range, of: track, at: start ?? range.start)
        return copy
    }
    let video = try await add(videoTrack)
    var audio: [AVCompositionTrack] = []
    // Held for the whole function. A track only points weakly at its asset, and inserting from
    // a track whose asset is gone fails.
    let cleanedAsset = cleaned.map { AVURLAsset(url: $0.file) }
    if let cleaned, let cleanedAsset {
        // The microphone is the last audio track the recorder adds.
        audioTracks.removeLast()
        if let track = try await cleanedAsset.loadTracks(withMediaType: .audio).first {
            audio.append(try await add(track, at: cleaned.start))
        }
    }
    for track in audioTracks { audio.append(try await add(track)) }

    let reader = try AVAssetReader(asset: composition)
    // `nil` settings hand over the compressed video samples untouched.
    let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
    let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
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

/// Runs the microphone track of the recording at `url` through Apple's voice isolation, which
/// keeps speech and drops room noise, hiss and breathing. The result goes to a temporary audio
/// file. Returns nil when there is no audio or the system has no voice isolation.
///
/// It works on the finished recording, not live. On an M-series Mac it runs about a hundred
/// times faster than the audio plays.
func isolateVoice(inMicrophoneTrackOf url: URL) async throws -> CleanedMicrophone? {
    let asset = AVURLAsset(url: url)
    // The microphone is the last audio track the recorder adds.
    guard let track = try await asset.loadTracks(withMediaType: .audio).last else { return nil }
    let start = try await track.load(.timeRange).start
    guard let file = try isolateVoice(in: asset, track: track) else { return nil }
    return CleanedMicrophone(file: file, start: start)
}

// Not async on purpose. In an async function Swift picks the awaiting form of `scheduleBuffer`,
// which waits for playback that only happens when this same code renders.
private func isolateVoice(in asset: AVAsset, track: AVAssetTrack) throws -> URL? {
    let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard !AVAudioUnitComponentManager.shared().components(matching: description).isEmpty,
          let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    else { return nil }

    let reader = try AVAssetReader(asset: asset)
    let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(decoded)
    guard reader.startReading() else { throw reader.error ?? RecordingError.cannotFinish }

    // An offline engine: nothing plays, the audio is pulled through as fast as it can be computed.
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let isolation = AVAudioUnitEffect(audioComponentDescription: description)
    engine.attach(player)
    engine.attach(isolation)
    engine.connect(player, to: isolation, format: format)
    engine.connect(isolation, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    try engine.start()
    player.play()
    defer { engine.stop() }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-voice-\(UUID().uuidString).caf")
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { return nil }

    // The effect answers a little late. Dropping that much from the front keeps the voice in sync.
    let latency = AVAudioFrameCount(isolation.auAudioUnit.latency * format.sampleRate)
    var toDrop = latency
    func pull(_ frames: AVAudioFrameCount) throws {
        var remaining = frames
        while remaining > 0 {
            guard try engine.renderOffline(min(remaining, 4096), to: rendered) == .success, rendered.frameLength > 0 else { return }
            remaining -= rendered.frameLength
            if toDrop >= rendered.frameLength {
                toDrop -= rendered.frameLength
                continue
            }
            if toDrop > 0, let values = rendered.floatChannelData?[0] {
                let kept = rendered.frameLength - toDrop
                values.update(from: values + Int(toDrop), count: Int(kept))
                rendered.frameLength = kept
                toDrop = 0
            }
            try file.write(from: rendered)
        }
    }

    while let sample = decoded.copyNextSampleBuffer() {
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr
        else { continue }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        try pull(frames)
    }
    // What is still inside the effect.
    try pull(latency)
    return url
}
