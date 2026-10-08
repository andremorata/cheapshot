import AppKit
import UniformTypeIdentifiers

@MainActor
enum Output {
    static func copy(_ shot: Shot) {
        let rep = bitmap(shot)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // PNG for modern apps, TIFF for the ones that only read the classic image type.
        pasteboard.setData(rep.representation(using: .png, properties: [:]), forType: .png)
        pasteboard.setData(rep.tiffRepresentation, forType: .tiff)
    }

    /// Asks where to save. The file extension picks the format, PNG or JPEG.
    static func save(_ shot: Shot) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        panel.nameFieldStringValue = "cheapshot \(stamp).png"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let isJPEG = UTType(filenameExtension: url.pathExtension)?.conforms(to: .jpeg) ?? false
        // NOTE: JPEG quality is fixed at 0.9 until there is a preferences screen.
        let data = isJPEG
            ? bitmap(shot).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            : bitmap(shot).representation(using: .png, properties: [:])
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    private static func bitmap(_ shot: Shot) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: shot.image)
        // Point size below pixel size records the DPI, so a Retina capture pastes at its on-screen size.
        rep.size = NSSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        return rep
    }
}
