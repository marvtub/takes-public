import Foundation
import Testing
@testable import TakesEmbed

@Test func failedSaveKeepsIndexDirtyAndReportsFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "takes-embed-save-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }

    let search = root.appending(path: "_library/search")
    try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
    let initial = IndexFile(files: [
        "gone.mov": Entry(mtime: 1, size: 1, items: [])
    ])
    try JSONEncoder().encode(initial).write(to: search.appending(path: "index.json"))
    let engine = Engine(root: root, models: root.appending(path: "models"))

    try FileManager.default.removeItem(at: root.appending(path: "_library"))
    try Data().write(to: root.appending(path: "_library"))

    let succeeded = await engine.runIndex(id: 1)
    let remainsDirty = await engine.dirty

    #expect(!succeeded)
    #expect(remainsDirty)
}

@Test func failedSaveReplyFinishesTheIndexRun() {
    let reply = indexSaveFailure(
        id: 1,
        indexed: 3,
        files: 4,
        error: CocoaError(.fileWriteNoPermission)
    )

    #expect(reply["ok"] as? Bool == false)
    #expect(reply["indexed"] as? Int == 3)
    #expect(reply["files"] as? Int == 4)
}
