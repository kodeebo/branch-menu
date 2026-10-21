import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard installed == noErr else { return nil }
    }

    /// Replaces the current shortcut. Fails when another app already owns that combination.
    @discardableResult
    func register(keyCode: Int, modifiers: Int) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x424D_4E55), id: 1)  // "BMNU"
        return RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef
        ) == noErr
    }

    /// Frees the shortcut, e.g. while recording a new one so the old one reaches the recorder.
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// Carbon modifier mask and a label like "⌥⌘B" for a key press, or nil without ⌘, ⌥ or ⌃.
    static func shortcut(from event: NSEvent) -> (code: Int, modifiers: Int, label: String)? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        var modifiers = 0
        var label = ""
        if flags.contains(.control) { modifiers |= controlKey; label += "⌃" }
        if flags.contains(.option) { modifiers |= optionKey; label += "⌥" }
        if flags.contains(.shift) { modifiers |= shiftKey; label += "⇧" }
        if flags.contains(.command) { modifiers |= cmdKey; label += "⌘" }
        let key: String = switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        default: event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
        return (Int(event.keyCode), modifiers, label + key)
    }
}
