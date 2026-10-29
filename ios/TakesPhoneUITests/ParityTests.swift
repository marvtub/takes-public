import XCTest

/// The screens that copy the Mac (2026-10-09, PhoneParity.swift), against ios/standin.py:
/// ios/check.sh parity. Each step saves a screenshot to TAKES_SHOTS to compare with the Mac's.
final class ParityTests: XCTestCase {
    var server: String { ProcessInfo.processInfo.environment["TAKES_SERVER"] ?? "http://127.0.0.1:8798" }

    override func setUp() {
        super.setUp()
        freshStandin()
    }

    func get(_ path: String) throws -> Data {
        var out: Data?
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: URL(string: server + path)!) { d, _, _ in out = d; done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(out)
    }

    func log() -> [[String: Any]] { ((try? JSONSerialization.jsonObject(with: try get("/test/log"))) as? [[String: Any]]) ?? [] }

    /// Waits for the stand-in to log a change that matches.
    func logged(_ match: ([String: Any]) -> Bool) -> Bool { eventually { log().contains(where: match) } }

    /// The same for a Plan button's /api/plan call.
    func planLogged(_ match: @escaping ([String: Any]) -> Bool) -> Bool {
        logged { ($0["/api/plan"] as? [String: Any]).map(match) ?? false }
    }

    func open(_ app: XCUIApplication) {
        app.launchEnvironment["TAKES_SERVER"] = server
        app.launch()
        app.buttons["Connect"].tap()
        let row = app.buttons.matching(identifier: "session-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
    }

    func testEverydayActions() throws {
        _ = try get("/test/parity")
        let app = XCUIApplication()
        open(app)
        shot(app, "p1-0-list")
        app.buttons["Tests actions"].tap()
        app.settle(timeout: 1)
        shot(app, "p1-1-project-panel")
        app.buttons["Rename…"].tap()
        app.settle(timeout: 1)
        shot(app, "p1-2-rename-project")
        app.buttons["Cancel"].tap()
        app.buttons.matching(identifier: "session-row").firstMatch.tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "p1-2b-session")
        app.buttons["More"].firstMatch.tap()
        app.settle(timeout: 1)
        shot(app, "p1-3-session-more")
        app.buttons["Move to project"].tap()
        app.settle(timeout: 1)
        shot(app, "p1-4-move-open")
        app.buttons["Move session to Trash"].tap()
        app.settle(timeout: 1)
        shot(app, "p1-5-confirm-trash")
        app.buttons["Cancel"].tap()
        app.buttons["Script"].tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "p1-6-script-drafts")
        app.buttons["Short"].firstMatch.tap()
        app.settle(timeout: 1)
        shot(app, "p1-7-script-variant")
        app.buttons["Script history"].tap()
        app.settle(timeout: 2)
        shot(app, "p1-8-history")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Wrote the hook'")).firstMatch.tap()
        app.settle(timeout: 1)
        shot(app, "p1-9-history-version")
        app.buttons["Restore This Version"].tap()
        XCTAssertTrue(logged { ($0["/api/script/draft"] as? [String: String])?["action"] == "restore" }, "\(log())")
        app.buttons["Files"].tap()
        // The tab remembers its page (Files, B-roll, Sound): the second "Files" is the switch.
        app.buttons.matching(NSPredicate(format: "label == 'Files'")).element(boundBy: 1).tapWhenReady()
        app.settle(timeout: 2)
        shot(app, "p1-10-files")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Take 1'")).firstMatch.tap()
        app.buttons["More"].firstMatch.tapWhenReady()
        app.settle(timeout: 2)
        shot(app, "p1-11-take-more")
        app.buttons["Clean voice…"].tap()
        app.settle(timeout: 2)
        shot(app, "p1-12-voice")
        app.buttons["Clean voice"].firstMatch.tap()
        app.settle(timeout: 2)
        shot(app, "p1-13-voice-done")
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Close"].firstMatch.tapWhenReady()
        app.buttons["Post"].tapWhenReady()
        app.buttons["Post history"].firstMatch.tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "p1-14-post-history")
    }

    /// Stage 2: the schedule panel, the plan on the list, and X's variants and hooks.
    func testScheduleAndPlatformVariants() throws {
        _ = try get("/test/parity")
        let app = XCUIApplication()
        open(app)
        app.buttons.matching(identifier: "session-row").firstMatch.tap()
        app.buttons["Post"].tapWhenReady()
        // The tab remembers the platform from the last run.
        app.buttons["LinkedIn"].firstMatch.tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "p2-0-post")
        app.buttons["Schedule"].firstMatch.tap()
        app.settle(timeout: 2)
        shot(app, "p2-1-schedule")
        app.buttons["Set time"].tap()
        XCTAssertTrue(logged { ($0["/api/schedule"] as? [String: String])?["action"] == "set" }, "\(log())")
        app.settle(timeout: 2)
        shot(app, "p2-2-planned")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'When it goes out'")).firstMatch.tap()
        app.settle(timeout: 2)
        shot(app, "p2-3-schedule-again")
        app.buttons["Back to Draft"].tap()
        XCTAssertTrue(logged { ($0["/api/schedule"] as? [String: String])?["action"] == "draft" }, "\(log())")
        app.buttons["Schedule"].firstMatch.tap()
        app.buttons["Set time"].tapWhenReady()
        app.buttons["X"].firstMatch.tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "p2-4-x")
        app.buttons["Thread"].firstMatch.tap()
        app.settle(timeout: 1)
        shot(app, "p2-5-x-variant")
        app.buttons["Use hook: 75 updates in 4 days."].tap()
        XCTAssertTrue(logged { ($0["/api/post/draft"] as? [String: String])?["hook"] == "x2" }, "\(log())")
        app.buttons["Back"].firstMatch.tap()
        app.settle(timeout: 1)
        app.swipeDown()
        app.settle(timeout: 2)
        shot(app, "p2-6-list")
    }

    /// Stage 3: a shot's variants and Make Final, a take's card, B-roll and Sound on the Files tab.
    func testBoardBrollAndSound() throws {
        _ = try get("/test/parity")
        let app = XCUIApplication()
        open(app)
        app.buttons.matching(identifier: "session-row").firstMatch.tap()
        app.buttons["Board"].tapWhenReady()
        app.settle(timeout: 2)
        shot(app, "p3-0-board")
        app.buttons["Try B"].tap()
        app.settle(timeout: 1)
        shot(app, "p3-1-variant")
        app.buttons["Use B in the video"].tap()
        XCTAssertTrue(logged { ($0["/api/shot"] as? [String: String])?["action"] == "pick" }, "\(log())")
        app.buttons["Take 2"].tap()
        app.settle(timeout: 1)
        shot(app, "p3-2-take-card")
        app.buttons["Find the Best Cut Again"].tap()
        XCTAssertTrue(logged { ($0["/api/shot"] as? [String: String])?["action"] == "cut" }, "\(log())")
        app.buttons["Files"].tap()
        app.buttons["B-roll"].tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "p3-3-broll")
        app.buttons["Add Typing to this session"].tap()
        XCTAssertTrue(logged { ($0["/api/broll"] as? [String: String])?["action"] == "add" }, "\(log())")
        app.settle(timeout: 2)
        shot(app, "p3-4-broll-added")
        app.buttons["Sound"].tap()
        app.settle(timeout: 2)
        shot(app, "p3-5-sound")
        app.buttons["Use"].firstMatch.tap()
        XCTAssertTrue(logged { ($0["/api/sounds"] as? [String: String])?["action"] == "use" }, "\(log())")
        app.buttons["SFX"].tap()
        app.buttons["Add"].firstMatch.tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "p3-6-place")
        app.buttons["Later"].tap()
        app.buttons["Later"].tap()
        app.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(logged { ($0["/api/sounds"] as? [String: String])?["video"] != nil }, "\(log())")
        app.settle(timeout: 2)
        shot(app, "p3-7-sound-set")
        app.buttons["Files"].firstMatch.tap()
    }

    /// Stage 4: the memory card and Compact, the chat's tools, past conversations, and @ to name a file.
    func testChatToolsAndRefs() throws {
        _ = try get("/test/parity")
        let app = XCUIApplication()
        open(app)
        app.buttons.matching(identifier: "session-row").firstMatch.tap()
        app.buttons["Chat"].tapWhenReady()
        app.settle(timeout: 2)
        shot(app, "p4-0-chat")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Context'")).firstMatch.tap()
        app.settle(timeout: 1)
        shot(app, "p4-1-memory")
        app.buttons["Compact now"].tap()
        XCTAssertTrue(logged { $0["say"] as? String == "/compact" }, "\(log())")
        // The log answers before the memory card has closed: a tap then lands on the card's
        // shade and the tools never open.
        XCTAssertTrue(app.buttons["Compact now"].waitForNonExistence(timeout: 5))
        app.settle(timeout: 1)
        app.buttons["Conversations"].tapWhenReady()
        XCTAssertTrue(app.buttons["Past conversations…"].waitForExistence(timeout: 5))
        app.settle(timeout: 1)
        shot(app, "p4-2-tools")
        app.buttons["Past conversations…"].tapWhenReady()
        app.settle(timeout: 2)
        shot(app, "p4-3-past")
        app.buttons["Open Write the hook"].tap()
        XCTAssertTrue(logged { ($0["/api/chat/history"] as? [String: String])?["file"] == "c0.json" }, "\(log())")
        XCTAssertTrue(app.descendants(matching: .any)["chat-input"].waitForExistence(timeout: 10))
        let box = app.textFields["chat-input"].exists ? app.textFields["chat-input"] : app.textViews["chat-input"]
        box.tap()
        box.typeText("Look at @Ta")
        app.settle(timeout: 1)
        shot(app, "p4-4-at")
        app.buttons["Take 1"].firstMatch.tap()
        app.settle(timeout: 1)
        shot(app, "p4-5-ref")
        app.buttons["Add files"].tap()
        app.settle(timeout: 1)
        shot(app, "p4-6-plus")
        app.buttons["Add files"].tap()
        app.buttons["Send"].tap()
        XCTAssertTrue(logged { ($0["say"] as? String)?.contains("take-01-camera.mov") == true }, "\(log())")
    }

    /// Stage 5: ⌘K as the Search screen.
    /// While Takes works, a message waits in the queue above the box and its x takes it back.
    func testQueueWhileWorking() throws {
        _ = try get("/test/parity")
        _ = try get("/test/chat/busy")
        let app = XCUIApplication()
        open(app)
        app.buttons.matching(identifier: "session-row").firstMatch.tap()
        if app.buttons["Chat"].waitForExistence(timeout: 10) { app.buttons["Chat"].tap() }
        let box = app.textViews["chat-input"].exists ? app.textViews["chat-input"] : app.textFields["chat-input"]
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        box.tap()
        box.typeText("Also make it vertical")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Also make it vertical"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Take it out of the queue"].exists)
        shot(app, "q-1-queued")
        app.buttons["Take it out of the queue"].tap()
        XCTAssertTrue(app.staticTexts["Also make it vertical"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(logged { $0["/api/chat/unqueue"] as? String == "0" }, "\(log())")
    }

    func testSearch() throws {
        _ = try get("/test/parity")
        let app = XCUIApplication()
        open(app)
        app.buttons["Takes menu"].tap()
        app.settle(timeout: 1)
        shot(app, "p5-menu")
        XCTAssertFalse(app.buttons["Search"].exists, "Search left the Takes menu (2026-10-11)")
        app.buttons["Takes menu"].tap()
        // The panel folds up and the field moves with it: a tap before it rests misses the field.
        XCTAssertTrue(app.buttons["Settings"].waitForNonExistence(timeout: 5))
        app.settle(timeout: 1)
        // Search starts from Find a session: its words carry over to the clip search.
        let find = app.textFields["Find a session or a clip"]
        find.tapWhenReady()
        find.typeText("typing")
        app.settle(timeout: 1)
        shot(app, "p5-0-search")
        app.buttons["Search clips"].tap()
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.wait(until: "value == 'typing'", timeout: 10), "\(field.value ?? "")")
        shot(app, "p5-1-hits")
        app.buttons["Edits"].tap()
        XCTAssertTrue(logged { ($0["/api/search"] as? [String: String])?["filter"] == "edits" }, "\(log())")
        app.buttons["All"].tap()
        app.settle(timeout: 1)
        // The results page (2026-10-28): the sort puts the hits in date groups.
        app.buttons["search-sort"].tapWhenReady()
        app.settle(timeout: 1)
        shot(app, "p5-3-sort-menu")
        app.buttons["Newest first"].tapWhenReady()
        XCTAssertTrue(logged { ($0["/api/search"] as? [String: String])?["sort"] == "newest" }, "\(log())")
        XCTAssertTrue(app.staticTexts["This week"].waitForExistence(timeout: 10))
        app.settle(timeout: 2)
        shot(app, "p5-4-sorted")
        // A clip opens its preview first, in its own shape, with the moments found in it.
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'hands typing'")).firstMatch.tapWhenReady()
        XCTAssertTrue(app.staticTexts["Vertical 9:16 · 1080×1920 · 0:48"].waitForExistence(timeout: 10))
        app.settle(timeout: 2)
        shot(app, "p5-5-preview")
        app.buttons["Back"].tapWhenReady()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Offline video'")).firstMatch.tapWhenReady()
        app.settle(timeout: 2)
        shot(app, "p5-2-session")
    }

    /// The Update row lists the build's changes, open at first, as the Mac's What's new (2026-10-11).
    func testWhatsNew() throws {
        _ = try get("/test/parity")
        _ = try get("/test/update")
        let app = XCUIApplication()
        open(app)
        XCTAssertTrue(app.buttons["Update the app"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["The body reads as markdown"].exists, "changes show without a tap")
        shot(app, "p6-whats-new")
        app.buttons["Hide what's new"].tap()
        XCTAssertTrue(app.staticTexts["The body reads as markdown"].waitForNonExistence(timeout: 5))
    }

    /// Plan (2026-10-25): the board, a day's +, a card's menu, Add a week, Change days and the Plan
    /// chat. Each button reaches the Mac as the Mac's own (PlanPhone.swift).
    func testPlan() throws {
        _ = try get("/test/parity")
        let app = XCUIApplication()
        open(app)
        app.page("Plan")
        XCTAssertTrue(app.staticTexts["Your next 3 posting days have a video. Next free one: Tue, Oct 20."].waitForExistence(timeout: 10), "the board loads")
        app.settle(timeout: 1)
        shot(app, "p8-a-plan")
        app.buttons["2 weeks in a row"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 rest week free this month'")).firstMatch.waitForExistence(timeout: 3))
        app.swipeUp()
        app.settle(timeout: 1)
        shot(app, "p8-b-plan-weeks")
        app.swipeUp()
        app.settle(timeout: 1)
        shot(app, "p8-c-plan-weeks-more")

        // A day's +: find a video, tap it.
        let add = app.buttons["Add a video to Tue 20"]
        for _ in 0..<3 where !add.isHittable { app.swipeUp() }
        add.tap()
        XCTAssertTrue(app.buttons["Office tour"].waitForExistence(timeout: 10), "the picker lists the sessions")
        shot(app, "p8-d-plan-add")
        app.buttons["Office tour"].tap()
        XCTAssertTrue(planLogged { $0["action"] as? String == "place" && $0["id"] as? String == "Proj/Office tour" && $0["day"] as? String == "2026-10-20" }, "\(log())")

        // A card's menu: Move up on its day.
        let more = app.buttons["Move or take off Three cheap formats"]
        for _ in 0..<3 where !more.isHittable { app.swipeDown() }
        more.tap()
        XCTAssertTrue(app.buttons["Move up on Tue 13"].waitForExistence(timeout: 5))
        shot(app, "p8-e-plan-card-menu")
        app.buttons["Move up on Tue 13"].tap()
        XCTAssertTrue(planLogged { $0["action"] as? String == "place" && $0["before"] as? String == "Proj/Teleprompter tricks" }, "\(log())")

        let week = app.buttons["Add a week"]
        for _ in 0..<4 where !week.isHittable { app.swipeUp() }
        week.tap()
        XCTAssertTrue(planLogged { $0["action"] as? String == "weeks" && $0["n"] as? Int == 4 }, "\(log())")

        // Change days: Saturday on, Save.
        for _ in 0..<6 { app.swipeDown() }
        app.buttons["Change days"].tap()
        XCTAssertTrue(app.buttons["Sat"].waitForExistence(timeout: 5))
        app.settle(timeout: 1)
        shot(app, "p8-f-plan-change-days")
        app.buttons["Sat"].tap()
        let save = app.buttons["Save"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        shot(app, "p8-g-plan-change-days-more")
        save.tap()
        XCTAssertTrue(planLogged {
            $0["action"] as? String == "save" && ($0["days"] as? [String]) == ["tue", "thu", "sat"] && $0["time"] as? String == "08:02"
        }, "\(log())")

        XCTAssertTrue(app.buttons["Plan chat"].waitForExistence(timeout: 5))
        app.buttons["Plan chat"].tap()
        app.settle(timeout: 2)
        shot(app, "p8-h-plan-chat")
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = ProcessInfo.processInfo.environment["TAKES_SHOTS"] ?? NSTemporaryDirectory()
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}
