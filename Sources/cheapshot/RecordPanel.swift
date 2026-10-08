import AppKit

/// What the record panel asks before a recording. The last choice is kept between recordings.
struct RecordOptions: Equatable, Sendable {
    enum Mode: Int, CaseIterable, Sendable {
        case region, window, screen
    }

    /// Seconds to wait before recording. 0 starts right away.
    static let countdownChoices = [0, 3, 5, 10]
    /// Volume goes from silent to four times the captured level.
    static let volumeRange = 0.0...4.0

    var mode: Mode = .region
    var systemAudio = true
    var microphone = true
    /// 1 keeps the level as captured. Above 1 boosts it, which helps a quiet microphone.
    var systemVolume = 1.0
    var microphoneVolume = 1.0
    /// Runs the microphone through voice isolation, which drops room noise and breathing.
    var reduceNoise = true
    var countdown = 3

    static func load(from defaults: UserDefaults = .standard) -> RecordOptions {
        var options = RecordOptions()
        if let mode = (defaults.object(forKey: "record.mode") as? Int).flatMap(Mode.init) { options.mode = mode }
        if let on = defaults.object(forKey: "record.systemAudio") as? Bool { options.systemAudio = on }
        if let on = defaults.object(forKey: "record.microphone") as? Bool { options.microphone = on }
        func volume(_ key: String) -> Double? {
            (defaults.object(forKey: key) as? Double).map { min(max($0, volumeRange.lowerBound), volumeRange.upperBound) }
        }
        if let saved = volume("record.systemVolume") { options.systemVolume = saved }
        if let saved = volume("record.microphoneVolume") { options.microphoneVolume = saved }
        if let on = defaults.object(forKey: "record.reduceNoise") as? Bool { options.reduceNoise = on }
        if let seconds = defaults.object(forKey: "record.countdown") as? Int, countdownChoices.contains(seconds) {
            options.countdown = seconds
        }
        return options
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: "record.mode")
        defaults.set(systemAudio, forKey: "record.systemAudio")
        defaults.set(microphone, forKey: "record.microphone")
        defaults.set(systemVolume, forKey: "record.systemVolume")
        defaults.set(microphoneVolume, forKey: "record.microphoneVolume")
        defaults.set(reduceNoise, forKey: "record.reduceNoise")
        defaults.set(countdown, forKey: "record.countdown")
    }
}

/// The quick window that opens on the record hotkey. Return starts with what is shown, Esc cancels.
@MainActor
final class RecordPanel: NSObject, NSWindowDelegate {
    private static var current: RecordPanel?

    static func show(onStart: @escaping @MainActor (RecordOptions) -> Void) {
        if current == nil { current = RecordPanel(options: .load(), onStart: onStart) }
        current?.present()
    }

    let window: NSWindow
    private let onStart: @MainActor (RecordOptions) -> Void
    private let modes: NSSegmentedControl
    private let systemAudio = NSButton(checkboxWithTitle: "System Audio", target: nil, action: nil)
    private let microphone = NSButton(checkboxWithTitle: "Microphone", target: nil, action: nil)
    private let systemVolume = NSSlider()
    private let microphoneVolume = NSSlider()
    private let systemPercent = NSTextField(labelWithString: "")
    private let microphonePercent = NSTextField(labelWithString: "")
    private let reduceNoise = NSButton(checkboxWithTitle: "Reduce microphone noise", target: nil, action: nil)
    private let countdown: NSSegmentedControl
    /// The app that was in front when the panel opened. It gets the focus back, so its windows
    /// do not look inactive in the recording.
    private var previousApp: NSRunningApplication?

    /// Builds the window without showing it. `show` is the way in for the app.
    init(options: RecordOptions, onStart: @escaping @MainActor (RecordOptions) -> Void) {
        self.onStart = onStart
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // In the order of `RecordOptions.Mode`.
        let modeEntries = [("Region", "rectangle.dashed"), ("Window", "macwindow"), ("Screen", "display")]
        modes = NSSegmentedControl(labels: modeEntries.map(\.0), trackingMode: .selectOne, target: nil, action: nil)
        countdown = NSSegmentedControl(
            labels: RecordOptions.countdownChoices.map { $0 == 0 ? "Off" : "\($0) s" },
            trackingMode: .selectOne, target: nil, action: nil)
        super.init()

        modes.controlSize = .large
        modes.segmentDistribution = .fillEqually
        for (index, entry) in modeEntries.enumerated() {
            modes.setImage(NSImage(systemSymbolName: entry.1, accessibilityDescription: nil), forSegment: index)
        }
        modes.selectedSegment = options.mode.rawValue
        systemAudio.state = options.systemAudio ? .on : .off
        microphone.state = options.microphone ? .on : .off
        for (box, slider, percent, value) in [
            (systemAudio, systemVolume, systemPercent, options.systemVolume),
            (microphone, microphoneVolume, microphonePercent, options.microphoneVolume),
        ] {
            slider.minValue = RecordOptions.volumeRange.lowerBound
            slider.maxValue = RecordOptions.volumeRange.upperBound
            slider.doubleValue = value
            // A tick at every 100%.
            slider.numberOfTickMarks = 5
            slider.toolTip = "Volume of this source in the recording. 100% keeps it as captured"
            percent.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            percent.textColor = .secondaryLabelColor
            percent.alignment = .right
            percent.widthAnchor.constraint(equalToConstant: 46).isActive = true
            for control in [box, slider] {
                control.target = self
                control.action = #selector(audioChanged)
            }
        }
        reduceNoise.state = options.reduceNoise ? .on : .off
        reduceNoise.toolTip = "Keeps the voice and drops room noise, hiss and breathing. Applied when the recording stops"
        audioChanged()
        countdown.segmentDistribution = .fillEqually
        countdown.selectedSegment = RecordOptions.countdownChoices.firstIndex(of: options.countdown) ?? 0

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        cancel.controlSize = .large
        let record = NSButton(title: "Record", target: self, action: #selector(start))
        record.keyEquivalent = "\r"
        record.controlSize = .large

        let audio = NSGridView(views: [
            [systemAudio, systemVolume, systemPercent],
            [microphone, microphoneVolume, microphonePercent],
            [reduceNoise],
        ])
        audio.mergeCells(inHorizontalRange: NSRange(location: 0, length: 3), verticalRange: NSRange(location: 2, length: 1))
        audio.rowSpacing = 10
        audio.columnSpacing = 12
        audio.rowAlignment = .firstBaseline
        let timerLabel = NSTextField(labelWithString: "Countdown")
        let timer = NSStackView(views: [timerLabel, countdown])
        timer.spacing = 12
        let buttons = NSStackView(views: [NSView(), cancel, record])
        buttons.spacing = 10

        let content = NSStackView(views: [modes, audio, timer, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 16, right: 24)
        content.setCustomSpacing(22, after: timer)
        // Every row spans the window.
        for row in [modes, audio, timer, buttons] {
            row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
        }
        content.widthAnchor.constraint(equalToConstant: 400).isActive = true

        window.title = "Record"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setContentSize(content.fittingSize)
        // A quick question in the middle of the screen. It stays above other windows until answered.
        window.level = .floating
        window.delegate = self
    }

    private func present() {
        if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        if let screen = NSScreen.underMouse?.visibleFrame {
            window.setFrameOrigin(CGPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private var options: RecordOptions {
        RecordOptions(
            mode: RecordOptions.Mode(rawValue: modes.selectedSegment) ?? .region,
            systemAudio: systemAudio.state == .on,
            microphone: microphone.state == .on,
            systemVolume: systemVolume.doubleValue,
            microphoneVolume: microphoneVolume.doubleValue,
            reduceNoise: reduceNoise.state == .on,
            countdown: RecordOptions.countdownChoices[max(countdown.selectedSegment, 0)])
    }

    /// Keeps each percentage in step with its slider, and grays out the volume of a source that is off.
    @objc private func audioChanged() {
        for (box, slider, percent) in [(systemAudio, systemVolume, systemPercent), (microphone, microphoneVolume, microphonePercent)] {
            slider.isEnabled = box.state == .on
            percent.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
        }
        reduceNoise.isEnabled = microphone.state == .on
    }

    @objc private func start() {
        let options = options
        options.save()
        let onStart = onStart
        close()
        onStart(options)
    }

    @objc private func close() { window.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        previousApp?.activate()
        RecordPanel.current = nil
    }
}

/// A big number in a dark bubble that counts down to the start of a recording.
@MainActor
enum Countdown {
    /// Ticks from `seconds` to 1 with the bubble centered on `center`, in AppKit screen
    /// coordinates. Returns false when Esc cancels it.
    static func run(seconds: Int, at center: CGPoint) async -> Bool {
        let side: CGFloat = 150
        let panel = NSPanel(
            contentRect: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bubble = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        bubble.material = .hudWindow
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 32
        bubble.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 84, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bubble.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
        ])
        panel.contentView = bubble
        panel.orderFrontRegardless()

        let state = State()
        let escape = HotKey.register(keyCode: 53, modifiers: 0) { state.cancelled = true } // kVK_Escape
        defer {
            if let escape { HotKey.unregister(escape) }
            panel.orderOut(nil)
        }
        for remaining in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(remaining)"
            // Short naps, so Esc is noticed within a tenth of a second.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if state.cancelled { return false }
            }
        }
        return true
    }

    @MainActor private final class State { var cancelled = false }
}

/// A thin outline around the region being recorded. It ignores the mouse, and it is never in
/// the recording, because cheapshot leaves its own windows out of what it captures.
@MainActor
enum RecordingFrame {
    private static var panel: NSPanel?

    /// `region` is in AppKit screen coordinates.
    static func show(around region: CGRect) {
        hide()
        // The line sits just outside the region, so it never covers what is being recorded.
        let margin: CGFloat = 4
        let panel = NSPanel(
            contentRect: region.insetBy(dx: -margin, dy: -margin),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = OutlineView()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            // A dark line under a light dashed one stays visible on any background.
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            path.lineWidth = 2
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.stroke()
            path.lineWidth = 1
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}
