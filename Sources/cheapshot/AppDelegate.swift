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

        // NOTE: shortcuts are fixed until there is a preferences screen. They mirror the system
        // screenshot keys with Option in place of Command.
        let modifiers = optionKey | shiftKey
        HotKey.register(keyCode: kVK_ANSI_3, modifiers: modifiers) { [weak self] in self?.captureScreen() }
        HotKey.register(keyCode: kVK_ANSI_4, modifiers: modifiers) { [weak self] in self?.captureRegion() }
        HotKey.register(keyCode: kVK_ANSI_5, modifiers: modifiers) { [weak self] in self?.captureWindow() }
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
        add("Save Last Capture…", #selector(saveLastCapture), key: "s", mask: [.command])
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit cheapshot", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(saveLastCapture) || lastShot != nil
    }

    @objc private func captureRegion() { pickAndCapture(.region) }
    @objc private func captureWindow() { pickAndCapture(.window) }

    @objc private func captureScreen() {
        guard hasScreenAccess() else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let displayID = screen?.displayID else { return }
        Task { await deliver { try await Capture.display(displayID) } }
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
