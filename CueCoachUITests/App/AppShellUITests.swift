import XCTest

/// App shell flows (docs/design/app-shell.md). Fake mesh via `-appshell.fakeMesh`; in-memory roster via `-appshell.uitest`.
/// Screenshots: XCTAttachments, plus PNGs in $APPSHELL_SHOTS (set TEST_RUNNER_APPSHELL_SHOTS) when given.
final class AppShellUITests: XCTestCase {
    enum Variant: String { case standard, ax5, reduceMotion }

    override func setUp() { continueAfterFailure = false }

    @MainActor func launch(_ extra: [String] = [], variant: Variant = .standard) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-appshell.uitest"] + extra
        switch variant {
        case .standard: break
        case .ax5: args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        case .reduceMotion: args += ["-appshell.reduceMotion"]
        }
        app.launchArguments = args
        app.launch()
        return app
    }

    @MainActor func shot(_ app: XCUIApplication, _ name: String, _ variant: Variant = .standard) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = "\(name)-\(variant.rawValue)"
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["APPSHELL_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(variant.rawValue).png"))
        }
    }

    @MainActor func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor func wait(_ app: XCUIApplication, _ id: String, _ t: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = element(app, id)
        if !e.waitForExistence(timeout: t) { print("TREE:\n\(app.debugDescription)") }
        XCTAssertTrue(e.exists, "missing \(id)", file: file, line: line)
        return e
    }

    @MainActor func waitValue(_ e: XCUIElement, _ value: String, _ t: TimeInterval = 8) {
        expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: e)
        waitForExpectations(timeout: t)
    }

    /// Tap `id` once it is hittable and wait for `destination`. On the device a tap right after launch can be
    /// swallowed (the tile exists but the app isn't taking touches yet): if the destination doesn't show, tap
    /// once more. The destination is still asserted, with the full timeout.
    @MainActor @discardableResult
    func tapThrough(_ app: XCUIApplication, _ id: String, to destination: String, _ t: TimeInterval = 8,
                    file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = wait(app, id, file: file, line: line)
        let hittable = NSPredicate(format: "isHittable == true")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hittable, object: e)], timeout: 5)
        e.tap()
        if !element(app, destination).waitForExistence(timeout: 3), e.exists, e.isHittable { e.tap() }
        return wait(app, destination, t, file: file, line: line)
    }

    /// After a navigation the push may still be settling (reduce motion, a loaded Mac): wait up to `t` for the
    /// element to become hittable, then assert it. Same assertion, waited for.
    @MainActor func assertHittable(_ e: XCUIElement, _ t: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: e)], timeout: t)
        XCTAssertTrue(e.isHittable, "\(e.identifier) not hittable", file: file, line: line)
    }

    @MainActor func tapSeat(_ app: XCUIApplication, _ seat: String, pick: String) {
        wait(app, "setup.seat.\(seat)").tap()
        wait(app, pick).tap()
    }

    // MARK: Home → Game → New game → Live → Review → Home

    @MainActor func testNewGameToLiveToReviewAndHome() {
        let app = launch(["-appshell.fakeMesh=host", "-appshell.demoShot"])
        let game = wait(app, "home.game")
        XCTAssertGreaterThanOrEqual(game.frame.height, 120)
        XCTAssertGreaterThanOrEqual(element(app, "home.settings").frame.width, 44)
        shot(app, "01-home")
        game.tap()
        tapThrough(app, "game.new", to: "setup.start")
        let start = wait(app, "setup.start")
        XCTAssertEqual(start.value as? String, "not ready")
        start.tap()                                   // blocked: stays here
        XCTAssertTrue(start.exists)
        shot(app, "03-setup-empty")

        tapSeat(app, "0.0", pick: "seat.player.Ari")
        tapSeat(app, "1.0", pick: "seat.guest")
        XCTAssertTrue(wait(app, "setup.phone.p1").exists)   // a joiner appeared live
        waitValue(element(app, "setup.phones"), "3")
        element(app, "setup.table.nineFoot").tap()
        XCTAssertEqual(start.value as? String, "ready")
        shot(app, "04-setup-ready")
        start.tap()

        wait(app, "shell.live.game")
        wait(app, "postshot.badge.great", 8)
        shot(app, "05-live-badge")
        // Demo shot passed the turn (D17 A1 → B1).
        XCTAssertEqual(element(app, "chrome.team.1").value as? String, "shooting")
        wait(app, "chrome.menu").tap()
        shot(app, "06-live-menu")
        tapThrough(app, "chrome.endGame", to: "review.done")
        wait(app, "review.done", 8)
        shot(app, "07-review")
        element(app, "review.done").tap()
        XCTAssertTrue(wait(app, "home.game").exists)
    }

    /// D37: LiveScreen's own ✕ in a game asks "End game?" first. "Keep playing" stays in Live; "End game" dismisses
    /// the cover and the shell re-presents Review, then Done → Home.
    @MainActor func testCloseAsksBeforeEndingAGame() {
        let app = launch()
        tapThrough(app, "home.game", to: "game.new")
        wait(app, "game.new").tap()
        tapSeat(app, "0.0", pick: "seat.player.Ari")
        tapSeat(app, "1.0", pick: "seat.player.Sam")
        element(app, "setup.start").tap()
        wait(app, "shell.live.game")
        let alert = app.alerts["End game?"]
        wait(app, "live.close").tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "✕ in a game asks first")
        alert.buttons["Keep playing"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(wait(app, "shell.live.game").exists)
        XCTAssertFalse(element(app, "review.done").exists)
        wait(app, "live.close").tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "✕ in a game asks first")
        alert.buttons["End game"].tap()
        wait(app, "review.done", 10).tap()
        XCTAssertTrue(wait(app, "home.game").exists)
    }

    @MainActor func testMidGameOrderEdit() {
        let app = launch()
        tapThrough(app, "home.game", to: "game.new")
        tapThrough(app, "game.new", to: "setup.format.teams")
        wait(app, "setup.format.teams").tap()
        tapSeat(app, "0.0", pick: "seat.player.Ari")
        tapSeat(app, "1.0", pick: "seat.player.Sam")
        tapSeat(app, "0.1", pick: "seat.player.Ana")
        tapSeat(app, "1.1", pick: "seat.player.Bo")
        element(app, "setup.start").tap()
        tapThrough(app, "chrome.menu", to: "chrome.order.0.0")
        wait(app, "chrome.order.0.0").tap()
        element(app, "chrome.order.0.1").tap()
        XCTAssertTrue(element(app, "chrome.order.0.0").label.hasPrefix("Ana"))
        shot(app, "06b-order-edit")
        element(app, "chrome.resume").tap()
        XCTAssertTrue(wait(app, "chrome.team.0").label.contains("Ari"))   // Ari keeps the turn
    }

    @MainActor func testTeamsShowD17OrderAndOneTapTurnCorrection() {
        let app = launch()
        tapThrough(app, "home.game", to: "game.new")
        tapThrough(app, "game.new", to: "setup.format.teams")
        wait(app, "setup.format.teams").tap()
        tapSeat(app, "0.0", pick: "seat.player.Ari")
        tapSeat(app, "1.0", pick: "seat.player.Sam")
        tapSeat(app, "0.1", pick: "seat.player.Ana")
        tapSeat(app, "1.1", pick: "seat.player.Bo")
        let order = ["0.0", "1.0", "0.1", "1.1"].map { element(app, "setup.seat.\($0)").frame.minX }
        // Wrapped rows aside, the first row reads left to right in shooting order.
        XCTAssertLessThan(order[0], order[1])
        XCTAssertTrue((element(app, "setup.seat.1.0").label).contains("shoots 2nd"))
        XCTAssertTrue((element(app, "setup.seat.0.1").label).contains("shoots 3rd"))
        shot(app, "04b-setup-teams")
        element(app, "setup.start").tap()
        wait(app, "shell.live.game")
        XCTAssertEqual(wait(app, "chrome.team.0").value as? String, "shooting")
        let b = wait(app, "chrome.team.1")
        XCTAssertEqual(b.value as? String, "waiting")
        b.tap()                                       // hand the turn to team B
        XCTAssertEqual(b.value as? String, "shooting")
        XCTAssertTrue(b.label.contains("Sam"))
    }

    // MARK: Home → Training → Live

    @MainActor func testTrainingToLiveAndBack() {
        let app = launch()
        tapThrough(app, "home.training", to: "training.drill.banks")
        tapThrough(app, "training.drill.banks", to: "training.level.4")
        wait(app, "training.level.4").tap()
        XCTAssertEqual(element(app, "training.levelName").label, "No help")
        shot(app, "08-training")
        tapThrough(app, "training.start", to: "shell.live.training")
        wait(app, "shell.live.training")
        XCTAssertFalse(element(app, "chrome.team.0").exists)   // no turn chrome in Training
        tapThrough(app, "chrome.menu", to: "chrome.stop")
        wait(app, "chrome.stop").tap()
        XCTAssertTrue(wait(app, "training.start").exists)
        XCTAssertTrue(element(app, "training.drill.banks").isSelected)
    }

    // MARK: Home → Game → Join nearby (fake mesh)

    @MainActor func testJoinNearbySeesLineupThenHostStarts() {
        let app = launch(["-appshell.fakeMesh=games"])
        tapThrough(app, "home.game", to: "game.join")
        tapThrough(app, "game.join", to: "join.state")
        let state = wait(app, "join.state")
        wait(app, "join.game.g1").tap()
        waitValue(state, "joined")
        wait(app, "join.lineup.Sam")
        wait(app, "join.lineup.Ari", 6)            // lineup synced live from the host
        shot(app, "10-join-waiting")
        wait(app, "shell.live.game", 10)
        XCTAssertTrue(wait(app, "chrome.team.0").label.contains("Sam"))
    }

    @MainActor func testJoinNearbyListShot() {
        let app = launch(["-appshell.fakeMesh=games"])
        wait(app, "home.game").tap()
        shot(app, "02-gamehub")
        tapThrough(app, "game.join", to: "join.game.g2")
        wait(app, "join.game.g2")
        shot(app, "09-join-list")
    }

    @MainActor func testJoinFullLobby() {
        let app = launch(["-appshell.fakeMesh=full"])
        tapThrough(app, "home.game", to: "game.join")
        tapThrough(app, "game.join", to: "join.game.g1")
        wait(app, "join.game.g1").tap()
        waitValue(element(app, "join.state"), "full")
        shot(app, "11-join-full")
        tapThrough(app, "join.back", to: "join.game.g1")
        wait(app, "join.game.g1")
    }

    @MainActor func testJoinHostLeft() {
        let app = launch(["-appshell.fakeMesh=hostLeft"])
        tapThrough(app, "home.game", to: "game.join")
        tapThrough(app, "game.join", to: "join.game.g1")
        wait(app, "join.game.g1").tap()
        waitValue(element(app, "join.state"), "hostLeft", 10)
        shot(app, "12-join-hostleft")
    }

    @MainActor func testSettingsAndProfileFromHome() {
        let app = launch()
        tapThrough(app, "home.settings", to: "sheet.done")
        tapThrough(app, "sheet.done", to: "home.profile")
        tapThrough(app, "home.profile", to: "shell.profile.nameField")
        let name = wait(app, "shell.profile.nameField")
        name.tap()
        name.typeText("Ari")
        shot(app, "13-profile-create")
        element(app, "shell.profile.save").tap()
        wait(app, "profile.name")                                       // screens-a profile header
        XCTAssertTrue(app.staticTexts["Ari"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "shell.profile.nameField").exists)
        wait(app, "sheet.done").tap()
    }

    // MARK: AX5 + Reduce Motion matrix

    @MainActor func walkMatrix(_ v: Variant) {
        var app = launch(["-appshell.fakeMesh=games", "-appshell.demoShot"], variant: v)
        wait(app, "home.game")
        shot(app, "01-home", v)
        tapThrough(app, "home.game", to: "game.new")
        shot(app, "02-gamehub", v)
        tapThrough(app, "game.new", to: "setup.start")
        shot(app, "03-setup", v)
        tapSeat(app, "0.0", pick: "seat.player.Ari")
        tapSeat(app, "1.0", pick: "seat.guest")
        element(app, "setup.start").tap()
        wait(app, "postshot.badge.great", 8)
        shot(app, "05-live-badge", v)
        app.terminate()

        // Waiting-only lobby: the host never starts, so Live can't cover the join screen mid-check.
        app = launch(["-appshell.fakeMesh=gamesWaiting"], variant: v)
        tapThrough(app, "home.game", to: "game.join")
        tapThrough(app, "game.join", to: "join.game.g1")
        shot(app, "09-join-list", v)
        element(app, "join.game.g1").tap()
        wait(app, "join.lineup.Ari", 6)
        // The next step and the way out are in the first viewport at every size.
        assertHittable(element(app, "join.waiting"))
        assertHittable(element(app, "join.leave"))
        // ≥ 44 pt touch target (the frame must be on the tappable label, not outside the button).
        XCTAssertGreaterThanOrEqual(element(app, "join.leave").frame.height, 44)
        shot(app, "10-join-waiting", v)
        app.terminate()

        app = launch(variant: v)
        tapThrough(app, "home.training", to: "training.start")
        shot(app, "08-training", v)
    }

    @MainActor func testMatrixAX5() { walkMatrix(.ax5) }
    @MainActor func testMatrixReduceMotion() { walkMatrix(.reduceMotion) }
}
