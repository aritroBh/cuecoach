import XCTest

/// Opens Settings and Player profile through the debug router (`-screen=<name>`), checks the key flows,
/// and captures a screenshot of every screen/state in three runs: default, Dynamic Type XXL, Reduce Motion.
final class ScreensAUITests: XCTestCase {
    static let shotsDir = URL(fileURLWithPath:
        "/private/tmp/claude-501/-Users-aritro-Downloads-Pool/fb384a25-d7ca-4434-9fb6-43a4e97094df/scratchpad/shots")

    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(_ screen: String, fixture: String = "default", tab: String? = nil,
                        mode: Mode = .standard) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen=\(screen)", "-fixture=\(fixture)"]
        if let tab { app.launchArguments.append("-tab=\(tab)") }
        switch mode {
        case .standard: break
        case .xxl: app.launchArguments += ["-dynamicType=xxl",
                                           "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXL"]
        case .reduceMotion: app.launchArguments.append("-reduceMotion")
        }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.\(screen)"].waitForExistence(timeout: 10),
                      "screen.\(screen) did not appear")
        return app
    }

    enum Mode: String, CaseIterable { case standard = "light", xxl, reduceMotion = "reducemotion" }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(at: Self.shotsDir, withIntermediateDirectories: true)
        try? png.write(to: Self.shotsDir.appending(path: "screens-a-\(name).png"))
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "screens-a-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: Settings flows

    @MainActor func testDeleteRecognitionDataFlow() {
        let app = launch("settings")
        let toggle = app.switches["settings.recognition"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        let delete = app.buttons["settings.delete"]
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        let confirm = app.buttons["settings.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Delete recognition data?"].exists)
        shot(app, "settings-delete-confirm")
        confirm.tap()
        let off = NSPredicate(format: "value == '0'")
        expectation(for: off, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["Nothing stored."].waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)
        XCTAssertFalse(app.switches["settings.includeFace"].exists)
        shot(app, "settings-deleted")
    }

    @MainActor func testDeleteFailureShowsInlineError() {
        let app = launch("settings", fixture: "deleteFail")
        app.buttons["settings.delete"].tap()
        app.buttons["settings.delete.confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Couldn't delete. Try again."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.delete"].isEnabled)
        shot(app, "settings-delete-failed")
    }

    @MainActor func testRuleTilesAndThreeBallToggle() {
        let app = launch("settings")
        XCTAssertFalse(app.switches["settings.threeBall"].exists)
        let nine = app.buttons["settings.rule.wpaNine"]
        XCTAssertTrue(nine.exists)
        XCTAssertGreaterThanOrEqual(nine.frame.height, 64)
        nine.tap()
        XCTAssertTrue(nine.isSelected)
        let three = app.switches["settings.threeBall"]
        XCTAssertTrue(three.waitForExistence(timeout: 5))
        XCTAssertEqual(three.value as? String, "1")      // D13 default on
        shot(app, "settings-wpa9")
        app.buttons["settings.rule.barEight"].tap()
        XCTAssertFalse(app.switches["settings.threeBall"].waitForExistence(timeout: 1))
    }

    @MainActor func testTableMeasuredThenManual() {
        let app = launch("settings", fixture: "measured")
        app.swipeUp()
        XCTAssertTrue(app.buttons["settings.table.eightFoot"].isSelected)
        XCTAssertTrue(app.staticTexts["Auto-measured"].waitForExistence(timeout: 5))
        shot(app, "settings-table-measured")
        app.buttons["settings.table.nineFoot"].tap()
        XCTAssertTrue(app.buttons["settings.table.nineFoot"].isSelected)
        XCTAssertTrue(app.staticTexts["Manual"].waitForExistence(timeout: 5))
    }

    @MainActor func testExportOpensShareSheet() {
        let app = launch("settings")
        app.buttons["settings.export"].tap()
        let sheet = app.otherElements["ActivityListView"]
        let appeared = sheet.waitForExistence(timeout: 8) || app.navigationBars["UIActivityContentView"].exists
            || app.buttons["Copy"].exists || app.collectionViews.firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(appeared, "share sheet did not appear")
        shot(app, "settings-export-share")
    }

    @MainActor func testTouchTargets() {
        let app = launch("settings")
        for id in ["settings.delete", "settings.export", "settings.import",
                   "settings.rule.barEight", "settings.rule.wpaEight", "settings.rule.wpaNine"] {
            let e = app.buttons[id]
            XCTAssertTrue(e.exists, id)
            XCTAssertGreaterThanOrEqual(e.frame.height, 44, id)
        }
    }

    // MARK: Profile flows

    @MainActor func testProfileTabsAndHistoryExpand() {
        let app = launch("profile", fixture: "veteran")
        XCTAssertTrue(app.staticTexts["Sam"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["profile.archetype"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["profile.procomp"].exists)
        let tabs = app.segmentedControls["profile.tabs"]
        XCTAssertEqual(tabs.buttons.count, 3)
        tabs.buttons["History"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Bar · 2v2'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Game 3'")).firstMatch
            .waitForExistence(timeout: 5))
        shot(app, "profile-history-expanded")
        tabs.buttons["Training"].tap()
        XCTAssertTrue(app.staticTexts["Training only"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Make %"].exists)
    }

    @MainActor func testGuestHasNoTrainingOrEdit() {
        let app = launch("profile", fixture: "guest")
        let tabs = app.segmentedControls["profile.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertEqual(tabs.buttons.count, 2)
        XCTAssertFalse(app.buttons["profile.edit"].exists)
    }

    @MainActor func testLockedAndNewPlayerStates() {
        var app = launch("profile", fixture: "preUnlock")
        XCTAssertTrue(app.descendants(matching: .any)["profile.procomp.locked"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["profile.archetype"].exists)
        app.terminate()
        app = launch("profile", fixture: "newPlayer")
        XCTAssertTrue(app.staticTexts["Play a game to start."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Badges"].exists)
    }

    @MainActor func testErrorShowsRetry() {
        let app = launch("profile", fixture: "error")
        XCTAssertTrue(app.staticTexts["Couldn't load stats."].waitForExistence(timeout: 5))
        let retry = app.buttons["profile.retry"]
        XCTAssertTrue(retry.exists)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
    }

    @MainActor func testBadgeSheet() {
        let app = launch("profile", fixture: "veteran")
        app.swipeUp()
        let badge = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Cut Artist badge'")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        badge.tap()
        XCTAssertTrue(app.descendants(matching: .any)["profile.badge.detail"].waitForExistence(timeout: 5))
        shot(app, "profile-badge-sheet")
        app.swipeDown(velocity: .fast)
        let all = app.buttons["profile.badges.all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        XCTAssertTrue(app.descendants(matching: .any)["profile.badges.sheet"].waitForExistence(timeout: 5))
        shot(app, "profile-badges-all")
    }

    // MARK: Screenshot matrix

    @MainActor func testScreenshotMatrix() {
        let states: [(String, String, String?, String)] = [
            ("settings", "default", nil, "settings"),
            ("settings", "measured", nil, "settings-measured"),
            ("settings", "empty", nil, "settings-empty"),
            ("profile", "veteran", "stats", "profile-veteran"),
            ("profile", "veteran", "history", "profile-history"),
            ("profile", "veteran", "training", "profile-training"),
            ("profile", "preUnlock", "stats", "profile-preunlock"),
            ("profile", "newPlayer", "stats", "profile-new"),
            ("profile", "newPlayer", "history", "profile-history-empty"),
            ("profile", "newPlayer", "training", "profile-training-empty"),
            ("profile", "error", nil, "profile-error"),
            ("profile", "guest", "stats", "profile-guest"),
        ]
        for mode in Mode.allCases {
            for (screen, fixture, tab, name) in states {
                let app = launch(screen, fixture: fixture, tab: tab, mode: mode)
                _ = app.staticTexts.firstMatch.waitForExistence(timeout: 3)
                Thread.sleep(forTimeInterval: 0.6)   // let the one-time chart draw-in finish
                shot(app, "\(name)-\(mode.rawValue)")
                if screen == "settings" || tab == "stats" {
                    app.swipeUp()
                    Thread.sleep(forTimeInterval: 0.4)
                    shot(app, "\(name)-\(mode.rawValue)-scrolled")
                }
                app.terminate()
            }
        }
    }
}
