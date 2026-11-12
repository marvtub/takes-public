import AppKit
import SwiftUI
import Testing
@testable import Takes

// The Assets list in the Record column stays mounted from one session to the next (2026-11-06).
@MainActor @Suite struct AssetsPaneTests {
    /// Two sessions with enough edits to scroll.
    func sessions() throws -> (URL, [SessionDoc]) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "assetspane-\(UUID())")
        var docs: [SessionDoc] = []
        for name in ["2026-11-01-one", "2026-11-02-two"] {
            let url = root.appending(path: "Proj/\(name)")
            try fm.createDirectory(at: url.appending(path: "edits"), withIntermediateDirectories: true)
            let doc = SessionDoc(url: url)
            doc.meta = SessionMeta(title: name, createdAt: Date(), named: true)
            doc.save()
            for k in 0..<24 { fm.createFile(atPath: url.appending(path: "edits/clip-v\(k + 1).mp4").path, contents: Data()) }
            docs.append(doc)
        }
        return (root, docs)
    }

    struct Column: View {
        @Bindable var pick: Pick
        var body: some View { AssetsPane(doc: pick.doc).frame(width: 340, height: 300) }
    }

    @Observable final class Pick { var doc: SessionDoc; init(_ d: SessionDoc) { doc = d } }

    static func scrollViews(_ v: NSView) -> [NSScrollView] {
        let mine: [NSScrollView] = (v as? NSScrollView).map { [$0] } ?? []
        return mine + v.subviews.flatMap { scrollViews($0) }
    }

    @Test func aNewSessionOpensAtTheTop() throws {
        let (root, docs) = try sessions()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = UserDefaults.standard
        let folded = d.string(forKey: "assets.folded")
        defer { d.set(folded, forKey: "assets.folded") }
        d.set("", forKey: "assets.folded")
        let app = AppModel()
        let pick = Pick(docs[0])
        let host = NSHostingView(rootView: Column(pick: pick).environment(app))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 340, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func settle() { for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded() } }
        // Four edits show (the first few), taller than the column.
        for _ in 0..<50 where Self.scrollViews(host).isEmpty { settle() }
        let scroll = try #require(Self.scrollViews(host).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 })
        scroll.documentView?.scroll(NSPoint(x: 0, y: 300))
        settle()
        #expect(scroll.contentView.bounds.origin.y > 0)
        pick.doc = docs[1]
        settle()
        let now = try #require(Self.scrollViews(host).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 })
        #expect(now.contentView.bounds.origin.y == 0)
    }

    @Test func onlyTheNewestReadLands() {
        let reads = NewestRead()
        let first = reads.begin()   // the last session's read, still on its way
        let second = reads.begin()  // the new session's
        #expect(!reads.isNewest(first))
        #expect(reads.isNewest(second))
    }
}
