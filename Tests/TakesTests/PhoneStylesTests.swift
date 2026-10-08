import Foundation
import Testing
@testable import Takes

/// The phone's Styles board (PhoneStyles.swift), on a library in a temp folder.
@MainActor
struct PhoneStylesTests {
    /// Magazine (a guide, tokens, a logo in two versions, a font) and Bold (new, no preview);
    /// project Work picks Bold and has looks of its own; one video in Work has an edit.
    static func library() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "phone-styles-\(UUID().uuidString)")
        let mag = StyleLib.style("Magazine", root: root)
        try fm.createDirectory(at: mag.appending(path: "assets/logos"), withIntermediateDirectories: true)
        try fm.createDirectory(at: mag.appending(path: "fonts"), withIntermediateDirectories: true)
        try "# Magazine\n\nPaper pages and thin lines.".write(to: mag.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try ##"{"color": {"tokens": [{"name": "ink", "value": "#111111", "usage": "text"}]}, "type": {"families": {"serif": "Instrument Serif, serif"}, "groups": [{"family": "serif", "styles": [{"name": "Title", "fontSize": "40px", "fontWeight": 400}]}]}}"##
            .write(to: mag.appending(path: "tokens.json"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50]).write(to: mag.appending(path: "assets/logos/logo-v1.png"))
        try Data([0x89, 0x50]).write(to: mag.appending(path: "assets/logos/logo-v2.png"))
        try Data().write(to: mag.appending(path: "fonts/Serif.ttf"))
        try Data().write(to: mag.appending(path: "preview.png"))
        try #"{"assets/logos/logo-v2.png": {"note": "Use on dark"}}"#.write(to: mag.appending(path: "assets.json"), atomically: true, encoding: .utf8)
        let bold = StyleLib.style("Bold", root: root)
        try fm.createDirectory(at: bold, withIntermediateDirectories: true)
        try #"{"status": "new", "description": "Big type"}"#.write(to: bold.appending(path: "style.json"), atomically: true, encoding: .utf8)

        let work = root.appending(path: "Work")
        StyleLib.choose("Bold", project: work)
        try "Only here".write(to: StyleLib.project(work).appending(path: "README.md"), atomically: true, encoding: .utf8)
        let s = work.appending(path: "2026-10-08-demo")
        try fm.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        try Data().write(to: s.appending(path: "edits/cut-v1.mp4"))
        try Store.encoder.encode(SessionMeta(title: "Demo", createdAt: Date())).write(to: s.appending(path: "session.json"))
        return root
    }

    @Test func listsTheStylesWithTheirVideos() async throws {
        let root = try Self.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PhoneServer(root: root)
        let list = await server.styles()
        #expect(list.styles.map(\.name) == ["Bold", "Magazine"])
        #expect(list.styles[0].isNew && list.styles[0].description == "Big type" && list.styles[0].poster == nil)
        #expect(list.styles[0].usedBy == ["Work/2026-10-08-demo"])
        #expect(list.styles[1].poster?.hasSuffix("Magazine/preview.png") == true && list.styles[1].usedBy.isEmpty)
        #expect(list.projects == ["Work"])
    }

    @Test func oneStyleHasItsGuideTokensAndParts() async throws {
        let root = try Self.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PhoneServer(root: root)
        let dir = try #require(server.library("_library/styles/Magazine"))
        _ = CommentStore.addMedia(dir, file: "assets/logos/logo-v2.png", start: nil, end: nil, rect: nil, text: "Thinner")
        let d = await server.style(dir)
        #expect(d.id == "_library/styles/Magazine" && d.name == "Magazine")
        #expect(d.readme?.hasPrefix("# Magazine") == true && d.hasTokens)
        #expect(d.swatches == [PhoneSwatch(name: "ink", value: "#111111", usage: "text")])
        #expect(d.type.first?.family == "Instrument Serif" && d.type.first?.size == 40)
        #expect(d.fonts.count == 1 && d.fonts[0].hasSuffix("fonts/Serif.ttf"))
        let logo = try #require(d.groups.first { $0.name == "logos" }?.items.first)
        #expect(logo.name == "logo.png" && logo.versions.map(\.version) == [1, 2])
        #expect(logo.versions[1].note == "Use on dark" && logo.versions[1].openComments == 1 && d.openComments == 1)

        let own = try #require(server.library("Work/_library"))
        #expect(await server.style(own).name == "Only Work")
    }

    @Test func commentsGoToALibraryButNowhereElse() throws {
        let root = try Self.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PhoneServer(root: root)
        #expect(server.commentRoot("_library/styles/Magazine") != nil)
        #expect(server.commentRoot("Work/_library") != nil)
        #expect(server.commentRoot("Work/2026-10-08-demo") != nil)
        #expect(server.library("_library/styles/Magazine/assets") == nil)
        #expect(server.library("_library/styles/../../x") == nil)
        #expect(server.library("_library/styles/Gone") == nil)
        #expect(server.library("Work") == nil)
    }

    @Test func keepAndAVideosStyle() throws {
        let root = try Self.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = PhoneServer(root: root)
        _ = server.changeStyle(["action": "keep", "name": "Bold"])
        #expect(StyleLib.json(StyleLib.style("Bold", root: root).appending(path: "style.json"))["status"] == nil)

        let s = root.appending(path: "Work/2026-10-08-demo")
        var meta = try #require(Store.readMeta(s))
        #expect(PhoneServer.sessionStyle(s, meta: meta, root: root).own == nil)
        #expect(PhoneServer.sessionStyle(s, meta: meta, root: root).project == "Bold")
        _ = server.setStyle(["style": "Magazine"], in: s)
        meta = try #require(Store.readMeta(s))
        #expect(meta.style == "Magazine")
        _ = server.setStyle(["style": "Magazine", "project": "1"], in: s)
        meta = try #require(Store.readMeta(s))
        #expect(meta.style == nil && StyleLib.chosen(project: s.deletingLastPathComponent(), root: root) == "Magazine")
        _ = server.setStyle(["style": "Nope"], in: s)
        #expect(Store.readMeta(s)?.style == nil)
    }

    @Test func theStylesChatHasItsLane() {
        #expect(PhoneServer.lane("board:styles") == "styles")
        #expect(PhoneServer.origin(["text": "x", "from": "Styles"]).contains("Styles board"))
    }
}
