import XCTest

final class AdminLaunchUITests: XCTestCase {
    @MainActor
    func testNormalLaunchIsDisconnectedAdministration() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Review target"].exists)
        XCTAssertFalse(app.buttons["Start voice mode"].exists)
        XCTAssertFalse(app.buttons["Apply change"].exists)
    }

    @MainActor
    func testTargetReviewIsNotAuthentication() {
        let app = XCUIApplication()
        app.launch()
        let address = app.textFields["HTTPS dashboard address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("https://example.com")
        app.buttons["Review target"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Not authenticated"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Apply change"].exists)
    }
}
