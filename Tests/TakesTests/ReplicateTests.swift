import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Takes

/// Plugins › Replicate (2026-10-09). The jobs themselves are tested in mcp/tests/test_replicate.py.
@MainActor @Suite(.serialized) struct ReplicateTests {
    @Test func aPastedLinkBecomesTheModelName() {
        #expect(Replicate.clean(" https://replicate.com/bytedance/seedance-2.5/ ") == "bytedance/seedance-2.5")
        #expect(Replicate.clean("kwaivgi/kling-v3.0") == "kwaivgi/kling-v3.0")
        #expect(Replicate.label("bytedance/seedance-2.5") == "Seedance 2.5")
        #expect(Replicate.label("kwaivgi/kling-v3.0") == "Kling V3.0")
    }

    @Test func aCardReadsTheCatalog() throws {
        let c = try #require(VideoModel(["model": "wan-video/wan-2.2-i2v-fast", "runs": 14_703_995,
                                             "video": "https://replicate.delivery/x/out.mp4"]))
        #expect(c.label == "Wan 2.2 I2V Fast")
        #expect(c.image == nil && c.video?.pathExtension == "mp4")
        #expect(Replicate.runs(14_703_995) == "14.7M runs")
        #expect(Replicate.runs(87_422) == "87K runs")
        #expect(VideoModel(["runs": 3]) == nil)
    }

    @Test func replicateMakesTheVideosOnceItsTokenIsIn() {
        let d = UserDefaults.standard
        let removed = d.string(forKey: Plugins.removedKey)
        let rep = Replicate.shared
        let was = rep.state
        defer { d.set(removed, forKey: Plugins.removedKey); rep.state = was }
        d.set("", forKey: Plugins.removedKey)
        rep.state = .noKey
        #expect(VideoMaker.current == .higgsfield)
        rep.state = .ready("Signed in as user")
        #expect(VideoMaker.current == .replicate)
        Plugins.setInstalled("replicate", false)
        #expect(VideoMaker.current == .higgsfield)
        Plugins.setInstalled("higgsfield", false)
        #expect(VideoMaker.current == nil)
        Plugins.setInstalled("replicate", true)
        rep.state = .noKey
        // Only Replicate on: ✦ shows and opens its setup.
        #expect(VideoMaker.current == .replicate)
    }

    @Test func theShotAskNeverUsesTheSketchAsTheFirstFrame() {
        var shot = StoryShot()
        shot.id = "s1"
        let ask = VideoMaker.replicate.shotPrompt(shot)
        #expect(ask.contains("replicate tool, shot=s1"))
        #expect(ask.contains("never as the first frame"))
        #expect(VideoMaker.replicate.changeDraft("generated/a-v1.mp4") == "Change generated/a-v1.mp4 with Replicate: ")
    }
}

// TAKES_REPLICATE_SHOT=/tmp/shots ./test.sh --filter ReplicateShots: Plugins › Replicate, set up and not.
// TAKES_REPLICATE_CATALOG=<takes_mcp.py --replicate catalog output> adds the model browser.
let replicateShotDir = ProcessInfo.processInfo.environment["TAKES_REPLICATE_SHOT"]

@MainActor @Suite(.serialized) struct ReplicateShots {
    @Test(.enabled(if: replicateShotDir != nil)) func pictures() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let d = UserDefaults.standard
        let picked = d.string(forKey: Plugins.pickedKey)
        defer { d.set(picked, forKey: Plugins.pickedKey) }
        d.set("replicate", forKey: Plugins.pickedKey)
        let app = AppModel()
        let rep = Replicate.shared
        for (name, connected) in [("replicate-setup", false), ("replicate-ready", true)] {
            let size = CGSize(width: 1100, height: connected ? 1900 : 760)
            let host = NSHostingView(rootView: AnyView(PluginsBoard().environment(app).tint(Theme.accent)
                .frame(width: size.width, height: size.height)))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            // The page's own check runs first (no server in tests); then the state to show.
            try await Task.sleep(for: .seconds(1))
            rep.state = connected ? .ready("Signed in as user") : .noKey
            rep.models = ["bytedance/seedance-2.5", "kwaivgi/kling-v3.0"]
            if connected, let f = ProcessInfo.processInfo.environment["TAKES_REPLICATE_CATALOG"],
               let d = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: f))) as? [String: Any] {
                rep.featured = (d["featured"] as? [[String: Any]] ?? []).compactMap(VideoModel.init)
                rep.popular = (d["popular"] as? [[String: Any]] ?? []).compactMap(VideoModel.init)
            }
            try await Task.sleep(for: .seconds(connected ? 6 : 0.6))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            window.orderOut(nil)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: replicateShotDir!).appending(path: "\(name).png"))
        }
        rep.state = .unknown
    }

    /// TAKES_HF_CATALOG and TAKES_MODEL_DETAILS (files with the MCP's output, from --higgsfield catalog
    /// and --replicate details): the Higgsfield page and a model's sheet.
    @Test(.enabled(if: replicateShotDir != nil && ProcessInfo.processInfo.environment["TAKES_HF_CATALOG"] != nil))
    func browserPictures() async throws {
        _ = NSApplication.shared
        let env = ProcessInfo.processInfo.environment
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..")
        for f in (try? FileManager.default.contentsOfDirectory(at: repo.appending(path: "assets/fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        func json(_ k: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: env[k]!))) as? [String: Any] ?? [:]
        }
        func shoot(_ name: String, _ view: some View, _ size: CGSize, wait: Double) async throws {
            let host = NSHostingView(rootView: AnyView(view.tint(Theme.accent).frame(width: size.width, height: size.height)))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            try await Task.sleep(for: .seconds(wait))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            window.orderOut(nil)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: replicateShotDir!).appending(path: "\(name).png"))
        }
        let d = UserDefaults.standard
        let picked = d.string(forKey: Plugins.pickedKey)
        defer { d.set(picked, forKey: Plugins.pickedKey) }
        d.set("higgsfield", forKey: Plugins.pickedKey)
        let hf = Higgsfield.shared
        let cat = try json("TAKES_HF_CATALOG")
        let host = Task { @MainActor in
            try await Task.sleep(for: .seconds(1))
            hf.state = .ready("me@example.com — plus plan, 657 credits")
            hf.featured = VideoModel.list(cat, "featured")
            hf.more = VideoModel.list(cat, "more")
            hf.defaultModel = "seedance_2_5"
        }
        try await shoot("higgsfield-models", PluginsBoard().environment(AppModel()), CGSize(width: 1100, height: 1500), wait: 7)
        _ = await host.result
        if env["TAKES_MODEL_DETAILS"] != nil {
            let det = try json("TAKES_MODEL_DETAILS")
            let card = try #require(VideoModel(det.merging(["url": det["page"] ?? NSNull()]) { a, _ in a }))
            try await shoot("model-sheet", ModelSheet(card: card, provider: "Replicate", load: { det }, action: {
                ModelAction(title: "Add", done: "Added", help: "") {}
            }), CGSize(width: 560, height: 720), wait: 6)
        }
        hf.state = .unknown
    }
}
