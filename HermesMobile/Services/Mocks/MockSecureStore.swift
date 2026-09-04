import Foundation

@MainActor
@Observable
final class MockSecureStore: SecureStoreProtocol {
    private static let keyPrefix = "hermes.mockSecureStore."

    private var store: [String: String] = [:]
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    func store(key: String, value: String) async {
        store[key] = value
        defaults?.set(value, forKey: Self.keyPrefix + key)
    }

    func retrieve(key: String) async -> String? {
        store[key] ?? defaults?.string(forKey: Self.keyPrefix + key)
    }

    func delete(key: String) async {
        store.removeValue(forKey: key)
        defaults?.removeObject(forKey: Self.keyPrefix + key)
    }
}
