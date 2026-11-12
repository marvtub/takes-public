import Foundation
import Testing
@testable import Takes

/// A save in the app keeps what Claude's MCP wrote to session.json since the app read it
/// (set_published, set_keeper, rename_take, …): the app wrote its old copy over it (2026-11-06).
@MainActor
@Suite struct SessionSaveTests {
    let created = Date(timeIntervalSince1970: 1_790_000_000)

    func take(_ n: Int, keeper: Bool = false, name: String? = nil) -> Take {
        Take(number: n, kind: .camera, file: "take-0\(n)-camera.mov", startedAt: created, keeper: keeper, name: name)
    }

    func meta(_ takes: [Take]) -> SessionMeta {
        SessionMeta(title: "Demo", createdAt: created, named: true, takes: takes, id: "abcdef123456")
    }

    @Test func eachSideKeepsWhatItChanged() {
        let base = meta([take(1), take(2)])
        var disk = base
        disk.takes[0].keeper = true  // set_keeper
        disk.published = [Post(platform: "X", at: created)]  // set_published
        var mine = base
        mine.takes[1].name = "Hook"
        mine.takes.append(take(3))  // just recorded
        mine.favorite = "main"
        let m = SessionMeta.merge(base: base, mine: mine, disk: disk)
        #expect(m.takes.map(\.number) == [1, 2, 3])
        #expect(m.takes[0].keeper && m.takes[1].name == "Hook")
        #expect(m.published?.first?.platform == "X")
        #expect(m.favorite == "main")
    }

    @Test func takesAddedOrRemovedOnDiskStayThatWay() {
        let base = meta([take(1), take(2)])
        var disk = base
        disk.takes = [take(1), take(4)]  // trash_takes 2, import_take 4
        var mine = base
        mine.title = "New title"
        let m = SessionMeta.merge(base: base, mine: mine, disk: disk)
        #expect(m.takes.map(\.number) == [1, 4])
        #expect(m.title == "New title")
    }

    @Test func saveKeepsAnMCPWriteSinceTheLastRead() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "session.json")
        try Store.encoder.encode(meta([take(1), take(2)])).write(to: file)
        let doc = SessionDoc(url: dir)
        // The MCP's set_keeper and set_published, before the app reloads.
        var mcp = meta([take(1, keeper: true), take(2)])
        mcp.published = [Post(platform: "LinkedIn", at: created)]
        try Store.encoder.encode(mcp).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        doc.toggleKeeper(2)
        let saved = try #require(Store.readMeta(dir))
        #expect(saved.takes.map(\.keeper) == [true, true])
        #expect(saved.published?.first?.platform == "LinkedIn")
        #expect(doc.meta == saved)
    }

    @Test func saveWithNoChangeOnDiskWritesTheDoc() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Store.encoder.encode(meta([take(1), take(2)])).write(to: dir.appending(path: "session.json"))
        let doc = SessionDoc(url: dir)
        doc.toggleKeeper(1)
        doc.trashTake(2)
        #expect(Store.readMeta(dir) == doc.meta)
        #expect(doc.meta.takes.map(\.number) == [1] && doc.meta.takes[0].keeper)
    }

    /// The stamp after a save is the file's new time, so the next save and the reload for the app's
    /// own write leave the doc alone. A take just recorded has a time with fractions of a second that
    /// session.json cuts off: a needless re-read or merge would change it.
    @Test func saveStampsTheNewFileTime() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Store.encoder.encode(meta([take(1)])).write(to: dir.appending(path: "session.json"))
        let doc = SessionDoc(url: dir)
        let now = Date(timeIntervalSince1970: 1_790_000_100.25)
        doc.meta.takes.append(Take(number: 2, kind: .camera, file: "take-02-camera.mov", startedAt: now))
        doc.toggleKeeper(1)
        doc.toggleKeeper(2)
        _ = doc.reloadFromDiskIfChanged()
        #expect(doc.meta.takes.last?.startedAt == now)
    }
}
