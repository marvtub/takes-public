import XCTest

/// Walks the app against a stand-in server (TAKES_SERVER) and saves a screenshot of each screen
/// to TAKES_SHOTS. Run: ios/check.sh
final class ScreensTests: XCTestCase {
    func testWalkThrough() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        shot(app, "1-pair")
        app.buttons["Connect"].tap()
        // The app opens on the tab it showed last.
        if app.buttons["Videos"].waitForExistence(timeout: 15) { app.buttons["Videos"].tap() }
        XCTAssertTrue(app.staticTexts["Takes"].waitForExistence(timeout: 15))
        sleep(1)
        shot(app, "2-sessions")
        app.buttons.matching(identifier: "session-row").element(boundBy: 0).tap()
        sleep(3)
        shot(app, "3-chat")
        app.buttons["Files"].tap()
        sleep(4)
        shot(app, "4-files")
        app.buttons["Script"].tap()
        shot(app, "5-script")
        app.buttons["Post"].tap()
        sleep(2)
        shot(app, "6-post")
        app.buttons["Edit"].tap()
        sleep(1)
        shot(app, "6b-edit-post")
        app.buttons["Cancel"].tap()
        sleep(1)
        app.swipeUp()
        sleep(1)
        shot(app, "6c-post-hooks")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Use hook'")).firstMatch.tap()
        sleep(2)
        app.swipeDown()
        sleep(1)
        app.buttons["Short"].firstMatch.tap()
        sleep(1)
        shot(app, "6d-post-variant")
        app.buttons["Script"].tap()
        sleep(1)
        app.buttons["Comment on the whole script"].tap()
        sleep(1)
        app.textFields["What should change?"].typeText("Cut the second paragraph.")
        shot(app, "7-comment")
        app.buttons["Save"].tap()
        sleep(1)
        app.swipeUp()
        shot(app, "8-comments")
        app.buttons["Back"].tap()
        sleep(1)
        app.buttons["Performance"].tap()
        sleep(3)
        shot(app, "9-performance")
        app.swipeUp()
        sleep(1)
        shot(app, "10-performance-more")
        app.swipeUp()
        sleep(2)
        shot(app, "11-top-posts")
        app.swipeUp()
        sleep(2)
        shot(app, "12-top-posts-more")
        app.buttons["Comments"].tap()
        sleep(3)
        shot(app, "13-comments-review")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Watch'")).firstMatch.tap()
        sleep(2)
        shot(app, "15-finding-chat")
        app.buttons["Back"].tap()
        sleep(1)
        app.swipeUp()
        sleep(1)
        shot(app, "14-comments-review-more")
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Posted'")).firstMatch.tap()
        sleep(2)
        shot(app, "16-comments-posted")
        app.buttons["Videos"].tap()
        sleep(1)
        shot(app, "17-sessions-list")
        app.buttons["New video"].firstMatch.tap()
        sleep(3)
        shot(app, "18-new-video-chat")
        app.typeText("Why I record every video twice")
        shot(app, "19-new-video-typed")
    }

    /// The Videos list (in work first, posted closed at the bottom) and a new video: + opens an
    /// empty chat with "Just record".
    func testNewVideo() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        if app.buttons["Videos"].waitForExistence(timeout: 15) { app.buttons["Videos"].tap() }
        XCTAssertTrue(app.staticTexts["Takes"].waitForExistence(timeout: 15))
        sleep(2)
        shot(app, "20-videos-list")
        app.swipeUp()
        app.swipeUp()
        sleep(1)
        shot(app, "21-videos-list-end")
        app.buttons["New video"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Just record"].waitForExistence(timeout: 10))
        sleep(1)
        shot(app, "22-new-video")
    }

    /// The review deck: one draft at a time, copy by tap, approve by swiping right.
    /// The performance tab alone: its charts, scrolled through.
    func testPerformanceBoard() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons["Performance"].waitForExistence(timeout: 15))
        app.buttons["Performance"].tap()
        sleep(3)
        for i in 1...5 {
            shot(app, "40-performance-\(i)")
            app.swipeUp()
            sleep(1)
        }
    }

    /// The Videos home: the big card, the grid of covers, the posted row.
    func testHome() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        app.buttons["Connect"].tap()
        if app.buttons["Videos"].waitForExistence(timeout: 15) { app.buttons["Videos"].tap() }
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15))
        sleep(4)
        shot(app, "70-home")
        app.swipeUp()
        sleep(2)
        shot(app, "71-home-grid")
        app.swipeUp()
        sleep(2)
        shot(app, "72-home-posted")
    }

    /// The Board tab: the strip, the big shot, a swipe to the next one, a shot with a note.
    func testStoryboard() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        app.buttons["Connect"].tap()
        if app.buttons["Videos"].waitForExistence(timeout: 15) { app.buttons["Videos"].tap() }
        // The video may sit far down the grid: search for it.
        let search = app.textFields["Find a session"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("make videos with")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'make videos with'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["Board"].waitForExistence(timeout: 15))
        app.buttons["Board"].tap()
        sleep(4)
        shot(app, "50-board")
        app.swipeLeft()
        sleep(2)
        shot(app, "51-board-next")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Shot'")).element(boundBy: 4).tap()
        sleep(3)
        shot(app, "52-board-note")
        app.swipeUp()
        sleep(1)
        shot(app, "53-board-note-field")
    }

    /// Appearance: the picker, then the app in another theme and in dark mode.
    func testAppearance() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        app.buttons["Connect"].tap()
        if app.buttons["Videos"].waitForExistence(timeout: 15) { app.buttons["Videos"].tap() }
        XCTAssertTrue(app.buttons["Takes menu"].waitForExistence(timeout: 15))
        app.buttons["Takes menu"].tap()
        sleep(1)
        shot(app, "59-takes-menu")
        app.buttons["Appearance"].tap()
        sleep(1)
        shot(app, "60-appearance")
        app.buttons["Sand"].tap()
        app.buttons["Dark"].tap()
        sleep(1)
        shot(app, "61-appearance-sand-dark")
        app.buttons["Done"].tap()
        sleep(1)
        shot(app, "62-videos-sand-dark")
        app.buttons["Takes menu"].tap()
        sleep(1)
        app.buttons["Appearance"].tap()
        sleep(1)
        app.buttons["Reset"].tap()
        app.buttons["Done"].tap()
    }

    func testCommentDeck() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        XCTAssertTrue(app.buttons["Comments"].waitForExistence(timeout: 15))
        app.buttons["Comments"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Approve"].waitForExistence(timeout: 10))
        shot(app, "20-deck")
        app.staticTexts["Tap to copy"].firstMatch.tap()
        sleep(1)
        shot(app, "21-deck-copied")
        let left = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'to review'")).firstMatch.label
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
        start.press(forDuration: 0.3, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        shot(app, "22-deck-dragging")
        // A short, slow drag springs back.
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'to review'")).firstMatch.label, left)
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 1.2, dy: 0.47)))
        sleep(1)
        shot(app, "23-deck-approved")
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
    }

    /// The LinkedIn look: tabs with counts, the post card, your comment, and the feed video.
    func testFeedLook() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        XCTAssertTrue(app.buttons["Comments"].waitForExistence(timeout: 15))
        app.buttons["Comments"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Approve"].waitForExistence(timeout: 10))
        shot(app, "30-review")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Approved'")).firstMatch.tap()
        sleep(1)
        shot(app, "31-approved")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Posted'")).firstMatch.tap()
        sleep(1)
        app.swipeUp()
        sleep(1)
        shot(app, "32-posted")
        app.buttons["Videos"].tap()
        sleep(1)
        app.staticTexts["Claude ran a shop"].firstMatch.tap()
        sleep(2)
        app.buttons["Post"].tap()
        sleep(3)
        app.swipeUp()
        sleep(4)
        shot(app, "33-post-video")
        sleep(3)
        shot(app, "34-post-video-later")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = ProcessInfo.processInfo.environment["TAKES_SHOTS"] ?? NSTemporaryDirectory()
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
