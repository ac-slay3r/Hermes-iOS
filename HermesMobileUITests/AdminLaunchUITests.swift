import XCTest

final class AdminLaunchUITests: XCTestCase {
    @MainActor
    func testCombinedShellDefaultsToDashboardAndExposesCompanionTabs() {
        let app = makeApp()
        XCTAssertTrue(app.navigationBars["Hermes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Dashboard"].exists)
        XCTAssertTrue(app.tabBars.buttons["Chat"].exists)
        XCTAssertTrue(app.tabBars.buttons["Device"].exists)

        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(app.staticTexts["Hermes iOS"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scan QR Code"].exists)

        app.tabBars.buttons["Device"].tap()
        XCTAssertTrue(app.staticTexts["Hermes iOS"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Enter Code Manually"].exists)
    }

    @MainActor
    func testDashboardManagementAreasLeadPrimaryNavigation() {
        let app = makeApp()
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
        for planned in [
            "Configuration & models", "Profiles & sessions", "Skills, tools & MCP",
            "Memory & instructions", "Automation & connections", "System & operations"
        ] {
            XCTAssertFalse(app.buttons[planned].exists, "Planned area must not appear actionable: \(planned)")
        }
    }

    @MainActor
    func testNormalLaunchIsDisconnectedAdministration() {
        let app = makeApp()
        XCTAssertTrue(app.staticTexts["Not connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Review target"].exists)
        XCTAssertFalse(app.buttons["Start voice mode"].exists)
        XCTAssertFalse(app.buttons["Apply change"].exists)
    }

    @MainActor
    func testTargetReviewIsNotAuthentication() {
        let app = makeApp()
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

    @MainActor
    private func makeApp() -> XCUIApplication {
        let isolationID = UUID().uuidString
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_DEFAULTS_SUITE"] = "admin-launch.\(isolationID)"
        app.launchEnvironment["UITEST_KEYCHAIN_SERVICE"] = "cool.n0thing.hermes.uitest.\(isolationID)"
        app.launchEnvironment["UITEST_PAIRING_MODE"] = "mock"
        app.launch()
        return app
    }
}
