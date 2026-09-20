import XCTest

final class AdminLaunchUITests: XCTestCase {
    @MainActor
    func testDashboardManagementAreasLeadPrimaryNavigation() {
        let app = XCUIApplication()
        app.launch()
        for label in [
            "Overview & health", "Configuration & models", "Profiles & sessions",
            "Skills, tools & MCP", "Memory & instructions",
            "Automation & connections", "System & operations"
        ] {
            var row = app.staticTexts[label]
            for _ in 0..<8 where !row.exists {
                app.swipeUp(velocity: .slow)
                row = app.staticTexts[label]
            }
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Missing dashboard area: \(label)")
        }
        XCTAssertFalse(app.buttons["admin.localWorkspace"].exists)
        XCTAssertFalse(app.buttons["admin.composerLab"].exists)
    }

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
        let identity = app.descendants(matching: .any).matching(identifier: "admin.identity").firstMatch
        for _ in 0..<8 {
            if identity.exists && identity.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(identity.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(identity.value as? String, "Not authenticated")
        XCTAssertFalse(app.buttons["Apply change"].exists)
    }
}
