import AppKit

// The app's single-key shortcuts, as a pure decision so tests can pin it down
// (Tests/TakesTests/KeysTests.swift). A key the app does not take goes on to the focused view;
// if that view cannot use it either, macOS beeps. So: take every shortcut unless the user is
// really typing in an editable field.

enum KeyAction: Equatable {
    case toggleRecord, toggleScroll, saveFrame, toggleComment, endComment, playPause
    case nudge(Int, frame: Bool)   // ←/→: one frame, with ⇧ one second
    case speed(Int)                // ↑/↓ while recording: teleprompter speed
}

struct KeyContext {
    var countdown = false
    var recording = false
    var typing = false
    var hasPreview = false     // something is on the stage
    var videoOnStage = false   // a video is on the stage (save frame, nudge)
    var canComment = false     // a video or still is on the stage
    var commentMode = false
    var hasPlayer = false
}

enum Key {
    static let space: UInt16 = 49, escape: UInt16 = 53, s: UInt16 = 1, c: UInt16 = 8
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
}

enum KeyRouter {
    /// Only an editable field counts as typing. A read-only text view (script, style guide) cannot
    /// take the key, so passing it on makes the system beep.
    static func isTyping(_ responder: NSResponder?) -> Bool {
        if let t = responder as? NSTextView { return t.isEditable }
        return responder is NSText
    }

    static func action(key: UInt16, modifiers: NSEvent.ModifierFlags, _ c: KeyContext) -> KeyAction? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        let media = !c.typing && c.videoOnStage && c.hasPlayer
        switch key {
        case Key.escape where c.countdown: return .toggleRecord
        case Key.space where c.recording || (!c.typing && !c.hasPreview): return .toggleScroll
        case Key.s where !c.typing && !c.recording && c.videoOnStage: return .saveFrame
        case Key.c where !c.typing && !c.recording && c.canComment: return .toggleComment
        case Key.escape where c.commentMode: return .endComment
        case Key.space where media: return .playPause
        case Key.left where media: return .nudge(-1, frame: !modifiers.contains(.shift))
        case Key.right where media: return .nudge(1, frame: !modifiers.contains(.shift))
        case Key.up where c.recording: return .speed(10)
        case Key.down where c.recording: return .speed(-10)
        default: return nil
        }
    }
}
