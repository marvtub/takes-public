import Foundation
import Testing
@testable import TakesEmbed

@Suite(.serialized)
struct IndexFailureTests {
    actor Attempts {
        var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }

    enum TestError: Error {
        case transient
    }

    func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func transientFailureKeepsPreviousEntryAndRetries() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "take.mp4")
        try Data([0]).write(to: video)
        let attempts = Attempts()
        let engine = Engine(root: root, models: root) { source in
            if await attempts.next() == 1 {
                return (source.rel, [Item(start: 0, end: 1, kind: "video", text: nil, v: "valid")])
            }
            throw TestError.transient
        }

        await engine.runIndex(id: nil)
        try Data([0, 1]).write(to: video)
        await engine.runIndex(id: nil)
        let afterFailure = await engine.status()
        #expect(afterFailure["files"] as? Int == 1)
        #expect(afterFailure["items"] as? Int == 1)

        let restarted = Engine(root: root, models: root) { _ in
            _ = await attempts.next()
            throw TestError.transient
        }
        await restarted.runIndex(id: nil)
        let count = await attempts.count
        #expect(count == 3)
    }

    @Test func cancellationLeavesNewFileRetryable() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root.appending(path: "take.mp4"))
        let attempts = Attempts()
        let engine = Engine(root: root, models: root) { _ in
            _ = await attempts.next()
            throw CancellationError()
        }

        await engine.runIndex(id: nil)
        await engine.runIndex(id: nil)

        let count = await attempts.count
        let status = await engine.status()
        #expect(count == 2)
        #expect(status["files"] as? Int == 0)
    }

    @Test func legacyEmptyEntryRetriesWithoutAFileChange() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root.appending(path: "take.mp4"))
        let source = try #require(sources(root: root).first)
        let index = IndexFile(files: [source.rel: Entry(mtime: source.mtime, size: source.size, items: [])])
        let indexURL = Engine.indexURL(root)
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: indexURL)
        let attempts = Attempts()
        let engine = Engine(root: root, models: root) { source in
            _ = await attempts.next()
            return (source.rel, [Item(start: 0, end: 1, kind: "video", text: nil, v: "valid")])
        }

        await engine.runIndex(id: nil)

        let count = await attempts.count
        let status = await engine.status()
        #expect(count == 1)
        #expect(status["items"] as? Int == 1)
    }

    @Test func emptyResultIsNotCachedAndRetries() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root.appending(path: "take.mp4"))
        let attempts = Attempts()
        let engine = Engine(root: root, models: root) { source in
            if await attempts.next() == 1 { return (source.rel, []) }
            return (source.rel, [Item(start: 0, end: 1, kind: "video", text: nil, v: "valid")])
        }

        await engine.runIndex(id: nil)
        let afterEmpty = await engine.status()
        #expect(afterEmpty["files"] as? Int == 0)
        await engine.runIndex(id: nil)

        let count = await attempts.count
        let status = await engine.status()
        #expect(count == 2)
        #expect(status["items"] as? Int == 1)
    }
}
