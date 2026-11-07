import XCTest

/// Simulator has no camera/ARKit: the live screen replays a synthetic table through the same
/// locator → auto-lock → detection → aim path.
final class LiveReplayUITests: XCTestCase {
    @MainActor func testPlayLocksTableWithoutTapsAndShowsBallsAndAim() {
        let app = XCUIApplication()
        app.launch()
        let play = app.buttons["home.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(play.frame.width, 64)
        play.tap()

        let overlay = app.descendants(matching: .any)["live.overlay"].firstMatch
        if !overlay.waitForExistence(timeout: 5) { print("TREE:\n\(app.debugDescription)") }
        XCTAssertTrue(overlay.exists)
        let locked = NSPredicate(format: "value CONTAINS 'calibrated:true'")
        expectation(for: locked, evaluatedWith: overlay)
        waitForExpectations(timeout: 15)

        let balls = NSPredicate(format: "value CONTAINS 'balls:6'")
        expectation(for: balls, evaluatedWith: overlay)
        waitForExpectations(timeout: 10)

        let aim = NSPredicate(format: "value CONTAINS 'aim:true'")
        expectation(for: aim, evaluatedWith: overlay)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.descendants(matching: .any)["live.shotDock"].exists)

        // Recalibrate goes back to locating, then relocks on its own.
        // (Replay relocks in ~1 s, faster than XCUITest polls, so assert the relock end state.)
        app.buttons["live.recalibrate"].tap()
        expectation(for: NSPredicate(format: "value CONTAINS 'calibrated:true' AND value CONTAINS 'balls:6'"),
                    evaluatedWith: overlay)
        waitForExpectations(timeout: 15)

        app.buttons["live.close"].tap()
        XCTAssertTrue(app.images["home.logo"].waitForExistence(timeout: 5))
    }
}
