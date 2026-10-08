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
