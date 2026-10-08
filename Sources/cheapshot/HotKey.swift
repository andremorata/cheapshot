import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon. It is the only hotkey API that needs no Accessibility permission.
@MainActor
enum HotKey {
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// `keyCode` is a `kVK_*` constant. `modifiers` is a mask of Carbon `cmdKey`, `optionKey`, `shiftKey`, `controlKey`.
    /// Returns a token for `unregister`, or `nil` when another app already holds the combination.
    @discardableResult
    static func register(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) -> UInt32? {
        installHandler()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers),
            EventHotKeyID(signature: 0x4348_5348, id: id), // 'CHSH'
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("cheapshot: hotkey \(keyCode) not registered, OSStatus \(status)")
            return nil
        }
        actions[id] = action
        refs[id] = ref
        return id
    }

    static func unregister(_ id: UInt32) {
        actions[id] = nil
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
