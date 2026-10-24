import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Takes

// 2026-09-27: dragging on the timeline always made a range comment. You drag to scrub, so a plain
// drag must only move the playhead. A range needs comment mode (C) or ⌥.

struct TimelineDragTests {
    @Test func plainDragScrubs() {
        #expect(!ReviewBar.picksRange(commentMode: false, modifiers: []))
        #expect(!ReviewBar.picksRange(commentMode: false, modifiers: [.shift]))
    }

    @Test func commentModeDragPicksRange() {
        #expect(ReviewBar.picksRange(commentMode: true, modifiers: []))
    }

    @Test func optionDragPicksRange() {
        #expect(ReviewBar.picksRange(commentMode: false, modifiers: [.option]))
    }
}

// Picking several files on the Assets tab.

struct AssetPickTests {
    let a = URL(fileURLWithPath: "/s/a.mp4"), b = URL(fileURLWithPath: "/s/b.mp4"), c = URL(fileURLWithPath: "/s/c.png")

    @Test func plainClickPicksOnlyThat() {
        #expect(AssetPick.click(b, picked: [a, c], anchor: a, command: false, shift: false) == [b])
    }

    @Test func commandClickAddsToLastClicked() {
        // Click a, then ⌘-click b: both.
        #expect(AssetPick.click(b, picked: [], anchor: a, command: true, shift: false) == [a, b])
        #expect(AssetPick.click(c, picked: [a, b], anchor: b, command: true, shift: false) == [a, b, c])
    }

    @Test func shiftClickAddsToo() {
        #expect(AssetPick.click(c, picked: [a], anchor: a, command: false, shift: true) == [a, c])
    }

    @Test func modifierClickRemovesPicked() {
        #expect(AssetPick.click(b, picked: [a, b], anchor: a, command: true, shift: false) == [a])
    }

    @Test func boxPicksTouchedTiles() {
        let frames = [a: CGRect(x: 0, y: 0, width: 100, height: 80),
                      b: CGRect(x: 120, y: 0, width: 100, height: 80),
                      c: CGRect(x: 0, y: 100, width: 100, height: 80)]
        let box = AssetPick.box(CGPoint(x: 150, y: 110), CGPoint(x: 50, y: 40))
        #expect(AssetPick.band(box, frames: frames, base: []) == [a, b, c])
        let small = AssetPick.box(CGPoint(x: 110, y: 10), CGPoint(x: 130, y: 20))
        #expect(AssetPick.band(small, frames: frames, base: [c]) == [b, c])
    }
}

// Idle cost: the camera and file polling were the big spenders.

struct IdleTests {
    // 2026-09-28: the app opens with the camera off. Record or "Turn camera on" starts it.
    @Test func cameraStartsPaused() {
        #expect(CameraRecorder().paused)
    }

    @Test func cameraStopsWhileAFilePlaysOverIt() {
        #expect(AppModel.holdsCamera(idle: true, preview: true, seen: true))
    }

    @Test func cameraStopsWhenNoWindowShowsIt() {
        #expect(AppModel.holdsCamera(idle: true, preview: false, seen: false))
    }

    @Test func cameraRunsWhenLive() {
        #expect(!AppModel.holdsCamera(idle: true, preview: false, seen: true))
    }

    // 2026-10-11: Assets and Sound hid the camera, but it and the mic meter kept running.
    @Test func assetsAndSoundCoverTheCameraUntilAFileOpens() {
        #expect(DetailView.covers("assets", previewing: false))
        #expect(DetailView.covers("sounds", previewing: false))
        #expect(!DetailView.covers("assets", previewing: true))
        #expect(!DetailView.covers("script", previewing: false))
    }

    @Test func recordingAndCountdownKeepTheCamera() {
        #expect(!AppModel.holdsCamera(idle: false, preview: true, seen: false))
    }

    @Test func playheadRate() {
        #expect(PlayerClock.interval(for: 0) == 1.0 / 30)
        #expect(PlayerClock.interval(for: 5) == 1.0 / 30)       // short clip: smooth
        #expect(PlayerClock.interval(for: 600) == 0.1)          // long video: tenths, no more
        #expect(PlayerClock.interval(for: 30) > 1.0 / 30 && PlayerClock.interval(for: 30) < 0.1)
    }

    @Test func fileChangesMatchTheirFolder() {
        let session = URL(fileURLWithPath: "/Movies/Takes/p/2026-09-27-x")
        #expect(FileWatch.touches(["/Movies/Takes/p/2026-09-27-x"], session))
        #expect(FileWatch.touches(["/Movies/Takes/p/2026-09-27-x/edits"], session))
        #expect(!FileWatch.touches(["/Movies/Takes/p/2026-09-27-xy"], session))
        #expect(!FileWatch.touches(["/Movies/Takes/p"], session))
    }

    @Test func chatSavesAreNotChanges() {
        let s = "/Movies/Takes/p/2026-09-27-x"
        #expect(FileWatch.folders([s + "/.claude-chat.json", s + "/.claude-chat.json.sb-aa06c7e4-H7mIXC"]).isEmpty)
        #expect(FileWatch.folders([s + "/script.md", s + "/edits/cut-v2.mp4"]) == [s, s + "/edits"])
        #expect(FileWatch.folders([s]) == ["/Movies/Takes/p"])  // a new session folder: its project changed
    }

    @Test func watcherSeesAWrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "takes-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watch = FileWatch()
        let start = Date()
        watch.watch(dir)
        // The stream starts on its own queue (a 99 s launch hang on 14 Oct); changes still come on main.
        #expect(Date().timeIntervalSince(start) < 1)
        let seen = Seen(), offMain = Seen()
        let token = NotificationCenter.default.addObserver(forName: .takesFilesChanged, object: nil, queue: nil) { n in
            guard FileWatch.touches(n, dir) else { return }
            Thread.isMainThread ? seen.hit() : offMain.hit()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        // The stream starts on its own queue, and fseventsd can take seconds to start it and to send
        // an event: one write 300 ms in was missed in about 1 run in 6 (2026-10-20). Write again
        // every half second and wait up to 20 s (one run needed 7 s on a busy Mac).
        for i in 0..<200 where !seen.value {
            if i % 5 == 0 { try Data("x\(i)".utf8).write(to: dir.appending(path: "comments.json")) }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(seen.value)
        #expect(!offMain.value)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func hit() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}

// 2026-09-28: after a comment was sent, the text field wrote its text back and opened the box again.

struct ComposerTests {
    @Test func sentDraftStaysClosed() {
        var draft: ReviewPlayer.Draft? = ReviewPlayer.Draft(text: "cut this")
        let b = Binding(get: { draft }, set: { draft = $0 })
        let composer = Composer.bind(b, ReviewPlayer.Draft())
        draft = nil                                   // sent
        composer.wrappedValue = ReviewPlayer.Draft(text: "cut this")  // late write-back
        #expect(draft == nil)
    }

    @Test func typingStillUpdatesTheDraft() {
        var draft: ReviewPlayer.Draft? = ReviewPlayer.Draft()
        let composer = Composer.bind(Binding(get: { draft }, set: { draft = $0 }), ReviewPlayer.Draft())
        composer.wrappedValue.text = "tighter"
        #expect(draft?.text == "tighter")
    }
}
