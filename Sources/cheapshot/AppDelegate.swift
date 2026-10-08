import AppKit
import AVFoundation
import Carbon.HIToolbox
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var lastShot: Shot?
    private var askedForScreenAccess = false
    private var hotKeyTokens: [UInt32] = []
    private var recorder: Recorder?
    /// True from the hotkey press until the stream is running, so a second press cannot start another.
    private var isStartingRecording = false

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
        // While recording, the status item is a stop button and has no menu.
        if recorder == nil { statusItem?.menu = makeMenu() }
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .region: pickAndCapture(.region)
        case .window: pickAndCapture(.window)
        case .screen: captureScreen()
        case .text: captureText()
        case .annotate: annotateLastCapture()
        case .record: recorder == nil ? showRecordPanel() : stopRecording()
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
        add(.record)
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
        Task { await deliver { try await Capture.shot(.display(displayID)) } }
    }

    /// Reads the text in a dragged region and opens it in an editable window.
    private func captureText() {
        guard hasScreenAccess() else { return }
        Task {
            guard let target = await SelectionOverlay.pick(.region) else { return }
            do {
                let shot = try await Capture.shot(target)
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
            guard let target = await SelectionOverlay.pick(mode) else { return }
            await deliver { try await Capture.shot(target) }
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

    // MARK: Recording

    /// The record hotkey opens a quick panel first: what to record, which audio, and the countdown.
    private func showRecordPanel() {
        guard !isStartingRecording else { return }
        RecordPanel.show { [weak self] in self?.record($0) }
    }

    /// Shows the system prompt the first time. After a refusal it explains where to turn the permission on.
    private func hasMicrophoneAccess() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "cheapshot needs Microphone permission"
        alert.informativeText = "Turn it on in System Settings, under Privacy & Security, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func record(_ options: RecordOptions) {
        guard recorder == nil, !isStartingRecording, hasScreenAccess() else { return }
        isStartingRecording = true
        Task { [self] in
            defer { isStartingRecording = false }
            // Asked before anything else, so the system prompt never lands in the middle of the countdown.
            if options.microphone {
                guard await hasMicrophoneAccess() else { return }
            }
            let target: Capture.Target? = switch options.mode {
            case .region: await SelectionOverlay.pick(.region)
            case .window: await SelectionOverlay.pick(.window)
            case .screen: NSScreen.underMouse?.displayID.map { .display($0) }
            }
            guard let target else { return }
            // Up from here until the recording stops, so the limits stay visible. Shown during the countdown too.
            if let region = screenRect(of: target) { RecordingFrame.show(around: region) }
            if options.countdown > 0 {
                guard await Countdown.run(seconds: options.countdown, at: center(of: target)) else {
                    RecordingFrame.hide()
                    return
                }
            }
            // NOTE: fixed defaults (HEVC, 30 fps, 1x, medium) until the settings screen exposes them.
            var settings = VideoSettings()
            settings.systemAudio = options.systemAudio
            settings.microphone = options.microphone
            settings.systemGain = Float(options.systemVolume)
            settings.microphoneGain = Float(options.microphoneVolume)
            settings.reduceNoise = options.reduceNoise
            do {
                let recorder = try await Recorder.start(target, settings: settings)
                recorder.onInterrupted = { [weak self] in self?.stopRecording() }
                self.recorder = recorder
                showStopButton()
            } catch {
                RecordingFrame.hide()
                report(error)
            }
        }
    }

    /// The recorded region in AppKit screen coordinates. Nil for a window or a whole screen,
    /// which need no outline.
    private func screenRect(of target: Capture.Target) -> CGRect? {
        guard case .display(let id, let region?) = target,
              let screen = NSScreen.screens.first(where: { $0.displayID == id })
        else { return nil }
        // The region counts down from the top of its screen. AppKit counts up from the bottom.
        return CGRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY, width: region.width, height: region.height)
    }

    /// The middle of what will be recorded, in AppKit screen coordinates. The countdown sits there.
    private func center(of target: Capture.Target) -> CGPoint {
        let rect = screenRect(of: target) ?? NSScreen.underMouse?.frame ?? .zero
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Turns the status item into a stop button that counts the seconds.
    private func showStopButton() {
        guard let statusItem, let button = statusItem.button else { return }
        statusItem.menu = nil
        statusItem.length = NSStatusItem.variableLength
        // The red is baked into the image. A tint on the button also darkens the title, which then
        // disappears on a dark menu bar. The title is left plain so the system picks its color.
        let stop = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        stop?.isTemplate = false
        button.image = stop
        button.imagePosition = .imageLeading
        // Fixed-width digits, so the item does not twitch every second.
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.target = self
        button.action = #selector(stopRecording)
        let started = Date.now
        Task {
            while recorder != nil {
                let seconds = Int(Date.now.timeIntervalSince(started))
                button.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    @objc private func stopRecording() {
        guard let recorder else { return }
        self.recorder = nil
        RecordingFrame.hide()
        if let statusItem, let button = statusItem.button {
            button.title = ""
            button.image = Self.menuBarIcon
            button.imagePosition = .imageOnly
            button.action = nil
            statusItem.length = NSStatusItem.squareLength
            statusItem.menu = makeMenu()
        }
        Task {
            do { try await saveRecording(try await recorder.stop()) } catch { report(error) }
        }
    }

    /// Asks where the recording goes. Cancelling asks once more before the file is thrown away.
    private func saveRecording(_ temporary: URL) async throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = Output.fileName("mp4")
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        NSApp.activate()
        while true {
            if panel.runModal() == .OK, let destination = panel.url {
                // The panel already asked about replacing an existing file.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([destination as NSURL])
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
                generator.appliesPreferredTrackTransform = true
                if let frame = try? await generator.image(at: .zero).image {
                    Thumbnail.show(Shot(image: frame, scale: 1)) { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                }
                return
            }
            let alert = NSAlert()
            alert.messageText = "Discard this recording?"
            alert.informativeText = "It has not been saved anywhere yet."
            alert.addButton(withTitle: "Save…")
            alert.addButton(withTitle: "Discard")
            if alert.runModal() != .alertFirstButtonReturn {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
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
