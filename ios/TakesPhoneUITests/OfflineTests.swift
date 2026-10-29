import XCTest

/// Offline (2026-10-03): with the Mac away, a script edit and a comment wait on the phone, show
/// at once, and reach the Mac when it is back. Needs ios/standin.py (check.sh offline starts it).
final class OfflineTests: XCTestCase {
    var server: String { ProcessInfo.processInfo.environment["TAKES_SERVER"] ?? "http://127.0.0.1:8797" }

    override func setUp() {
        super.setUp()
        freshStandin()
    }

    func get(_ path: String) throws -> Data {
        var out: Data?
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: URL(string: server + path)!) { d, _, _ in out = d; done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        // Thrown, not a failure: the polls below ask while the stand-in is away on purpose.
        guard let out else { throw URLError(.cannotConnectToHost) }
        return out
    }

    func testChangesWaitAndGoOut() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = server
        app.launch()
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
        let row = text(app, "Offline video")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        // The phone keeps a copy of the video a few seconds after the list: the script opens
        // offline from it. Comments come last.
        XCTAssertTrue(eventually(timeout: 20) {
            ((try? JSONSerialization.jsonObject(with: try get("/test/seen"))) as? [String])?.contains("/api/comments") == true
        }, "the phone never kept its copy")

        // The Mac goes away for a while: the dot by Takes goes grey.
        _ = try get("/test/down?s=40")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Not connected'")).firstMatch.waitForExistence(timeout: 15))
        shot(app, "offline-1-list")

        row.tap()
        app.buttons["Script"].tap()
        app.buttons["Edit"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        // The editor has the keyboard when it opens; type at the end.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)).tap()
        app.typeText(" Written offline.")
        app.buttons["Save"].tap()
        // The sheet closes and the script shows the new words while the Mac is away.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Written offline.' OR value CONTAINS 'Written offline.'")).firstMatch.waitForExistence(timeout: 8))
        app.buttons["Comment on the whole script"].tap()
        // The comment box has the keyboard when it opens.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Offline comment.")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.settle(timeout: 1)
        shot(app, "offline-2-script")

        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'wait for the Mac'")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "offline-3-waiting")

        // The Mac comes back: both changes reach it, in order, and the bar goes.
        var log: [[String: Any]] = []
        eventually(timeout: 80, every: 1) {
            log = (try? JSONSerialization.jsonObject(with: try get("/test/log")) as? [[String: Any]]) ?? []
            return log.count >= 2
        }
        XCTAssertEqual(log.count, 2, "\(log)")
        XCTAssertTrue((log.first?["script"] as? String)?.hasSuffix("Written offline.") == true, "\(log)")
        XCTAssertEqual(log.last?["comment"] as? String, "Offline comment.")
        _ = text(app, "wait for the Mac").waitForNonExistence(timeout: 10)
        app.settle(timeout: 2)
        shot(app, "offline-4-back")
    }

    /// A new video made with the Mac away: it opens on its chat, the message waits, and when the Mac
    /// is back it makes the video first, then the message goes to it.
    func testNewVideoOffline() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = server
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
        XCTAssertTrue(text(app, "Offline video").waitForExistence(timeout: 15))
        let before = ((try? JSONSerialization.jsonObject(with: try get("/test/log")) as? [[String: Any]]) ?? []).count

        _ = try get("/test/down?s=30")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Not connected'")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["New video"].tap()
        let field = app.textFields["Message Takes"].exists ? app.textFields["Message Takes"] : app.textViews["Message Takes"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("A video about offline mode.")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Waits for the Mac'")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "offline-5-new-video")

        var log: [[String: Any]] = []
        eventually(timeout: 80, every: 1) {
            log = Array(((try? JSONSerialization.jsonObject(with: try get("/test/log")) as? [[String: Any]]) ?? []).dropFirst(before))
            return log.count >= 2
        }
        XCTAssertEqual(log.count, 2, "\(log)")
        XCTAssertNotNil(log.first?["new"], "\(log)")
        XCTAssertEqual(log.last?["say"] as? String, "A video about offline mode.", "\(log)")
        // The message goes to the video the Mac made, not to the phone's own id.
        XCTAssertEqual(log.last?["id"] as? String, log.first?["new"] as? String, "\(log)")
        _ = text(app, "Waits for the Mac").waitForNonExistence(timeout: 10)
        app.settle(timeout: 2)
        shot(app, "offline-6-new-video-back")
    }

    /// 2026-10-07: generated files and their model, a sound that plays in its chat card, the Files
    /// tab's first four with Show all, a folded section, and the renew warning on the home screen.
    func testFilesAndSound() throws {
        _ = try get("/test/files")
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = server
        app.launch()
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
        XCTAssertTrue(text(app, "Xcode lost your Apple ID").waitForExistence(timeout: 15))
        shot(app, "files-1-renew")

        let row = text(app, "Offline video")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let play = app.buttons["Play intro-v1.wav"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        shot(app, "files-2-chat-sound")
        play.tap()
        XCTAssertTrue(app.buttons["Stop intro-v1.wav"].waitForExistence(timeout: 5))
        app.settle(timeout: 1)
        shot(app, "files-3-chat-playing")

        app.buttons["Files"].firstMatch.tap()
        XCTAssertTrue(text(app, "Show all 6").waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, "Nano Banana 2.1").exists)
        XCTAssertFalse(text(app, "hook-v5.mp4").exists)
        shot(app, "files-4-first-four")
        text(app, "Show all 6").tap()
        XCTAssertTrue(text(app, "hook-v5.mp4").waitForExistence(timeout: 5))
        app.buttons["Fold edits"].tap()
        XCTAssertTrue(app.buttons["Open edits"].waitForExistence(timeout: 5))
        app.settle(timeout: 1)
        shot(app, "files-5-folded")
        app.buttons["Open edits"].tap()  // the fold stays for every session: leave it open
    }

    func text(_ app: XCUIApplication, _ t: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", t)).firstMatch
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SHOTS"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: name + ".png"))
    }
}
