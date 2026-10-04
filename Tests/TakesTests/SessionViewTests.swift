import Foundation
import Testing
@testable import Takes

// 2026-10-02: each session opens on the tab and the file it showed last.

struct SessionViewTests {
    @Test func keepsTabFileAndTimePerSession() {
        let a = URL(fileURLWithPath: "/tmp/takes-view-\(UUID().uuidString)/p/a")
        let b = URL(fileURLWithPath: "/tmp/takes-view-\(UUID().uuidString)/p/b")
        defer {
            var all = UserDefaults.standard.dictionary(forKey: SessionView.key) ?? [:]
            all[a.path] = nil; all[b.path] = nil
            UserDefaults.standard.set(all, forKey: SessionView.key)
        }
        SessionView.write(a, mode: .assets, file: a.appending(path: "edits/cut-v2.mp4"), time: 12.5)
        SessionView.write(b, mode: .post, file: nil, time: nil)

        let va = SessionView.read(a)
        #expect(va.mode == .assets)
        #expect(va.file?.path == a.appending(path: "edits/cut-v2.mp4").path)
        #expect(va.time == 12.5)
        let vb = SessionView.read(b)
        #expect(vb.mode == .post)
        #expect(vb.file == nil)

        // The file is kept relative to the session folder.
        let raw = (UserDefaults.standard.dictionary(forKey: SessionView.key)?[a.path] as? [String: Any])?["file"] as? String
        #expect(raw == "edits/cut-v2.mp4")
        // A session never seen opens on Record.
        #expect(SessionView.read(URL(fileURLWithPath: "/tmp/nowhere")).mode == .record)
    }
}

// 2026-10-03: the tabs kept mounted belong to one session. A switch must not build the old
// session's panes for the new one.
struct KeptTabsTests {
    @Test func tabsOfAnotherSessionDoNotCount() {
        let a = URL(fileURLWithPath: "/tmp/p/a"), b = URL(fileURLWithPath: "/tmp/p/b")
        var k = KeptTabs()
        k.open("assets", in: a)
        k.open("post", in: a)
        #expect(k.on(a) == ["assets", "post"])
        #expect(k.on(b).isEmpty)
        // Opening a tab in another session starts a new set.
        k.open("sounds", in: b)
        #expect(k.on(b) == ["sounds"])
        #expect(k.on(a).isEmpty)
    }
}
