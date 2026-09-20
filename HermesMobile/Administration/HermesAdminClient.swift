import Foundation

/// Dashboard authority is deliberately separate from relay/chat authorization.
struct AdminTarget: Equatable, Sendable {
    let baseURL: URL
    let profile: String

    init(address: String, profile: String) throws {
        guard let parts = URLComponents(string: address), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url,
              profile.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}\z"#, options: .regularExpression) != nil
        else { throw AdminError.invalidTarget }
        baseURL = url
        self.profile = profile
    }
}

enum AdminResource: Equatable, Sendable {
    case soul
    case sessionTitle(String)

    var label: String {
        switch self {
        case .soul: return "SOUL.md"
        case .sessionTitle(let id): return "Session \(id) title"
        }
    }
}

struct AdminSnapshot: Equatable, Sendable {
    let value: String
    let exists: Bool
}

struct AdminOverview: Equatable, Sendable {
    let target: AdminTarget
    let status: AdminHostStatus
    let identity: AdminIdentity
    let profiles: AdminProfileContext
}

struct AdminHostStatus: Equatable, Decodable, Sendable {
    let version: String
    let overall: String
    let gatewayRunning: Bool
    let gatewayState: String?
    let activeAgents: Int
    let activeSessions: Int
    let authRequired: Bool
    let authFlows: [String]
    let availableProfiles: [String]

    enum CodingKeys: String, CodingKey {
        case version, overall
        case gatewayRunning = "gateway_running"
        case gatewayState = "gateway_state"
        case activeAgents = "active_agents"
        case activeSessions = "active_sessions"
        case authRequired = "auth_required"
        case authFlows = "auth_flows"
        case availableProfiles = "profiles"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        overall = try values.decodeIfPresent(String.self, forKey: .overall) ?? "unknown"
        gatewayRunning = try values.decode(Bool.self, forKey: .gatewayRunning)
        gatewayState = try values.decodeIfPresent(String.self, forKey: .gatewayState)
        activeAgents = try values.decodeIfPresent(Int.self, forKey: .activeAgents) ?? 0
        activeSessions = try values.decode(Int.self, forKey: .activeSessions)
        authRequired = try values.decodeIfPresent(Bool.self, forKey: .authRequired) ?? false
        authFlows = try values.decodeIfPresent([String].self, forKey: .authFlows) ?? []
        availableProfiles = try values.decodeIfPresent([String].self, forKey: .availableProfiles) ?? []
    }
}

struct AdminIdentity: Equatable, Decodable, Sendable {
    let userID: String
    let email: String
    let displayName: String
    let organizationID: String
    let provider: String
    let expiresAt: Int

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email
        case displayName = "display_name"
        case organizationID = "org_id"
        case provider
        case expiresAt = "expires_at"
    }
}

struct AdminProfileContext: Equatable, Decodable, Sendable {
    let active: String
    let current: String
}

struct AdminHTTPResponse: Sendable {
    let status: Int
    let body: Data
}

enum AdminError: Error {
    case invalidTarget, invalidResource, unavailable, malformedResponse, wrongTarget
    case http(Int), rejected
}

/// A future authenticated transport must bind authority to the exact origin,
/// reject redirects, disable persistent caches/logging, and handle expiry.
/// No production network implementation is enabled until iOS sign-in is verified.
@MainActor
protocol AdminTransport {
    func send(_ request: URLRequest) async throws -> AdminHTTPResponse
}

struct UnavailableAdminTransport: AdminTransport {
    func send(_ request: URLRequest) async throws -> AdminHTTPResponse {
        throw AdminError.unavailable
    }
}

@MainActor
struct HermesAdminClient {
    let transport: any AdminTransport

    func readStatus(target: AdminTarget) async throws -> AdminHostStatus {
        let statusData = try await perform(get(
            path: "api/status",
            target: target,
            query: [URLQueryItem(name: "profile", value: target.profile)]
        ))
        return try JSONDecoder().decode(AdminHostStatus.self, from: statusData)
    }

    func readOverview(target: AdminTarget) async throws -> AdminOverview {
        let status = try await readStatus(target: target)
        guard !status.availableProfiles.isEmpty, status.availableProfiles.contains(target.profile)
        else { throw AdminError.wrongTarget }

        // Identity must be established before reading any authenticated management context.
        let identityData = try await perform(get(path: "api/auth/me", target: target))
        let identity = try JSONDecoder().decode(AdminIdentity.self, from: identityData)

        let profilesData = try await perform(get(path: "api/profiles/active", target: target))
        let profiles = try JSONDecoder().decode(AdminProfileContext.self, from: profilesData)
        return AdminOverview(target: target, status: status, identity: identity, profiles: profiles)
    }

    func read(_ resource: AdminResource, target: AdminTarget) async throws -> AdminSnapshot {
        let data = try await perform(request(resource, target: target, value: nil))
        switch resource {
        case .soul:
            let result = try JSONDecoder().decode(Soul.self, from: data)
            return AdminSnapshot(value: result.content, exists: result.exists)
        case .sessionTitle(let id):
            let result = try JSONDecoder().decode(Session.self, from: data)
            guard result.id == id, result.profile == target.profile else { throw AdminError.wrongTarget }
            return AdminSnapshot(value: result.title ?? "", exists: true)
        }
    }

    func write(_ resource: AdminResource, target: AdminTarget, value: String) async throws {
        let data = try await perform(request(resource, target: target, value: value))
        guard try JSONDecoder().decode(Receipt.self, from: data).ok else { throw AdminError.rejected }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else { throw AdminError.http(response.status) }
        // Never reflect server bodies/errors into UI or diagnostic logs.
        guard response.body.count <= 1_048_576 else { throw AdminError.malformedResponse }
        return response.body
    }

    private func get(
        path: String,
        target: AdminTarget,
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: target.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw AdminError.invalidTarget }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw AdminError.invalidTarget }
        var result = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        result.httpMethod = "GET"
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        return result
    }

    private func request(_ resource: AdminResource, target: AdminTarget, value: String?) throws -> URLRequest {
        let path: String
        var query: [URLQueryItem] = []
        var payload: [String: String] = [:]
        switch resource {
        case .soul:
            path = "api/profiles/\(target.profile)/soul"
            if let value { payload = ["content": value] }
        case .sessionTitle(let id):
            // Exact identifiers only: do not accept path syntax or resolve prefixes.
            guard !id.isEmpty, id.range(of: #"^[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil
            else { throw AdminError.invalidResource }
            path = "api/sessions/\(id)"
            if let value { payload = ["title": value, "profile": target.profile] }
            else { query = [URLQueryItem(name: "profile", value: target.profile)] }
        }
        guard var components = URLComponents(url: target.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw AdminError.invalidTarget }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw AdminError.invalidTarget }
        var result = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        result.httpMethod = value == nil ? "GET" : (resource == .soul ? "PUT" : "PATCH")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        if value != nil {
            result.setValue("application/json", forHTTPHeaderField: "Content-Type")
            result.httpBody = try JSONEncoder().encode(payload)
        }
        return result
    }

    private struct Soul: Decodable { let content: String; let exists: Bool }
    private struct Session: Decodable { let id: String; let profile: String; let title: String? }
    private struct Receipt: Decodable { let ok: Bool }
}
