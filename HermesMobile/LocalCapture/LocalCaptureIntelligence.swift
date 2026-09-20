import Foundation
import Observation

struct LocalCaptureIntelligenceInput: Equatable, Sendable {
    // A conservative byte budget, not a promise about the model's token count.
    static let maximumUTF8Bytes = 2_000
    let text: String

    init(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalCaptureIntelligenceError.invalidInput("Add or select some text to review.")
        }
        guard text.utf8.count <= Self.maximumUTF8Bytes else {
            throw LocalCaptureIntelligenceError.invalidInput("Select a shorter excerpt (at most 2,000 UTF-8 bytes). Nothing has been truncated or sent.")
        }
        self.text = text
    }
}

enum LocalCaptureIntelligenceError: LocalizedError {
    case invalidInput(String)
    case invalidOutput(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .invalidOutput(let message), .unavailable(let message): return message
        }
    }
}

struct LocalCaptureIntelligenceSuggestions: Equatable, Sendable {
    static let maximumTasks = 5
    var title: String
    var summary: String
    var tasks: [String]

    func validated() throws -> Self {
        guard tasks.count <= Self.maximumTasks else {
            throw LocalCaptureIntelligenceError.invalidOutput("On-device review returned too many task suggestions.")
        }
        return self
    }
}

enum LocalCaptureIntelligenceCapability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }
    var message: String {
        switch self {
        case .available: return "On-device review is available for your current language."
        case .unavailable(let reason): return reason
        }
    }
}

/// A text-only seam. No store, capture identifiers, attachment URLs or app services.
@MainActor
protocol LocalCaptureIntelligenceProviding {
    func capability() -> LocalCaptureIntelligenceCapability
    func review(_ input: LocalCaptureIntelligenceInput) async throws -> LocalCaptureIntelligenceSuggestions
}
