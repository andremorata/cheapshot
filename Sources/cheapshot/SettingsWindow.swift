import AppKit
import Carbon.HIToolbox

/// The settings window. For now it holds the global shortcuts.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static var current: SettingsWindow?

    /// `setHotKeysEnabled(false)` runs while a shortcut is being typed, so a combination that is
    /// already bound gets recorded instead of fired. `true` registers them again from the saved values.
    static func show(setHotKeysEnabled: @escaping @MainActor (Bool) -> Void) {
        if current == nil { current = SettingsWindow(setHotKeysEnabled: setHotKeysEnabled) }
        NSApp.activate()
        current?.window.makeKeyAndOrderFront(nil)
    }

    let window: NSWindow
    private let setHotKeysEnabled: @MainActor (Bool) -> Void
    private var recorders: [HotKeyAction: ShortcutRecorder] = [:]
    private let message = NSTextField(wrappingLabelWithString: "")

    init(setHotKeysEnabled: @escaping @MainActor (Bool) -> Void) {
        self.setHotKeysEnabled = setHotKeysEnabled
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        let hint = NSTextField(wrappingLabelWithString: "Click a shortcut, then press the new keys. Esc keeps the current one.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 300

        var rows: [[NSView]] = [[hint]] + HotKeyAction.allCases.map { action in
            let recorder = ShortcutRecorder(shortcut: .current(for: action))
            recorder.onRecording = { [weak self] recording in self?.recordingChanged(recording, for: action) }
            recorder.validate = { [weak self] in self?.problem(with: $0, for: action) }
            recorder.onChange = { Shortcut.save($0, for: action) }
            recorder.onMessage = { [weak self] in self?.message.stringValue = $0 }
            recorders[action] = recorder
            return [NSTextField(labelWithString: action.title), recorder]
        }
        rows.append([NSGridCell.emptyContentView, NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))])
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .systemRed
        message.preferredMaxLayoutWidth = 300
        rows.append([message])

        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        // The hint and the message span both columns. The message keeps room for two lines even
        // when empty, so the window does not jump.
        for row in [0, rows.count - 1] {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: row, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .leading
        }
        grid.row(at: 0).bottomPadding = 6
        grid.row(at: rows.count - 1).height = 28
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.title = "cheapshot Settings"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.delegate = self
        window.center()
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
