import XCTest

/// The Styles board's Effects tab and the chat's @ list of styles, effects and skills, against
/// standin.py.
final class EffectsTests: XCTestCase {
    private var server: String { ProcessInfo.processInfo.environment["TAKES_SERVER"] ?? "http://127.0.0.1:8797" }

    override func setUp() {
        super.setUp()
        freshStandin()
    }

    private func get(_ path: String) -> String {
        let done = expectation(description: path)
        var body = ""
        URLSession.shared.dataTask(with: URL(string: server + path)!) { data, _, _ in
            body = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return body
    }

    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = server
        app.launchArguments += ["-lookMode", mode]
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        return app
    }

    func testEffectsTab() throws {
        _ = get("/test/styles")
        for mode in ["light", "dark"] {
            let app = launch(mode)
            app.page("Styles")
            app.buttons["Effects"].tapWhenReady()
            let checklist = app.buttons["Checklist effect"]
            XCTAssertTrue(checklist.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["New effect"].firstMatch.exists)
            app.settle()
            shot(app, "effects-1-grid-\(mode)")
            checklist.tap()
            XCTAssertTrue(app.staticTexts["FITS WHEN"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["6 s · Any format · Overlay"].exists)
            app.settle()
            shot(app, "effects-2-details-\(mode)")
            app.swipeUp()
            app.buttons["Use in a video"].tapWhenReady()
            let video = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Offline video'")).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 5))
            app.settle(timeout: 1)
            shot(app, "effects-3-use-\(mode)")
            video.tap()
            XCTAssertTrue(eventually { self.get("/test/log").contains("\"use\"") })
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sent to the chat of'")).firstMatch.waitForExistence(timeout: 5))
            app.buttons["Open the source"].tapWhenReady()
            XCTAssertTrue(app.staticTexts["What you can change"].waitForExistence(timeout: 5))
            shot(app, "effects-4-source-\(mode)")
            app.buttons["Back"].tap()
            app.buttons["Back"].tap()
            app.buttons["New effect"].firstMatch.tapWhenReady()
            let field = app.descendants(matching: .any)["effect-example"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeText("My screen slides in from the side")
            app.settle(timeout: 1)
            shot(app, "effects-5-new-\(mode)")
            app.buttons["Make it"].tap()
            XCTAssertTrue(eventually { self.get("/test/log").contains("slides in from the side") })
            app.terminate()
        }
    }

    func testAtListNamesStylesEffectsAndSkills() throws {
        _ = get("/test/styles")
        let app = launch("dark")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Offline video'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        if app.buttons["Chat"].waitForExistence(timeout: 10) { app.buttons["Chat"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["chat-input"].waitForExistence(timeout: 10))
        let box = app.textViews["chat-input"].exists ? app.textViews["chat-input"] : app.textFields["chat-input"]
        box.tap()
        box.typeText("Add @")
        XCTAssertTrue(app.staticTexts["Effects"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Styles"].exists)
        XCTAssertTrue(app.buttons["Magazine"].exists)
        app.settle(timeout: 1)
        shot(app, "at-1-list")
        box.typeText("check")
        XCTAssertTrue(app.buttons["Checklist"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Magazine"].exists)
        app.settle(timeout: 1)
        shot(app, "at-2-filtered")
        app.buttons["Checklist"].tap()
        box.typeText("to the tips")
        app.settle(timeout: 1)
        shot(app, "at-3-picked")
        app.buttons["Send"].tap()
        XCTAssertTrue(eventually { let l = self.get("/test/log"); return l.contains("Add @Checklist to the tips") && l.contains("Effects:/fx/checklist") },
                      get("/test/log"))
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        writeScreenshot(XCUIScreen.main.screenshot(), named: name)
    }
}
