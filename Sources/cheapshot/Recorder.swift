import AVFoundation
import ScreenCaptureKit

/// One screen recording, from the first frame to the finished file.
@MainActor
final class Recorder {
    /// Runs when the system ends the stream by itself, for example when the recorded window closes.
    var onInterrupted: (@MainActor () -> Void)?

    private let stream: SCStream
    private let sink: Sink
    private let url: URL

    static func start(_ target: Capture.Target, settings: VideoSettings) async throws -> Recorder {
        let source = try await Capture.source(for: target)
        let scale = settings.nativeResolution ? CGFloat(source.filter.pointPixelScale) : 1
        let width = evenPixels(source.size.width * scale)
        let height = evenPixels(source.size.height * scale)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let region = source.region { config.sourceRect = region }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.framesPerSecond))
        // The encoder's native format, so no conversion sits between capture and compression.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = settings.systemAudio
        // Keeps the shutter and other cheapshot sounds out of the recording.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = settings.microphone

        // Recorded to a temporary file first. The user picks the real destination when it stops.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cheapshot-\(UUID().uuidString).mp4")
        let sink = Sink(writer: try VideoWriter(url: url, width: width, height: height, settings: settings))
        let stream = SCStream(filter: source.filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        if settings.systemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
        if settings.microphone { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue) }
        let recorder = Recorder(stream: stream, sink: sink, url: url)
        sink.onStop = { [weak recorder] in
            Task { @MainActor in recorder?.onInterrupted?() }
        }
        try await stream.startCapture()
        return recorder
    }

    private init(stream: SCStream, sink: Sink, url: URL) {
        self.stream = stream
        self.sink = sink
        self.url = url
    }

    /// Stops and returns the temporary file. The caller moves or deletes it.
    func stop() async throws -> URL {
        // Throws when the system already stopped the stream. The file is finished either way.
        try? await stream.stopCapture()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.queue.async { [sink] in
                    sink.writer.finish { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            RecordingLog.write(sink.writer.summary)
            try await mixAudioTracks(of: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }
}

/// Receives frames on its own queue and hands them to the writer.
private final class Sink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "cheapshot.recording")
    let writer: VideoWriter
    var onStop: (@Sendable () -> Void)?

    init(writer: VideoWriter) {
        self.writer = writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio: return writer.append(sampleBuffer, from: .system)
        case .microphone: return writer.append(sampleBuffer, from: .microphone)
        case .screen: break
        @unknown default: return
        }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init)
        else { return }
        switch status {
        case .complete: writer.append(sampleBuffer)
        // Nothing changed on screen. No picture comes with it, only the time.
        case .idle: writer.extend(to: sampleBuffer.presentationTimeStamp)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?()
    }
}
