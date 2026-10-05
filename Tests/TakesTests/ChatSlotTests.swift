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
        try fake(#"""
        echo '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}'
        for i in $(seq 1 80); do
          echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"word '$i' "}}}'
          sleep 0.025
        done
        """#)
        let slot = SlotHarness.Slot()
        let (view, window, chat, _) = SlotHarness.host(slot, session: session)
        defer { window.orderOut(nil) }

        func stream() async -> Int {
            SlotHarness.settle(view)
            let start = Perf.count("ChatRows")
            chat.send("Go", title: "Slot", onStage: nil)
            await until(15) { !chat.running }
            try? await Task.sleep(for: .milliseconds(100))
            return Perf.count("ChatRows") - start
        }

        SlotHarness.set(slot, false)
        let hidden = await stream()
        SlotHarness.set(slot, true)
        let shown = await stream()
        #expect(chat.messages.last?.text.contains("word 80") == true)
        // Hidden: only when the run starts and ends. Shown: for the words too. (Without the freeze,
        // both were 30. The count is for the whole test run, so other tests add a little.)
        #expect(shown >= hidden * 2, "hidden copy redrew \(hidden) times, shown \(shown)")
    }
}
