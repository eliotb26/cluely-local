import Carbon

/// A global hotkey through Carbon's RegisterEventHotKey. Unlike an NSEvent monitor it swallows the
/// keystroke, so ⌘⏎ doesn't also reach the frontmost app (where it often means "send"), and it
/// needs no Accessibility permission.
final class Hotkey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    /// Returns nil if another app already owns the shortcut.
    init?(keyCode: Int = kVK_Return, modifiers: Int = cmdKey, action: @escaping () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.action?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x434C_4C59), id: 1) // "CLLY"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}
