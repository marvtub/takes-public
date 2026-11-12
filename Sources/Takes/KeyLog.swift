import AppKit
import Carbon.HIToolbox

// 2026-10-30: shortcuts in a screen take. Off by default: the ⌨ button in the screen pill turns it on
// (remembered). While a screen take records, a listen-only event tap (Input Monitoring) notes each
// shortcut or special key into the cursor log as "keys": [{"t": 2.4, "keys": "⌘K"}]:
//   a key with ⌘, ⌥ or ⌃ held, and Return, Esc, Tab, Delete, the arrows and the F-keys alone.
// Never plain typing, never a key repeat, and nothing while secure input is on (a password field).
// render_edit shows them only when asked (recipe keys: true).
// 2026-11-02: plain typing adds only when it happened: "typing": [[start, end], ...], one run per stretch of
// typing (keys less than CursorLog.typingGap s apart). Never which keys, never each key's time. The zoom
// reads it to zoom in on typing.

enum KeyLog {
    static let defaultsKey = "keystrokes"

    static var on: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Input Monitoring is allowed for Takes.
    static var allowed: Bool { CGPreflightListenEventAccess() }

    /// Asks once (macOS shows its prompt the first time only). True when it is allowed now.
    static func ask() -> Bool { allowed || CGRequestListenEventAccess() }

    private static let named: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Escape: "⎋", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "Space", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
    /// Special keys that count alone, without ⌘, ⌥ or ⌃.
    private static let alone: Set<Int> = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_Tab, kVK_Delete,
                                          kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                          kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                          kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// "⌃⌥⇧⌘K" for a key press worth showing, nil for plain typing. key = the key's own character
    /// (without modifiers), for the keys that have no name.
    static func label(code: Int, command: Bool, option: Bool, control: Bool, shift: Bool, key: String?) -> String? {
        guard command || option || control || alone.contains(code) else { return nil }
        guard let name = named[code] ?? key.map({ $0.uppercased() }).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + name
    }

    /// A key-down event from the tap worth noting: its label, or nil for plain typing. Not counted at all
    /// (nil, false): a key repeat, or secure input on.
    static func read(_ e: CGEvent) -> (label: String?, counts: Bool) {
        guard e.getIntegerValueField(.keyboardEventAutorepeat) == 0, !IsSecureEventInputEnabled() else { return (nil, false) }
        return (label(e), true)
    }

    /// The label of a key-down event from the tap, or nil.
    static func label(_ e: CGEvent) -> String? {
        let f = e.flags
        let key = NSEvent(cgEvent: e)?.charactersIgnoringModifiers
        return label(code: Int(e.getIntegerValueField(.keyboardEventKeycode)), command: f.contains(.maskCommand),
                     option: f.contains(.maskAlternate), control: f.contains(.maskControl), shift: f.contains(.maskShift), key: key)
    }

    /// A listen-only tap on key downs, on the main run loop. nil when Input Monitoring is not allowed.
    static func tap(_ log: CursorLog) -> (CFMachPort, CFRunLoopSource)? {
        let me = Unmanaged.passUnretained(log).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, ref in
                guard let ref else { return Unmanaged.passUnretained(event) }
                let log = Unmanaged<CursorLog>.fromOpaque(ref).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    log.reenableKeys()
                } else if type == .keyDown {
                    let (s, counts) = KeyLog.read(event)
                    if let s { log.key(s) }
                    if counts && (s == nil || s == "⌫" || s == "⌦") { log.typed() }  // deleting is typing too
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: me),
              let src = CFMachPortCreateRunLoopSource(nil, port, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return (port, src)
    }
}
