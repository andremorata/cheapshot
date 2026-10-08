import AppKit
import Carbon.HIToolbox

/// What a global hotkey can trigger.
enum HotKeyAction: String, CaseIterable, Sendable {
    case region, window, screen, text, annotate

    var title: String {
        switch self {
        case .region: "Capture Region"
        case .window: "Capture Window"
        case .screen: "Capture Screen"
        case .text: "Capture Text"
        case .annotate: "Annotate Last Capture"
        }
    }

    /// The system screenshot keys, with Option in place of Command.
    var defaultShortcut: Shortcut {
        let modifiers = optionKey | shiftKey
        switch self {
        case .screen: return Shortcut(keyCode: kVK_ANSI_3, modifiers: modifiers, key: "3")
        case .region: return Shortcut(keyCode: kVK_ANSI_4, modifiers: modifiers, key: "4")
        case .window: return Shortcut(keyCode: kVK_ANSI_5, modifiers: modifiers, key: "5")
        case .text: return Shortcut(keyCode: kVK_ANSI_T, modifiers: modifiers, key: "T")
        case .annotate: return Shortcut(keyCode: kVK_ANSI_E, modifiers: modifiers, key: "E")
        }
    }
}

struct Shortcut: Sendable {
    /// A `kVK_*` virtual key code.
    var keyCode: Int
    /// A Carbon mask of `cmdKey`, `optionKey`, `controlKey` and `shiftKey`.
    var modifiers: Int
    /// The key's name for display, such as "4" or "F5".
    var key: String

    var label: String {
        Self.modifierTable.filter { modifiers & $0.carbon != 0 }.map(\.glyph).joined() + key
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        Self.modifierTable.reduce(into: []) { flags, entry in
            if modifiers & entry.carbon != 0 { flags.insert(entry.cocoa) }
        }
    }

    /// For `NSMenuItem.keyEquivalent`. Named keys have no single character, so they show no hint.
    var menuKeyEquivalent: String { Self.namedKeys[keyCode] == nil ? key.lowercased() : "" }

    /// The display name is left out: the same key can be named differently across layouts.
    func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    // In the order macOS shows them.
    private static let modifierTable: [(carbon: Int, cocoa: NSEvent.ModifierFlags, glyph: String)] = [
        (controlKey, .control, "⌃"), (optionKey, .option, "⌥"), (shiftKey, .shift, "⇧"), (cmdKey, .command, "⌘"),
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

extension Shortcut {
    /// Reads a shortcut from a key press. Returns nil without Command, Option or Control, because
    /// a bare or Shift-only key would hijack normal typing in every app.
    init?(event: NSEvent) {
        self.init(keyCode: Int(event.keyCode), flags: event.modifierFlags, character: event.characters(byApplyingModifiers: []))
    }

    init?(keyCode: Int, flags: NSEvent.ModifierFlags, character: String?) {
        let modifiers = Self.modifierTable.reduce(0) { flags.contains($1.cocoa) ? $0 | $1.carbon : $0 }
        guard modifiers & (cmdKey | optionKey | controlKey) != 0 else { return nil }
        let name = Self.namedKeys[keyCode] ?? character?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, key: name)
    }

    // MARK: Persistence

    var plist: [String: Any] { ["keyCode": keyCode, "modifiers": modifiers, "key": key] }

    init?(plist: Any?) {
        guard let values = plist as? [String: Any],
              let keyCode = values["keyCode"] as? Int,
              let modifiers = values["modifiers"] as? Int,
              let key = values["key"] as? String
        else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, key: key)
    }

    static func current(for action: HotKeyAction) -> Shortcut {
        Shortcut(plist: UserDefaults.standard.object(forKey: defaultsKey(action))) ?? action.defaultShortcut
    }

    /// `nil` goes back to the default.
    static func save(_ shortcut: Shortcut?, for action: HotKeyAction) {
        UserDefaults.standard.set(shortcut?.plist, forKey: defaultsKey(action))
    }

    private static func defaultsKey(_ action: HotKeyAction) -> String { "shortcut.\(action.rawValue)" }
}
