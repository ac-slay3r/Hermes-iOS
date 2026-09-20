import AppIntents
import Observation

@MainActor @Observable
final class LocalInboxRoute {
    static let shared = LocalInboxRoute()
    private(set) var requestID = 0
    private var consumedRequestID = 0
    /// Local presentation state only. External entry points increment requestID instead.
    var isPresented = false

    func requestInbox() {
        if requestID == Int.max {
            requestID = 1
            consumedRequestID = 0
        } else {
            requestID += 1
        }
    }

    func consumeRequest(_ id: Int) -> Bool {
        guard id > consumedRequestID, id <= requestID else { return false }
        consumedRequestID = id
        return true
    }
}

struct SaveLocalTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Save text to local inbox"
    static let description = IntentDescription("Save explicitly supplied text on this device. No sensing, recording, link fetching, or agent connection.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Text") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let envelope = try IntakeEnvelope(text: text)
        try await requestConfirmation(result: .result(dialog: "Save this text to the local inbox? \(text)"))
        try LocalIntakeQueue().save(envelope)
        LocalInboxRoute.shared.requestInbox()
        return .result(dialog: "Saved on this device. Open the local inbox to review. No links were fetched.")
    }
}

struct OpenLocalInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Open local inbox"
    static let description = IntentDescription("Open local captures only. Does not record or collect device data.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult {
        LocalInboxRoute.shared.requestInbox()
        return .result()
    }
}

struct LocalCaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SaveLocalTextIntent(), phrases: ["Save text with \(.applicationName)"],
                    shortTitle: "Save local text", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenLocalInboxIntent(), phrases: ["Open local inbox in \(.applicationName)"],
                    shortTitle: "Open local inbox", systemImageName: "tray")
    }
}
