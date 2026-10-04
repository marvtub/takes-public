import Foundation
import Testing
@testable import Takes

// 2026-09-28: mark a session as published, then clean it up. By default only the newest edit stays.

struct PublishTests {
    func asset(_ group: String, _ name: String, age: Double, take: Bool = false) -> Asset {
        let rel = take ? name : "\(group)/\(name)"
        return Asset(url: URL(fileURLWithPath: "/s/\(rel)"), group: group, name: name, size: 10,
                     modified: Date(timeIntervalSince1970: 1_000_000 - age), take: take)
    }

    func take(_ n: Int, _ kind: TakeKind, keeper: Bool = false) -> Take {
        Take(number: n, kind: kind, file: "take-0\(n)-\(kind.rawValue).mov", startedAt: .now, keeper: keeper)
    }

    @Test func keepsOnlyTheNewestEdit() {
        let v2 = asset("edits", "hook-v2.mp4", age: 10)
        let all = [asset("edits", "hook-v1.mp4", age: 100), v2, asset("thumbnails", "hook-v3.png", age: 1),
                   asset("stills", "a.png", age: 5), asset("takes", "take-01-camera.mov", age: 500, take: true)]
        #expect(Cleanup.defaultKeep(all, takes: [take(1, .camera, keeper: true)]) == [v2.url])
    }

    @Test func withoutEditsKeepsTheStarredTake() {
        let t1 = asset("takes", "take-01-camera.mov", age: 50, take: true)
        let t1s = asset("takes", "take-01-screen.mov", age: 50, take: true)
        let t2 = asset("takes", "take-02-camera.mov", age: 5, take: true)
        let takes = [take(1, .camera, keeper: true), take(1, .screen, keeper: true), take(2, .camera)]
        #expect(Cleanup.defaultKeep([t1, t1s, t2], takes: takes) == [t1.url, t1s.url])
    }

    @Test func withoutEditsOrStarKeepsTheNewestTake() {
        let t1 = asset("takes", "take-01-camera.mov", age: 50, take: true)
        let t2 = asset("takes", "take-02-camera.mov", age: 5, take: true)
        #expect(Cleanup.defaultKeep([t1, t2], takes: [take(1, .camera), take(2, .camera)]) == [t2.url])
    }

    @Test func onePostPerPlatform() {
        let t = Date()
        var list = SessionDoc.adding(Post(platform: nil, at: t), to: [])
        list = SessionDoc.adding(Post(platform: "LinkedIn", at: t), to: list)
        #expect(list.map(\.platform) == ["LinkedIn"])  // "somewhere" became LinkedIn
        list = SessionDoc.adding(Post(platform: "X", at: t), to: list)
        list = SessionDoc.adding(Post(platform: "linkedin", url: "https://l.in/p", at: t), to: list)
        #expect(list.map(\.platform) == ["X", "linkedin"])
        #expect(list.last?.url == "https://l.in/p")
    }

    @Test func oldSessionFilesStillRead() throws {
        let json = #"{"createdAt":"2026-09-01T10:00:00Z","named":true,"takes":[],"title":"Old"}"#
        let m = try Store.decoder.decode(SessionMeta.self, from: Data(json.utf8))
        #expect(m.published == nil)
        let mcp = #"{"createdAt":"2026-09-01T10:00:00Z","named":true,"takes":[],"title":"New","published":[{"at":"2026-09-28T15:00:00Z","platform":"X"}]}"#
        let n = try Store.decoder.decode(SessionMeta.self, from: Data(mcp.utf8))
        #expect(n.published?.first?.platform == "X" && n.published?.first?.url == nil)
    }

    @MainActor @Test func cleanupTrashesPickedFilesAndTheirTranscripts() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "takes-cleanup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        for f in ["edits/hook-v1.mp4", "edits/hook-v1.words.json", "edits/hook-v2.mp4", "stills/a.png",
                  "take-01-camera.mov", "take-01-screen.mov"] {
            let u = dir.appending(path: f)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        let doc = SessionDoc(url: dir)
        doc.meta.takes = [Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: .now),
                          Take(number: 1, kind: .screen, file: "take-01-screen.mov", startedAt: .now)]
        doc.markPublished("LinkedIn")
        let store = AssetStore()
        store.scan(doc)
        let keep = Cleanup.defaultKeep(store.assets, takes: doc.meta.takes)
        #expect(keep.map(\.lastPathComponent) == ["hook-v2.mp4"])
        // Keep the camera file of take 1 too: the screen file goes, the camera file stays listed.
        let camera = store.assets.first { $0.name == "take-01-camera.mov" }!.url
        Cleanup.run(store.assets.filter { !keep.contains($0.url) && $0.url != camera }, in: doc)

        #expect(fm.fileExists(atPath: dir.appending(path: "edits/hook-v2.mp4").path))
        #expect(!fm.fileExists(atPath: dir.appending(path: "edits/hook-v1.mp4").path))
        #expect(!fm.fileExists(atPath: dir.appending(path: "edits/hook-v1.words.json").path))
        #expect(!fm.fileExists(atPath: dir.appending(path: "stills").path))  // empty folder removed
        #expect(fm.fileExists(atPath: dir.appending(path: "take-01-camera.mov").path))
        #expect(!fm.fileExists(atPath: dir.appending(path: "take-01-screen.mov").path))
        let saved = Store.readMeta(dir)!
        #expect(saved.takes.map(\.file) == ["take-01-camera.mov"])
        #expect(saved.published?.map(\.platform) == ["LinkedIn"])
        #expect(try String(contentsOf: dir.appending(path: "SESSION.md"), encoding: .utf8).contains("Published: LinkedIn ("))
    }

    @Test func markingAgainKeepsLinkAndNumbers() {
        let first = Date(timeIntervalSince1970: 1000)
        var old = Post(platform: "LinkedIn", url: "https://x.test/1", at: first)
        old.stats = [PostStat(at: first, impressions: 500, likes: 9)]
        let next = SessionDoc.adding(Post(platform: "linkedin", at: .now), to: [old])
        #expect(next.count == 1)
        #expect(next[0].at == first && next[0].url == "https://x.test/1" && next[0].latest?.reach == 500)
    }

    @Test func weeklyGainCountsOnlyNewReach() {
        let now = Date()
        var p = Post(platform: "LinkedIn", at: now.addingTimeInterval(-20 * 86400))
        p.stats = [PostStat(at: now.addingTimeInterval(-10 * 86400), impressions: 1000),
                   PostStat(at: now.addingTimeInterval(-1 * 86400), impressions: 1600)]
        var fresh = Post(platform: "X", at: now.addingTimeInterval(-2 * 86400))
        fresh.stats = [PostStat(at: now, views: 300)]
        let items = [p, fresh].map { PerfItem(session: URL(fileURLWithPath: "/s"), project: "P", title: "T", post: $0) }
        #expect(PerfBoard.gain(items, since: now.addingTimeInterval(-7 * 86400)) == 900)
        #expect(Num.short(12_400) == "12k" && Num.short(1_250) == "1.2k" && Num.short(nil) == "–")
    }

    @MainActor @Test func typedTakeNameIsSavedBeforeReturn() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "takes-name-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appending(path: "take-01-camera.mov"))
        let doc = SessionDoc(url: dir)
        doc.meta.takes = [Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: .now)]
        doc.nameTake(1, "Slow intro")
        // A restart now keeps the name, though the file has no slug yet.
        #expect(Store.readMeta(dir)?.takes.first?.name == "Slow intro")
        #expect(fm.fileExists(atPath: dir.appending(path: "take-01-camera.mov").path))
        doc.renameTake(1, to: "Slow intro")
        #expect(Store.readMeta(dir)?.takes.first?.file == "take-01-slow-intro-camera.mov")
    }

    @MainActor @Test func platformsSwitchOnAndOffOneByOne() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "takes-publish-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let doc = SessionDoc(url: dir)
        doc.setPublished("LinkedIn", true)
        doc.setPublished("X", true)
        #expect(doc.posts.map(\.platform) == ["LinkedIn", "X"])
        doc.setPublished("linkedin", false)
        #expect(doc.posts.map(\.platform) == ["X"])
        doc.setPublished("X", false)
        #expect(!doc.isPublished)
        #expect(Store.readMeta(dir)?.published == nil)
    }

    @Test func starredEditShowsOnThePost() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "takes-media-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        for f in ["edits/a-v1.mp4", "edits/a-v2.mp4"] {
            let u = dir.appending(path: f)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                             ofItemAtPath: dir.appending(path: "edits/a-v1.mp4").path)
        // No post yet: the star starts one.
        PostFile.pickMedia("edits/a-v1.mp4", in: dir)
        #expect(PostFile.read(dir)?.media == "edits/a-v1.mp4")
        #expect(PostFile.media(PostFile.read(dir), in: dir)?.lastPathComponent == "a-v1.mp4")
        PostFile.write(PostFile.Content(text: "Hello", meta: PostFile.read(dir)!.meta), to: dir)
        PostFile.pickMedia(nil, in: dir)
        #expect(PostFile.read(dir)?.text == "Hello")
        #expect(PostFile.media(PostFile.read(dir), in: dir)?.lastPathComponent == "a-v2.mp4")
    }

    /// One video on LinkedIn, another on X. X without its own pick shows LinkedIn's.
    @Test func eachPlatformPicksItsOwnMedia() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "takes-media-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        for f in ["edits/a-v1.mp4", "edits/b-v1.mp4", "edits/c-v1.mp4"] {
            let u = dir.appending(path: f)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        func shows(_ p: PostPlatform) -> String? { PostFile.media(PostFile.read(dir, p), in: dir, p)?.lastPathComponent }
        PostFile.pickMedia("edits/a-v1.mp4", in: dir, .linkedin)
        PostFile.write(PostFile.Content(text: "Tweet"), to: dir, .x)
        #expect(shows(.x) == "a-v1.mp4")
        PostFile.pickMedia("edits/b-v1.mp4", in: dir, .x)
        #expect(shows(.linkedin) == "a-v1.mp4")
        #expect(shows(.x) == "b-v1.mp4")
        #expect(PostFile.read(dir, .x)?.text == "Tweet")
        PostFile.pickMedia(nil, in: dir, .x)
        #expect(shows(.x) == "a-v1.mp4")
    }
}

struct PerfWatchTests {
    @Test func folderEventsThatChangeTheBoard() {
        let root = URL(fileURLWithPath: "/m/Takes")
        #expect(PerfBoard.matters(["/m/Takes/_library"], root: root))           // social.json
        #expect(PerfBoard.matters(["/m/Takes/Acme/2026-10-01-a"], root: root)) // a session.json
        #expect(PerfBoard.matters(["/m/Takes"], root: root))
        #expect(!PerfBoard.matters(["/m/Takes/Acme/2026-10-01-a/edits"], root: root))
        #expect(!PerfBoard.matters(["/other/_library"], root: root))
    }
}
