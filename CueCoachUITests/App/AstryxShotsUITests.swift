import XCTest

/// D34 design pass: one PNG per main screen, for a light and a dark run (the runner sets the simulator's
/// appearance). Writes to $ASTRYX_SHOTS as `<NN-screen>-<ASTRYX_MODE>.png` (set TEST_RUNNER_ASTRYX_SHOTS and
/// TEST_RUNNER_ASTRYX_MODE); without $ASTRYX_SHOTS it only checks that every screen renders.
final class AstryxShotsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var mode: String { ProcessInfo.processInfo.environment["ASTRYX_MODE"] ?? "system" }

    @MainActor private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    @MainActor private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor @discardableResult
    private func wait(_ app: XCUIApplication, _ id: String, _ t: TimeInterval = 10) -> XCUIElement {
        let e = el(app, id)
        XCTAssertTrue(e.waitForExistence(timeout: t), "missing \(id)")
        return e
    }

    @MainActor private func tap(_ app: XCUIApplication, _ id: String, to next: String) {
        let e = wait(app, id)
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"),
                                                             object: e)], timeout: 5)
        e.tap()
        if !el(app, next).waitForExistence(timeout: 3), e.exists, e.isHittable { e.tap() }
        wait(app, next)
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        sleep(1)   // let entrance animations settle
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = "\(name)-\(mode)"
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["ASTRYX_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(mode).png"))
    }

    @MainActor func testShellScreens() {
        var app = launch(["-appshell.uitest", "-appshell.fakeMesh=host", "-appshell.demoShot"])
        wait(app, "home.game")
        shot(app, "01-home")
        tap(app, "home.game", to: "game.new")
        shot(app, "02-gamehub")
        tap(app, "game.new", to: "setup.start")
        wait(app, "setup.seat.0.0").tap(); wait(app, "seat.player.Ari").tap()
        wait(app, "setup.seat.1.0").tap(); wait(app, "seat.guest").tap()
        el(app, "setup.table.nineFoot").tap()
        shot(app, "03-setup")
        el(app, "setup.start").tap()
        wait(app, "postshot.badge.great", 10)
        shot(app, "05-live-badge")
        tap(app, "chrome.menu", to: "chrome.endGame")
        shot(app, "06-live-menu")
        tap(app, "chrome.endGame", to: "review.done")
        shot(app, "07-review")
        app.terminate()

        app = launch(["-appshell.uitest", "-appshell.fakeMesh=gamesWaiting"])
        tap(app, "home.game", to: "game.join")
        tap(app, "game.join", to: "join.game.g1")
        shot(app, "09-join-list")
        el(app, "join.game.g1").tap()
        wait(app, "join.lineup.Ari", 8)
        shot(app, "10-join-waiting")
        app.terminate()

        app = launch(["-appshell.uitest"])
        tap(app, "home.training", to: "training.start")
        shot(app, "08-training")
        tap(app, "training.start", to: "live.overlay")
        let overlay = el(app, "live.overlay")
        expectation(for: NSPredicate(format: "value CONTAINS 'aim:true'"), evaluatedWith: overlay)
        waitForExpectations(timeout: 25)
        shot(app, "04-live-aim")
        app.terminate()

        app = launch(["-appshell.uitest"])
        tap(app, "home.settings", to: "sheet.done")
        shot(app, "11-settings")
        tap(app, "sheet.done", to: "home.profile")
        tap(app, "home.profile", to: "shell.profile.nameField")
        shot(app, "12-profile-create")
    }

    @MainActor func testScreensAAndB() {
        let states: [(String, [String], String)] = [
            ("13-profile", ["-screen=profile", "-fixture=veteran"], "profile.name"),
            ("14-profile-training", ["-screen=profile", "-fixture=veteran", "-tab=training"], "profile.name"),
            ("15-lobby", ["-screen=lobby"], "lobby.start"),
            ("16-review-full", ["-screen=review"], "review.header"),
            ("17-badge-brilliant", ["-screen=badge-brilliant"], "postshot.badge.brilliant"),
            ("18-badge-blunder", ["-screen=badge-blunder"], "postshot.badge.blunder"),
        ]
        for (name, args, marker) in states {
            let app = launch(args)
            wait(app, marker)
            shot(app, name)
            app.terminate()
        }
    }
}
