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
        app.page("Performance")
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

    /// Record: the script in the island panel, then the take plays with "Ask Takes", the record
    /// button and a small "Send to Mac". TAKES_FAKE_TAKE stands in for the camera.
    func testRecordReview() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launchEnvironment["TAKES_FAKE_TAKE"] = env["TAKES_FAKE_TAKE"]
        addUIInterruptionMonitor(withDescription: "Allow") { alert in
            for b in ["Allow", "OK", "Allow While Using App"] where alert.buttons[b].exists { alert.buttons[b].tap(); return true }
            return false
        }
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        if app.buttons["Videos"].waitForExistence(timeout: 15) { app.buttons["Videos"].tap() }
        app.buttons.matching(identifier: "session-row").element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Record a take"].waitForExistence(timeout: 10))
        app.buttons["Record a take"].tap()
        sleep(3)
        app.tap()
        shot(app, "50-record-island")
        app.buttons["Record"].tap()
        sleep(1)
        shot(app, "51-recording")
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Send to Mac"].waitForExistence(timeout: 10))
        sleep(2)
        shot(app, "52-take-review")
        app.buttons["Record another take"].tap()
        XCTAssertTrue(app.buttons["Record"].waitForExistence(timeout: 10))
        sleep(1)
        shot(app, "53-record-again")
    }

    /// The review deck: one draft at a time, copy by tap, approve by swiping right.
    /// The performance tab alone: its charts, scrolled through.
    func testPerformanceBoard() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        app.buttons["Connect"].tap()
        app.page("Performance")
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
        app.page("Comments")
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
        app.page("Comments")
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

    /// The chat's + opens the photo picker and the file picker (2026-10-09: it did nothing).
    func testAddFiles() throws {
        let server = ProcessInfo.processInfo.environment["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = server
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        if app.buttons["Videos"].waitForExistence(timeout: 15) { app.buttons["Videos"].tap() }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Offline video'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        for (item, picker) in [("add-photos", "Photos"), ("add-files", "Browse")] {
            let add = app.buttons["Add files"]
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
            let choice = app.buttons[item]
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "no \(item) in the menu")
            choice.tap()
            sleep(3)
            shot(app, "add-\(picker)")
            let shown = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", picker)).firstMatch
            XCTAssertTrue(shown.waitForExistence(timeout: 8), "the \(item) picker did not open")
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.waitForExistence(timeout: 3) { cancel.tap() }
            sleep(2)
        }
    }

    /// Regression for the blank/jumping chat: tall streamed replies, keyboard and multiline
    /// composer resizing, reading history during a stream, and explicitly returning to latest.
    /// Run against the controlled stand-in with ios/check.sh chat.
    func testChatStaysPut() throws {
        let server = ProcessInfo.processInfo.environment["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        func fixture(_ path: String) throws {
            let done = expectation(description: path)
            var status: Int?
            URLSession.shared.dataTask(with: URL(string: server + path)!) { _, response, _ in
                status = (response as? HTTPURLResponse)?.statusCode
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 10)
            XCTAssertEqual(status, 200)
        }
        try fixture("/test/chat/start")
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = server
        // The chat keeps unsent text per session: start from an empty field, not the last run's draft.
        app.launchArguments += ["-chatDraft.Tests/offline-video", ""]
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        if app.buttons["Videos"].waitForExistence(timeout: 15) { app.buttons["Videos"].tap() }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Offline video'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let transcript = app.scrollViews["chat-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let tail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Latest reply marker'")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 10))

        func assertTailVisible(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertGreaterThan(tail.frame.maxY, transcript.frame.minY, file: file, line: line)
            XCTAssertLessThanOrEqual(tail.frame.maxY, transcript.frame.maxY + 2, file: file, line: line)
            XCTAssertTrue(tail.isHittable, file: file, line: line)
        }
        sleep(2)
        assertTailVisible()
        // Five tool steps in a row fold to one line, as on the Mac; two stay as they are.
        let fold = app.buttons.matching(NSPredicate(format: "value BEGINSWITH '5 steps'")).firstMatch
        XCTAssertTrue(fold.exists)
        XCTAssertFalse(app.staticTexts["Grep · ascii"].exists)
        XCTAssertTrue(app.staticTexts["Read · sheet5.jpg"].exists)
        shot(app, "chat-1-bottom")
        // XCUITest reports the multiline field as a TextField or a TextView, from one query to the next.
        func messageField() -> XCUIElement {
            let any = app.descendants(matching: .any).matching(NSPredicate(format:
                "(elementType == %d OR elementType == %d) AND identifier == 'chat-input'",
                XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
            XCTAssertTrue(any.waitForExistence(timeout: 5))
            return any
        }
        messageField().tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("One line\nTwo lines\nThree lines\nFour lines")
        sleep(2)
        assertTailVisible()
        try fixture("/test/chat/grow")
        sleep(3)
        assertTailVisible()
        shot(app, "chat-2-keyboard-stream")

        // Browsing dismisses the keyboard interactively; the stream must not pull us back.
        func visibleEarlier() -> XCUIElement? {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Earlier message'")).allElementsBoundByIndex
                // Its top on screen: with the keyboard up, one message is taller than the transcript.
                .first { $0.frame.minY >= transcript.frame.minY && $0.frame.minY <= transcript.frame.maxY - 40 }
        }
        for _ in 0..<16 {
            if visibleEarlier() != nil { break }
            transcript.swipeDown()
        }
        sleep(2)
        let latest = app.buttons["Jump to latest message"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        let reading = try XCTUnwrap(visibleEarlier())
        let readingY = reading.frame.minY
        try fixture("/test/chat/grow")
        sleep(3)
        XCTAssertEqual(reading.frame.minY, readingY, accuracy: 2, "A streaming reply moved the reader")
        XCTAssertTrue(latest.exists)
        shot(app, "chat-3-reading-history")
        latest.tap()
        sleep(2)
        assertTailVisible()
        try fixture("/test/chat/finish")
        sleep(3)
        assertTailVisible()
        shot(app, "chat-4-finished")

        // Sending from history is another explicit request to return to the conversation.
        for _ in 0..<3 { transcript.swipeDown() }
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        messageField().tap()
        app.typeText(" and send")
        app.buttons["Send"].tap()
        sleep(2)
        XCTAssertFalse(latest.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Four lines and send'")).firstMatch.isHittable)
        shot(app, "chat-5-sent-from-history")
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

extension XCUIApplication {
    /// Opens a page from the Takes menu (Performance, Comments, Search, plugins, Styles), where
    /// the home screen keeps them since 2026-10-09.
    func page(_ name: String) {
        let row = buttons[name]
        if !row.exists {
            XCTAssertTrue(buttons["Takes menu"].waitForExistence(timeout: 15))
            buttons["Takes menu"].tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name) in the Takes menu")
        row.tap()
    }
}
