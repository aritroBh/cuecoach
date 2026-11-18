import XCTest

final class LaunchUITests: XCTestCase {
    @MainActor func testLaunchShowsHome() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["home.game"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.training"].exists)
    }
}
