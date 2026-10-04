import XCTest

/// Offline (2026-10-03): with the Mac away, a script edit and a comment wait on the phone, show
/// at once, and reach the Mac when it is back. Needs ios/standin.py (check.sh offline starts it).
final class OfflineTests: XCTestCase {
    private var server: String { ProcessInfo.processInfo.environment["TAKES_SERVER"] ?? "http://127.0.0.1:8797" }

    private func get(_ path: String) throws -> Data {
        var out: Data?
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: URL(string: server + path)!) { d, _, _ in out = d; done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(out)
    }

    func testChangesWaitAndGoOut() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = server
        app.launch()
        app.buttons["Connect"].tap()
        if app.tabBars.buttons["Videos"].waitForExistence(timeout: 15) { app.tabBars.buttons["Videos"].tap() }
        let row = text(app, "Offline video")
        XCTAssertTrue(row.waitForExistence(timeout: 15))

        // The Mac goes away for a while.
        _ = try get("/test/down?s=40")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Changes wait on the phone'")).firstMatch.waitForExistence(timeout: 15))
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
        app.textFields["What should change?"].typeText("Offline comment.")
        app.buttons["Save"].tap()
        sleep(1)
        shot(app, "offline-2-script")

        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'wait for the Mac'")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "offline-3-waiting")

        // The Mac comes back: both changes reach it, in order, and the bar goes.
        var log: [[String: Any]] = []
        for _ in 0..<40 {
            sleep(2)
            log = (try? JSONSerialization.jsonObject(with: try get("/test/log")) as? [[String: Any]]) ?? []
            print("offline poll:", log)
            if log.count >= 2 { break }
        }
        XCTAssertEqual(log.count, 2, "\(log)")
        XCTAssertTrue((log.first?["script"] as? String)?.hasSuffix("Written offline.") == true, "\(log)")
        XCTAssertEqual(log.last?["comment"] as? String, "Offline comment.")
        sleep(2)
        shot(app, "offline-4-back")
    }

    /// A new video made with the Mac away: it opens on its chat, the message waits, and when the Mac
    /// is back it makes the video first, then the message goes to it.
    func testNewVideoOffline() throws {
        for _ in 0..<30 where (try? get("/api/ping")) == nil { sleep(2) }
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = server
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        if app.tabBars.buttons["Videos"].waitForExistence(timeout: 15) { app.tabBars.buttons["Videos"].tap() }
        XCTAssertTrue(text(app, "Offline video").waitForExistence(timeout: 15))
        let before = ((try? JSONSerialization.jsonObject(with: try get("/test/log")) as? [[String: Any]]) ?? []).count

        _ = try get("/test/down?s=30")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Changes wait on the phone'")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["New video"].tap()
        let field = app.textFields["Message Claude"].exists ? app.textFields["Message Claude"] : app.textViews["Message Claude"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("A video about offline mode.")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Waits for the Mac'")).firstMatch.waitForExistence(timeout: 5))
        shot(app, "offline-5-new-video")

        var log: [[String: Any]] = []
        for _ in 0..<40 {
            sleep(2)
            log = Array(((try? JSONSerialization.jsonObject(with: try get("/test/log")) as? [[String: Any]]) ?? []).dropFirst(before))
            print("new video poll:", log)
            if log.count >= 2 { break }
        }
        XCTAssertEqual(log.count, 2, "\(log)")
        XCTAssertNotNil(log.first?["new"], "\(log)")
        XCTAssertEqual(log.last?["say"] as? String, "A video about offline mode.", "\(log)")
        // The message goes to the video the Mac made, not to the phone's own id.
        XCTAssertEqual(log.last?["id"] as? String, log.first?["new"] as? String, "\(log)")
        sleep(2)
        shot(app, "offline-6-new-video-back")
    }

    private func text(_ app: XCUIApplication, _ t: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", t)).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SHOTS"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: name + ".png"))
    }
}
