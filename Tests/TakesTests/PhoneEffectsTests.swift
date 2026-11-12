import Foundation
import Testing
@testable import Takes

/// The phone's Effects tab and @ list (PhoneStyles.swift, 2026-10-30): an effect of your own in
/// _library/effects, its files, and the note a phone message gets for an @ pick.
struct PhoneEffectsTests {
    let root: URL
    let server: PhoneServer
    let s: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "phone-effects-\(UUID().uuidString)")
        let fx = EffectLib.own(root: root).appending(path: "glow")
        try FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
        try Data(#"{"name": "Glow", "when": "For the big line", "kind": "Overlay", "shape": "any"}"#.utf8).write(to: fx.appending(path: "effect.json"))
        try Data("# Glow".utf8).write(to: fx.appending(path: "README.md"))
        s = root.appending(path: "Inbox/2026-10-30-tips")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: s.appending(path: "session.json"))
        server = PhoneServer(root: root, demo: true)
    }

    @Test func listsYourEffectAndServesOnlyItsFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let glow = try #require(server.effects().first { $0.slug == "glow" })
        #expect(glow.name == "Glow" && glow.kind == "Overlay" && glow.readme && !glow.poster)
        #expect(server.effectFile("glow", "README.md") != nil)
        #expect(server.effectFile("glow", "effect.json") == nil)
        #expect(server.effectFile("glow", "preview.png") == nil)
        #expect(server.effectFile("nope", "README.md") == nil)
    }

    @Test func anAtPickGetsTheMacsNote() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let row = try #require(server.mentions(s).first { $0.kind == "Effects" && $0.effect == "glow" })
        let note = server.mentionNote(row.id, text: "Add @Glow to the end", session: s)
        #expect(note.hasPrefix(Mentions.mark))
        #expect(note.contains("list_effects glow"))
        // A name taken out of the message before sending adds nothing.
        #expect(server.mentionNote(row.id, text: "Add it to the end", session: s).isEmpty)
        #expect(server.mentions(s).allSatisfy { $0.kind != Mention.Kind.asset.rawValue })
    }
}
