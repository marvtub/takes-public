import AppKit
import SwiftUI
import Testing
@testable import Takes

/// The post previews follow the app's text size (⌘+ / ⌘−), like the rest of Takes (2026-10-05).
@MainActor
struct PreviewTextSizeTests {
    @Test func previewTypeGrowsWithTheTextSize() {
        let was = TextSize.shared.step
        defer { TextSize.shared.step = was }
        TextSize.shared.step = 0
        let small = (EditorLook.linkedin.font.pointSize, EditorLook.x.font.pointSize, EditorLook.youtube.font.pointSize)
        TextSize.shared.step = 2
        #expect(EditorLook.linkedin.font.pointSize > small.0)
        #expect(EditorLook.x.font.pointSize > small.1)
        #expect(EditorLook.youtube.font.pointSize > small.2)
        #expect(LinkedIn.lineHeight > 20)
    }

    /// The LinkedIn card at each text size, into TAKES_SNAP=<folder>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKES_SNAP"] != nil))
    func theCardAtEachTextSize() throws {
        let was = TextSize.shared.step
        defer { TextSize.shared.step = was }
        let dir = try #require(ProcessInfo.processInfo.environment["TAKES_SNAP"])
        for step in 0...2 {
            TextSize.shared.step = step
            let card = LinkedInCard(text: .constant("Legora just announced they went from $100M to $200M in 6 months.\nSo it's pretty clear that selling intelligence is becoming a great business."),
                                    media: nil, expanded: .constant(false), highlights: [], reveal: nil, focusToken: 0,
                                    onSelect: { _ in }, onComment: {}, onExpand: {})
                .frame(maxWidth: 555 * TextSize.shared.factor).padding(20)
            let view = NSHostingView(rootView: AnyView(card.background(Color.gray.opacity(0.2))))
            view.frame = NSRect(x: 0, y: 0, width: 760, height: 360)
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "card-\(step).png"))
            }
        }
    }
}
