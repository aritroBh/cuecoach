import XCTest

/// Simulator has no camera/ARKit: the live screen replays a synthetic table through the same
/// locator → auto-lock → detection → aim path.
final class LiveReplayUITests: XCTestCase {
    @MainActor func testPlayLocksTableWithoutTapsAndShowsBallsAndAim() throws {
        // The synthetic replay table exists only in simulator builds (D20); a device always runs the real AR camera,
        // so on a phone this would test whatever the camera sees.
        #if !targetEnvironment(simulator)
        throw XCTSkip("Replay is simulator-only (D20); device Live uses the AR camera.")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["-appshell.uitest"]
        app.launch()
        // App shell: Home → Training → Start opens Live (was a single Play button).
        let training = app.buttons["home.training"]
        XCTAssertTrue(training.waitForExistence(timeout: 5))
        training.tap()
        let play = app.buttons["training.start"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(play.frame.height, 56)
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
        XCTAssertTrue(app.buttons["training.start"].waitForExistence(timeout: 5))
    }
}
