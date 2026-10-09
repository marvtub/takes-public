import AppKit
import SwiftUI
import Testing
@testable import Takes

/// The What's new popover takes its size from the first layout. The list once measured its changes
/// a moment later, so the popover opened short and showed only the middle of the list (2026-10-08).
@MainActor struct WhatsNewSizeTests {
    private func log(_ n: Int) -> [Updater.Change] {
        (0..<n).map { i in
            Updater.Change.parse(subject: "Area \(i % 3): change number \(i) with a headline long enough to wrap onto a second line",
                                 body: "Detail for change \(i).", id: "c\(i)")
        }
    }

    private func firstAndSettled(_ n: Int) -> (CGSize, CGSize) {
        let v = WhatsNew(staged: Updater.Staged(stamp: "abc1234 Oct 8 13:00", changes: [], log: log(n)), updater: Updater.shared) {}
        let host = NSHostingView(rootView: v)
        let first = host.fittingSize
        host.frame = NSRect(origin: .zero, size: first)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (first, host.fittingSize)
    }

    @Test func theFirstLayoutIsAlreadyFullHeight() {
        for n in [1, 3, 8, 30] {
            let (first, settled) = firstAndSettled(n)
            #expect(abs(first.height - settled.height) < 1, "\(n) changes: first \(first.height), settled \(settled.height)")
        }
    }

    @Test func aLongListStopsAt560AndScrolls() {
        let (short, _) = firstAndSettled(1)
        let (long, _) = firstAndSettled(30)
        #expect(long.height > short.height)
        #expect(long.height < 560 + 200)
    }
}
