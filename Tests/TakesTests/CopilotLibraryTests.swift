import AppKit
import SwiftUI
import Testing
@testable import Takes

@MainActor
struct CopilotLibraryTests {
    @Test func tokensAreAboutFourCharactersEach() {
        #expect(TokenCount.of("") == 0)
        #expect(TokenCount.of("abcd") == 1)
        #expect(TokenCount.of(String(repeating: "a", count: 4000)) == 1000)
        #expect(TokenCount.label(850) == "850")
        #expect(TokenCount.label(2840) == "2.8k")
        #expect(TokenCount.label(17_000) == "17k")
    }

    @Test func theListHoldsTheFilesTheAgentReads() {
        let root = URL(fileURLWithPath: "/tmp/lib")
        let docs = CopilotDoc.all(root)
        #expect(docs.map(\.id) == ["lessons", "targets", "style", "best"])
        #expect(docs[0].url == CopilotStore.lessons(root))
        #expect(docs[1].url.lastPathComponent == "commenting-targets.md")
        #expect(docs[2].url.lastPathComponent == "comment-style-guide.md")
    }

    /// Renders the tab off screen and saves it as a PNG in TAKES_SNAP=<folder>, to look at. Only on
    /// request: its run-loop spin on the main thread made the sound-cue timer test miss its second.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKES_SNAP"] != nil))
    func theLibraryShowsTheListAndTheFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "copilot-lib-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: CopilotStore.folder(root), withIntermediateDirectories: true)
        try "# Comment lessons\n\n- Sound like a text message.\n- Never praise openers.\n"
            .write(to: CopilotStore.lessons(root), atomically: true, encoding: .utf8)
        let store = CopilotStore()
        store.scan(root)
        let app = AppModel()
        let view = NSHostingView(rootView: AnyView(CopilotLibrary(store: store).environment(app)
            .frame(width: 1000, height: 640).background(Theme.canvas)))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1000, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); view.layoutSubtreeIfNeeded() }
        let texts = Self.strings(view)
        #expect(texts.contains { $0.contains("Sound like a text message") })
        if let dir = ProcessInfo.processInfo.environment["TAKES_SNAP"], let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "copilot-library.png"))
        }
    }

    static func strings(_ v: NSView) -> [String] {
        var out: [String] = []
        if let t = v as? NSTextView { out.append(t.string) }
        for s in v.subviews { out += strings(s) }
        return out
    }
}
