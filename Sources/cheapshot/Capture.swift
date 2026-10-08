import AppKit
import ScreenCaptureKit

/// `scale` is pixels per point, kept so the clipboard and saved files carry the right DPI.
struct Shot {
    let image: CGImage
    let scale: CGFloat
}

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "The display is no longer available."
        case .windowNotFound: "The window is no longer on screen."
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static var underMouse: NSScreen? {
        screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? main
    }
}

@MainActor
enum Capture {
    /// What to capture. A region is in the display's own point space with a top-left origin,
    /// and `nil` means the whole display.
    enum Target: Sendable {
        case display(CGDirectDisplayID, region: CGRect? = nil)
        case window(CGWindowID)
    }

    /// The content filter for `target`, the size of what it shows in points, and for a display
    /// the region to read.
    static func source(for target: Target) async throws -> (filter: SCContentFilter, size: CGSize, region: CGRect?) {
        switch target {
        case .display(let id, let region):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.displayNotFound
            }
            // Leaves our own overlay, thumbnail and windows out of the picture.
            let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            let rect = region ?? CGRect(origin: .zero, size: display.frame.size)
            return (filter, rect.size, rect)
        case .window(let id):
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.windowNotFound
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return (filter, filter.contentRect.size, nil)
        }
    }

    static func shot(_ target: Target) async throws -> Shot {
        let source = try await source(for: target)
        let scale = CGFloat(source.filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(source.size.width * scale)
        config.height = Int(source.size.height * scale)
        if let region = source.region { config.sourceRect = region }
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: source.filter, configuration: config)
        return Shot(image: image, scale: scale)
    }
}
