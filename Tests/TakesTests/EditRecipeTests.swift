import AppKit
import AVFoundation
import CoreText
import Foundation
import SwiftUI
import Testing
@testable import Takes

/// Edit recipes (2026-10-11): edits/<name>-vN.recipe.json beside each version, written by the MCP's
/// publish_edit. The app hides the file and the _edit/ folder, shows the note under the edit, and the
/// Cover button keeps the recipe's cover from stacking.
struct EditRecipeTests {
    private func session() throws -> URL {
        let s = FileManager.default.temporaryDirectory.appending(path: "recipe-\(UUID().uuidString)/P/2026-10-11-a")
        try FileManager.default.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: s.appending(path: "session.json"))
        return s
    }

    private func clean(_ s: URL) { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }

    private func write(_ json: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    @Test func assetsAndSearchHideRecipesAndWorkingFiles() async throws {
        let s = try session()
        defer { clean(s) }
        try Data().write(to: s.appending(path: "edits/hook-v1.mp4"))
        try write(["note": "First cut."], s.appending(path: "edits/hook-v1.recipe.json"))
        try FileManager.default.createDirectory(at: s.appending(path: "_edit/hook/.versions/v1"), withIntermediateDirectories: true)
        try Data().write(to: s.appending(path: "_edit/hook/hook-layer.mp4"))
        let files = AssetStore.walk(s, takeFiles: []).map(\.rel)
        #expect(files == ["edits/hook-v1.mp4"])
        let hits = await MediaSearch.byName("hook", root: s.deletingLastPathComponent().deletingLastPathComponent(), limit: 10)
        #expect(hits.map(\.path.lastPathComponent) == ["hook-v1.mp4"])
    }

    @Test func noteReadsTheRecipe() throws {
        let s = try session()
        defer { clean(s) }
        let v = s.appending(path: "edits/hook-v2.mp4")
        #expect(EditRecipe.note(for: v) == nil)
        try write(["note": "Music softer."], EditRecipe.url(for: v))
        #expect(EditRecipe.url(for: v).lastPathComponent == "hook-v2.recipe.json")
        #expect(EditRecipe.note(for: v) == "Music softer.")
        let bad = s.appending(path: "edits/hook-v3.mp4")
        try Data("{not json".utf8).write(to: EditRecipe.url(for: bad))
        #expect(EditRecipe.note(for: bad) == nil)
    }

    @Test func coverVersionWritesItsRecipe() throws {
        let s = try session()
        defer { clean(s) }
        let src = s.appending(path: "edits/hook-v2.mp4"), out = s.appending(path: "edits/hook-v3.mp4")
        try write(["name": "hook", "edit": "edits/hook-v2.mp4", "note": "Old.", "commands": [["ffmpeg"]],
                   "render_id": "job-1", "cover": ["image": "thumbnails/a.png", "seconds": 0.1], "music": []],
                  EditRecipe.url(for: src))
        EditRecipe.withCover(source: src, image: "thumbnails/hook-v4.png", out: out, session: s)
        let r = try #require(EditRecipe.read(out))
        #expect(r["parent"] as? String == "edits/hook-v2.mp4")
        #expect(r["edit"] as? String == "edits/hook-v3.mp4")
        #expect(r["by"] as? String == "app")
        #expect(r["note"] as? String == "New cover: thumbnail hook-v4")
        #expect((r["cover"] as? [String: Any])?["image"] as? String == "thumbnails/hook-v4.png")
        #expect(r["commands"] == nil && r["render_id"] == nil)
        #expect(r["music"] != nil)
        EditRecipe.withCover(source: out, image: nil, out: s.appending(path: "edits/hook-v4.mp4"), session: s)
        let off = try #require(EditRecipe.read(s.appending(path: "edits/hook-v4.mp4")))
        #expect(off["cover"] is NSNull)
        #expect(off["note"] as? String == "Cover removed")
        // No recipe at the source: the app does not know how it was made, so it writes none.
        EditRecipe.withCover(source: s.appending(path: "edits/other-v1.mp4"), image: "x.png",
                             out: s.appending(path: "edits/other-v2.mp4"), session: s)
        #expect(!FileManager.default.fileExists(atPath: s.appending(path: "edits/other-v2.recipe.json").path))
    }

    @Test func versionsAndSidecarsCountTheRecipe() throws {
        let s = try session()
        defer { clean(s) }
        try Data().write(to: s.appending(path: "edits/hook-v2.mp4"))
        try write(["render_id": "job-1"], s.appending(path: "edits/hook-v3.recipe.json"))  // publish_edit's claim
        #expect(Cover.next(after: s.appending(path: "edits/hook-v2.mp4")).lastPathComponent == "hook-v4.mp4")
        try write(["note": "x"], s.appending(path: "edits/hook-v2.recipe.json"))
        #expect(Cleanup.sidecars(of: s.appending(path: "edits/hook-v2.mp4")).map(\.lastPathComponent) == ["hook-v2.recipe.json"])
    }

    @Test func exportsHideAndGoWithTheirVersion() throws {
        let s = try session()
        defer { clean(s) }
        let v = s.appending(path: "edits/hook-v2.mp4")
        try Data().write(to: v)
        #expect(!EditRecipe.canExport(v, group: "edits"))  // no recipe, no cut list
        try write(["note": "x"], EditRecipe.url(for: v))
        #expect(EditRecipe.canExport(v, group: "edits"))
        #expect(!EditRecipe.canExport(v, group: "generated"))
        for ext in ["fcpxml", "premiere.xml", "edl"] { try Data().write(to: s.appending(path: "edits/hook-v2.\(ext)")) }
        try Data().write(to: s.appending(path: "notes.edl"))  // not next to a version: a file of his own, shown
        #expect(EditRecipe.exportURL(for: v).lastPathComponent == "hook-v2.fcpxml")
        #expect(Set(AssetStore.walk(s, takeFiles: []).map(\.rel)) == ["edits/hook-v2.mp4", "notes.edl"])
        #expect(Cleanup.sidecars(of: v).map(\.lastPathComponent)
                == ["hook-v2.recipe.json", "hook-v2.fcpxml", "hook-v2.premiere.xml", "hook-v2.edl"])
    }

    @Test func exportAnswerAndToast() {
        let s = URL(fileURLWithPath: "/lib/P/2026-10-18-a")
        let done = EditRecipe.exported(["fcpxml": "edits/hook-v2.fcpxml", "left_out": ["the cover"]], session: s)
        #expect(done == .done(s.appending(path: "edits/hook-v2.fcpxml")))
        #expect(EditRecipe.toast(done) == "Exported hook-v2.fcpxml for Resolve / Premiere")
        let bad = EditRecipe.exported(["error": "edits/old-v1.mp4 has no recipe, so Takes does not know its cut."], session: s)
        #expect(EditRecipe.toast(bad) == "Takes could not export it. edits/old-v1.mp4 has no recipe, so Takes does not know its cut.")
        #expect(EditRecipe.exported([:], session: s) == .failed("The export gave no answer."))
        #expect(!EditRecipe.toast(bad).contains("Claude"))
        #expect(EditRecipe.toastIcon(done) == "checkmark" && EditRecipe.toastIcon(bad) == "exclamationmark.triangle")
    }

    /// Runs ffmpeg: a version whose recipe baked a red cover; a new cover replaces it, No cover cuts it off.
    @Test func coverOnARecipeVersionReplacesItAndRemoveCutsItOff() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { return }
        let s = try session()
        defer { clean(s) }
        try FileManager.default.createDirectory(at: s.appending(path: "thumbnails"), withIntermediateDirectories: true)
        let v1 = s.appending(path: "edits/a-v1.mp4")
        let parts = s.appending(path: "parts.txt")
        try sh(["-f", "lavfi", "-i", "color=red:s=360x640:r=30:d=0.1", "-c:v", "libx264", "-pix_fmt", "yuv420p", s.appending(path: "c.mp4").path])
        try sh(["-f", "lavfi", "-i", "color=blue:s=360x640:r=30:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", s.appending(path: "b.mp4").path])
        try Data("file 'c.mp4'\nfile 'b.mp4'\n".utf8).write(to: parts)
        try sh(["-f", "concat", "-safe", "0", "-i", parts.path, "-c", "copy", v1.path])
        try write(["name": "a", "edit": "edits/a-v1.mp4", "cover": ["image": "thumbnails/red.png", "seconds": 0.1]], EditRecipe.url(for: v1))
        let green = s.appending(path: "thumbnails/green.png")
        try sh(["-f", "lavfi", "-i", "color=green:s=360x640", "-frames:v", "1", green.path])
        PostFile.write(PostFile.Content(text: "Vertical", media: "edits/a-v1.mp4"), to: s, .vertical)
        var c = try #require(PostFile.read(s, .vertical))
        c.meta["cover"] = "thumbnails/red.png"
        PostFile.write(c, to: s, .vertical)

        let out = try await Cover.use(green, on: .vertical)
        #expect(out.lastPathComponent == "a-v2.mp4")
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(d - 1.1) < 0.08)  // the old 0.1 s cover went, the new one came: not 1.2
        let post = try #require(PostFile.read(s, .vertical))
        #expect(post.media == "edits/a-v2.mp4" && post.meta["cover_from"] == nil && post.meta["media_by"] == "takes")
        #expect((EditRecipe.read(out)?["cover"] as? [String: Any])?["image"] as? String == "thumbnails/green.png")

        try await Cover.remove(from: s, .vertical)
        let after = try #require(PostFile.read(s, .vertical))
        #expect(after.media == "edits/a-v3.mp4" && after.meta["cover"] == nil)
        let d3 = try await AVURLAsset(url: s.appending(path: "edits/a-v3.mp4")).load(.duration).seconds
        #expect(abs(d3 - 1.0) < 0.08)
        #expect(EditRecipe.read(s.appending(path: "edits/a-v3.mp4"))?["cover"] is NSNull)
    }

    @Test func aPickByTheUserHasNoMediaBy() throws {
        let s = try session()
        defer { clean(s) }
        var c = PostFile.Content(text: "Hi", media: "edits/a-v1.mp4")
        c.meta["media_by"] = "takes"
        PostFile.write(c, to: s)
        PostFile.pickMedia("edits/a-v2.mp4", in: s)
        let after = try #require(PostFile.read(s))
        #expect(after.media == "edits/a-v2.mp4" && after.meta["media_by"] == nil)
    }

    @Test func jobRowSaysTheStage() {
        let now = Date()
        var j = Job(id: "job-1", label: "New version of hook", outputs: ["_edit/renders/job-1.mp4"], fromChat: true,
                    status: .running, started: now.addingTimeInterval(-20), isGenerate: false,
                    folder: URL(fileURLWithPath: "/tmp/s/.jobs"), stage: "Mixing the sound")
        #expect(JobBoard.line(j, now: now) == "Mixing the sound")
        j.progress = 0.5
        #expect(JobBoard.line(j, now: now) == "Mixing the sound · 50%")
        j.status = .done
        j.stage = "Ready. Takes checks it before it saves it."
        #expect(JobBoard.line(j, now: now) == "Ready. Takes checks it before it saves it.")
        #expect(JobBoard.note(for: [j]).contains("publish_edit render=job-1"))
        let raw = Data(#"{"id": "job-1", "status": "running", "stage": "Cutting the takes"}"#.utf8)
        #expect(Job.decode(raw, folder: URL(fileURLWithPath: "/tmp/s/.jobs"), generate: false)?.stage == "Cutting the takes")
    }

    private func sh(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
}

/// The edit tile's right-click menu with Export for Resolve / Premiere, and its toasts, in light and dark:
/// `TAKES_SNAPSHOT=/some/dir ./test.sh --filter ExportMenuSnapshot`.
@MainActor
struct ExportMenuSnapshotTests {
    @Test func exportRowAndToasts() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        @MenuBuilder func rows() -> [MenuItem] {
            MenuButton("Show in Player", icon: "play.rectangle") {}
            MenuGroup("Use in Post", icon: "rectangle.stack") { MenuButton("LinkedIn post") {} }
            EditRecipe.exportRow {}
            MenuButton("Open", icon: "arrow.up.forward.app") {}
            MenuButton("Reveal in Finder", icon: "folder") {}
            MenuButton("Copy Path", icon: "doc.on.doc") {}
            MenuDivider()
            MenuButton("Move to Trash", icon: "trash", danger: true) {}
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let st = MenuState()
            st.highlight = "b:" + EditRecipe.exportTitle
            let s = URL(fileURLWithPath: "/lib/P/a")
            let v = HStack(alignment: .top, spacing: 28) {
                TakesMenuList(content: rows, state: st)
                VStack(alignment: .leading, spacing: 14) {
                    StagePill(text: "Exporting hook-v4 for Resolve / Premiere", icon: EditRecipe.exportingIcon, accent: true)
                    ForEach([EditRecipe.Exported.done(s.appending(path: "edits/hook-v4.fcpxml")), .failed("No edit hook-v9 here.")],
                            id: \.self) { e in
                        StagePill(text: EditRecipe.toast(e), icon: EditRecipe.toastIcon(e), accent: true)
                    }
                }
            }
            .padding(30).background(Theme.canvas)
            .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let cg = try #require(r.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "export-menu-\(name).png"))
        }
    }
}

/// Edit tiles with and without a note: the same height. Off by default:
/// `TAKES_SNAPSHOT=/some/dir ./test.sh --filter EditTileSnapshot`.
@MainActor
struct EditTileSnapshotTests {
    /// Edit tiles with and without a note, to look at: `TAKES_SNAPSHOT=/dir ./test.sh --filter editTiles`.
    @Test func editTilesSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let tile = { (note: String?) in
            AssetTile(asset: Asset(url: URL(fileURLWithPath: "/nowhere/edits/hook-v\(note == nil ? 1 : 2).mp4"), group: "edits",
                                   name: "hook-v\(note == nil ? 1 : 2).mp4", size: 1, modified: Date()),
                      selected: false, note: note)
                .frame(width: 200)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let v = HStack(alignment: .top, spacing: 16) { tile(nil); tile("Music softer. Cut the restart at 0:41.") }
                .padding(24).background(Theme.paper)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let cg = try #require(r.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "edit-tiles-\(name).png"))
        }
    }
}
