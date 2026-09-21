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

/// One entry from `GET /api/profiles`. Read-only inventory row; no mutation fields accepted.
struct AdminProfileSummary: Equatable, Decodable, Sendable, Identifiable {
    let name: String
    let isDefault: Bool
    let model: String?
    let provider: String?
    let gatewayRunning: Bool
    let displayName: String
    let description: String
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "is_default"
        case model, provider
        case gatewayRunning = "gateway_running"
        case displayName = "display_name"
        case description
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        isDefault = try values.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        model = try values.decodeIfPresent(String.self, forKey: .model)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        gatewayRunning = try values.decodeIfPresent(Bool.self, forKey: .gatewayRunning) ?? false
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

/// One row from `GET /api/sessions`. Preview/list projection only; never carries full transcript content.
struct AdminSessionSummary: Equatable, Decodable, Sendable, Identifiable {
    let id: String
    let title: String?
    let preview: String
    let profile: String
    let archived: Bool
    let pinned: Bool
    let unread: Bool
    let isActive: Bool
    let startedAt: Double?
    let lastActive: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, preview, profile, archived, pinned, unread
        case isActive = "is_active"
        case startedAt = "started_at"
        case lastActive = "last_active"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        preview = try values.decodeIfPresent(String.self, forKey: .preview) ?? ""
        profile = try values.decodeIfPresent(String.self, forKey: .profile) ?? ""
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        unread = try values.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        isActive = try values.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        startedAt = try values.decodeIfPresent(Double.self, forKey: .startedAt)
        lastActive = try values.decodeIfPresent(Double.self, forKey: .lastActive)
    }
}

struct AdminSessionListPage: Equatable, Decodable, Sendable {
    let sessions: [AdminSessionSummary]
    let total: Int
    let limit: Int
    let offset: Int

    enum CodingKeys: String, CodingKey { case sessions, total, limit, offset }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try values.decodeIfPresent([AdminSessionSummary].self, forKey: .sessions) ?? []
        total = try values.decodeIfPresent(Int.self, forKey: .total) ?? sessions.count
        limit = try values.decodeIfPresent(Int.self, forKey: .limit) ?? sessions.count
        offset = try values.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

/// `GET /api/sessions/{id}` detail. Distinct from AdminSessionSummary: server omits list-only
/// projection fields (preview/is_active) and may include additional detail-only fields we ignore.
struct AdminSessionDetail: Equatable, Decodable, Sendable {
    let id: String
    let title: String?
    let profile: String
    let archived: Bool
    let pinned: Bool

    enum CodingKeys: String, CodingKey { case id, title, profile, archived, pinned }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        profile = try values.decodeIfPresent(String.self, forKey: .profile) ?? ""
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// One row from `GET /api/sessions/{id}/messages`. Read-only rendering; content is opaque text/JSON,
/// never re-serialized as an editable resource.
struct AdminSessionMessage: Equatable, Decodable, Sendable, Identifiable {
    let id: String
    let role: String
    let displayContent: String?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case displayContent = "display_content"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        role = try values.decodeIfPresent(String.self, forKey: .role) ?? "unknown"
        displayContent = try values.decodeIfPresent(String.self, forKey: .displayContent)
        // `content` may be a string or structured payload server-side; decode leniently as string only.
        content = try? values.decodeIfPresent(String.self, forKey: .content)
    }
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

    /// `GET /api/profiles`. Read-only inventory; explicitly excludes create/rename/delete/clone.
    func readProfiles(target: AdminTarget) async throws -> [AdminProfileSummary] {
        let data = try await perform(get(path: "api/profiles", target: target))
        struct Envelope: Decodable { let profiles: [AdminProfileSummary] }
        return try JSONDecoder().decode(Envelope.self, from: data).profiles
    }

    /// `GET /api/sessions`. Always binds to the reviewed target's exact profile; never omits the
    /// profile query and relies on server-side default resolution.
    func readSessions(
        target: AdminTarget,
        limit: Int = 20,
        offset: Int = 0,
        archived: String = "exclude"
    ) async throws -> AdminSessionListPage {
        let clampedLimit = min(max(limit, 0), 100)
        let data = try await perform(get(
            path: "api/sessions",
            target: target,
            query: [
                URLQueryItem(name: "profile", value: target.profile),
                URLQueryItem(name: "limit", value: String(clampedLimit)),
                URLQueryItem(name: "offset", value: String(max(offset, 0))),
                URLQueryItem(name: "archived", value: archived)
            ]
        ))
        return try JSONDecoder().decode(AdminSessionListPage.self, from: data)
    }

    /// `GET /api/sessions/search`. Read-only; `query` is passed verbatim as the server-side search term.
    func searchSessions(target: AdminTarget, query: String, limit: Int = 20) async throws -> AdminSessionListPage {
        let clampedLimit = min(max(limit, 0), 100)
        let data = try await perform(get(
            path: "api/sessions/search",
            target: target,
            query: [
                URLQueryItem(name: "profile", value: target.profile),
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: String(clampedLimit))
            ]
        ))
        return try JSONDecoder().decode(AdminSessionListPage.self, from: data)
    }

    /// `GET /api/sessions/{id}`. Exact identifiers only; rejects the same malformed-id shapes as
    /// the existing session-title editor so read and write paths share one validation rule.
    func readSessionDetail(target: AdminTarget, id: String) async throws -> AdminSessionDetail {
        guard !id.isEmpty, id.range(of: #"^[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil
        else { throw AdminError.invalidResource }
        let data = try await perform(get(
            path: "api/sessions/\(id)",
            target: target,
            query: [URLQueryItem(name: "profile", value: target.profile)]
        ))
        let detail = try JSONDecoder().decode(AdminSessionDetail.self, from: data)
        guard detail.id == id, detail.profile == target.profile else { throw AdminError.wrongTarget }
        return detail
    }

    /// `GET /api/sessions/{id}/messages`. Read-only transcript projection; no rewrite path exists
    /// here or on the server for message content.
    func readSessionMessages(target: AdminTarget, id: String, limit: Int = 50) async throws -> [AdminSessionMessage] {
        guard !id.isEmpty, id.range(of: #"^[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil
        else { throw AdminError.invalidResource }
        let data = try await perform(get(
            path: "api/sessions/\(id)/messages",
            target: target,
            query: [
                URLQueryItem(name: "profile", value: target.profile),
                URLQueryItem(name: "limit", value: String(min(max(limit, 0), 200)))
            ]
        ))
        struct Envelope: Decodable { let messages: [AdminSessionMessage] }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return envelope.messages
        }
        // Some server responses return a bare array rather than an envelope.
        return try JSONDecoder().decode([AdminSessionMessage].self, from: data)
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
