import Foundation
import Testing
@testable import Takes

/// Projects are sections of the sidebar (2026-10-02): every project's sessions load, a click opens
/// a session of any project, and a project can be renamed.
@MainActor
@Suite struct SidebarTests {
    private func library() throws -> (Library, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "takes-sidebar-\(UUID().uuidString)")
        for (p, s) in [("Alpha", "2026-10-01-one"), ("Alpha", "2026-10-02-two"), ("Beta", "2026-10-02-three")] {
            let url = root.appending(path: p).appending(path: s)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let doc = SessionDoc(url: url)
            doc.meta = SessionMeta(title: s, createdAt: Date(), named: true)
            doc.save()
        }
        let lib = Library()
        lib.setRoot(root)
        return (lib, root)
    }

    @Test func everyProjectLoads() throws {
        let (lib, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(lib.projects.map(\.name) == ["Alpha", "Beta"])
        #expect(lib.grouped.values.map(\.count).sorted() == [1, 2])
    }

    @Test func aClickOpensASessionOfAnotherProject() throws {
        let (lib, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let beta = try #require(lib.projects.first { $0.name == "Beta" })
        let three = try #require(lib.grouped[beta.url]?.first)
        lib.select(three.url)
        #expect(lib.selectedProject == beta.url)
        #expect(lib.selectedSessions == [three.url])
        #expect(lib.current?.url == three.url)
    }

    @Test func renameMovesTheFolderAndKeepsTheOpenSession() throws {
        let (lib, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = try #require(lib.projects.first { $0.name == "Alpha" })
        let two = try #require(lib.grouped[alpha.url]?.first { $0.url.lastPathComponent == "2026-10-02-two" })
        lib.select(two.url)
        let moved = try #require(lib.renameProject(alpha.url, to: "Gamma"))
        #expect(moved.lastPathComponent == "Gamma")
        #expect(lib.projects.map(\.name) == ["Beta", "Gamma"])
        #expect(lib.current?.url.lastPathComponent == "2026-10-02-two")
        #expect(lib.selectedProject == moved)
        // A taken name is refused.
        #expect(lib.renameProject(moved, to: "Beta") == nil)
    }
}

/// Which file changes rescan the library (2026-10-03): not renders, stills or `_library`.
@Suite struct LibraryChangeTests {
    let root = URL(fileURLWithPath: "/lib")

    @Test func sessionAndProjectFoldersCount() {
        #expect(Library.matters(["/lib/"], root: root))
        #expect(Library.matters(["/lib/Inbox/"], root: root))
        #expect(Library.matters(["/lib/Inbox/2026-10-03-x/"], root: root))
        #expect(Library.matters(["/lib/Inbox/2026-10-03-x/variants/"], root: root))
    }

    @Test func assetFoldersAndLibraryDoNot() {
        #expect(!Library.matters(["/lib/Inbox/2026-10-03-x/edits/"], root: root))
        #expect(!Library.matters(["/lib/Inbox/2026-10-03-x/storyboard/"], root: root))
        #expect(!Library.matters(["/lib/_library/broll/1 Desk work/"], root: root))
        #expect(!Library.matters(["/lib/.trash/"], root: root))
        #expect(!Library.matters(["/elsewhere/"], root: root))
    }

    @Test func postsMatterForTheQueue() {
        #expect(PostQueue.matters(["/lib/Inbox/2026-10-03-x/posts/"]))
        #expect(PostQueue.matters(["/lib/Inbox/2026-10-03-x/"]))
        #expect(!PostQueue.matters(["/lib/Inbox/2026-10-03-x/edits/"]))
        #expect(!PostQueue.matters(["/lib/_library/comments/suggestions/"]))
    }
}
