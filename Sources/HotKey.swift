import AppKit
import Carbon

/// A system-wide shortcut registered through Carbon, which needs no Accessibility access.
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return nil }
        let identifier = EventHotKeyID(signature: OSType(0x4D44_4B59), id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// ⌃⌥M: add the link on the clipboard.
    static let enabledKey = "ClipboardHotKeyEnabled"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static func clipboardShortcut(_ action: @escaping () -> Void) -> HotKey? {
        HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), action: action)
    }
}
