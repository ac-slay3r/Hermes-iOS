import XCTest

final class LocalCaptureUITests: XCTestCase {
    @MainActor private func openWorkspace(_ app: XCUIApplication) {
        let entry = app.buttons["admin.localWorkspace"]
        app.swipeUp()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Local captures"].waitForExistence(timeout: 5))
    }

    @MainActor func testAIReviewUsesUnsavedTextCopyWithoutChangingEditor() throws {
        let app = XCUIApplication()
        app.launch()
        openWorkspace(app)
        app.buttons["New text note"].tap()
        let original = "Unsaved local draft"
        let editor = app.textViews["Capture text"]
        editor.tap()
        editor.typeText(original)
        app.swipeUp()
        app.buttons["capture.aiReview"].tap()
        let copy = app.textViews["Text to review, copy of original"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertEqual(copy.value as? String, original)
        XCTAssertTrue(app.staticTexts["Tap Review when you are ready. No analysis runs automatically."].exists)
        copy.tap()
        copy.typeText(" changed copy")
        app.buttons["Done"].tap()
        XCTAssertEqual(editor.value as? String, original)
        app.buttons["capture.aiReview"].tap()
        XCTAssertEqual(copy.value as? String, original)
        app.buttons["Done"].tap()
        app.buttons["Cancel"].tap()
    }

    @MainActor func testSearchOrganizeAndExplicitChecklist() throws {
        let app = XCUIApplication()
        app.launch()
        openWorkspace(app)
        app.buttons["New text note"].tap()
        let token = "Workspace" + UUID().uuidString
        app.textFields["Capture title"].tap()
        app.textFields["Capture title"].typeText(token)
        app.buttons["Save capture"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(token + "\n")
        app.buttons["capture.actions"].firstMatch.tap()
        app.buttons["Pin capture"].tap()
        app.buttons["capture.checklist"].firstMatch.tap()
        let task = app.textFields["New checklist item"]
        task.tap()
        task.typeText("Review locally")
        app.buttons["Add checklist item"].tap()
        let toggle = app.switches["Review locally"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        app.buttons["Done"].tap()
        app.buttons["capture.actions"].firstMatch.tap()
        app.buttons["Archive capture"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", token)).firstMatch.exists)
        app.buttons["capture.scope"].tap()
        app.buttons["Archived"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", token)).firstMatch.exists)
        app.buttons["capture.actions"].firstMatch.tap()
        app.buttons["Unarchive capture"].tap()
    }

    @MainActor func testLocalLaunchAndPersistentNote() throws {
        let app = XCUIApplication()
        app.launch()
        openWorkspace(app)
        XCTAssertTrue(app.navigationBars["Local captures"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Connect Hermes"].exists)
        XCTAssertFalse(app.buttons["Start voice mode"].exists)
        app.buttons["New text note"].tap()
        let title = "Local test " + UUID().uuidString
        let field = app.textFields["Capture title"]
        field.tap()
        // Replace the default title using select-all through keyboard shortcuts is
        // unreliable on devices; append a unique token and query the resulting title.
        field.typeText(title)
        let text = app.textViews["Capture text"]
        text.tap()
        text.typeText("An offline note")
        app.buttons["Save capture"].tap()
        app.terminate()
        app.launch()
        openWorkspace(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.waitForExistence(timeout: 5))
    }
}
