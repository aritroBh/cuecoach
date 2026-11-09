import XCTest

/// Opens Screens B through the debug router (`-screen=<name>`) and captures every screen/state in three runs:
/// base, largest Dynamic Type (AX5, files suffixed `-xxl`), Reduce Motion.
final class ScreensBUITests: XCTestCase {
    static let shotsDir: URL = {
        let env = ProcessInfo.processInfo.environment["SCREENSB_SHOTS_DIR"]
        return URL(fileURLWithPath: env ?? "/private/tmp/claude-501/-Users-aritro-Downloads-Pool/fb384a25-d7ca-4434-9fb6-43a4e97094df/scratchpad/shots")
    }()

    static let ratings = ["brilliant", "great", "best", "good", "okay", "book", "inaccuracy", "miss", "mistake", "blunder"]

    /// (screen, element that proves it rendered)
    static let states: [(String, String)] = [
        ("lobby", "lobby.start"), ("lobby-locked", "lobby.start"), ("lobby-solo", "lobby.start"),
        ("lobby-peer", "lobby.start"), ("lobby-identity", "lobby.identity.guest"), ("lobby-join", "lobby.sheet.host"),
        ("lobby-meshdenied", "lobby.join"),
        ("review", "review.header"), ("review-loading", "review.loading"), ("review-empty", "review.empty"),
        ("review-locked", "review.header"), ("review-error", "review.replay.unavailable"),
        ("review-short", "review.evalbars"), ("review-failed", "review.failed"),
    ] + ratings.map { ("badge-\($0)", "postshot.badge.\($0)") }

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: Self.shotsDir, withIntermediateDirectories: true)
    }

    @MainActor private func launch(_ screen: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen=\(screen)"] + extra
        app.launch()
        return app
    }

    @MainActor private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor private func snap(_ name: String, _ variant: String) {
        let shot = XCUIScreen.main.screenshot()
        let file = Self.shotsDir.appendingPathComponent("screens-b-\(name)\(variant.isEmpty ? "" : "-\(variant)").png")
        try? shot.pngRepresentation.write(to: file)
        let a = XCTAttachment(screenshot: shot)
        a.name = file.lastPathComponent
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor private func captureAll(variant: String, args: [String]) {
        for (screen, marker) in Self.states {
            let app = launch(screen, args)
            XCTAssertTrue(el(app, marker).waitForExistence(timeout: 10), "\(screen) did not show \(marker)")
            sleep(1)   // let entrance animations settle
            snap(screen, variant)
            switch screen {
            case "review":
                el(app, "review.moment").buttons["Before"].tap()
                snap("review-before", variant)
                app.swipeUp(); app.swipeUp()
                snap("review-cards", variant)
            case "lobby-meshdenied":
                el(app, "lobby.join").tap()
                XCTAssertTrue(el(app, "lobby.meshDenied.settings").waitForExistence(timeout: 5))
                sleep(1)
                snap("lobby-meshdenied-sheet", variant)
            case "lobby":
                app.swipeUp()
                snap("lobby-bottom", variant)
            default: break
            }
            app.terminate()
        }
    }

    // MARK: Screenshot runs

    @MainActor func testScreenshotsBase() { captureAll(variant: "light", args: []) }
    @MainActor func testScreenshotsDynamicTypeXXL() { captureAll(variant: "xxl", args: ["-sbDynamicType=xxl"]) }
    @MainActor func testScreenshotsReduceMotion() { captureAll(variant: "reducemotion", args: ["-sbReduceMotion"]) }

    // MARK: Behaviour

    @MainActor func testBadgeAutoDismissesAndHidesOnAim() {
        let app = launch("badge-live")
        let badge = el(app, "postshot.badge.great")
        XCTAssertTrue(app.buttons["debug.rate"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["debug.rate"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["debug.aim"].frame.height, 44)
        app.buttons["debug.rate"].tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 3))
        // Auto-dismiss after ~1.8 s hold.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: badge)
        waitForExpectations(timeout: 5)
        // Re-rate, then aim: hides instantly.
        app.buttons["debug.rate"].tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 3))
        app.buttons["debug.aim"].tap()
        XCTAssertFalse(badge.waitForExistence(timeout: 0.5))
        // Next shot (Rate = stroke + settle) shows again.
        app.buttons["debug.rate"].tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 2))
    }

    @MainActor func testPinnedBadgeStaysUntilTapped() {
        let app = launch("badge-blunder")
        let badge = el(app, "postshot.badge.blunder")
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        sleep(3)
        XCTAssertTrue(badge.exists)
        badge.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: badge)
        waitForExpectations(timeout: 3)
    }

    @MainActor func testLobbyStartLockedAndVoteAndTable() {
        let app = launch("lobby-locked")
        let start = el(app, "lobby.start")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.value as? String, "Locked")
        let nine = el(app, "lobby.vote.wpaNine")
        nine.tap()
        XCTAssertTrue(nine.label.contains("1 vote"))
        let nineFt = el(app, "lobby.table.nineFoot")
        nineFt.tap()
        XCTAssertTrue(nineFt.label.contains("selected"))
    }

    @MainActor func testLobbyFullCanStartAndShowsOrder() {
        let app = launch("lobby")
        let start = el(app, "lobby.start")
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertNotEqual(start.value as? String, "Locked")
        XCTAssertEqual(el(app, "lobby.order").label, "Shooting order: Ari, Sam, Ana, Bo")
    }

    @MainActor func testLobbyIdentityGuestFillsSeat() {
        let app = launch("lobby-identity")
        XCTAssertTrue(el(app, "lobby.identity.guest").waitForExistence(timeout: 5))
        el(app, "lobby.identity.guest").tap()
        XCTAssertTrue(el(app, "lobby.seat.0.1").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "lobby.seat.0.1").label.hasPrefix("Guest"))
    }

    @MainActor func testReviewSelectsShotFromTimeline() {
        let app = launch("review")
        XCTAssertTrue(el(app, "review.header").waitForExistence(timeout: 5))
        let shot = el(app, "review.shot.9")
        XCTAssertTrue(shot.waitForExistence(timeout: 5))
        shot.tap()
        XCTAssertTrue(shot.isSelected)
        XCTAssertTrue(el(app, "review.replay").label.contains("Engine preferred"))
        XCTAssertTrue(el(app, "review.sotg.play").exists)
        XCTAssertTrue(el(app, "review.sotg.play").elementType == .button)
    }

    @MainActor func testPeerSeesHostLineupAndReadOnlySeats() {
        let app = launch("lobby-peer")
        XCTAssertTrue(el(app, "lobby.start").waitForExistence(timeout: 5))
        XCTAssertEqual(el(app, "lobby.order").label, "Shooting order: Ari, Sam, Ana, empty")
        XCTAssertEqual(el(app, "lobby.start").label, "Waiting for host")
        // Someone else's seat is not a button; tapping it opens nothing.
        el(app, "lobby.seat.0.0").tap()
        XCTAssertFalse(el(app, "lobby.sheet.identity").waitForExistence(timeout: 1))
    }

    @MainActor func testReviewLoadingShowsHeaderSkeleton() {
        let app = launch("review-loading")
        XCTAssertTrue(el(app, "review.loading").waitForExistence(timeout: 5))
        XCTAssertTrue(el(app, "review.header.skeleton").exists)
    }
}
