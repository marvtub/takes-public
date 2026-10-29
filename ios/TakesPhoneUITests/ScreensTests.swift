import XCTest

/// Walks the app against a stand-in server (TAKES_SERVER) and saves a screenshot of each screen
/// to TAKES_SHOTS. Run: ios/check.sh
final class ScreensTests: XCTestCase {
    override func setUp() {
        super.setUp()
        freshStandin()
    }

    func testWalkThrough() throws {
        let env = ProcessInfo.processInfo.environment
        try standin("/test/screens")
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        shot(app, "1-pair")
        app.buttons["Connect"].tap()
        // The app opens on the videos (UI tests start with no saved choices, App.swift).
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
        XCTAssertTrue(app.staticTexts["Takes"].waitForExistence(timeout: 15))
        app.settle(timeout: 1)
        shot(app, "2-sessions")
        app.buttons.matching(identifier: "session-row").element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 10))
        app.settle(timeout: 3)
        shot(app, "3-chat")
        app.buttons["Files"].tap()
        app.settle(timeout: 4)
        shot(app, "4-files")
        app.buttons["Script"].tap()
        shot(app, "5-script")
        app.buttons["Post"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
        app.settle(timeout: 2)
        shot(app, "6-post")
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.settle(timeout: 1)
        shot(app, "6b-edit-post")
        app.buttons["Cancel"].tap()
        app.settle(timeout: 1)
        app.swipeUp()
        app.settle(timeout: 1)
        shot(app, "6c-post-hooks")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Use hook'")).firstMatch.tap()
        app.settle(timeout: 2)
        app.swipeDown()
        app.buttons["Short"].firstMatch.tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "6d-post-variant")
        app.buttons["Script"].tap()
        app.buttons["Comment on the whole script"].tapWhenReady()
        let comment = app.textFields["What should change?"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.typeText("Cut the second paragraph.")
        shot(app, "7-comment")
        app.buttons["Save"].tap()
        XCTAssertTrue(comment.waitForNonExistence(timeout: 5))
        app.swipeUp()
        shot(app, "8-comments")
        app.buttons["Back"].tap()
        app.page("Performance")
        app.settle(timeout: 3)
        shot(app, "9-performance")
        app.swipeUp()
        app.settle(timeout: 1)
        shot(app, "10-performance-more")
        app.swipeUp()
        app.settle(timeout: 2)
        shot(app, "11-top-posts")
        app.swipeUp()
        app.settle(timeout: 2)
        shot(app, "12-top-posts-more")
        // Pages open from the Takes menu since 2026-10-09, and go back to the videos.
        app.buttons["Back to videos"].tapWhenReady()
        app.page("Comments")
        app.settle(timeout: 3)
        shot(app, "13-comments-review")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Watch'")).firstMatch.tap()
        app.settle(timeout: 2)
        shot(app, "15-finding-chat")
        app.buttons["Back"].tap()
        app.settle(timeout: 1)
        app.swipeUp()
        app.settle(timeout: 1)
        shot(app, "14-comments-review-more")
        app.swipeDown()
        app.swipeDown()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Posted'")).firstMatch.tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "16-comments-posted")
        app.buttons["Back to videos"].tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "17-sessions-list")
        app.buttons["New video"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the new chat takes the keyboard")
        app.settle(timeout: 3)
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
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
        XCTAssertTrue(app.staticTexts["Takes"].waitForExistence(timeout: 15))
        app.settle(timeout: 2)
        shot(app, "20-videos-list")
        app.swipeUp()
        app.swipeUp()
        app.settle(timeout: 1)
        shot(app, "21-videos-list-end")
        app.buttons["New video"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Just record"].waitForExistence(timeout: 10))
        app.settle(timeout: 1)
        shot(app, "22-new-video")
    }

    /// Record: the script in the island panel, then the take plays with "Ask Takes", the record
    /// button and a small "Send to Mac". TAKES_FAKE_TAKE stands in for the camera.
    func testRecordReview() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        let fake = try XCTUnwrap(env["TAKES_FAKE_TAKE"], "check.sh sets TAKES_FAKE_TAKE: a clip in place of the camera")
        app.launchEnvironment["TAKES_FAKE_TAKE"] = fake
        addUIInterruptionMonitor(withDescription: "Allow") { alert in
            for b in ["Allow", "OK", "Allow While Using App"] where alert.buttons[b].exists { alert.buttons[b].tap(); return true }
            return false
        }
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
        app.buttons.matching(identifier: "session-row").element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Record a take"].waitForExistence(timeout: 10))
        app.buttons["Record a take"].tap()
        // Wait for the camera view; the tap below lets the monitor answer a permission alert.
        _ = app.buttons["Record"].waitForExistence(timeout: 10)
        app.tap()
        app.settle(timeout: 3)
        shot(app, "50-record-island")
        app.buttons["Record"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        shot(app, "51-recording")
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Send to Mac"].waitForExistence(timeout: 10))
        // The take plays here, so the screen never rests: a short settle is enough for the picture.
        app.settle(timeout: 2)
        shot(app, "52-take-review")
        app.buttons["Record another take"].tap()
        XCTAssertTrue(app.buttons["Record"].waitForExistence(timeout: 10))
        app.settle(timeout: 1)
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
        app.settle(timeout: 3)
        for i in 1...5 {
            shot(app, "40-performance-\(i)")
            app.swipeUp()
            app.settle(timeout: 1)
        }
    }

    /// The Videos home: the big card, the grid of covers, the posted row.
    func testHome() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15))
        app.settle(timeout: 4)
        shot(app, "70-home")
        app.swipeUp()
        app.settle(timeout: 2)
        shot(app, "71-home-grid")
        app.swipeUp()
        app.settle(timeout: 2)
        shot(app, "72-home-posted")
    }

    /// The Board tab: the strip, the big shot, a swipe to the next one, a shot with a note.
    func testStoryboard() throws {
        let env = ProcessInfo.processInfo.environment
        try standin("/test/screens")
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
        // The video may sit far down the grid: search for it.
        let search = app.textFields["Find a session or a clip"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("make videos with")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'make videos with'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.buttons["Board"].waitForExistence(timeout: 15))
        app.buttons["Board"].tap()
        let shots = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Shot'"))
        XCTAssertTrue(shots.element(boundBy: 4).waitForExistence(timeout: 10))
        app.settle(timeout: 4)
        shot(app, "50-board")
        app.swipeLeft()
        app.settle(timeout: 2)
        shot(app, "51-board-next")
        shots.element(boundBy: 4).tap()
        app.settle(timeout: 3)
        shot(app, "52-board-note")
        app.swipeUp()
        app.settle(timeout: 1)
        shot(app, "53-board-note-field")
    }

    /// Appearance: the picker, then the app in another theme and in dark mode.
    func testAppearance() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
        XCTAssertTrue(app.buttons["Takes menu"].waitForExistence(timeout: 15))
        app.buttons["Takes menu"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.settle(timeout: 1)
        shot(app, "59-takes-menu")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Sand"].waitForExistence(timeout: 5))
        app.settle(timeout: 1)
        shot(app, "60-appearance")
        // Settings holds forgetting the Mac too, out of the Takes menu (2026-10-11).
        app.swipeUp()
        XCTAssertTrue(app.buttons["Forget this Mac"].waitForExistence(timeout: 5))
        shot(app, "60b-settings-mac")
        app.swipeDown()
        app.buttons["Sand"].tap()
        app.buttons["Dark"].tap()
        app.settle(timeout: 1)
        shot(app, "61-appearance-sand-dark")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Sand"].waitForNonExistence(timeout: 5))
        app.settle(timeout: 1)
        shot(app, "62-videos-sand-dark")
        app.buttons["Takes menu"].tap()
        app.buttons["Settings"].tapWhenReady()
        app.buttons["Reset"].tapWhenReady()
        app.buttons["Done"].tap()
    }

    func testCommentDeck() throws {
        let env = ProcessInfo.processInfo.environment
        try standin("/test/screens")
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        app.page("Comments")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review'")).firstMatch.tap()
        // The deck has no Approve button (a swipe right approves): its More shows the card is up.
        XCTAssertTrue(app.buttons["More: edit, note, decline"].waitForExistence(timeout: 10))
        shot(app, "20-deck")
        app.staticTexts["Tap to copy"].firstMatch.tap()
        app.settle(timeout: 1)
        shot(app, "21-deck-copied")
        // How many are left: the count on the Review tab ("Review 3").
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review'")).firstMatch
        let left = review.label
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
        start.press(forDuration: 0.3, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        shot(app, "22-deck-dragging")
        // A short, slow drag springs back.
        XCTAssertEqual(review.label, left)
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 1.2, dy: 0.47)))
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
        app.settle(timeout: 1)
        shot(app, "23-deck-approved")
    }

    /// The LinkedIn look: tabs with counts, the post card, your comment, and the feed video.
    func testFeedLook() throws {
        let env = ProcessInfo.processInfo.environment
        try standin("/test/screens")
        let app = XCUIApplication()
        app.launchEnvironment["TAKES_SERVER"] = env["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        app.page("Comments")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review'")).firstMatch.tap()
        // The deck has no Approve button (a swipe right approves): its More shows the card is up.
        XCTAssertTrue(app.buttons["More: edit, note, decline"].waitForExistence(timeout: 10))
        shot(app, "30-review")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Approved'")).firstMatch.tap()
        app.settle(timeout: 1)
        shot(app, "31-approved")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Posted'")).firstMatch.tap()
        app.settle(timeout: 1)
        app.swipeUp()
        app.settle(timeout: 1)
        shot(app, "32-posted")
        app.buttons["Back to videos"].tapWhenReady()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Claude ran a shop'")).firstMatch.tapWhenReady()
        app.buttons["Post"].tapWhenReady()
        app.settle(timeout: 1)
        app.swipeUp()
        // The feed video plays, so the screen never rests: give it time to start.
        app.settle(timeout: 4)
        shot(app, "33-post-video")
        // Kept: this shot shows the video a few seconds on, so the wait is the point.
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
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Offline video'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        for (item, picker) in [("add-photos", "Photos"), ("add-files", "Browse")] {
            app.buttons["Add files"].tapWhenReady()
            let choice = app.buttons[item]
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "no \(item) in the menu")
            choice.tap()
            let shown = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", picker)).firstMatch
            XCTAssertTrue(shown.waitForExistence(timeout: 8), "the \(item) picker did not open")
            app.settle(timeout: 3)
            shot(app, "add-\(picker)")
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.waitForExistence(timeout: 3) { cancel.tap() }
            // The picker runs out of process: wait for it to close before the next one.
            _ = cancel.waitForNonExistence(timeout: 5)
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
        XCTAssertTrue(app.buttons.matching(identifier: "session-row").firstMatch.waitForExistence(timeout: 15), "the videos list")
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
        app.settle(timeout: 2)
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
        app.settle(timeout: 2)
        assertTailVisible()
        // A streamed reply lands when the tail's words change.
        func grow(file: StaticString = #filePath, line: UInt = #line) throws {
            let before = tail.label
            try fixture("/test/chat/grow")
            XCTAssertTrue(tail.wait(until: "label != %@", before, timeout: 10), "the reply never grew", file: file, line: line)
            app.settle(timeout: 3)
        }
        try grow()
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
        app.settle(timeout: 2)
        let latest = app.buttons["Jump to latest message"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        let reading = try XCTUnwrap(visibleEarlier())
        let readingY = reading.frame.minY
        try fixture("/test/chat/grow")
        // Kept: the tail is off screen, so nothing shows the reply landed, and the point is that
        // the reader does not move. Give the app time to take the stream in.
        sleep(3)
        XCTAssertEqual(reading.frame.minY, readingY, accuracy: 2, "A streaming reply moved the reader")
        XCTAssertTrue(latest.exists)
        shot(app, "chat-3-reading-history")
        latest.tap()
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
        app.settle(timeout: 2)
        assertTailVisible()
        try fixture("/test/chat/finish")
        // Nothing marks the end of a run on screen; the next poll may still move the tail.
        app.settle(timeout: 3)
        assertTailVisible()
        shot(app, "chat-4-finished")

        // Sending from history is another explicit request to return to the conversation.
        for _ in 0..<3 { transcript.swipeDown() }
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        messageField().tap()
        app.typeText(" and send")
        app.buttons["Send"].tap()
        XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
        let sent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Four lines and send'")).firstMatch
        XCTAssertTrue(sent.wait(for: \.isHittable, toEqual: true, timeout: 5))
        app.settle(timeout: 2)
        shot(app, "chat-5-sent-from-history")
    }

    /// Turns on a stand-in fixture, e.g. /test/screens.
    private func standin(_ path: String) throws {
        let server = ProcessInfo.processInfo.environment["TAKES_SERVER"] ?? "http://127.0.0.1:8797"
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: URL(string: server + path)!) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
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
    /// Opens a page from the Takes menu (Performance, Comments, plugins, Styles), where
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
