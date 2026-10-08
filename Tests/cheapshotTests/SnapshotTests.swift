import AppKit
import Testing
@testable import cheapshot

/// Not a pass/fail test. With CHEAPSHOT_SNAPSHOTS set to a folder, it draws the windows into PNG
/// files there, so the interface can be reviewed without screen recording. Run `make snapshots`.
private let snapshotFolder = ProcessInfo.processInfo.environment["CHEAPSHOT_SNAPSHOTS"]

@MainActor
@Test(.enabled(if: snapshotFolder != nil))
func snapshotWindows() throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: try #require(snapshotFolder))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let editor = Editor(shot: try sampleShot())
        editor.window.appearance = NSAppearance(named: appearance)
        let ink = RGBA.defaultInk
        editor.canvas.document = Document(
            annotations: [
                Annotation(kind: .arrow, start: CGPoint(x: 80, y: 90), end: CGPoint(x: 230, y: 200), color: ink, lineWidth: 4),
                Annotation(kind: .rectangle, start: CGPoint(x: 300, y: 250), end: CGPoint(x: 520, y: 330), color: ink, lineWidth: 4),
                Annotation(kind: .ellipse, start: CGPoint(x: 60, y: 250), end: CGPoint(x: 200, y: 340), color: ink, lineWidth: 4, fillOpacity: 0.35),
                Annotation(kind: .line, start: CGPoint(x: 250, y: 370), end: CGPoint(x: 560, y: 370), color: ink, lineWidth: 24),
                Annotation(
                    kind: .freehand, start: CGPoint(x: 60, y: 60), end: CGPoint(x: 290, y: 70), color: ink, lineWidth: 5,
                    points: stride(from: 0.0, through: 230.0, by: 10).map { CGPoint(x: 60 + $0, y: 60 + 22 * sin($0 / 18)) }),
                Annotation(kind: .blur, start: CGPoint(x: 40, y: 150), end: CGPoint(x: 260, y: 215), color: ink, lineWidth: 4),
                Annotation(kind: .pixelate, start: CGPoint(x: 330, y: 150), end: CGPoint(x: 560, y: 215), color: ink, lineWidth: 4),
                Annotation(kind: .redact, start: CGPoint(x: 330, y: 60), end: CGPoint(x: 560, y: 100), color: .black, lineWidth: 4),
            ],
            crop: nil)
        editor.canvas.selected = 1
        try write(editor.window, to: folder.appendingPathComponent("editor-\(name).png"))

        editor.canvas.selected = 4
        try write(editor.window, to: folder.appendingPathComponent("editor-brush-\(name).png"))

        editor.canvas.selected = nil
        editor.canvas.document.crop = CGRect(x: 40, y: 40, width: 420, height: 300)
        try write(editor.window, to: folder.appendingPathComponent("editor-crop-\(name).png"))

        let text = TextWindow(text: "Captura rápida não custa nada\ncheapshot 2026, invoice #4821")
        text.window.appearance = NSAppearance(named: appearance)
        try write(text.window, to: folder.appendingPathComponent("text-\(name).png"))

        var recordOptions = RecordOptions()
        recordOptions.microphoneVolume = 2.5
        let record = RecordPanel(options: recordOptions, onStart: { _ in })
        record.window.appearance = NSAppearance(named: appearance)
        try write(record.window, to: folder.appendingPathComponent("record-\(name).png"))

        let settings = SettingsWindow(setHotKeysEnabled: { _ in })
        settings.window.appearance = NSAppearance(named: appearance)
        for (index, tab) in ["general", "shortcuts", "recording"].enumerated() {
            settings.tabs.selectTabViewItem(at: index)
            try write(settings.window, to: folder.appendingPathComponent("settings-\(tab)-\(name).png"))
        }
    }
}

/// Draws the whole window frame, title bar included, into a PNG.
@MainActor
private func write(_ window: NSWindow, to url: URL) throws {
    let frame = try #require(window.contentView?.superview)
    frame.layoutSubtreeIfNeeded()
    frame.displayIfNeeded()
    let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
    frame.cacheDisplay(in: frame.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
}

/// A 600x400 pt capture at 2x that looks a little like a document: a page with gray text lines.
private func sampleShot() throws -> Shot {
    let context = try #require(CGContext(
        data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 720, width: 1200, height: 80))
    context.setFillColor(CGColor(gray: 0.25, alpha: 1))
    for row in 0..<14 {
        let width = [900, 1040, 760, 980, 620][row % 5]
        context.fill(CGRect(x: 80, y: 640 - row * 44, width: width, height: 18))
    }
    return Shot(image: try #require(context.makeImage()), scale: 2)
}
