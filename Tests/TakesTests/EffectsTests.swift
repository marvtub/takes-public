import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Takes

/// Effects on the Styles board (EffectLib): the shipped ones, and yours over them.
struct EffectsTests {
    @Test func ownEffectWinsOverTheShippedOne() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "effects-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let shipped = tmp.appending(path: "shipped"), root = tmp.appending(path: "lib")
        func make(_ base: URL, _ slug: String, _ name: String) throws {
            let d = base.appending(path: slug)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try #"{"name": "\#(name)", "description": "d", "when": "w", "kind": "Overlay", "needs": ["a", "b"], "length_s": 6\#(slug == "glass-graph" ? #", "shape": "any""# : "")}"#.write(to: d.appending(path: "effect.json"), atomically: true, encoding: .utf8)
        }
        try make(shipped, "text-behind", "Text behind")
        try make(shipped, "glass-graph", "Glass graph")
        try make(EffectLib.own(root: root), "text-behind", "Mine")
        // A folder with no effect.json is not an effect.
        try fm.createDirectory(at: shipped.appending(path: "notes"), withIntermediateDirectories: true)

        let cards = EffectLib.cards(shipped: shipped, root: root)
        #expect(cards.map(\.slug) == ["glass-graph", "text-behind"])
        #expect(cards.map(\.name) == ["Glass graph", "Mine"])
        #expect(cards[0].video == nil && cards[0].when == "w")
        #expect(cards[0].kind == "Overlay" && cards[0].needs == ["a", "b"] && cards[0].seconds == 6)
        // "any" = it lays itself out for the video's frame; no shape = the old 9:16 ones.
        #expect(cards[0].shape == "any" && cards[1].shape == "9:16")
        #expect(cards[1].dir?.resolvingSymlinksInPath().path == EffectLib.own(root: root).appending(path: "text-behind").resolvingSymlinksInPath().path)
    }

    @Test func theAskNamesTheEffect() {
        let c = EffectCard(slug: "text-behind", name: "Text behind", description: "", when: "", video: nil, poster: nil)
        #expect(EffectLib.useAsk(c).contains("list_effects text-behind"))
    }
}

/// The Effects tab on the Styles board, light and dark, wide and in the narrow column beside a
/// player, from the effects in the repo.
@MainActor @Suite(.serialized) struct EffectsShots {
    @Test(.enabled(if: snapDir != nil)) func effectsSection() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let root = FileManager.default.temporaryDirectory.appending(path: "effects-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel()
        app.library.setRoot(root)
        for (dark, width) in [(false, 1100.0), (true, 1100.0), (false, 440.0)] {
            let size = CGSize(width: width, height: width > 500 ? 1300 : 1700)
            let view = EffectsSection(root: root, shipped: repo.appending(path: "effects"))
                .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.paper).environment(app)
            let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            let end = Date().addingTimeInterval(3.5)
            while Date() < end { try? await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: snapDir!).appending(path: "effects-section\(dark ? "-dark" : "")\(width < 500 ? "-narrow" : "").png"))
        }
    }
}
