import Foundation

/// Persists only the non-secret dashboard target (address + profile name) the user last
/// reviewed. Credentials/tokens are never stored here — those remain Keychain-only via
/// KeychainAdminCredentialStore. Kept outside HermesMobile/Administration because that
/// folder's source guard forbids raw UserDefaults use (reserved for the credential path).
@MainActor
protocol AdminTargetPersistenceProtocol {
    func loadLastAdminTarget() -> (address: String, profile: String)?
    func saveLastAdminTarget(address: String, profile: String)
    func clearLastAdminTarget()
}

extension AdminTargetPersistenceProtocol where Self == UserDefaultsAdminTargetPersistence {
    /// Default live implementation. Named so `Administration/` call sites can reference
    /// `.liveAdminTargetPersistence` without spelling the concrete UserDefaults-backed type.
    static var liveAdminTargetPersistence: UserDefaultsAdminTargetPersistence {
        UserDefaultsAdminTargetPersistence()
    }
}
