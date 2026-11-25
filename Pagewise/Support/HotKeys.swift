import AppKit
import Carbon.HIToolbox

/// A key with modifier keys, like ⇧⌘2.
struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value: only ⌘ ⇧ ⌥ ⌃.
    var modifiers: UInt
    /// What the key prints, for showing the shortcut.
    var key: String

    /// ⌃⌥P opens the ask box. Few apps use Control with Option, so it rarely clashes.
    static let ask = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: "P")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    fileprivate var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    /// The system screenshot keys. Pagewise never takes these.
    var isSystemScreenshot: Bool {
        let shot: Set<Int> = [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
        return flags.contains([.command, .shift]) && shot.contains(Int(keyCode))
    }

    /// Makes a shortcut from a key press, or nil when it has no ⌘, ⌃ or ⌥.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let key = Self.name(for: Int(event.keyCode)) ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        self.init(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, key: key)
    }

    init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func name(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: nil
        }
    }
}

/// System-wide shortcuts through Carbon's hot keys. These need no
/// Accessibility permission, and the key press never reaches other apps.
@MainActor
final class HotKeys {
    enum Action: UInt32, CaseIterable {
        case ask = 1
    }

    var onPress: ((Action) -> Void)?
    private var registered: [Action: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let owner = Unmanaged<HotKeys>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let action = Action(rawValue: id.id) { owner.onPress?(action) }
            }
            return noErr
        }, 1, &spec, refcon, &handler)
    }

    /// Registers one shortcut per action. Returns the actions whose
    /// shortcut another app already holds.
    @discardableResult
    func register(_ shortcuts: [Action: Shortcut]) -> [Action] {
        unregisterAll()
        var failed: [Action] = []
        for (action, shortcut) in shortcuts {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5047_5753), id: action.rawValue)  // "PGWS"
            let status = RegisterEventHotKey(
                shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[action] = ref
            } else {
                failed.append(action)
            }
        }
        return failed
    }

    func unregisterAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
    }
}
