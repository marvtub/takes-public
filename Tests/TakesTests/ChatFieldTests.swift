import AppKit
import SwiftUI
import Testing
@testable import Takes

@MainActor
final class FieldWidthBox: ObservableObject {
    @Published var width: CGFloat = 300
}

private struct FieldHost: View {
    @ObservedObject var box: FieldWidthBox
    @State private var draft = ""
    @State private var after = ""
    @FocusState private var focused: Bool
    @StateObject private var dictation = Dictation()

    var body: some View {
        VStack {
            Spacer()
            ChatField(draft: $draft, focused: $focused, dictation: dictation, spokenAfter: $after,
                      placeholder: "Message Takes", running: false, canSend: true,
                      send: {}, stop: {})
                .frame(width: box.width)
        }
        .padding(12)
        .frame(width: 640, height: 260, alignment: .bottomLeading)
        .background(Theme.paper)
        .onAppear { focused = true }
    }
}

@MainActor
@Suite struct ChatFieldTests {
    /// The box got wider while you typed: the words must wrap at the new width, not the old one
    /// (2026-10-09: they broke at half the box and the top line was cut off). TAKES_SNAPSHOT: pictures.
    @Test func wordsWrapAtTheBoxsWidth() throws {
        let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"]
        let box = FieldWidthBox()
        let host = NSHostingView(rootView: FieldHost(box: box))
        host.appearance = NSAppearance(named: .darkAqua)
        let win = KeyWindow(contentRect: NSRect(x: -3000, y: -3000, width: 640, height: 260),
                            styleMask: .borderless, backing: .buffered, defer: false)
        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        func spin(_ s: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func shot(_ name: String) throws {
            spin()
            let ed = try #require(win.firstResponder as? NSTextView)
            let area = try #require(ed.textContainer)
            #expect(abs(area.size.width - ed.bounds.width) < 1, "\(name): wraps at \(area.size.width), box \(ed.bounds.width)")
            guard let dir else { return }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: name + ".png"))
        }
        spin(1)
        let ed = try #require(win.firstResponder as? NSTextView, "no editor")
        ed.insertText("Add some hook variations to each of the three posts please", replacementRange: ed.selectedRange())
        try shot("1-narrow")
        box.width = 600
        try shot("2-wide")
        for line in ["second line", "third line", "fourth line", "fifth line"] {
            ed.insertNewlineIgnoringFieldEditor(nil)
            ed.insertText(line, replacementRange: ed.selectedRange())
            spin(0.2)
        }
        try shot("3-lines")
        box.width = 300
        try shot("4-narrow-again")
    }
}

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
