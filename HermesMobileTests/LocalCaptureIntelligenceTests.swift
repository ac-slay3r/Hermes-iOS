import XCTest
@testable import HermesMobile

private enum TestFailure: Error { case failed }

@MainActor
private final class ControlledIntelligenceProvider: LocalCaptureIntelligenceProviding {
    var status: LocalCaptureIntelligenceCapability = .available
    var requested: [String] = []
    private var pending: [String: CheckedContinuation<LocalCaptureIntelligenceSuggestions, Error>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func capability() -> LocalCaptureIntelligenceCapability { status }

    func review(_ input: LocalCaptureIntelligenceInput) async throws -> LocalCaptureIntelligenceSuggestions {
        try await withCheckedThrowingContinuation { continuation in
            requested.append(input.text)
            pending[input.text] = continuation
            waiters.removeValue(forKey: input.text)?.resume()
        }
    }

    func waitUntilStarted(_ text: String) async {
        if pending[text] != nil { return }
        await withCheckedContinuation { waiters[text] = $0 }
    }

    func finish(_ text: String, with result: Result<LocalCaptureIntelligenceSuggestions, Error>) {
        pending.removeValue(forKey: text)?.resume(with: result)
    }
}

@MainActor
final class LocalCaptureIntelligenceTests: XCTestCase {
    func testSystemProviderCapabilityIsInspectableWithoutGenerating() {
        let status = LocalCaptureIntelligenceSystemProvider().capability()
        XCTAssertFalse(status.message.isEmpty)
        #if !canImport(FoundationModels)
        XCTAssertFalse(status.isAvailable)
        #endif
    }

    func testUnavailableDoesNotInvokeProvider() async {
        let provider = ControlledIntelligenceProvider()
        provider.status = .unavailable("Not ready")
        let model = LocalCaptureIntelligenceReviewModel(provider: provider)
        await model.start(text: "Private note").value
        XCTAssertEqual(model.phase, .unavailable("Not ready"))
        XCTAssertTrue(provider.requested.isEmpty)
    }

    func testOversizedInputDoesNotInvokeProvider() async {
        let provider = ControlledIntelligenceProvider()
        let model = LocalCaptureIntelligenceReviewModel(provider: provider)
        await model.start(text: String(repeating: "a", count: 2_001)).value
        guard case .failed = model.phase else { return XCTFail("Expected input error") }
        XCTAssertTrue(provider.requested.isEmpty)
    }

    func testSuccessIsEditableSuggestionOnlyAndUsesExactText() async {
        let provider = ControlledIntelligenceProvider()
        let original = "Original body"
        let model = LocalCaptureIntelligenceReviewModel(provider: provider)
        let work = model.start(text: original)
        await provider.waitUntilStarted(original)
        provider.finish(original, with: .success(.init(title: "Title", summary: "Summary", tasks: ["Call"])))
        await work.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(provider.requested, [original])
        model.suggestions?.title = "Edited suggestion"
        XCTAssertEqual(model.suggestions?.title, "Edited suggestion")
        XCTAssertEqual(original, "Original body")
    }

    func testDismissalIgnoresLateCompletionEvenIfProviderIgnoresCancellation() async {
        let provider = ControlledIntelligenceProvider()
        let model = LocalCaptureIntelligenceReviewModel(provider: provider)
        let work = model.start(text: "old")
        await provider.waitUntilStarted("old")
        model.cancel(message: "Review dismissed.")
        provider.finish("old", with: .success(.init(title: "Stale", summary: "", tasks: [])))
        await work.value
        XCTAssertEqual(model.phase, .cancelled("Review dismissed."))
        XCTAssertNil(model.suggestions)
    }

    func testReplacementIgnoresOldFailureAndRetainsNewResult() async {
        let provider = ControlledIntelligenceProvider()
        let model = LocalCaptureIntelligenceReviewModel(provider: provider)
        let old = model.start(text: "old")
        await provider.waitUntilStarted("old")
        let new = model.start(text: "new")
        await provider.waitUntilStarted("new")
        provider.finish("new", with: .success(.init(title: "New", summary: "", tasks: [])))
        await new.value
        provider.finish("old", with: .failure(TestFailure.failed))
        await old.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.suggestions?.title, "New")
    }

    func testBackgroundCancellationClearsResultsAndRefreshDoesNotGenerate() async {
        let provider = ControlledIntelligenceProvider()
        let model = LocalCaptureIntelligenceReviewModel(provider: provider)
        let work = model.start(text: "note")
        await provider.waitUntilStarted("note")
        provider.finish("note", with: .success(.init(title: "Title", summary: "", tasks: [])))
        await work.value
        model.cancel(message: "Review cancelled because the app left the foreground.")
        XCTAssertNil(model.suggestions)
        provider.status = .unavailable("Disabled")
        model.refreshCapability()
        XCTAssertEqual(model.capability, .unavailable("Disabled"))
        XCTAssertEqual(provider.requested.count, 1)
    }

    func testErrorsDoNotExposeProviderTextAndCanRetry() async {
        let provider = ControlledIntelligenceProvider()
        let model = LocalCaptureIntelligenceReviewModel(provider: provider)
        let work = model.start(text: "note")
        await provider.waitUntilStarted("note")
        provider.finish("note", with: .failure(TestFailure.failed))
        await work.value
        guard case .failed(let message) = model.phase else { return XCTFail("Expected visible error") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(model.suggestions)
        let retry = model.start(text: "retry")
        await provider.waitUntilStarted("retry")
        provider.finish("retry", with: .failure(CancellationError()))
        await retry.value
        XCTAssertEqual(model.phase, .cancelled("Review cancelled."))
    }

    func testInputRequiresTextAndNeverSilentlyTruncates() throws {
        XCTAssertThrowsError(try LocalCaptureIntelligenceInput(text: " \n\t"))
        let boundary = String(repeating: "a", count: LocalCaptureIntelligenceInput.maximumUTF8Bytes)
        XCTAssertEqual(try LocalCaptureIntelligenceInput(text: boundary).text, boundary)
        XCTAssertThrowsError(try LocalCaptureIntelligenceInput(text: boundary + "a"))
        XCTAssertThrowsError(try LocalCaptureIntelligenceInput(text: String(repeating: "🦊", count: 600)))
        XCTAssertEqual(try LocalCaptureIntelligenceInput(text: " Original \n").text, " Original \n")
    }

    func testOverLimitProviderResultNeverReachesReady() async {
        let provider = ControlledIntelligenceProvider()
        let model = LocalCaptureIntelligenceReviewModel(provider: provider)
        let work = model.start(text: "many explicit tasks")
        await provider.waitUntilStarted("many explicit tasks")
        let tasks = (0..<(LocalCaptureIntelligenceSuggestions.maximumTasks + 1)).map { "Task \($0)" }
        provider.finish("many explicit tasks", with: .success(.init(title: "Title", summary: "Summary", tasks: tasks)))
        await work.value

        guard case .failed = model.phase else { return XCTFail("Over-limit suggestions must fail closed") }
        XCTAssertNil(model.suggestions)
    }
}
