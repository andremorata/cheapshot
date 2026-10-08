import AppKit
import Carbon.HIToolbox

/// The settings window, in three tabs: general behavior, the global shortcuts and recording.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static var current: SettingsWindow?

    static let showMenuBarIconKey = "general.showMenuBarIcon"

    /// On unless the user turned it off.
    static var showsMenuBarIcon: Bool { UserDefaults.standard.object(forKey: showMenuBarIconKey) as? Bool ?? true }

    /// `setHotKeysEnabled(false)` runs while a shortcut is being typed, so a combination that is
    /// already bound gets recorded instead of fired. `true` registers them again from the saved values.
    /// `menuBarIconChanged` runs after the icon option is switched.
    static func show(setHotKeysEnabled: @escaping @MainActor (Bool) -> Void, menuBarIconChanged: @escaping @MainActor () -> Void) {
        if current == nil { current = SettingsWindow(setHotKeysEnabled: setHotKeysEnabled, menuBarIconChanged: menuBarIconChanged) }
        NSApp.activate()
        current?.window.makeKeyAndOrderFront(nil)
    }

    let window: NSWindow
    let tabs = NSTabView()
    private let setHotKeysEnabled: @MainActor (Bool) -> Void
    private let menuBarIconChanged: @MainActor () -> Void
    private let showIcon = NSButton(checkboxWithTitle: "Show icon in the menu bar", target: nil, action: nil)
    private var recorders: [HotKeyAction: ShortcutRecorder] = [:]
    private let message = NSTextField(wrappingLabelWithString: "")
    private var codec = NSSegmentedControl()
    private var resolution = NSSegmentedControl()
    private var frameRate = NSSegmentedControl()
    private var quality = NSSegmentedControl()
    private let estimate = NSTextField(wrappingLabelWithString: "")
    private let afterCapture = NSPopUpButton()
    private let folderPath = NSPathControl()
    private let chooseFolder = NSButton(title: "Choose…", target: nil, action: nil)

    init(setHotKeysEnabled: @escaping @MainActor (Bool) -> Void, menuBarIconChanged: @escaping @MainActor () -> Void = {}) {
        self.setHotKeysEnabled = setHotKeysEnabled
        self.menuBarIconChanged = menuBarIconChanged
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        func note(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 340
            return label
        }

        // General.
        var general = Page()
        showIcon.state = Self.showsMenuBarIcon ? .on : .off
        showIcon.target = self
        showIcon.action = #selector(showIconChanged)
        general.span(showIcon)
        general.span(note("With the icon hidden, open cheapshot again from Applications or Spotlight to come back to this window. The shortcuts keep working."))
        afterCapture.addItems(withTitles: CaptureAction.allCases.map(\.title))
        afterCapture.selectItem(at: CaptureAction.allCases.firstIndex(of: .current()) ?? 0)
        afterCapture.target = self
        afterCapture.action = #selector(afterCaptureChanged)
        general.padding[general.rows.count] = 10
        general.row("After a screenshot", afterCapture)
        folderPath.url = CaptureAction.folder()
        folderPath.pathStyle = .standard
        folderPath.isEditable = false
        folderPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseFolder.target = self
        chooseFolder.action = #selector(pickFolder)
        let folder = NSStackView(views: [folderPath, chooseFolder])
        folder.spacing = 8
        general.row("Folder", folder)
        general.span(note("Every screenshot also goes to the clipboard. The folder is only used by \"Save to a folder\"."))
        afterCaptureChanged()

        // Shortcuts.
        var shortcuts = Page()
        shortcuts.span(note("Click a shortcut, then press the new keys. Esc keeps the current one."))
        for action in HotKeyAction.allCases {
            let recorder = ShortcutRecorder(shortcut: .current(for: action))
            recorder.onRecording = { [weak self] recording in self?.recordingChanged(recording, for: action) }
            recorder.validate = { [weak self] in self?.problem(with: $0, for: action) }
            recorder.onChange = { Shortcut.save($0, for: action) }
            recorder.onMessage = { [weak self] in self?.message.stringValue = $0 }
            recorders[action] = recorder
            shortcuts.row(action.title, recorder)
        }
        shortcuts.rows.append([NSGridCell.emptyContentView, NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))])
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .systemRed
        message.preferredMaxLayoutWidth = 340
        // Room for two lines even when empty, so nothing jumps when a message appears.
        shortcuts.heights[shortcuts.rows.count] = 28
        shortcuts.span(message)

        // Recording. Each control is a short list of choices, in the order of the model's cases.
        var recording = Page()
        let video = VideoSettings.load()
        func picker(_ labels: [String], selected: Int, tip: String) -> NSSegmentedControl {
            let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: #selector(videoChanged))
            control.segmentDistribution = .fillEqually
            control.selectedSegment = selected
            control.toolTip = tip
            return control
        }
        codec = picker(["HEVC", "H.264"], selected: VideoSettings.Codec.allCases.firstIndex(of: video.codec) ?? 0,
                       tip: "HEVC makes smaller files. H.264 plays on older devices and some websites that reject HEVC")
        resolution = picker(["Standard", "Retina"], selected: video.nativeResolution ? 1 : 0,
                            tip: "Standard records one pixel per point. Retina records every pixel of the screen, about four times the data")
        frameRate = picker(VideoSettings.frameRates.map { "\($0) fps" }, selected: VideoSettings.frameRates.firstIndex(of: video.framesPerSecond) ?? 0,
                           tip: "60 fps is smoother for motion and about doubles the file size")
        quality = picker(["Low", "Medium", "High"], selected: VideoSettings.Quality.allCases.firstIndex(of: video.quality) ?? 1,
                         tip: "How many bits the encoder may spend. Each step up doubles the file size")
        recording.row("Codec", codec)
        recording.row("Resolution", resolution)
        recording.row("Frame rate", frameRate)
        recording.row("Quality", quality)
        estimate.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        estimate.textColor = .secondaryLabelColor
        estimate.preferredMaxLayoutWidth = 340
        recording.span(estimate)
        recording.span(note("Audio sources, their volume and the countdown are chosen in the panel that opens when you start a recording."))
        updateEstimate(video)

        var largest = CGSize.zero
        for (title, page) in [("General", general), ("Shortcuts", shortcuts), ("Recording", recording)] {
            let item = NSTabViewItem()
            item.label = title
            let view = page.view()
            largest = CGSize(width: max(largest.width, view.fittingSize.width), height: max(largest.height, view.fittingSize.height))
            item.view = view
            tabs.addTabViewItem(item)
        }

        tabs.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            // Sized for the tallest tab, so switching tabs does not resize the window.
            tabs.widthAnchor.constraint(equalToConstant: largest.width + 24),
            tabs.heightAnchor.constraint(equalToConstant: largest.height + 48),
        ])
        window.title = "cheapshot Settings"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.delegate = self
        window.center()
    }

    /// The rows of one tab: a label and a control, or one view across both columns.
    @MainActor private struct Page {
        var rows: [[NSView]] = []
        var spanning: [Int] = []
        var heights: [Int: CGFloat] = [:]
        /// Extra space above a row, to set a group apart.
        var padding: [Int: CGFloat] = [:]

        mutating func row(_ label: String, _ control: NSView) {
            rows.append([NSTextField(labelWithString: label), control])
        }

        mutating func span(_ view: NSView) {
            spanning.append(rows.count)
            rows.append([view])
        }

        func view() -> NSView {
            let grid = NSGridView(views: rows)
            grid.column(at: 0).xPlacement = .trailing
            grid.rowAlignment = .firstBaseline
            grid.rowSpacing = 10
            grid.columnSpacing = 12
            for row in spanning {
                grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: row, length: 1))
                grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .leading
            }
            for (row, height) in heights { grid.row(at: row).height = height }
            for (row, space) in padding { grid.row(at: row).topPadding = space }
            grid.translatesAutoresizingMaskIntoConstraints = false
            let container = NSView()
            container.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
                grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
                grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
            ])
            return container
        }
    }

    private func recordingChanged(_ recording: Bool, for action: HotKeyAction) {
        // One recorder at a time. The others finish first and switch the hotkeys back on, then this one switches them off.
        if recording { for (other, recorder) in recorders where other != action { recorder.cancel() } }
        setHotKeysEnabled(!recording)
    }

    /// A message when `shortcut` cannot be used for `action`, or nil when it can.
    private func problem(with shortcut: Shortcut, for action: HotKeyAction) -> String? {
        if let other = HotKeyAction.allCases.first(where: { $0 != action && Shortcut.current(for: $0).matches(shortcut) }) {
            return "\(shortcut.label) is already used by \(other.title)."
        }
        // Our own hotkeys are off while recording, so a failed probe points at something outside the app.
        guard let probe = HotKey.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: {}) else {
            return "\(shortcut.label) could not be registered. Another app may be using it."
        }
        HotKey.unregister(probe)
        return nil
    }

    @objc private func showIconChanged() {
        UserDefaults.standard.set(showIcon.state == .on, forKey: Self.showMenuBarIconKey)
        menuBarIconChanged()
    }

    /// Saves the choice. The folder row only matters for "Save to a folder", so it is grayed out otherwise.
    @objc private func afterCaptureChanged() {
        let action = CaptureAction.allCases[max(afterCapture.indexOfSelectedItem, 0)]
        CaptureAction.setCurrent(action)
        folderPath.isEnabled = action == .folder
        chooseFolder.isEnabled = action == .folder
    }

    @objc private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = CaptureAction.folder()
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        CaptureAction.setFolder(url)
        folderPath.url = url
    }

    @objc private func videoChanged() {
        var video = VideoSettings()
        video.codec = VideoSettings.Codec.allCases[max(codec.selectedSegment, 0)]
        video.nativeResolution = resolution.selectedSegment == 1
        video.framesPerSecond = VideoSettings.frameRates[max(frameRate.selectedSegment, 0)]
        video.quality = VideoSettings.Quality.allCases[max(quality.selectedSegment, 0)]
        video.save()
        updateEstimate(video)
    }

    /// Puts the choices in terms of file size, for a Full HD area, which is easier to judge than a bitrate.
    private func updateEstimate(_ video: VideoSettings) {
        let megabytes = video.megabytesPerMinute(width: 1920, height: 1080)
        estimate.stringValue = String(format: "About %.0f MB per minute for a 1920 × 1080 recording, before audio.", megabytes)
    }

    @objc private func restoreDefaults() {
        for (action, recorder) in recorders {
            recorder.cancel()
            Shortcut.save(nil, for: action)
            recorder.shortcut = action.defaultShortcut
        }
        message.stringValue = ""
        setHotKeysEnabled(true)
    }

    func windowWillClose(_ notification: Notification) {
        for recorder in recorders.values { recorder.cancel() }
    }
}

/// A button that shows a shortcut. Click it, then press the new combination. Esc keeps the old one.
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut { didSet { if monitor == nil { title = shortcut.label } } }
    var onRecording: ((Bool) -> Void)?
    /// Returns a message when the shortcut cannot be used.
    var validate: ((Shortcut) -> String?)?
    var onChange: ((Shortcut) -> Void)?
    var onMessage: ((String) -> Void)?

    private var monitor: Any?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        title = shortcut.label
        bezelStyle = .rounded
        target = self
        action = #selector(toggle)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func toggle() {
        if monitor == nil { begin() } else { cancel() }
    }

    private func begin() {
        onRecording?(true)
        onMessage?("")
        title = "Type shortcut…"
        // A local monitor sees every key press in the app first, Command combinations included.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = Int(event.keyCode)
            let candidate = Shortcut(event: event)
            MainActor.assumeIsolated { self?.record(keyCode: keyCode, candidate) }
            return nil
        }
    }

    private func record(keyCode: Int, _ candidate: Shortcut?) {
        if keyCode == kVK_Escape { return cancel() }
        guard let candidate else {
            onMessage?("Use at least one of ⌘, ⌥ or ⌃.")
            return
        }
        if let problem = validate?(candidate) {
            onMessage?(problem)
            return
        }
        shortcut = candidate
        onChange?(candidate)
        cancel()
    }

    /// Stops recording and shows the shortcut that is in effect.
    func cancel() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        title = shortcut.label
        onRecording?(false)
    }
}
