import XCTest

extension ParityTests {
    /// Slides in place of the video (2026-10-26): Carousel on the LinkedIn post, Photos on the vertical post.
    func testCarousel() throws {
        _ = try get("/test/parity")
        _ = try get("/test/carousel")
        let app = XCUIApplication()
        open(app)
        app.buttons.matching(identifier: "session-row").firstMatch.tap()
        app.buttons["Post"].tapWhenReady()
        app.buttons["LinkedIn"].firstMatch.tapWhenReady()
        XCTAssertTrue(app.buttons["Carousel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Slide 1 of 4"].waitForExistence(timeout: 5))
        shot(app, "carousel-1-linkedin")
        // A comment on a slide (2026-10-31): the button on the slide, a tap for the whole slide, then the text.
        app.buttons["Comment on slide 1"].tapWhenReady()
        app.descendants(matching: .any)["Slide 1 of 4"].firstMatch.tap()
        let field = app.textFields["What should change?"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Bigger title")
        app.buttons["Save"].tapWhenReady()
        XCTAssertTrue(logged { $0["comment"] as? String == "Bigger title" && $0["slide"] as? Int == 1 && $0["place"] as? String == "linkedin" }, "\(log())")
        XCTAssertTrue(app.staticTexts["Comments on the slides"].waitForExistence(timeout: 5))
        shot(app, "carousel-1b-slide-comment")
        app.buttons["Add a slide"].tap()
        XCTAssertTrue(logged { ($0["/api/carousel"] as? [String: String])?["action"] == "add" }, "\(log())")
        // Each slide has a layout and the set a look (2026-10-29).
        app.buttons["Layout"].tapWhenReady()
        app.buttons["One word"].tapWhenReady()
        XCTAssertTrue(logged { ($0["/api/carousel"] as? [String: String])?["layout"] == "word" }, "\(log())")
        app.buttons["Look"].tapWhenReady()
        app.buttons["Bold"].tapWhenReady()
        XCTAssertTrue(logged { ($0["/api/carousel"] as? [String: String]) == ["look": "bold"] }, "\(log())")

        app.buttons["Vertical"].firstMatch.tap()
        app.buttons["Photos"].tapWhenReady()
        XCTAssertTrue(logged { ($0["/api/carousel"] as? [String: String]) == ["platform": "vertical", "on": "true"] }, "\(log())")
        XCTAssertTrue(app.descendants(matching: .any)["Slide 1 of 5"].waitForExistence(timeout: 5))
        shot(app, "carousel-2-vertical-photos")
    }
}
