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
    /// `region` is in the display's own point space with a top-left origin. `nil` captures the whole display.
    static func display(_ id: CGDirectDisplayID, region: CGRect? = nil) async throws -> Shot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.displayNotFound
        }
        // Leaves our own overlay out of the picture.
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        let rect = region ?? CGRect(origin: .zero, size: display.frame.size)
        let config = configuration(for: filter, size: rect.size)
        config.sourceRect = rect
        return try await shoot(filter, config)
    }

    static func window(_ id: CGWindowID) async throws -> Shot {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await shoot(filter, configuration(for: filter, size: filter.contentRect.size))
    }

    private static func configuration(for filter: SCContentFilter, size: CGSize) -> SCStreamConfiguration {
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(size.width * scale)
        config.height = Int(size.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    private static func shoot(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws -> Shot {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Shot(image: image, scale: CGFloat(filter.pointPixelScale))
    }
}
