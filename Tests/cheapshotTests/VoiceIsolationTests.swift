import Accelerate
import AVFoundation
import Testing
@testable import cheapshot

private let rate = 48_000

/// Mono float samples as a buffer at `time`, the way the recorder would get them from a microphone.
private func buffer(_ values: ArraySlice<Float>, at time: CMTime) throws -> CMSampleBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
    pcm.frameLength = AVAudioFrameCount(values.count)
    let data = try #require(pcm.floatChannelData)[0]
    for (offset, value) in values.enumerated() { data[offset] = value }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var created: CMSampleBuffer?
    CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format.formatDescription, sampleCount: values.count, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &created)
    let sample = try #require(created)
    CMSampleBufferSetDataBufferFromAudioBufferList(
        sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList)
    return sample
}

private func videoFrame(at time: CMTime) throws -> CMSampleBuffer {
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
    let image = try #require(pixels)
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: image, formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample)
    return try #require(sample)
}

/// The first audio track of a file as mono floats.
private func decode(_ url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    reader.startReading()
    var values: [Float] = []
    while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { continue }
        pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { values += UnsafeBufferPointer(start: $0, count: length / 4) }
    }
    return values
}

private func rms(_ values: ArraySlice<Float>) -> Float {
    var result: Float = 0
    values.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &result, vDSP_Length($0.count)) }
    return result
}

/// Records synthetic speech with hiss under it as the microphone, then cleans it. The hiss in
/// the quiet parts has to all but vanish, and the speech has to survive, still in the same place.
@Test func voiceIsolationRemovesNoiseAndKeepsSpeech() async throws {
    // Speech from the system voice, so the test needs no recording and no audio file in the repo.
    let speechURL = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: speechURL) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", speechURL.path, "--data-format=LEI16@\(rate)", "Testing the recorder. This is a sentence with a voice in it."]
    try say.run()
    say.waitUntilExit()
    let speechFile = try AVAudioFile(forReading: speechURL)
    let speechBuffer = try #require(AVAudioPCMBuffer(pcmFormat: speechFile.processingFormat, frameCapacity: AVAudioFrameCount(speechFile.length)))
    try speechFile.read(into: speechBuffer)
    let speech = Array(UnsafeBufferPointer(start: try #require(speechBuffer.floatChannelData)[0], count: Int(speechBuffer.frameLength)))
    try #require(speech.count > rate)

    // One second of hiss alone, the speech with hiss under it, one more second of hiss alone.
    let quiet = [Float](repeating: 0, count: rate)
    var generator = SystemRandomNumberGenerator()
    let noisy = (quiet + speech.map { $0 * 0.5 } + quiet).map { $0 + Float.random(in: -0.05...0.05, using: &generator) }
    let speechRange = rate..<(rate + speech.count)
    let hissRange = (rate / 10)..<(rate * 8 / 10)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    var settings = VideoSettings()
    settings.microphone = true
    let writer = try VideoWriter(url: url, width: 320, height: 240, settings: settings)
    let start = CMTime(seconds: 50, preferredTimescale: CMTimeScale(rate))
    let chunk = rate / 10
    for offset in stride(from: 0, to: noisy.count - chunk + 1, by: chunk) {
        let time = start + CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(rate))
        writer.append(try videoFrame(at: time))
        writer.append(try buffer(noisy[offset..<(offset + chunk)], at: time), from: .microphone)
        try await Task.sleep(for: .milliseconds(15))
    }
    let failure: Error? = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    #expect(failure == nil)
    let before = try await decode(url)

    let cleaned = try #require(try await isolateVoice(inMicrophoneTrackOf: url))
    defer { try? FileManager.default.removeItem(at: cleaned.file) }
    try await mixAudioTracks(of: url, replacingMicrophoneWith: cleaned)
    let after = try await decode(url)

    #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count == 1)
    #expect(abs(after.count - before.count) < rate / 5)
    let hissBefore = rms(before[hissRange])
    let hissAfter = rms(after[hissRange])
    let speechBefore = rms(before[speechRange])
    let speechAfter = rms(after[speechRange])
    // The hiss drops to under a tenth. The speech keeps at least half of its energy.
    #expect(hissAfter < hissBefore / 10)
    #expect(speechAfter > speechBefore / 2)
    // Still in sync: the second after the speech is quiet, so the voice did not slide later.
    #expect(rms(after[(speechRange.upperBound + rate / 5)..<(speechRange.upperBound + rate * 8 / 10)]) < hissBefore / 5)
}
