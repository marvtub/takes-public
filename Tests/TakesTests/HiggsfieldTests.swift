import Foundation
import Testing
@testable import Takes

// Higgsfield in Takes (2026-10-06): the account line from `higgsfield account status`, and the
// storyboard fields the takes MCP writes while a clip is on its way.

struct HiggsfieldTests {
    @Test func theAccountLineSaysWhereSetupStands() {
        #expect(Higgsfield.state(ok: true, out: "me@example.com — Basic plan, 120 credits\n") == .ready("me@example.com — Basic plan, 120 credits"))
        #expect(Higgsfield.state(ok: false, out: "Error: Not authenticated.\nHint: higgsfield auth login") == .signedOut(nil))
        #expect(Higgsfield.state(ok: false, out: "Error: Session expired.") == .signedOut(nil))
        #expect(Higgsfield.state(ok: false, out: "Error: No workspace selected.\nHint: Run: higgsfield workspace set <id>") == .signedOut("No workspace selected."))
        #expect(Higgsfield.state(ok: false, out: "") == .signedOut(nil))
    }

    @Test func aShotShowsItsClipOnTheWay() throws {
        let json = #"{"shots": [{"id": "a1", "say": "Hi.", "sketch": "A desk.", "generating": "generated/shot-a1-v1.mp4"}, {"id": "b2", "sketch": "Cards.", "clip_error": "Session expired."}]}"#
        let b = try JSONDecoder().decode(Storyboard.self, from: Data(json.utf8))
        #expect(b.shots[0].generating == "generated/shot-a1-v1.mp4")
        #expect(b.shots[1].clipError == "Session expired.")
        #expect(b.shots[1].generating == nil)
    }

    @Test func theAsksNameTheShotAndTheFile() {
        let shot = StoryShot(id: "a1", say: "Hi.")
        #expect(Higgsfield.shotPrompt(shot).contains("shot=a1"))
        #expect(Higgsfield.changeDraft("edits/cut-v2.mp4") == "Change edits/cut-v2.mp4 with Higgsfield: ")
        #expect(Higgsfield.imageDraft("thumbnails/cover-v1.png") == "Change thumbnails/cover-v1.png with make_image: ")
    }

    @Test func aFileNamesTheModelThatMadeIt() throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "madewith-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        try Data(#"{"desk-v1.png": "Nano Banana 2.1"}"#.utf8).write(to: d.appending(path: ".models.json"))
        #expect(MadeWith.label(for: d.appending(path: "desk-v1.png")) == "Nano Banana 2.1")
        #expect(MadeWith.label(for: d.appending(path: "other.png")) == nil)
        #expect(MadeWith.label(for: FileManager.default.temporaryDirectory.appending(path: "none/x.png")) == nil)
    }
}
