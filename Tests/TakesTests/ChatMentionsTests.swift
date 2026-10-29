import AppKit
import SwiftUI
import Testing
@testable import Takes

@Suite struct ChatMentionsTests {
    let green = Mention(kind: .style, name: "Green Room", path: URL(fileURLWithPath: "/lib/styles/Green Room"))
    let argon = Mention(kind: .style, name: "Green Room Argon", path: URL(fileURLWithPath: "/lib/styles/Green Room Argon"))
    let behind = Mention(kind: .effect, name: "Text behind", detail: "Cut-out", path: URL(fileURLWithPath: "/app/effects/text-behind"))
    let hyper = Mention(kind: .skill, name: "Hyperframes", path: URL(fileURLWithPath: "/home/.claude/skills/hyperframes"))
    let edit = Mention(kind: .asset, name: "launch-v3.mp4", detail: "Edit", path: URL(fileURLWithPath: "/s/edits/launch-v3.mp4"))

    @Test func theListOpensOnlyForAnAtBeingTyped() {
        #expect(Mentions.query("Make it in @")?.text == "")
        #expect(Mentions.query("@gre")?.text == "gre")
        #expect(Mentions.query("Make it in @green ro")?.text == "green ro")
        #expect(Mentions.query("mail me at user@acme.com") == nil)
        #expect(Mentions.query("@ green") == nil)
        #expect(Mentions.query("@green\nnext") == nil)
        #expect(Mentions.query("no at here") == nil)
        // A picked name does not open the list again.
        #expect(Mentions.query("in @Green Room ", picked: [green]) == nil)
    }

    @Test func typingFiltersByNameOrKind() {
        let all = [green, argon, hyper, edit]
        #expect(Mentions.filter(all, "") == all)
        #expect(Mentions.filter(all, "room").map(\.name) == ["Green Room", "Green Room Argon"])
        #expect(Mentions.filter(all, "sty").count == 2)
        #expect(Mentions.filter(all, "hyper") == [hyper])
        #expect(Mentions.filter(all, "argon") == [argon])
        #expect(Mentions.filter(all, "nothing").isEmpty)
    }

    @Test func aPickReplacesTheTypedWords() {
        #expect(Mentions.pick(green, into: "Make the hook in @gre") == "Make the hook in @Green Room ")
        #expect(Mentions.pick(hyper, into: "@") == "@Hyperframes ")
    }

    @Test func theNoteSaysWhatEachNameIs() {
        let text = "Make the hook in @Green Room with @Hyperframes"
        let used = Mentions.used([green, hyper, edit], in: text)
        #expect(used == [green, hyper])
        let note = Mentions.note(used, session: URL(fileURLWithPath: "/m/Takes/p/s"))
        #expect(note.contains("set_style with session /m/Takes/p/s"))
        #expect(note.contains("\"Green Room\""))
        #expect(note.contains("/home/.claude/skills/hyperframes/SKILL.md"))
        #expect(Mentions.note([], session: nil) == "")
        // The chat shows the message alone, and tints the names it read back from the note.
        #expect(CopilotAsk.shown(text + note) == text)
        #expect(Mentions.tokens(in: text + note) == ["@Green Room", "@Hyperframes"])
    }

    @Test func anEffectIsAskedForByItsFolder() {
        let text = "Put @Text behind on the hook"
        let note = Mentions.note(Mentions.used([behind, green], in: text), session: nil)
        #expect(note.contains("the effect \"Text behind\""))
        #expect(note.contains("list_effects text-behind"))
        #expect(!note.contains("Green Room"))
        #expect(Mentions.tokens(in: text + note) == ["@Text behind"])
        #expect(Mentions.filter([green, hyper, behind], "eff") == [behind])
    }

    @Test func theListHasEveryEffect() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "mention-fx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let shipped = tmp.appending(path: "effects/tier-list")
        try fm.createDirectory(at: shipped, withIntermediateDirectories: true)
        try #"{"name": "Tier list", "kind": "Overlay"}"#.write(to: shipped.appending(path: "effect.json"), atomically: true, encoding: .utf8)
        let fx = Mentions.all(session: nil, root: tmp, effects: tmp.appending(path: "effects")).filter { $0.kind == .effect }
        #expect(fx.map(\.name) == ["Tier list"])
        #expect(fx.first?.detail == "Overlay")
        #expect(Mentions.note(fx, session: nil).contains("list_effects tier-list"))
    }

    @Test func aLongerNameWinsOverItsStart() {
        let text = "@Green Room Argon and @Green Room"
        let r = Mentions.ranges(of: ["@Green Room", "@Green Room Argon"], in: text).map { String(text[$0]) }
        #expect(r == ["@Green Room Argon", "@Green Room"])
    }

    @Test func aFileNameWithAColonReadsBack() {
        let still = Mention(kind: .asset, name: "v10 at 0:12.png", path: URL(fileURLWithPath: "/s/stills/v10 at 0:12.png"))
        let note = Mentions.note([still], session: nil)
        #expect(Mentions.tokens(in: "look at @v10 at 0:12.png" + note) == ["@v10 at 0:12.png"])
    }
}

private struct MentionHost: View {
    let picker: MentionPicker
    @State private var draft = ""
    @State private var after = ""
    @FocusState private var focused: Bool
    @StateObject private var dictation = Dictation()

    var body: some View {
        VStack {
            Spacer()
            ChatField(draft: $draft, focused: $focused, dictation: dictation, spokenAfter: $after,
                      placeholder: "Message Takes", running: false, canSend: true,
                      send: {}, stop: {}, mentions: picker)
                .frame(width: 366)
        }
        .padding(12)
        .frame(width: 390, height: 460, alignment: .bottomLeading)
        .background(Theme.surface)
        .onAppear { focused = true }
    }
}

private final class MentionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
@Suite struct ChatMentionsViewTests {
    /// Type @, filter, pick with Return: the list shows and the pick lands in the box.
    /// TAKES_SNAPSHOT: pictures of each step.
    @Test func typeAtFilterAndPick() throws {
        let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"]
        let root = FileManager.default.temporaryDirectory.appending(path: "mentions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
        for name in ["Magazine", "Green Room", "Green Room Argon", "Ember Split"] {
            let d = StyleLib.style(name, root: root)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let png = StyleLib.style(name, root: real).appending(path: "preview.png")
            if FileManager.default.fileExists(atPath: png.path) {
                try FileManager.default.copyItem(at: png, to: d.appending(path: "preview.png"))
            }
        }
        let picker = MentionPicker()
        picker.root = root
        let host = NSHostingView(rootView: MentionHost(picker: picker))
        let win = MentionWindow(contentRect: NSRect(x: -3000, y: -3000, width: 390, height: 460),
                                styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        func spin(_ s: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func shot(_ name: String) throws {
            spin()
            guard let dir else { return }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "mention-" + name + ".png"))
        }
        spin(1)
        let ed = try #require(win.firstResponder as? NSTextView, "no editor")
        ed.insertText("Make the hook card in @", replacementRange: ed.selectedRange())
        try shot("1-open")
        #expect(!picker.rows(ed.string).isEmpty)
        ed.insertText("gre", replacementRange: ed.selectedRange())
        try shot("2-filtered")
        #expect(picker.rows(ed.string).first?.name == "Green Room")
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: win.windowNumber, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        win.sendEvent(enter)
        spin(0.3)
        ed.insertText("and put it at 0:03", replacementRange: ed.selectedRange())
        try shot("3-picked")
        #expect(ed.string == "Make the hook card in @Green Room and put it at 0:03")
        #expect(picker.picked.map(\.name) == ["Green Room"])
        #expect(picker.rows(ed.string).isEmpty)
    }
}
