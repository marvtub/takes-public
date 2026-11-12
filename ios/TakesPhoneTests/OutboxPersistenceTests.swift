import XCTest
@testable import Takes

final class OutboxPersistenceTests: XCTestCase {
    enum Failure: Error { case full }

    @MainActor
    func testSendReportsWhenItsQueueCannotBeSaved() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = failingOutbox(root)
        let model = Model(outbox: outbox)

        do {
            _ = try await outbox.send(Outbox.Op(.reply, session: "session", path: "/api/comments/reply"))
            XCTFail("A change must not report success when it was not saved")
        } catch is Outbox.StorageError {
            XCTAssertTrue(outbox.ops.isEmpty)
            XCTAssertEqual(model.error, "Takes could not keep this change on the phone.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testTakeRestoresMovedRecordingWhenItsQueueCannotBeSaved() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "camera.mov")
        try Data("recording".utf8).write(to: source)
        let outbox = failingOutbox(root.appending(path: "outbox"))

        XCTAssertFalse(outbox.take(source, name: "phone-take.mov", session: "session", asTake: true, shot: nil))
        XCTAssertEqual(try Data(contentsOf: source), Data("recording".utf8))
        XCTAssertTrue(outbox.ops.isEmpty)
        let staged = try FileManager.default.contentsOfDirectory(at: root.appending(path: "outbox/files"),
                                                                  includingPropertiesForKeys: nil)
        XCTAssertTrue(staged.isEmpty)
    }

    @MainActor
    func testFailedReplyAndKeeperAreNotAcknowledged() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Model(outbox: failingOutbox(root))

        let replied = await model.reply("session", comment: "comment", text: "Keep this draft")
        let kept = await model.keeper("session", take: 2)
        XCTAssertFalse(replied)
        XCTAssertFalse(kept)
    }

    @MainActor
    func testFailedResolveAndReopenAreNotAcknowledged() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = failingOutbox(root)
        let model = Model(outbox: outbox)

        let resolved = await model.resolve("session", comment: "comment", true)
        let reopened = await model.resolve("session", comment: "comment", false)
        XCTAssertFalse(resolved)
        XCTAssertFalse(reopened)
        XCTAssertTrue(outbox.ops.isEmpty)
    }

    @MainActor
    private func failingOutbox(_ directory: URL) -> Outbox {
        Outbox(directory: directory) { _, _ in throw Failure.full }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "outbox-tests-\(UUID())")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
