import Foundation
import Testing
import SwiftUI
import AppKit
@testable import Takes

// 2026-09-28: the post tab shows the LinkedIn post Claude wrote (MCP set_post) as a feed post.

struct PostTests {
    let session: URL

    init() throws {
        session = FileManager.default.temporaryDirectory.appending(path: "takes-post-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session.appending(path: "edits"), withIntermediateDirectories: true)
    }

    private func touch(_ rel: String, age: TimeInterval) throws {
        let u = session.appending(path: rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: u)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
    }

    @Test func readsWhatTheServerWrites() throws {
        #expect(PostFile.read(session) == nil)
        try FileManager.default.createDirectory(at: session.appending(path: "posts"), withIntermediateDirectories: true)
        try "---\nmedia: edits/a-v2.mp4\n---\nHook.\n\nBody.\n".write(to: PostFile.url(session), atomically: true, encoding: .utf8)
        #expect(PostFile.read(session) == PostFile.Content(text: "Hook.\n\nBody.\n", media: "edits/a-v2.mp4"))
    }

    @Test func writeKeepsThePickedMedia() {
        PostFile.write(.init(text: "New text\n", media: "edits/a-v2.mp4"), to: session)
        #expect(PostFile.read(session) == PostFile.Content(text: "New text\n", media: "edits/a-v2.mp4"))
        PostFile.write(.init(text: "Plain\n", media: nil), to: session)
        #expect((try? String(contentsOf: PostFile.url(session), encoding: .utf8)) == "Plain\n")
    }

    @Test func mediaIsThePickOrTheNewestEdit() throws {
        #expect(PostFile.media(nil, in: session) == nil)
        try touch("thumbnails/a-v1.png", age: 1)
        #expect(PostFile.media(nil, in: session)?.lastPathComponent == "a-v1.png")
        try touch("edits/a-v1.mp4", age: 100)
        try touch("edits/a-v2.mp4", age: 10)
        #expect(PostFile.media(nil, in: session)?.lastPathComponent == "a-v2.mp4")
        #expect(PostFile.media(.init(text: "", media: "edits/a-v1.mp4"), in: session)?.lastPathComponent == "a-v1.mp4")
        #expect(PostFile.media(.init(text: "", media: "edits/gone.mp4"), in: session)?.lastPathComponent == "a-v2.mp4")
    }

    @Test func verticalShowsOnlyAPortraitEdit() throws {
        try touch("thumbnails/a-v1.png", age: 1)
        try touch("edits/a-v1.mp4", age: 10)  // empty: no frame, so not taller than wide
        #expect(PostFile.media(nil, in: session, .vertical) == nil)
        #expect(PostFile.media(.init(text: "", media: "edits/a-v1.mp4"), in: session, .vertical)?.lastPathComponent == "a-v1.mp4")
    }

    @Test func tagsAreHashtagsMentionsAndLinks() {
        let text = "Ship it #buildinpublic with @Acme, see https://acme.com. Not a#tag or C#"
        let found = PostFile.tags(text).map { (text as NSString).substring(with: $0) }
        #expect(found == ["#buildinpublic", "@Acme", "https://acme.com"])
    }

    @MainActor @Test func typingIsSavedAndClaudesChangeShows() async throws {
        PostFile.write(.init(text: "One\n", media: nil), to: session)
        let store = PostStore()
        store.load(session)
        #expect(store.text == "One\n")
        store.edit("One, edited\n")
        store.load(session)                 // a file event while typing: his text stays
        #expect(store.text == "One, edited\n")
        // The save waits 500 ms after the last key. Under a busy test run it can be later.
        for _ in 0..<40 where PostFile.read(session)?.text != "One, edited\n" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(PostFile.read(session)?.text == "One, edited\n")
        try await Task.sleep(for: .milliseconds(1100))  // a new modification date
        PostFile.write(.init(text: "Claude\n", media: nil), to: session)
        store.load(session)
        #expect(store.text == "Claude\n")
    }

    @Test func hashMatchesTheServer() {
        // python3: takes_mcp.post_hash("Hello world\n")
        #expect(PostFile.hash("Hello world\n") == "7b502c3a1f48")
    }

    @Test func statusAndTimeRoundTrip() {
        var c = PostFile.Content(text: "Hi\n", media: "edits/a.mp4")
        #expect(c.status == .draft)
        c.status = .ready
        let la = TimeZone(identifier: "America/Los_Angeles")!
        c.plan(Date(timeIntervalSince1970: 1_790_870_400), in: la)   // 2026-10-01 16:00 UTC
        PostFile.write(c, to: session)
        let raw = (try? String(contentsOf: PostFile.url(session), encoding: .utf8)) ?? ""
        #expect(raw == "---\nmedia: edits/a.mp4\nstatus: ready\nat: 2026-10-01T09:00:00-07:00\ntz: America/Los_Angeles\n---\nHi\n")
        let back = PostFile.read(session)!
        #expect(back.status == .ready && back.at == c.at && back.tz == la)
        c.plan(nil, in: la)
        #expect(c.meta["at"] == nil && c.meta["tz"] == nil)
    }

    @Test func sameWallClockInAnotherZone() {
        let la = TimeZone(identifier: "America/Los_Angeles")!, berlin = TimeZone(identifier: "Europe/Berlin")!
        let nine = PostFile.date("2026-10-01T09:00:00-07:00")!
        #expect(PostFile.iso(PostFile.moved(nine, from: la, to: berlin), berlin) == "2026-10-01T09:00:00+02:00")
    }

    @Test func scheduledPostNeedsUpdateAfterAChange() {
        var c = PostFile.Content(text: "Hi\n", meta: ["status": "scheduled", "at": "2026-10-01T09:00:00-07:00",
                                                     "scheduled_at": "2026-10-01T18:00:00+02:00",
                                                     "scheduled_hash": PostFile.hash("Hi")])
        #expect(!c.needsUpdate)                       // same moment, other zone
        c.text = "Hi there\n"
        #expect(c.needsUpdate)
        c.text = "Hi\n"
        c.plan(PostFile.date("2026-10-02T09:00:00-07:00"), in: .current)
        #expect(c.needsUpdate)
    }

    @MainActor @Test func queueFindsReadyPostsAcrossProjects() throws {
        let root = session.appending(path: "lib")
        let a = root.appending(path: "P1/s1"), b = root.appending(path: "P2/s2"), d = root.appending(path: "P2/s3")
        PostFile.write(.init(text: "A", meta: ["status": "ready"]), to: a)
        PostFile.write(.init(text: "B", meta: ["status": "scheduled", "at": "2026-10-01T09:00:00-07:00"]), to: b)
        PostFile.write(.init(text: "draft"), to: d)
        let q = PostQueue()
        q.scan(root)
        #expect(q.posts.map(\.title) == ["s2", "s1", "s3"])   // timed first; no session.json: the folder name
        #expect(q.unplanned.map(\.title) == ["s1"])
        #expect(q.drafts.map(\.title) == ["s3"])              // drafts show in the list too, to drag in
        #expect(q.planned.map(\.title) == ["s2"])
        q.update(a) { $0.plan(PostFile.date("2026-09-30T10:00:00-07:00"), in: .current) }
        #expect(q.unplanned.isEmpty && q.planned.map(\.title) == ["s1", "s2"])
    }
}

// 2026-09-28: the post got variants (tabs), hook options and a history, like the script.

@MainActor
struct PostDraftTests {
    let session: URL

    init() throws {
        session = FileManager.default.temporaryDirectory.appending(path: "takes-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session.appending(path: "posts/history"), withIntermediateDirectories: true)
        PostFile.write(.init(text: "Main hook.\n\nBody.\n", media: nil), to: session)
    }

    private func write(_ rel: String, _ text: String) throws {
        let u = session.appending(path: rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    @Test func readsTheServersFiles() throws {
        try write("posts/variants/story-first.md", "---\nname: Story first\nauthor: claude\nnote: narrative\ncreated: 2026-09-28T10:00:00Z\n---\nStory.\n")
        try write("posts/history/20260928-100000-000001-linkedin.md", "---\nauthor: claude\nnote: Edited by Claude\ncreated: 2026-09-28T17:00:00.000Z\ndraft: main\n---\nOld.\n")
        try write("posts/history/20260928-090000-000000-linkedin.md", "---\nauthor: claude\nnote: first\ncreated: 2026-09-28T16:00:00.000Z\n---\nOlder.\n")
        #expect(PostFile.variants(session).map(\.name) == ["Story first"])
        let vs = PostFile.versions(session)
        #expect(vs.map { $0.text() } == ["Old.\n", "Older.\n"])       // newest first
        #expect(vs.map(\.draft) == ["main", "main"])                    // no draft field: main
        #expect(PostFile.versionCount(session) == vs.count)             // counted from the names alone
        #expect(PostFile.stamp.string(from: Date()).count == "20260928-100000-000001".count)
    }

    @Test func snapshotSkipsTheSameText() {
        #expect(PostFile.snapshot(session, draft: "main", text: "A\n", note: "x"))
        #expect(!PostFile.snapshot(session, draft: "main", text: "A\n", note: "x"))
        #expect(PostFile.snapshot(session, draft: "v", text: "A\n", note: "x"))  // another draft
        #expect(!PostFile.snapshot(session, draft: "main", text: "  \n", note: "x"))
    }

    @Test func variantTypingOnlyChangesTheVariant() {
        let post = PostStore()
        post.load(session)
        post.newVariant()
        #expect(post.draft == "variant-1")
        post.edit("Shorter.\n")
        post.close()
        #expect(PostFile.read(session)?.text == "Main hook.\n\nBody.\n")
        #expect(PostFile.variants(session).first?.text == "Shorter.\n")
        // The copy it started from and the edit are both in history.
        #expect(PostFile.versions(session).filter { $0.draft == "variant-1" }.map { $0.text() } == ["Shorter.\n", "Main hook.\n\nBody.\n"])
    }

    @Test func useAsMainKeepsTheOldMainAndThePlan() {
        PostFile.update(session) { $0.status = .ready }
        let post = PostStore()
        post.load(session)
        post.newVariant()
        post.edit("Variant text.\n")
        post.promote("variant-1")
        #expect(post.draft == "main")
        #expect(PostFile.read(session)?.text == "Variant text.\n")
        #expect(PostFile.read(session)?.status == .ready)
        #expect(PostFile.variants(session).isEmpty)
        let old = PostFile.versions(session).first { $0.draft == "main" && $0.text() == "Main hook.\n\nBody.\n" }
        #expect(old != nil)
        post.restore(old!)
        #expect(PostFile.read(session)?.text == "Main hook.\n\nBody.\n")
    }

    @Test func hookReplacesTheFirstParagraph() {
        let post = PostStore()
        post.load(session)
        let hooks = [Hook(id: "h1", text: "Main hook."), Hook(id: "h2", text: "New hook.")]
        post.use(hooks[1], known: hooks.map(\.text))
        #expect(PostFile.read(session)?.text == "New hook.\n\nBody.\n")
        #expect(HookStore.current(post.text, hooks)?.id == "h2")
    }

    @Test func firstCommentRoundTrips() {
        #expect(PostFile.firstComment(session) == "")
        PostFile.writeFirstComment(session, "Links below\nexample.com")
        #expect(PostFile.firstComment(session) == "Links below\nexample.com")   // as typed, no newline added
        PostFile.writeFirstComment(session, "  \n")
        #expect(!FileManager.default.fileExists(atPath: session.appending(path: PostFile.firstCommentRel).path))
    }

    @Test func commentsPointAtTheDraftFile() {
        #expect(PostFile.rel(of: "main") == "posts/linkedin.md")
        #expect(PostFile.rel(of: "story") == "posts/variants/story.md")
    }
}

// 2026-09-28: switching variant tabs while typing in the post left the old text in the editor.
@MainActor
struct PostEditorSwitchTests {
    final class Model: ObservableObject {
        @Published var text = "Main text."
        @Published var draft = "main"
    }

    struct Host: View {
        @ObservedObject var m: Model
        var body: some View {
            PostEditor(text: $m.text, identity: m.draft, highlights: [], reveal: nil, focusToken: 0,
                       onSelect: { _ in }, onComment: {})
                .frame(width: 400, height: 200)
        }
    }

    private func editor(in v: NSView) -> NSTextView? {
        if let t = v as? NSTextView { return t }
        for s in v.subviews { if let t = editor(in: s) { return t } }
        return nil
    }

    @Test func newDraftReplacesTheTextWhileTyping() async throws {
        let m = Model()
        let host = NSHostingView(rootView: Host(m: m))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        let tv = try #require(editor(in: host))
        #expect(tv.string == "Main text.")
        // Typing: the editor ignores outside text while you edit.
        (tv.delegate as? PostEditor.Coordinator)?.editing = true
        m.text = "Claude's change."
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(tv.string == "Main text.")
        // A variant tab: the text must follow, even while typing.
        m.draft = "short"
        m.text = "Short variant."
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(tv.string == "Short variant.")
    }
}

@MainActor
struct PostSettleTests {
    private func session(_ at: Date) throws -> URL {
        let s = FileManager.default.temporaryDirectory.appending(path: "settle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        let iso = PostFile.iso(at, .current)
        let text = "Less than 1% pay for AI."
        PostFile.write(PostFile.Content(text: text, meta: ["status": "scheduled", "at": iso, "tz": TimeZone.current.identifier,
                                                           "scheduled_at": iso, "scheduled_hash": PostFile.hash(text)]), to: s)
        return s
    }

    @Test func scheduledPostWhoseTimePassedIsPosted() throws {
        let at = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        let s = try session(at)
        defer { try? FileManager.default.removeItem(at: s) }
        var list = [QueuedPost(session: s, project: "P", title: "T", content: try #require(PostFile.read(s)))]
        PostQueue.settle(&list)
        #expect(list[0].content.status == .posted)
        #expect(PostFile.read(s)?.status == .posted)
        let doc = SessionDoc(url: s)
        #expect(doc.posts.map(\.platform) == ["LinkedIn"])
        #expect(doc.posts.first?.at == at)
    }

    @Test func futurePostStaysScheduled() throws {
        let s = try session(Date().addingTimeInterval(3600))
        defer { try? FileManager.default.removeItem(at: s) }
        var list = [QueuedPost(session: s, project: "P", title: "T", content: try #require(PostFile.read(s)))]
        PostQueue.settle(&list)
        #expect(list[0].content.status == .scheduled)
        #expect(SessionDoc(url: s).posts.isEmpty)
    }
}

struct PostMediaTests {
    @MainActor @Test func commentsOnThePostVideoGoToItsSession() throws {
        let s = FileManager.default.temporaryDirectory.appending(path: "post-media-\(UUID().uuidString)/P/2026-10-02-a")
        try FileManager.default.createDirectory(at: s.appending(path: "edits"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        try Data("{}".utf8).write(to: s.appending(path: "session.json"))
        #expect(PostMedia.commentRoot(s.appending(path: "edits/hook-v2.mp4"))?.standardizedFileURL == s.standardizedFileURL)
        #expect(PostMedia.commentRoot(FileManager.default.temporaryDirectory.appending(path: "nowhere/x.mp4")) == nil)
    }
}
