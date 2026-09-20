import Foundation
import Observation

@MainActor @Observable
final class LocalCaptureIntelligenceReviewModel {
    enum Phase: Equatable {
        case idle, reviewing, ready
        case unavailable(String), failed(String), cancelled(String)
    }

    private(set) var capability: LocalCaptureIntelligenceCapability
    private(set) var phase: Phase = .idle
    var suggestions: LocalCaptureIntelligenceSuggestions?
    @ObservationIgnored private let provider: any LocalCaptureIntelligenceProviding
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()

    init(provider: any LocalCaptureIntelligenceProviding) {
        self.provider = provider
        capability = provider.capability()
    }

    func refreshCapability() {
        capability = provider.capability()
    }

    /// Only call from an explicit user action; capability refresh never starts work.
    @discardableResult
    func start(text: String) -> Task<Void, Never> {
        work?.cancel()
        let id = UUID()
        requestID = id
        suggestions = nil
        refreshCapability()
        guard capability.isAvailable else {
            phase = .unavailable(capability.message)
            return Task {}
        }
        let input: LocalCaptureIntelligenceInput
        do { input = try LocalCaptureIntelligenceInput(text: text) }
        catch {
            phase = .failed(error.localizedDescription)
            return Task {}
        }
        phase = .reviewing
        let provider = provider
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await provider.review(input)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.suggestions = try result.validated()
                self.phase = .ready
                self.work = nil
            } catch {
                guard let self, self.requestID == id else { return }
                self.suggestions = nil
                if error is CancellationError || Task.isCancelled {
                    self.phase = .cancelled("Review cancelled.")
                } else {
                    self.refreshCapability()
                    self.phase = self.capability.isAvailable
                        ? .failed("On-device review could not finish. The text may use an unsupported language, exceed the model context, or be declined by safety checks. Try a shorter excerpt. Nothing was changed or sent to a server.")
                        : .unavailable(self.capability.message)
                }
                self.work = nil
            }
        }
        work = task
        return task
    }

    /// Invalidates late results even when the underlying framework ignores cancellation.
    func cancel(message: String = "Review cancelled.") {
        requestID = UUID()
        work?.cancel()
        work = nil
        suggestions = nil
        phase = .cancelled(message)
    }
}
