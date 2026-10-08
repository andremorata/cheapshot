// Renders an SVG to a transparent square PNG through WebKit. NSImage and sips drop SVG filters,
// so the soft shadows in AppIcon.svg only survive a WebKit render.
// usage: swift Support/render-icon.swift <in.svg> <out.png> <pixels>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4, let pixels = Int(args[3]), let svg = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <in.svg> <out.png> <pixels>\n".utf8))
    exit(2)
}

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    let output: URL
    let pixels: Int

    init(svg: String, output: URL, pixels: Int) {
        self.output = output
        self.pixels = pixels
        let frame = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        webView = WKWebView(frame: frame)
        webView.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        let sized = svg.replacingOccurrences(of: "<svg ", with: "<svg style=\"display:block;width:\(pixels)px;height:\(pixels)px\" ")
        webView.loadHTMLString("<body style=\"margin:0;background:transparent\">\(sized)</body>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        webView.takeSnapshot(with: config) { [self] image, error in
            guard let image else {
                FileHandle.standardError.write(Data("snapshot failed: \(String(describing: error))\n".utf8))
                exit(1)
            }
            // The snapshot comes at the screen's backing scale. Redraw into an exact pixel grid.
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: pixels, height: pixels)
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.current?.flushGraphics()
            do {
                try rep.representation(using: .png, properties: [:])!.write(to: output)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(svg: svg, output: URL(fileURLWithPath: args[2]), pixels: pixels)
app.run()
