import XCTest

final class LaunchUITests: XCTestCase {
    @MainActor func testLaunchShowsHome() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.images["home.logo"].waitForExistence(timeout: 5))
    }
}
