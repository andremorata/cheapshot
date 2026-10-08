import CoreGraphics
import Vision

enum TextRecognizer {
    /// The text Vision finds in `image`, one line per recognized line, top to bottom.
    /// Empty when it finds nothing. Runs on the device.
    static func read(_ image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        return try await request.perform(on: image)
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
