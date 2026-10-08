import AppKit

/// Shows recognized text in an editable box. Return copies what is in the box and closes.
/// Esc closes without copying.
@MainActor
final class TextWindow: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private static var current: TextWindow?

    static func open(_ text: String) {
        current?.window.close()
        let textWindow = TextWindow(text: text)
        current = textWindow
        textWindow.present()
    }

    let window: NSWindow
    private let textView: NSTextView

    /// Builds the window without showing it. `open` is the way in for the app.
    init(text: String) {
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as? NSTextView ?? NSTextView()
        super.init()

        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        // The box holds what was on screen. Nothing should rewrite it behind the user's back.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self
        scroll.borderType = .noBorder

        let hint = NSTextField(labelWithString: "↩ copies   ⇧↩ new line   esc closes")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The same keys work when the focus is on a button and not in the text.
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyAndClose))
        copy.keyEquivalent = "\r"

        let footer = NSStackView(views: [hint, NSView(), cancel, copy])
        footer.orientation = .horizontal
        footer.spacing = 10
        let divider = NSBox()
        divider.boxType = .separator
        let content = NSView()
        for view in [scroll, divider, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        let lines = text.split(whereSeparator: \.isNewline).count
        window.title = "Captured Text"
        window.subtitle = lines == 0 ? "No text found" : lines == 1 ? "1 line" : "\(lines) lines"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 380, height: 200)
        window.contentView = content
        // It is a short-lived result, so it stays above other windows until it is dismissed.
        window.level = .floating
        window.delegate = self
        window.center()
    }

    private func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift-Return still breaks the line.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            copyAndClose()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    @objc private func copyAndClose() {
        // An empty box copies nothing, so it does not wipe what is already on the clipboard.
        if !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textView.string, forType: .string)
        }
        close()
    }

    @objc private func close() { window.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        if TextWindow.current === self { TextWindow.current = nil }
    }
}
