import AppKit
import UniformTypeIdentifiers

/// What happens to a screenshot after it is taken. It always goes to the clipboard first.
enum CaptureAction: String, CaseIterable, Sendable {
    case copy, edit, ask, folder

    var title: String {
        switch self {
        case .copy: "Show a thumbnail"
        case .edit: "Open the editor"
        case .ask: "Ask where to save"
        case .folder: "Save to a folder"
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> CaptureAction {
        defaults.string(forKey: "capture.action").flatMap(CaptureAction.init) ?? .copy
    }

    static func setCurrent(_ action: CaptureAction, in defaults: UserDefaults = .standard) {
        defaults.set(action.rawValue, forKey: "capture.action")
    }

    /// Where `folder` saves. The Desktop until the user picks somewhere else, like the system screenshots.
    static func folder(in defaults: UserDefaults = .standard) -> URL {
        defaults.string(forKey: "capture.folder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static func setFolder(_ url: URL, in defaults: UserDefaults = .standard) {
        defaults.set(url.path, forKey: "capture.folder")
    }
}

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
        panel.nameFieldStringValue = fileName("png")
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

    /// Writes a PNG into `folder` under a dated name, creating the folder if needed.
    @discardableResult
    static func write(_ shot: Shot, toFolder folder: URL) throws -> URL {
        guard let data = bitmap(shot).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Two captures in the same second get "name 2.png", so the second does not replace the first.
        let name = fileName("png")
        var url = folder.appendingPathComponent(name)
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(name.replacingOccurrences(of: ".png", with: " \(copy).png"))
            copy += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A default name with the date and time, such as "cheapshot 2026-10-08T112033Z.png".
    static func fileName(_ fileExtension: String) -> String {
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        return "cheapshot \(stamp).\(fileExtension)"
    }

    private static func bitmap(_ shot: Shot) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: shot.image)
        // Point size below pixel size records the DPI, so a Retina capture pastes at its on-screen size.
        rep.size = NSSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        return rep
    }
}
