import XCTest

/// The Styles board and a video's style, against standin.py (GET /test/styles turns them on).
final class StylesTests: XCTestCase {
    private var server: String { ProcessInfo.processInfo.environment["TAKES_SERVER"] ?? "http://127.0.0.1:8797" }

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

    func testStylesBoardAndAVideosStyle() throws {
        _ = get("/test/styles")
        let app = launch("dark")
        app.page("Styles")
        let magazine = app.buttons["Magazine style"]
        XCTAssertTrue(magazine.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["In 1 video"].exists)
        shot(app, "styles-1-gallery")

        app.buttons["Keep"].tap()
        sleep(1)
        XCTAssertTrue(get("/test/log").contains("\"keep\""))

        magazine.tap()
        XCTAssertTrue(app.staticTexts["Guide, colours, type and parts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Ask Takes to fix"].exists)
        shot(app, "styles-2-style")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Use on dark pages"].waitForExistence(timeout: 5))
        app.buttons["v1"].tap()
        XCTAssertFalse(app.staticTexts["Use on dark pages"].exists)
        shot(app, "styles-3-parts")
        app.swipeDown()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Style guide'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Comment on the whole guide"].waitForExistence(timeout: 5))
        shot(app, "styles-4-guide")
        app.buttons["Back"].tap()
        app.buttons["Back"].tap()
        app.buttons["Back to videos"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Offline video'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["Files"].tap()
        let picker = app.buttons["Style: Magazine"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        shot(app, "styles-5-files")
        picker.tap()
        let bold = app.buttons["Bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        shot(app, "styles-6-picker")
        bold.tap()
        XCTAssertTrue(app.buttons["Style: Bold"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["this video only"].exists)
        XCTAssertTrue(get("/test/log").contains("\"Bold\""))

        app.buttons["Post"].tap()
        XCTAssertTrue(app.staticTexts["HOOKS"].waitForExistence(timeout: 5))
        shot(app, "post-dark")
    }

    func testPostInLightMode() throws {
        _ = get("/test/styles")
        let app = launch("light")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Offline video'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        app.buttons["Post"].tap()
        XCTAssertTrue(app.staticTexts["HOOKS"].waitForExistence(timeout: 5))
        shot(app, "post-light")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = ProcessInfo.processInfo.environment["TAKES_SHOTS"] ?? NSTemporaryDirectory()
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}
