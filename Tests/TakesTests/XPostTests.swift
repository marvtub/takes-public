import Foundation
import Testing
@testable import Takes

// 2026-09-29: the X post sits next to the LinkedIn post (posts/x.md), a thread split at "---" lines,
// with its own variants, hooks and history in posts/x/.

@MainActor
struct XPostTests {
    let session: URL

    init() throws {
        session = FileManager.default.temporaryDirectory.appending(path: "takes-x-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session.appending(path: "edits"), withIntermediateDirectories: true)
    }

    @Test func threadSplitsAndJoinsLikeTheServer() {
        #expect(PostFile.tweets("One\n\n---\n\nTwo\n---\nThree\n") == ["One", "Two", "Three"])
        #expect(PostFile.tweets("Just one --- inline\n") == ["Just one --- inline"])
        #expect(PostFile.thread(["Hook", "Second"]) == "Hook\n\n---\n\nSecond\n")
        // While editing, a tweet you just added stays even though it is empty.
        let withNew = PostFile.thread(["Hook", ""])
        #expect(PostFile.tweets(withNew, keepEmpty: true) == ["Hook", ""])
        #expect(PostFile.tweets(withNew) == ["Hook"])
        #expect(PostFile.tweets("", keepEmpty: true).isEmpty)
    }

    @Test func eachPlatformHasItsOwnFiles() {
        #expect(PostFile.rel(of: "main", .x) == "posts/x.md")
        #expect(PostFile.rel(of: "short", .x) == "posts/x/variants/short.md")
        #expect(PostFile.hooksURL(session, .x).path.hasSuffix("posts/x/hooks.json"))
        #expect(PostPlatform.of(rel: "posts/x/variants/a.md") == .x)
        #expect(PostPlatform.of(rel: "posts/variants/a.md") == .linkedin)
        PostFile.write(.init(text: "LinkedIn\n", media: "edits/a.mp4"), to: session)
        PostFile.write(.init(text: "X\n"), to: session, .x)
        #expect(PostFile.read(session)?.text == "LinkedIn\n")
        #expect(PostFile.read(session, .x)?.text == "X\n")
    }

    @Test func xUsesTheLinkedInMediaPick() throws {
        try Data().write(to: session.appending(path: "edits/a.mp4"))
        try Data().write(to: session.appending(path: "edits/b.mp4"))
        PostFile.write(.init(text: "LinkedIn\n", media: "edits/a.mp4"), to: session)
        PostFile.write(.init(text: "X\n"), to: session, .x)
        #expect(PostFile.media(PostFile.read(session, .x), in: session, .x)?.lastPathComponent == "a.mp4")
    }

    @Test func storeEditsTheXPostAndKeepsItsHistory() async throws {
        PostFile.write(.init(text: "LinkedIn\n"), to: session)
        PostFile.write(.init(text: "Hook\n"), to: session, .x)
        let post = PostStore(.x)
        post.load(session)
        post.edit(PostFile.thread(["Hook", "More"]))
        post.close()
        #expect(PostFile.read(session, .x)?.text == "Hook\n\n---\n\nMore\n")
        #expect(PostFile.read(session)?.text == "LinkedIn\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: session.appending(path: "posts/x/history").path)
        #expect(!names.isEmpty && names.allSatisfy { $0.hasSuffix("-x.md") })
        #expect(!FileManager.default.fileExists(atPath: session.appending(path: "posts/history").path))
    }

    @Test func calendarListsBothPostsOfASession() {
        let root = session.appending(path: "lib")
        let s = root.appending(path: "P/s1")
        PostFile.write(.init(text: "A", meta: ["status": "ready"]), to: s)
        PostFile.write(.init(text: "B", meta: ["status": "ready", "at": "2026-10-01T09:00:00-07:00"]), to: s, .x)
        let q = PostQueue()
        q.scan(root)
        #expect(Set(q.posts.map(\.platform)) == [.linkedin, .x])
        #expect(q.planned.map(\.platform) == [.x])
        q.update(q.planned[0]) { $0.plan(nil, in: .current) }
        #expect(PostFile.read(s, .x)?.at == nil && q.planned.isEmpty)
    }
}
