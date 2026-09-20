import Foundation

@MainActor
@Observable
final class PairingStore {
    private static let onboardingKey = "hermes.needsPermissionsOnboarding"

    var pairedRelayConfiguration: PairedRelayConfiguration?
    var isWorking = false
    var lastErrorMessage: String?
    var needsPermissionsOnboarding = false
    var onPairingChanged: (@MainActor (Bool) async -> Void)?

    private let pairingService: any PairingServiceProtocol
    private let sessionStore: AppSessionStore
    private let persistence: any AppPersistenceStoreProtocol
    private let onboardingDefaults: UserDefaults
    private let environmentProvider: @MainActor () -> AppEnvironment
    private let relayBaseURLProvider: @MainActor () -> String?

    init(
        pairingService: any PairingServiceProtocol,
        sessionStore: AppSessionStore,
        persistence: any AppPersistenceStoreProtocol,
        onboardingDefaults: UserDefaults,
        environmentProvider: @escaping @MainActor () -> AppEnvironment,
        relayBaseURLProvider: @escaping @MainActor () -> String?
    ) {
        self.pairingService = pairingService
        self.sessionStore = sessionStore
        self.persistence = persistence
        self.onboardingDefaults = onboardingDefaults
        self.environmentProvider = environmentProvider
        self.relayBaseURLProvider = relayBaseURLProvider
        self.pairedRelayConfiguration = persistence.loadPairedRelayConfiguration()
        self.needsPermissionsOnboarding = onboardingDefaults.bool(forKey: Self.onboardingKey)
    }

    var isPaired: Bool {
        pairedRelayConfiguration != nil
    }

    func normalizePairingCode(_ rawCode: String) throws -> String {
        try pairingService.normalizePairingCode(rawCode)
    }

    @discardableResult
    func pair(using rawSetupCode: String) async -> Bool {
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }

        do {
            let normalizedCode = try pairingService.normalizePairingCode(rawSetupCode)
            guard let relayBaseURLString = RelayConfiguration.normalizeBaseURL(relayBaseURLProvider()) else {
                lastErrorMessage = "Enter a valid relay URL ending with /v1 before pairing."
                return false
            }
            let request = DeviceRegistrationRequest.current(
                installationID: sessionStore.state.installationID,
                environment: environmentProvider(),
                relayBaseURLString: relayBaseURLString
            )
            let result = try await pairingService.redeemPairingCode(
                normalizedCode,
                request: request
            )

            persistence.savePairedRelayConfiguration(result.configuration)
            pairedRelayConfiguration = result.configuration
            lastErrorMessage = nil
            setNeedsPermissionsOnboarding(true)
            await sessionStore.applyPairedSession(state: result.state, tokens: result.tokens)
            await onPairingChanged?(true)
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func disconnect() async -> Bool {
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }

        guard await sessionStore.revokeCurrentSession() else {
            lastErrorMessage = sessionStore.lastErrorMessage
                ?? "The remote session could not be revoked. The device remains connected so you can retry safely."
            return false
        }
        await clearLocalPairing(notify: true)
        return true
    }

    func completePermissionsOnboarding() {
        setNeedsPermissionsOnboarding(false)
    }

    func clearLocalPairing(notify: Bool = true) async {
        persistence.clearPairedRelayConfiguration()
        pairedRelayConfiguration = nil
        lastErrorMessage = nil
        setNeedsPermissionsOnboarding(false)
        await sessionStore.clearSession()
        if notify {
            await onPairingChanged?(false)
        }
    }

    private func setNeedsPermissionsOnboarding(_ value: Bool) {
        needsPermissionsOnboarding = value
        onboardingDefaults.set(value, forKey: Self.onboardingKey)
    }
}
