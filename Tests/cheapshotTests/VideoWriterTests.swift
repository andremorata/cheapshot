import AVFoundation
import Testing
@testable import cheapshot

/// A solid-color frame in the pixel format the recorder asks ScreenCaptureKit for.
private func frame(width: Int, height: Int, at time: CMTime) throws -> CMSampleBuffer {
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
    let buffer = try #require(pixels)
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: buffer, formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample)
    return try #require(sample)
}

/// Writes a few frames, holds the last one, and checks the file that comes out.
@Test(arguments: [VideoSettings.Codec.hevc, .h264])
func writesAPlayableFile(codec: VideoSettings.Codec) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    var settings = VideoSettings()
    settings.codec = codec
    let writer = try VideoWriter(url: url, width: 320, height: 240, settings: settings)

    // The timeline starts late on purpose. Screen timestamps count from boot, not from zero.
    let start = CMTime(seconds: 1000, preferredTimescale: 600)
    for index in 0..<10 {
        writer.append(try frame(width: 320, height: 240, at: start + CMTime(value: CMTimeValue(index), timescale: 30)))
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(writer.frameCount > 0)
    // Two seconds with nothing new on screen.
    writer.extend(to: start + CMTime(seconds: 2, preferredTimescale: 600))
    let failure: Error? = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    #expect(failure == nil)

    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(size == CGSize(width: 320, height: 240))
    let subtype = try #require(try await track.load(.formatDescriptions).first).mediaSubType
    #expect(subtype == (codec == .hevc ? .hevc : .h264))
    // The held frame counts toward the length.
    let seconds = try await asset.load(.duration).seconds
    #expect(abs(seconds - 2) < 0.1)
}

@Test func finishingWithoutFramesFails() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).mp4")
    let writer = try VideoWriter(url: url, width: 320, height: 240, settings: VideoSettings())
    let failure: Error? = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    #expect(failure is RecordingError)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

/// A sine tone in the format ScreenCaptureKit delivers: 48 kHz float samples, one buffer per channel.
private func tone(_ frequency: Double, channels: UInt32, at time: CMTime, frames: Int = 4800) throws -> CMSampleBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.floatChannelData)
    for channel in 0..<Int(channels) {
        for index in 0..<frames { data[channel][index] = Float(sin(2 * .pi * frequency * Double(index) / 48_000)) * 0.3 }
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var created: CMSampleBuffer?
    CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &created)
    let sample = try #require(created)
    CMSampleBufferSetDataBufferFromAudioBufferList(
        sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: buffer.audioBufferList)
    return sample
}

/// The loudest sample in the file's first audio track, from 0 to 1.
private func peak(of url: URL) async throws -> Float {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    reader.startReading()
    var loudest: Int16 = 0
    while let sample = output.copyNextSampleBuffer(), let block = sample.dataBuffer {
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { continue }
        pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
            for index in 0..<(length / 2) { loudest = max(loudest, abs(samples[index] == .min ? .max : samples[index])) }
        }
    }
    return Float(loudest) / Float(Int16.max)
}

/// Records one second with the system sound and the microphone, then mixes the two into one track.
@Test func recordsBothAudioSourcesAndMixesThemDown() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    var settings = VideoSettings()
    settings.systemAudio = true
    settings.microphone = true
    let writer = try VideoWriter(url: url, width: 320, height: 240, settings: settings)

    let start = CMTime(seconds: 1000, preferredTimescale: 48_000)
    for tenth in 0..<10 {
        let time = start + CMTime(value: CMTimeValue(tenth * 4800), timescale: 48_000)
        writer.append(try frame(width: 320, height: 240, at: time))
        writer.append(try tone(440, channels: 2, at: time), from: .system)
        writer.append(try tone(880, channels: 1, at: time), from: .microphone)
        try await Task.sleep(for: .milliseconds(30))
    }
    writer.extend(to: start + CMTime(seconds: 1, preferredTimescale: 48_000))
    let failure: Error? = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    #expect(failure == nil)
    #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count == 2)

    try await mixAudioTracks(of: url)

    let mixed = AVURLAsset(url: url)
    #expect(try await mixed.loadTracks(withMediaType: .audio).count == 1)
    let video = try #require(try await mixed.loadTracks(withMediaType: .video).first)
    #expect(try #require(try await video.load(.formatDescriptions).first).mediaSubType == .hevc)
    #expect(abs(try await mixed.load(.duration).seconds - 1) < 0.15)
    // Two tones of 0.3 each add up to more than either one alone could reach.
    #expect(try await peak(of: url) > 0.35)
}

@Test func mixdownLeavesASingleTrackAlone() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    var settings = VideoSettings()
    settings.microphone = true
    let writer = try VideoWriter(url: url, width: 320, height: 240, settings: settings)
    let start = CMTime(seconds: 5, preferredTimescale: 48_000)
    for tenth in 0..<5 {
        let time = start + CMTime(value: CMTimeValue(tenth * 4800), timescale: 48_000)
        writer.append(try frame(width: 320, height: 240, at: time))
        writer.append(try tone(880, channels: 1, at: time), from: .microphone)
        try await Task.sleep(for: .milliseconds(30))
    }
    let failure: Error? = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    #expect(failure == nil)
    let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    try await mixAudioTracks(of: url)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == before)
    #expect(try await peak(of: url) > 0.2)
}

/// A sine tone the way many microphones deliver it: 16-bit integers with the two channels interleaved.
private func tone16(_ frequency: Double, at time: CMTime, frames: Int = 4800) throws -> CMSampleBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.int16ChannelData)[0]
    for index in 0..<frames {
        let value = Int16(sin(2 * .pi * frequency * Double(index) / 48_000) * 0.3 * Double(Int16.max))
        data[index * 2] = value
        data[index * 2 + 1] = value
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var created: CMSampleBuffer?
    CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &created)
    let sample = try #require(created)
    CMSampleBufferSetDataBufferFromAudioBufferList(
        sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: buffer.audioBufferList)
    return sample
}

@Test func gainScalesAndClips() throws {
    let time = CMTime(seconds: 3, preferredTimescale: 48_000)
    let quiet = try tone(440, channels: 2, at: time)
    // Unity gain hands back the same buffer, with no copy.
    #expect(amplified(quiet, by: 1) === quiet)
    let doubled = amplified(quiet, by: 2)
    #expect(abs(try #require(peak(of: doubled)) - 0.6) < 0.01)
    // The copy keeps its place in time and its length.
    #expect(doubled.presentationTimeStamp == time && doubled.numSamples == quiet.numSamples)
    #expect(peak(of: amplified(quiet, by: 10)) == 1)
    #expect(peak(of: amplified(quiet, by: 0)) == 0)
}

/// The same checks on 16-bit integer audio, which is what a real microphone delivered here.
@Test func gainWorksOnIntegerAudio() throws {
    let quiet = try tone16(440, at: CMTime(seconds: 3, preferredTimescale: 48_000))
    #expect(abs(try #require(peak(of: quiet)) - 0.3) < 0.01)
    #expect(abs(try #require(peak(of: amplified(quiet, by: 3))) - 0.9) < 0.01)
    // Past full scale it stops at the limit and does not wrap around into noise.
    #expect(try #require(peak(of: amplified(quiet, by: 10))) > 0.999)
    #expect(peak(of: amplified(quiet, by: 0)) == 0)
}

/// The gain reaches the file: a microphone turned all the way down records silence.
@Test func writerAppliesTheSourceGain() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-test-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    var settings = VideoSettings()
    settings.microphone = true
    settings.microphoneGain = 0
    let writer = try VideoWriter(url: url, width: 320, height: 240, settings: settings)
    let start = CMTime(seconds: 5, preferredTimescale: 48_000)
    for tenth in 0..<5 {
        let time = start + CMTime(value: CMTimeValue(tenth * 4800), timescale: 48_000)
        writer.append(try frame(width: 320, height: 240, at: time))
        writer.append(try tone(880, channels: 1, at: time), from: .microphone)
        try await Task.sleep(for: .milliseconds(30))
    }
    let failure: Error? = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    #expect(failure == nil)
    #expect(try await peak(of: url) < 0.01)
    // The summary names the format and shows the gain took effect.
    let line = try #require(writer.summary.first { $0.hasPrefix("audio microphone") })
    #expect(line.contains("lpcm 48000 Hz 1 ch 32 bit") && line.contains("gain 0.0") && line.contains("amplified true"))
    #expect(line.contains("peak in 0.3") && line.contains("out 0.0"))
}
