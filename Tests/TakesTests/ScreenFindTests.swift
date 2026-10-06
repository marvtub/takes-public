import AppKit
import SwiftUI
import Testing
@testable import Takes

// ⌘F reads the window with Vision (2026-10-05). These pin down that a snapshot of SwiftUI text
// reads back, that boxes land on the word, and that case and accents don't count.

@MainActor
struct ScreenFindTests {
    private func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text("Approve the hook first, then the needle in the post")
            Text("Café needle and NEEDLE again")
            Text("nothing here")
        }.font(.system(size: 14)).frame(width: 500, height: 300))
        w.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return w
    }

    @Test func findsEveryMatchOnScreen() throws {
        let w = window()
        defer { w.close() }
        let view = try #require(w.contentView)
        let image = try #require(ScreenFind.snapshot(view))
        let lines = ScreenFind.read(image, size: view.bounds.size)
        let found = ScreenFind.matches(of: "needle", in: lines)
        #expect(found.count == 3)
        // Top to bottom, and each box sits inside the window, about one line high.
        #expect(found.map(\.minY) == found.map(\.minY).sorted())
        for r in found {
            #expect(view.bounds.contains(r))
            #expect(r.height > 8 && r.height < 30)
            #expect(r.width > 20 && r.width < 120)
        }
        #expect(ScreenFind.matches(of: "cafe", in: lines).count == 1)
        #expect(ScreenFind.matches(of: "   ", in: lines).isEmpty)
        #expect(ScreenFind.matches(of: "zebra", in: lines).isEmpty)
    }
}
