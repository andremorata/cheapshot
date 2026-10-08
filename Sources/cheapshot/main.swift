import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Info.plist sets LSUIElement for the bundle. This covers `swift run`, which has no bundle.
app.setActivationPolicy(.accessory)
app.run()
