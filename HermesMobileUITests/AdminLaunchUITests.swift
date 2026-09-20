import XCTest

final class AdminLaunchUITests: XCTestCase {
    @MainActor
    func testSupportingWorkspaceReturnsToLockedAdministration() {
        let app = XCUIApplication()
        app.launch()
        app.swipeUp()
        let workspace = app.buttons["admin.localWorkspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        XCTAssertTrue(app.navigationBars["Local captures"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Apply change"].exists)
    }

    @MainActor
    func testComposerLabCannotDictateOrSend() {
        let app = XCUIApplication()
        app.launch()
        app.swipeUp()
        let lab = app.buttons["admin.composerLab"]
        XCTAssertTrue(lab.waitForExistence(timeout: 5))
        lab.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Dictate text"].isEnabled)
        composer.tap()
        composer.typeText("Local sample draft")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["Preview only — draft was not sent."].exists)
        XCTAssertEqual(composer.value as? String, "Local sample draft")
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
