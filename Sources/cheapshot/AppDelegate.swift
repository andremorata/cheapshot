import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var lastShot: Shot?
    private var askedForScreenAccess = false
    private var hotKeyTokens: [UInt32] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon
        statusItem = item
        NSApp.mainMenu = makeMainMenu()

        setHotKeysEnabled(true)
    }

    /// Registers every hotkey from the saved shortcuts, or drops them all. The menu is rebuilt
    /// either way, so its shortcut hints follow the settings.
    private func setHotKeysEnabled(_ enabled: Bool) {
        hotKeyTokens.forEach(HotKey.unregister)
        hotKeyTokens = []
        if enabled {
            for action in HotKeyAction.allCases {
                let shortcut = Shortcut.current(for: action)
                let token = HotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                    self?.perform(action)
                }
                if let token { hotKeyTokens.append(token) }
            }
        }
        statusItem?.menu = makeMenu()
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .region: pickAndCapture(.region)
        case .window: pickAndCapture(.window)
        case .screen: captureScreen()
        case .text: captureText()
        case .annotate: annotateLastCapture()
        }
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
        func add(_ action: HotKeyAction) {
            let shortcut = Shortcut.current(for: action)
            let item = menu.addItem(withTitle: action.title, action: #selector(hotKeyItemPicked), keyEquivalent: shortcut.menuKeyEquivalent)
            item.keyEquivalentModifierMask = shortcut.cocoaModifiers
            item.representedObject = action.rawValue
            item.target = self
        }
        add(.region)
        add(.window)
        add(.screen)
        add(.text)
        menu.addItem(.separator())
        add(.annotate)
        menu.addItem(withTitle: "Save Last Capture…", action: #selector(saveLastCapture), keyEquivalent: "s").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
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
        submenu("cheapshot", [
            ("Settings…", #selector(showSettings), ","),
            ("Quit cheapshot", #selector(NSApplication.terminate), "q"),
        ])
        submenu("File", [
            ("Save…", #selector(CanvasView.saveDocument), "s"),
            ("Close", #selector(NSWindow.performClose), "w"),
        ])
        // An uppercase key equivalent means Shift, so "Z" is Shift-Command-Z.
        submenu("Edit", [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        return main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let annotates = menuItem.representedObject as? String == HotKeyAction.annotate.rawValue
        let needsShot = annotates || menuItem.action == #selector(saveLastCapture)
        return !needsShot || lastShot != nil
    }

    @objc private func hotKeyItemPicked(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? String).flatMap(HotKeyAction.init) else { return }
        perform(action)
    }

    @objc private func showSettings() {
        SettingsWindow.show { [weak self] in self?.setHotKeysEnabled($0) }
    }

    private func captureScreen() {
        guard hasScreenAccess() else { return }
        guard let displayID = NSScreen.underMouse?.displayID else { return }
        Task { await deliver { try await Capture.display(displayID) } }
    }

    /// Reads the text in a dragged region and opens it in an editable window.
    private func captureText() {
        guard hasScreenAccess() else { return }
        Task {
            guard case .region(let displayID, let rect) = await SelectionOverlay.pick(.region) else { return }
            do {
                let shot = try await Capture.display(displayID, region: rect)
                TextWindow.open(try await TextRecognizer.read(shot.image))
            } catch {
                report(error)
            }
        }
    }

    private func annotateLastCapture() {
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
