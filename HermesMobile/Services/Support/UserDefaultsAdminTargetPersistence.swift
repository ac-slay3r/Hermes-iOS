import Foundation

/// UserDefaults-backed storage for the last reviewed dashboard address/profile only.
/// Plain, non-secret strings — same category of data as the existing custom relay URL
/// already persisted in RelayConfiguration. No tokens or credentials live here.
@MainActor
final class UserDefaultsAdminTargetPersistence: AdminTargetPersistenceProtocol {
    private enum Keys {
        static let address = "hermes.admin.lastAddress"
        static let profile = "hermes.admin.lastProfile"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadLastAdminTarget() -> (address: String, profile: String)? {
        guard let address = defaults.string(forKey: Keys.address), !address.isEmpty else { return nil }
        let profile = defaults.string(forKey: Keys.profile)
        return (address: address, profile: (profile?.isEmpty == false) ? profile! : "default")
    }

    func saveLastAdminTarget(address: String, profile: String) {
        defaults.set(address, forKey: Keys.address)
        defaults.set(profile, forKey: Keys.profile)
    }

    func clearLastAdminTarget() {
        defaults.removeObject(forKey: Keys.address)
        defaults.removeObject(forKey: Keys.profile)
    }
}
