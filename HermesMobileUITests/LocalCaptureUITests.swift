import XCTest

final class LocalCaptureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        throw XCTSkip("Local capture product is frozen; AdminLaunchUITests verifies the dashboard-management entry point.")
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                                   upward: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        // SwiftUI List materializes rows lazily. Waiting alone never scrolls to a row.
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            if upward { app.swipeUp(velocity: .slow) }
            else { app.swipeDown(velocity: .slow) }
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription, file: file, line: line)
    }

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
        app.navigationBars["Review on device"].buttons["Done"].tap()
        XCTAssertEqual(editor.value as? String, original)
        app.buttons["capture.aiReview"].tap()
        XCTAssertEqual(copy.value as? String, original)
        app.navigationBars["Review on device"].buttons["Done"].tap()
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
        reveal(app.buttons["capture.actions"].firstMatch, in: app)
        app.buttons["capture.actions"].firstMatch.tap()
        app.buttons["Pin capture"].tap()
        reveal(app.buttons["capture.checklist"].firstMatch, in: app)
        app.buttons["capture.checklist"].firstMatch.tap()
        let task = app.textFields["New checklist item"]
        task.tap()
        task.typeText("Review locally")
        app.buttons["Add checklist item"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let toggle = app.switches["Review locally"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable)
        // Tapping the element center can hit the row label without changing the
        // SwiftUI switch. Exercise the visible switch control at its trailing edge.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.navigationBars["Local checklist"].buttons["Done"].tap()
        reveal(app.buttons["capture.actions"].firstMatch, in: app)
        app.buttons["capture.actions"].firstMatch.tap()
        app.buttons["Archive capture"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", token)).firstMatch.exists)
        reveal(app.buttons["capture.scope"], in: app, upward: false)
        app.buttons["capture.scope"].tap()
        app.buttons["Archived"].tap()
        let archivedReview = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Review ", token)).firstMatch
        reveal(archivedReview, in: app)
        XCTAssertTrue(archivedReview.exists)
        reveal(app.buttons["capture.actions"].firstMatch, in: app)
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
        XCTAssertTrue((field.value as? String)?.contains(title) == true)
        app.buttons["Save capture"].tap()
        let savedReview = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Review ", title)).firstMatch
        reveal(savedReview, in: app)
        savedReview.tap()
        XCTAssertEqual(app.textViews["Capture text"].value as? String, "An offline note")
        app.navigationBars["Review capture"].buttons["Cancel"].tap()
        app.terminate()
        app.launch()
        openWorkspace(app)
        reveal(savedReview, in: app)
        XCTAssertTrue(savedReview.exists)
        savedReview.tap()
        XCTAssertTrue((app.textFields["Capture title"].value as? String)?.contains(title) == true)
        XCTAssertEqual(app.textViews["Capture text"].value as? String, "An offline note")
    }
}
