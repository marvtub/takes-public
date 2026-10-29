import AppKit
import SwiftUI
import Testing
@testable import Takes

/// The docked chat stays mounted when its slot goes out of sight, and the hidden copy skips
/// streamed words (2026-10-04: moving the chat between slots made each tab switch 2-3x slower).
@MainActor
enum SlotHarness {
    @Observable final class Slot { var active = true }

    struct Harness: View {
        let hub: ChatHub
        let target: ChatTarget
        let slot: Slot
        var body: some View {
            ChatSlot(hub: hub, target: target, active: slot.active) { Color.clear }
        }
    }

    /// A docked chat for `session` in a slot, in a window off every screen.
    static func host(_ slot: Slot, session: URL) -> (NSHostingView<AnyView>, NSWindow, ClaudeChat, AppModel) {
        let app = AppModel()
        app.chats.open = true
        app.chats.docked = true
        let chat = app.chats.chat(session)
        let target = ChatTarget(chat: chat, title: "Slot", session: session)
        let view = NSHostingView(rootView: AnyView(Harness(hub: app.chats, target: target, slot: slot)
            .environment(app).frame(width: 1200, height: 800)))
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1200, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        return (view, window, chat, app)
    }

    static func settle(_ view: NSView) {
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); view.layoutSubtreeIfNeeded() }
    }

    /// Off every screen, animations never end: a chat sliding out would stay. So no animation.
    static func set(_ slot: Slot, _ active: Bool) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { slot.active = active }
    }

    static func scrollViews(_ v: NSView) -> Set<ObjectIdentifier> {
        var out: Set<ObjectIdentifier> = v is NSScrollView ? [ObjectIdentifier(v)] : []
        for s in v.subviews { out.formUnion(scrollViews(s)) }
        return out
    }
}

@MainActor
@Suite struct ChatSlotTests {
    @Test func switchingTheSlotKeepsTheChat() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "chatslot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = dir.appending(path: "P/2026-10-04-slot")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let slot = SlotHarness.Slot()
        let (view, window, _, _) = SlotHarness.host(slot, session: session)
        defer { window.orderOut(nil) }
        SlotHarness.settle(view)
        let before = SlotHarness.scrollViews(view)
        #expect(!before.isEmpty)
        SlotHarness.set(slot, false)
        SlotHarness.settle(view)
        #expect(SlotHarness.scrollViews(view) == before)
        SlotHarness.set(slot, true)
        SlotHarness.settle(view)
        #expect(SlotHarness.scrollViews(view) == before)
    }
}

// In ChatRunTests: it sets the one fake claude, so it must not run beside those tests.
extension ChatRunTests {
    @Test func theHiddenDockedChatSkipsStreamedWords() async throws {
        defer { cleanup() }
        // Each word waits for the test (a word-<run>-<i> file), so every word is a change the view sees on
        // its own, however busy the Mac. A fixed 25 ms per word let a slow Mac fold many into one.
        let words = 20
        try fake(#"""
        echo '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}'
        for i in $(seq 1 \#(words)); do
          while [ -d "\#(dir.path)" ] && [ ! -e "\#(dir.path)/word-$n-$i" ]; do sleep 0.01; done
          echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"word '$i' "}}}'
        done
        """#)
        let slot = SlotHarness.Slot()
        let (view, window, chat, _) = SlotHarness.host(slot, session: session)
        defer { window.orderOut(nil) }

        func stream(_ run: Int) async -> Int {
            SlotHarness.settle(view)
            let start = Perf.count("ChatRows")
            chat.send("Go", title: "Slot", onStage: nil)
            for i in 1...words {
                FileManager.default.createFile(atPath: dir.appending(path: "word-\(run)-\(i)").path, contents: nil)
                await until { chat.messages.last?.text.contains("word \(i) ") == true }
                view.layoutSubtreeIfNeeded()  // the shown copy draws this word before the next comes
            }
            await until { !chat.running }
            SlotHarness.settle(view)
            return Perf.count("ChatRows") - start
        }

        SlotHarness.set(slot, false)
        let hidden = await stream(1)
        SlotHarness.set(slot, true)
        let shown = await stream(2)
        print("hidden copy drew \(hidden) times, shown \(shown), for \(words) words")
        #expect(chat.messages.last?.text.contains("word \(words) ") == true)
        // Hidden: only when the run starts and ends (3). Shown: for each word too (21). Without the
        // freeze, both were about one per word. The count is for the whole test run, so other tests add a little.
        #expect(hidden < words / 2, "hidden copy redrew \(hidden) times for \(words) words")
        #expect(shown >= words / 2, "shown copy redrew \(shown) times for \(words) words")
    }
}
