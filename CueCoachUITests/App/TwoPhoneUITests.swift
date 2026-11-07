import XCTest

/// Real two-phone test over MultipeerConnectivity (no fakes). Skipped unless TEST_RUNNER_APPSHELL_ROLE is
/// `host` or `join`. Run the host on one phone and the joiner on the other at the same time.
final class TwoPhoneUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    @MainActor func allowLocalNetwork() {
        for label in ["Allow", "OK"] where springboard.alerts.buttons[label].exists {
            springboard.alerts.buttons[label].tap()
        }
    }

    /// Waits while accepting the Local Network prompt whenever it shows up.
    @MainActor func wait(_ app: XCUIApplication, _ query: () -> XCUIElement, _ t: TimeInterval) -> XCUIElement {
        let end = Date().addingTimeInterval(t)
        while Date() < end {
            allowLocalNetwork()
            let e = query()
            if e.exists { return e }
            _ = e.waitForExistence(timeout: 1)
        }
        print("TREE:\n\(app.debugDescription)")
        XCTFail("timed out")
        return query()
    }

    @MainActor func id(_ app: XCUIApplication, _ s: String) -> XCUIElement { app.descendants(matching: .any)[s].firstMatch }

    @MainActor func testTwoPhones() throws {
        let role = ProcessInfo.processInfo.environment["APPSHELL_ROLE"]
        guard role == "host" || role == "join" else { throw XCTSkip("set TEST_RUNNER_APPSHELL_ROLE") }
        let app = XCUIApplication()
        app.launchArguments = ["-appshell.uitest", "-appshell.realMesh", "-appshell.name=\(role == "host" ? "Host" : "Joiner")"]
        app.launch()
        wait(app, { id(app, "home.game") }, 10).tap()
        if role == "host" { try host(app) } else { try join(app) }
    }

    @MainActor func host(_ app: XCUIApplication) throws {
        wait(app, { id(app, "game.new") }, 10).tap()
        wait(app, { id(app, "setup.seat.0.0") }, 10).tap()
        wait(app, { id(app, "seat.player.Ari") }, 5).tap()
        id(app, "setup.seat.1.0").tap()
        wait(app, { id(app, "seat.player.Sam") }, 5).tap()
        id(app, "setup.rule.wpaNine").tap()
        // The joiner shows up live.
        let phones = id(app, "setup.phones")
        let end = Date().addingTimeInterval(240)
        while Date() < end && (phones.value as? String) != "2" { allowLocalNetwork(); sleep(1) }
        XCTAssertEqual(phones.value as? String, "2", "joiner never appeared")
        add(XCTAttachment(screenshot: app.screenshot()))
        sleep(8)   // let the joiner screenshot the synced lineup
        id(app, "setup.start").tap()
        wait(app, { id(app, "shell.live.game") }, 10)
        XCTAssertTrue(id(app, "chrome.team.0").label.contains("Ari"))
        add(XCTAttachment(screenshot: app.screenshot()))
        sleep(15)
    }

    @MainActor func join(_ app: XCUIApplication) throws {
        wait(app, { id(app, "game.join") }, 10).tap()
        let row = wait(app, { app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'join.game.'")).firstMatch }, 240)
        row.tap()
        let state = id(app, "join.state")
        let end = Date().addingTimeInterval(60)
        while Date() < end && (state.value as? String) != "joined" { allowLocalNetwork(); sleep(1) }
        XCTAssertEqual(state.value as? String, "joined")
        wait(app, { id(app, "join.lineup.Ari") }, 30)
        wait(app, { id(app, "join.lineup.Sam") }, 30)
        XCTAssertTrue(id(app, "join.lineup.rules.wpaNine").exists, "rules did not sync")
        add(XCTAttachment(screenshot: app.screenshot()))
        wait(app, { id(app, "shell.live.game") }, 120)
        XCTAssertTrue(id(app, "chrome.team.0").label.contains("Ari"))
        add(XCTAttachment(screenshot: app.screenshot()))
    }
}
