import AVFoundation
import XCTest
@testable import Takes  // the app target's PRODUCT_NAME (and so its module) is Takes

final class OrientationRepairTests: XCTestCase {
    func testOnlyCompleteCompositionCanReplaceOriginal() {
        let complete = OrientationTrackCounts(video: 1, audio: 1)

        XCTAssertTrue(OrientationTrackCounts.canReplaceOriginal(
            expected: complete, inserted: complete, exported: complete
        ))
        XCTAssertFalse(OrientationTrackCounts.canReplaceOriginal(
            expected: complete,
            inserted: OrientationTrackCounts(video: 1, audio: 0),
            exported: OrientationTrackCounts(video: 1, audio: 0)
        ))
        XCTAssertFalse(OrientationTrackCounts.canReplaceOriginal(
            expected: complete,
            inserted: complete,
            exported: OrientationTrackCounts(video: 1, audio: 0)
        ))
        let silent = OrientationTrackCounts(video: 1, audio: 0)
        XCTAssertTrue(OrientationTrackCounts.canReplaceOriginal(
            expected: silent, inserted: silent, exported: silent
        ))
    }

    func testFailedTrackInsertionKeepsOriginalRecording() async throws {
        let fixture = try XCTUnwrap(
            ProcessInfo.processInfo.environment["TAKES_ORIENTATION_TAKE"],
            "ios/check.sh provides a video-and-audio fixture"
        )
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "orientation-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = folder.appending(path: "take.mov")
        try FileManager.default.copyItem(at: URL(filePath: fixture), to: original)
        let before = try Data(contentsOf: original)
        var insertionAttempts = 0

        let result = await Orientation.fix(original, portrait: false) { copy, range, source in
            insertionAttempts += 1
            if insertionAttempts == 2 { throw TestError.insertionFailed }
            try copy.insertTimeRange(range, of: source, at: .zero)
        }

        XCTAssertEqual(insertionAttempts, 2, "one track must be inserted before the next one fails")
        XCTAssertEqual(result, original)
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appending(path: "upright-take.mov").path
        ))
    }

    private enum TestError: Error {
        case insertionFailed
    }
}
