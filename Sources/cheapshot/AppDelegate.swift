import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var lastShot: Shot?
    private var askedForScreenAccess = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon
        item.menu = makeMenu()
        statusItem = item
        NSApp.mainMenu = makeMainMenu()

        // NOTE: shortcuts are fixed until there is a preferences screen. They mirror the system
        // screenshot keys with Option in place of Command.
        let modifiers = optionKey | shiftKey
        HotKey.register(keyCode: kVK_ANSI_3, modifiers: modifiers) { [weak self] in self?.captureScreen() }
        HotKey.register(keyCode: kVK_ANSI_4, modifiers: modifiers) { [weak self] in self?.captureRegion() }
        HotKey.register(keyCode: kVK_ANSI_5, modifiers: modifiers) { [weak self] in self?.captureWindow() }
        HotKey.register(keyCode: kVK_ANSI_E, modifiers: modifiers) { [weak self] in self?.annotateLastCapture() }
    }

    /// The bundled glyph. `swift run` has no bundle resources, so it falls back to a system symbol.
    private static var menuBarIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else { return NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "cheapshot") }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "cheapshot"
        return image
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", mask: NSEvent.ModifierFlags = [.option, .shift]) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = self
        }
        add("Capture Region", #selector(captureRegion), key: "4")
        add("Capture Window", #selector(captureWindow), key: "5")
        add("Capture Screen", #selector(captureScreen), key: "3")
        menu.addItem(.separator())
        add("Annotate Last Capture", #selector(annotateLastCapture), key: "e")
        add("Save Last Capture…", #selector(saveLastCapture), key: "s", mask: [.command])
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit cheapshot", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        return menu
    }

    /// Invisible while the app is menu-bar-only. It gives the editor window its key equivalents.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String)]) {
            let menu = NSMenu(title: title)
            for (itemTitle, action, key) in items { menu.addItem(withTitle: itemTitle, action: action, keyEquivalent: key) }
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        submenu("cheapshot", [("Quit cheapshot", #selector(NSApplication.terminate), "q")])
        submenu("File", [
            ("Save…", #selector(CanvasView.saveDocument), "s"),
            ("Close", #selector(NSWindow.performClose), "w"),
        ])
        submenu("Edit", [("Copy", #selector(CanvasView.copy(_:)), "c")])
        return main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let needsShot = [#selector(saveLastCapture), #selector(annotateLastCapture)]
        return !needsShot.contains { $0 == menuItem.action } || lastShot != nil
    }

    @objc private func captureRegion() { pickAndCapture(.region) }
    @objc private func captureWindow() { pickAndCapture(.window) }

    @objc private func captureScreen() {
        guard hasScreenAccess() else { return }
        guard let displayID = NSScreen.underMouse?.displayID else { return }
        Task { await deliver { try await Capture.display(displayID) } }
    }

    @objc private func annotateLastCapture() {
        guard let lastShot else { return }
        Editor.open(lastShot)
    }

    @objc private func saveLastCapture() {
        guard let lastShot else { return }
        do { try Output.save(lastShot) } catch { report(error) }
    }

    private func pickAndCapture(_ mode: SelectionOverlay.Mode) {
        guard hasScreenAccess() else { return }
        Task {
            switch await SelectionOverlay.pick(mode) {
            case .region(let displayID, let rect): await deliver { try await Capture.display(displayID, region: rect) }
            case .window(let id): await deliver { try await Capture.window(id) }
            case nil: break
            }
        }
    }

    private func deliver(_ capture: () async throws -> Shot) async {
        do {
            let shot = try await capture()
            lastShot = shot
            Output.copy(shot)
            Self.shutter?.play()
            Thumbnail.show(shot) { Editor.open(shot) }
        } catch {
            report(error)
        }
    }

    private static let shutter = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    /// The first call lets macOS show its own prompt. Later calls explain where to turn the permission on.
    private func hasScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !askedForScreenAccess {
            askedForScreenAccess = true
            return CGRequestScreenCaptureAccess()
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "cheapshot needs Screen Recording permission"
        alert.informativeText = "Turn it on in System Settings, under Privacy & Security, then quit and reopen cheapshot."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func report(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Capture failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
