import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Takes

@Suite struct CursorLogTests {
    /// Cocoa points (bottom-left of the main screen, y up) land on the .mov's pixels, top-left origin.
    @Test func pointsBecomeFramePixels() {
        // The main screen, 1512×982 points at 2x: its top-left is pixel 0,0; its bottom-right the frame's corner.
        let main = CursorMap(area: CGRect(x: 0, y: 0, width: 1512, height: 982), mainHeight: 982,
                             size: CGSize(width: 3024, height: 1964))
        #expect(main.pixel(CGPoint(x: 0, y: 982)) == CGPoint(x: 0, y: 0))
        #expect(main.pixel(CGPoint(x: 1512, y: 0)) == CGPoint(x: 3024, y: 1964))
        #expect(main.pixel(CGPoint(x: 100.5, y: 882)) == CGPoint(x: 201, y: 200))
        // A 1x display to the right of the main one, its top 200 points higher (CG y = -200).
        let side = CursorMap(area: CGRect(x: 1512, y: -200, width: 1920, height: 1080), mainHeight: 982,
                             size: CGSize(width: 1920, height: 1080))
        #expect(side.pixel(CGPoint(x: 1512, y: 1182)) == CGPoint(x: 0, y: 0))
        #expect(side.pixel(CGPoint(x: 1612, y: 1082)) == CGPoint(x: 100, y: 100))
        // A window recorded alone: its frame is the area, scaled to the frame size.
        let win = CursorMap(area: CGRect(x: 200, y: 100, width: 800, height: 600), mainHeight: 982,
                            size: CGSize(width: 1600, height: 1200))
        #expect(win.pixel(CGPoint(x: 600, y: 582)) == CGPoint(x: 800, y: 600))
    }

    /// Host times move to the video's clock: before the first frame only the last position and app
    /// stay, at 0; clicks before it go.
    @Test func timesStartAtTheFirstFrame() {
        let head = CursorEvents(source: "display", size: [3024, 1964], scale: 2, fps: 60)
        let e = CursorLog.events(head, raw: (
            moves: [(99.0, CGPoint(x: 1, y: 1)), (99.5, CGPoint(x: 2, y: 2)), (100.25, CGPoint(x: 3.04, y: 4.06))],
            clicks: [(99.9, CGPoint(x: 2, y: 2), "left", true), (101.0, CGPoint(x: 3, y: 4), "left", true),
                     (101.1234, CGPoint(x: 3, y: 4), "left", false)],
            apps: [(98.0, "com.a", "A"), (99.0, "com.b", "B"), (102.0, "com.c", "C")]), start: 100)
        #expect(e.moves == [[0, 2, 2], [0.25, 3, 4.1]])
        #expect(e.clicks.map(\.t) == [1, 1.123])
        #expect(e.clicks.map(\.down) == [true, false])
        #expect(e.apps.map(\.id) == ["com.b", "com.c"])
        #expect(e.apps.map(\.t) == [0, 2])
    }

    /// The JSON other tools read: these keys, moves as [t, x, y].
    @Test func jsonShape() throws {
        var e = CursorEvents(source: "window", size: [1600, 1200], scale: 2, fps: 60)
        e.moves = [[0, 10, 20]]
        e.clicks = [.init(t: 1.5, x: 10, y: 20, button: "right", down: true)]
        e.apps = [.init(t: 0, id: "com.apple.Safari", name: "Safari")]
        let o = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        #expect(Set(o.keys) == ["v", "clock", "source", "size", "scale", "fps", "moves", "clicks", "apps", "pointer"])
        #expect(o["pointer"] as? Bool == true)  // no arrow: the video keeps its pointer
        #expect(o["v"] as? Int == 1 && o["clock"] as? String == "video" && o["size"] as? [Int] == [1600, 1200])
        #expect(o["moves"] as? [[Double]] == [[0, 10, 20]])
        let c = try #require((o["clicks"] as? [[String: Any]])?.first)
        #expect(Set(c.keys) == ["t", "x", "y", "button", "down"])
        #expect(c["button"] as? String == "right" && c["down"] as? Bool == true)
        #expect((o["apps"] as? [[String: Any]])?.first?["id"] as? String == "com.apple.Safari")
    }

    /// 2026-10-30: the system arrow for drawing the pointer back. Without it the video keeps its pointer.
    @MainActor @Test func theArrowCanBeDrawn() throws {
        _ = NSApplication.shared
        let a = try #require(CursorLog.arrow())
        #expect(a.size[0] > 10 && a.size[1] > 10 && a.zoom >= 1)
        #expect(a.hot[0] >= 0 && a.hot[0] < a.size[0])
        #expect(NSImage(data: try #require(Data(base64Encoded: a.png))) != nil)
    }

    /// The stage draws the arrow with its hot spot on the logged point, in the video's place in the view.
    @Test func theStageMapsTheArrow() throws {
        let png = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))
        var e = CursorEvents(source: "display", size: [400, 200], scale: 2, fps: 60)
        e.moves = [[0, 100, 50], [1, 300, 150]]
        #expect(PointerTrack.make(e) == nil)  // the video has its pointer: nothing to draw
        e.pointer = false
        e.arrow = .init(png: png.base64EncodedString(), hot: [5, 5], size: [20, 30], zoom: 1)
        let t = try #require(PointerTrack.make(e))
        #expect(t.at(0.5) == CGPoint(x: 100, y: 50) && t.at(1) == CGPoint(x: 300, y: 150))
        // The video at half size, 10 pt from the left and bottom of the view.
        let f = t.frame(at: 0.5, in: CGRect(x: 10, y: 10, width: 200, height: 100))
        #expect(f == CGRect(x: 10 + (100 - 10) * 0.5, y: 110 - (50 - 10 + 60) * 0.5, width: 20, height: 30))
    }

    /// 2026-10-30: shortcuts and special keys only, never typing; modifiers in Apple's order.
    @Test func keysAreShortcutsNotTyping() {
        func l(_ code: Int, _ mods: String = "", _ key: String? = nil) -> String? {
            KeyLog.label(code: code, command: mods.contains("c"), option: mods.contains("o"), control: mods.contains("t"),
                         shift: mods.contains("s"), key: key)
        }
        #expect(l(kVK_ANSI_K, "", "k") == nil)
        #expect(l(kVK_ANSI_K, "s", "k") == nil)  // ⇧ alone is typing a capital
        #expect(l(kVK_Space, "", " ") == nil)
        #expect(l(kVK_ANSI_K, "c", "k") == "⌘K")
        #expect(l(kVK_ANSI_K, "tosc", "k") == "⌃⌥⇧⌘K")
        #expect(l(kVK_Space, "c", " ") == "⌘Space")
        #expect(l(kVK_Return) == "↩" && l(kVK_Escape) == "⎋" && l(kVK_Tab) == "⇥" && l(kVK_Delete) == "⌫")
        #expect(l(kVK_LeftArrow) == "←" && l(kVK_F5) == "F5")
        #expect(l(kVK_Tab, "c") == "⌘⇥")
    }

    /// 2026-11-02: typing is kept only as runs (start, end); keys under 1.5 s apart are one run.
    @Test func typingIsRunsNotKeys() {
        var r: [[Double]]? = []
        for t in [10.0, 10.2, 11.0, 12.4, 14.5, 14.6] { r = CursorLog.typed(r, at: t) }
        #expect(r == [[10, 12.4], [14.5, 14.6]])
        #expect(CursorLog.typed(nil, at: 1) == nil)  // ⌨ off: nothing
    }

    /// 2026-10-30: each move gets the cursor's look at its time; the stage switches looks with it.
    @Test func shapesFollowTheMoves() throws {
        #expect(CursorLog.shapes(at: [0, 1, 2, 3], [(1, 2), (2.5, 0)]) == [0, 2, 2, 0])
        let png = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:])).base64EncodedString()
        var e = CursorEvents(source: "display", size: [400, 200], scale: 2, fps: 60)
        e.pointer = false
        e.arrow = .init(png: png, hot: [5, 5], size: [20, 30], zoom: 1)
        e.shapes = [e.arrow!, .init(png: png, hot: [12, 11], size: [23, 22], zoom: 1)]
        e.moves = [[0, 100, 50, 0], [1, 100, 50, 1], [2, 100, 50, 9]]
        let t = try #require(PointerTrack.make(e))
        #expect(t.look(at: 0.5).box == CGRect(x: -10, y: -10, width: 40, height: 60))
        #expect(t.look(at: 1.5).box == CGRect(x: -24, y: -22, width: 46, height: 44))
        #expect(t.look(at: 2.5).box.width == 40)  // an id the log does not have: the arrow
    }

    /// It sits next to the screen file, so a rename and the trash carry it along.
    @Test func fileSitsNextToTheScreenFile() {
        let v = URL(fileURLWithPath: "/s/take-03-demo-screen.mov")
        #expect(CursorLog.file(for: v).lastPathComponent == "take-03-demo-screen.events.json")
    }
}
