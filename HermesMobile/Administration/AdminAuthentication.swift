import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import UIKit

enum AdminAuthenticationError: Error, Equatable {
    case invalidPKCE
    case invalidState
    case invalidCallback
    case cancelled
    case rejected(String)
    case malformedTokenResponse
    case http(Int)
}

struct AdminPKCE: Equatable, Sendable {
    let verifier: String
    let challenge: String

    init(verifier: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard (43...128).contains(verifier.utf8.count),
              verifier.unicodeScalars.allSatisfy(allowed.contains)
        else { throw AdminAuthenticationError.invalidPKCE }
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func generate() throws -> AdminPKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw AdminAuthenticationError.invalidPKCE }
        return try AdminPKCE(verifier: base64URL(Data(bytes)))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct AdminAuthorizationAttempt: Equatable, Sendable {
    static let callbackURLString = "cool.n0thing.hermes:/oauth/callback"
    static let callbackScheme = "cool.n0thing.hermes"

    let target: AdminTarget
    let provider: String?
    let pkce: AdminPKCE
    let state: String
    let authorizationURL: URL

    init(target: AdminTarget, provider: String? = nil, pkce: AdminPKCE, state: String) throws {
        guard !state.isEmpty else { throw AdminAuthenticationError.invalidState }
        var components = URLComponents(
            url: target.baseURL.appendingPathComponent("auth/native/authorize"),
            resolvingAgainstBaseURL: false
        )
        var query = [
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: Self.callbackURLString),
            URLQueryItem(name: "state", value: state)
        ]
        if let provider, !provider.isEmpty {
            query.append(URLQueryItem(name: "provider", value: provider))
        }
        components?.queryItems = query
        guard let authorizationURL = components?.url else {
            throw AdminAuthenticationError.invalidCallback
        }
        self.target = target
        self.provider = provider
        self.pkce = pkce
        self.state = state
        self.authorizationURL = authorizationURL
    }

    func authorizationCode(from callback: URL) throws -> String {
        guard let expected = URL(string: Self.callbackURLString),
              callback.scheme == expected.scheme,
              callback.host == nil,
              callback.path == expected.path,
              callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        else { throw AdminAuthenticationError.invalidCallback }

        let items = components.queryItems ?? []
        let errorItems = items.filter { $0.name == "error" }
        guard errorItems.count <= 1 else { throw AdminAuthenticationError.invalidCallback }
        func exactlyOne(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard exactlyOne("state") == state else { throw AdminAuthenticationError.invalidState }
        if let errorItem = errorItems.first {
            guard let error = errorItem.value, !error.isEmpty else {
                throw AdminAuthenticationError.invalidCallback
            }
            throw AdminAuthenticationError.rejected(error)
        }
        guard let code = exactlyOne("code"), !code.isEmpty else {
            throw AdminAuthenticationError.invalidCallback
        }
        return code
    }
}

struct AdminBearerTokens: Equatable, Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresAt: Int
    let provider: String
    let userID: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresAt = "expires_at"
        case provider
        case userID = "user_id"
    }
}

@MainActor
struct HermesAdminAuthClient {
    let transport: any AdminTransport

    func exchangeCode(_ code: String, verifier: String, target: AdminTarget) async throws -> AdminBearerTokens {
        guard !code.isEmpty, !verifier.isEmpty else { throw AdminAuthenticationError.malformedTokenResponse }
        let body = try JSONEncoder().encode(["code": code, "code_verifier": verifier])
        let request = try makePOST(path: "auth/native/token", target: target, body: body)
        return try await sendTokenRequest(request)
    }

    func refresh(_ credential: AdminStoredCredential, target: AdminTarget) async throws -> AdminBearerTokens {
        guard !credential.refreshToken.isEmpty else { throw AdminAuthenticationError.malformedTokenResponse }
        let body = try JSONEncoder().encode([
            "refresh_token": credential.refreshToken,
            "provider": credential.provider
        ])
        let request = try makePOST(path: "auth/native/refresh", target: target, body: body)
        return try await sendTokenRequest(request)
    }

    private func sendTokenRequest(_ request: URLRequest) async throws -> AdminBearerTokens {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else { throw AdminAuthenticationError.http(response.status) }
        guard response.body.count <= 1_048_576,
              let tokens = try? JSONDecoder().decode(AdminBearerTokens.self, from: response.body),
              !tokens.accessToken.isEmpty,
              !tokens.refreshToken.isEmpty,
              !tokens.provider.isEmpty,
              !tokens.userID.isEmpty,
              tokens.expiresAt > 0,
              tokens.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame
        else { throw AdminAuthenticationError.malformedTokenResponse }
        return tokens
    }

    private func makePOST(path: String, target: AdminTarget, body: Data) throws -> URLRequest {
        let url = target.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
}

@MainActor
protocol AdminWebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
    func cancel()
}

@MainActor
final class SystemAdminWebAuthentication: NSObject, AdminWebAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard continuation == nil else { throw AdminAuthenticationError.invalidCallback }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { [weak self] callback, error in
                    Task { @MainActor in
                        if let callback {
                            self?.finish(.success(callback))
                        } else {
                            self?.finish(.failure(error ?? AdminAuthenticationError.invalidCallback))
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                activeSession = session
                guard session.start() else {
                    finish(.failure(AdminAuthenticationError.invalidCallback))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        activeSession?.cancel()
        finish(.failure(AdminAuthenticationError.cancelled))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        activeSession = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

struct AdminStoredCredential: Codable, Equatable, Sendable {
    let refreshToken: String
    let provider: String
    let userID: String
    let expiresAt: Int
    let revision: String?

    init(
        refreshToken: String,
        provider: String,
        userID: String,
        expiresAt: Int,
        revision: String? = nil
    ) {
        self.refreshToken = refreshToken
        self.provider = provider
        self.userID = userID
        self.expiresAt = expiresAt
        self.revision = revision
    }
}

@MainActor
protocol AdminCredentialPersisting {
    func save(_ credential: AdminStoredCredential, for target: AdminTarget) async throws
    func load(for target: AdminTarget) async throws -> AdminStoredCredential?
    func delete(for target: AdminTarget) async throws
    func delete(_ credential: AdminStoredCredential, for target: AdminTarget) async throws
}

struct AdminKeychainError: Error, Equatable {
    let status: OSStatus
}

@MainActor
final class KeychainAdminCredentialStore: AdminCredentialPersisting {
    private let service = "cool.n0thing.hermes.dashboard-auth"

    func save(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(for: target)
        let updated = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw AdminKeychainError(status: updated) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let inserted = SecItemAdd(insert as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw AdminKeychainError(status: inserted) }
    }

    func load(for target: AdminTarget) async throws -> AdminStoredCredential? {
        try storedCredential(for: target)
    }

    func delete(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {
        guard try storedCredential(for: target) == credential else { return }
        try deleteItem(for: target)
    }

    func delete(for target: AdminTarget) async throws {
        try deleteItem(for: target)
    }

    private func storedCredential(for target: AdminTarget) throws -> AdminStoredCredential? {
        var query = baseQuery(for: target)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data
        else { throw AdminKeychainError(status: status) }
        return try JSONDecoder().decode(AdminStoredCredential.self, from: data)
    }

    private func deleteItem(for target: AdminTarget) throws {
        let status = SecItemDelete(baseQuery(for: target) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound
        else { throw AdminKeychainError(status: status) }
    }

    private func baseQuery(for target: AdminTarget) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: target.baseURL.absoluteString
        ]
    }
}

@Observable
@MainActor
final class AdminAuthSession {
    private let browser: any AdminWebAuthenticating
    private let client: HermesAdminAuthClient
    private let credentialStore: any AdminCredentialPersisting
    private var generation = 0

    private(set) var accessToken: String?
    private(set) var authenticatedTarget: AdminTarget?
    private(set) var authenticatedProvider: String?
    private(set) var authenticatedUserID: String?

    init(
        browser: any AdminWebAuthenticating,
        client: HermesAdminAuthClient,
        credentialStore: any AdminCredentialPersisting
    ) {
        self.browser = browser
        self.client = client
        self.credentialStore = credentialStore
    }

    func signIn(target: AdminTarget, provider: String? = nil) async throws {
        let operation = generation
        let pkce = try AdminPKCE.generate()
        let state = try secureToken(byteCount: 24)
        let attempt = try AdminAuthorizationAttempt(
            target: target,
            provider: provider,
            pkce: pkce,
            state: state
        )
        let callback = try await browser.authenticate(
            url: attempt.authorizationURL,
            callbackScheme: AdminAuthorizationAttempt.callbackScheme
        )
        try requireCurrent(operation)
        let code = try attempt.authorizationCode(from: callback)
        let tokens = try await client.exchangeCode(code, verifier: pkce.verifier, target: target)
        try requireCurrent(operation)
        try await accept(tokens, target: target, operation: operation)
    }

    func restore(target: AdminTarget) async throws -> Bool {
        let operation = generation
        let loaded = try await credentialStore.load(for: target)
        try requireCurrent(operation)
        guard let stored = loaded else { return false }
        do {
            let tokens = try await client.refresh(stored, target: target)
            guard tokens.provider == stored.provider, tokens.userID == stored.userID else {
                try await credentialStore.delete(stored, for: target)
                throw AdminAuthenticationError.malformedTokenResponse
            }
            try requireCurrent(operation)
            try await accept(tokens, target: target, operation: operation)
            return true
        } catch AdminAuthenticationError.http(401) {
            try await credentialStore.delete(stored, for: target)
            try requireCurrent(operation)
            return false
        }
    }

    func signOut() async throws {
        let target = authenticatedTarget
        generation += 1
        browser.cancel()
        clearAuthenticationState()
        if let target {
            try await credentialStore.delete(for: target)
        }
    }

    func validate(identity: AdminIdentity) async throws {
        guard identity.provider == authenticatedProvider, identity.userID == authenticatedUserID else {
            try await signOut()
            throw AdminError.wrongTarget
        }
    }

    func cancel() {
        generation += 1
        browser.cancel()
        clearAuthenticationState()
    }

    private func clearAuthenticationState() {
        accessToken = nil
        authenticatedTarget = nil
        authenticatedProvider = nil
        authenticatedUserID = nil
    }

    private func accept(_ tokens: AdminBearerTokens, target: AdminTarget, operation: Int) async throws {
        try requireCurrent(operation)
        let credential = AdminStoredCredential(
            refreshToken: tokens.refreshToken,
            provider: tokens.provider,
            userID: tokens.userID,
            expiresAt: tokens.expiresAt,
            revision: UUID().uuidString
        )
        try await credentialStore.save(credential, for: target)
        do {
            try requireCurrent(operation)
        } catch {
            try await credentialStore.delete(credential, for: target)
            throw error
        }
        accessToken = tokens.accessToken
        authenticatedTarget = target
        authenticatedProvider = tokens.provider
        authenticatedUserID = tokens.userID
    }

    private func requireCurrent(_ operation: Int) throws {
        guard operation == generation else { throw AdminAuthenticationError.cancelled }
    }

    private func secureToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw AdminAuthenticationError.invalidState }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
