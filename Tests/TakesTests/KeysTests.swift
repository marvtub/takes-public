import AppKit
import Testing
@testable import Takes

// Regression (2026-09-27): Space, C and ←/→ beeped while a video was on the stage. A read-only
// text view (script, style guide) held focus, counted as "typing", and the key went on to a view
// that could not use it.

@MainActor
struct KeysTests {
    let video = KeyContext(hasPreview: true, videoOnStage: true, canComment: true, hasPlayer: true)

    @Test func readOnlyTextIsNotTyping() {
        let t = NSTextView()
        t.isEditable = false
        #expect(!KeyRouter.isTyping(t))
    }

    @Test func editableTextIsTyping() {
        #expect(KeyRouter.isTyping(NSTextView()))
        #expect(!KeyRouter.isTyping(nil))
        #expect(!KeyRouter.isTyping(NSView()))
    }

    @Test func videoShortcutsAreTakenWhenNotTyping() {
        #expect(KeyRouter.action(key: Key.space, modifiers: [], video) == .playPause)
        #expect(KeyRouter.action(key: Key.c, modifiers: [], video) == .toggleComment)
        #expect(KeyRouter.action(key: Key.s, modifiers: [], video) == .saveFrame)
        #expect(KeyRouter.action(key: Key.left, modifiers: [], video) == .nudge(-1, frame: true))
        #expect(KeyRouter.action(key: Key.right, modifiers: [], video) == .nudge(1, frame: true))
        #expect(KeyRouter.action(key: Key.right, modifiers: .shift, video) == .nudge(1, frame: false))
        // Arrow keys carry these flags from the hardware; they must not block the shortcut.
        #expect(KeyRouter.action(key: Key.left, modifiers: [.function, .numericPad], video) == .nudge(-1, frame: true))
    }

    @Test func readOnlyFocusStillPlaysTheVideo() {
        let t = NSTextView()
        t.isEditable = false
        var c = video
        c.typing = KeyRouter.isTyping(t)
        for key in [Key.space, Key.c, Key.left, Key.right] {
            #expect(KeyRouter.action(key: key, modifiers: [], c) != nil, "key \(key) would beep")
        }
    }

    @Test func typingKeepsKeysForTheField() {
        var c = video
        c.typing = true
        for key in [Key.space, Key.c, Key.s, Key.left, Key.right] {
            #expect(KeyRouter.action(key: key, modifiers: [], c) == nil)
        }
    }

    @Test func stillOnStage() {
        let still = KeyContext(hasPreview: true, canComment: true)
        #expect(KeyRouter.action(key: Key.c, modifiers: [], still) == .toggleComment)
        #expect(KeyRouter.action(key: Key.space, modifiers: [], still) == nil)
    }

    @Test func commandKeysPassThrough() {
        #expect(KeyRouter.action(key: Key.c, modifiers: .command, video) == nil)
    }

    @Test func recording() {
        let rec = KeyContext(recording: true)
        #expect(KeyRouter.action(key: Key.space, modifiers: [], rec) == .toggleScroll)
        #expect(KeyRouter.action(key: Key.up, modifiers: [], rec) == .speed(10))
        #expect(KeyRouter.action(key: Key.escape, modifiers: [], KeyContext(countdown: true)) == .toggleRecord)
    }
}
