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

/// A deliberately small, hand-picked allowlist of `/api/config` scalar fields that are never
/// secret-shaped (no provider/tts/stt/proxy-credential paths; every field here is a plain
/// timeout, toggle, or non-sensitive selector). `/api/config` and `/api/config/schema` return
/// the ENTIRE config document unfiltered — no server-side secret-safe projection exists yet
/// (tracked separately) — so this client deliberately reads/writes only these named paths and
/// nothing else, rather than rendering the full schema.
enum AdminConfigField: String, CaseIterable, Sendable {
    case timezone
    case terminalBackend
    case terminalTimeout
    case agentGatewayTimeout
    case agentMaxTurns
    case checkpointsEnabled
    case checkpointsRetentionDays
    case browserHeaded

    var label: String {
        switch self {
        case .timezone: return "Timezone"
        case .terminalBackend: return "Terminal backend"
        case .terminalTimeout: return "Terminal command timeout (seconds)"
        case .agentGatewayTimeout: return "Gateway inactivity timeout (seconds)"
        case .agentMaxTurns: return "Max turns per run (0 = unlimited)"
        case .checkpointsEnabled: return "Filesystem checkpoints enabled"
        case .checkpointsRetentionDays: return "Checkpoint retention (days)"
        case .browserHeaded: return "Browser runs headed (visible window)"
        }
    }

    /// Dotted config.yaml path, matching the server's own schema keys.
    var path: String {
        switch self {
        case .timezone: return "timezone"
        case .terminalBackend: return "terminal.backend"
        case .terminalTimeout: return "terminal.timeout"
        case .agentGatewayTimeout: return "agent.gateway_timeout"
        case .agentMaxTurns: return "agent.max_turns"
        case .checkpointsEnabled: return "checkpoints.enabled"
        case .checkpointsRetentionDays: return "checkpoints.retention_days"
        case .browserHeaded: return "browser.headed"
        }
    }

    enum Kind: Equatable, Sendable {
        case string, number, boolean, selectString([String])
    }

    var kind: Kind {
        switch self {
        case .timezone: return .string
        case .terminalBackend: return .selectString(["local", "docker", "ssh", "modal", "daytona", "vercel_sandbox", "singularity"])
        case .terminalTimeout, .agentGatewayTimeout, .agentMaxTurns, .checkpointsRetentionDays: return .number
        case .checkpointsEnabled, .browserHeaded: return .boolean
        }
    }
}

enum AdminConfigValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
}

struct AdminConfigSnapshot: Equatable, Sendable {
    var values: [AdminConfigField: AdminConfigValue]
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
        // GET /api/sessions/{id} (detail) returns archived/pinned as raw SQLite 0/1 ints,
        // unlike GET /api/sessions (list), which explicitly casts them to real JSON booleans.
        // decodeIfPresent(Bool.self, ...) throws a type-mismatch on a present-but-wrong-type
        // value rather than falling through to a default — same failure class as the message
        // id bug. Accept either shape.
        archived = try Self.decodeLenientBool(values, forKey: .archived) ?? false
        pinned = try Self.decodeLenientBool(values, forKey: .pinned) ?? false
    }

    private static func decodeLenientBool(
        _ values: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Bool? {
        if let boolValue = try? values.decodeIfPresent(Bool.self, forKey: key) {
            return boolValue
        }
        if let intValue = try? values.decodeIfPresent(Int.self, forKey: key) {
            return intValue != 0
        }
        return nil
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
        // The server's row id is a SQLite integer, not a string; accept either shape rather
        // than throwing a type-mismatch that silently failed every message on every session.
        if let stringID = try? values.decodeIfPresent(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? values.decodeIfPresent(Int.self, forKey: .id) {
            id = String(intID)
        } else {
            id = UUID().uuidString
        }
        role = try values.decodeIfPresent(String.self, forKey: .role) ?? "unknown"
        displayContent = try values.decodeIfPresent(String.self, forKey: .displayContent)
        // `content` may be a string or structured payload server-side; decode leniently as string only.
        content = try? values.decodeIfPresent(String.self, forKey: .content)
    }
}

/// One row from `GET /api/skills`. Read-only inventory; no create/content-edit/toggle wired here.
struct AdminSkillSummary: Equatable, Decodable, Sendable, Identifiable {
    let name: String
    let description: String
    let category: String
    let enabled: Bool
    let usage: Int
    let provenance: String
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, description, category, enabled, usage, provenance }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        category = try values.decodeIfPresent(String.self, forKey: .category) ?? ""
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        usage = try values.decodeIfPresent(Int.self, forKey: .usage) ?? 0
        provenance = try values.decodeIfPresent(String.self, forKey: .provenance) ?? "agent"
    }
}

/// One row from `GET /api/tools/toolsets`. Read-only; no enable/disable, model/provider/env
/// assignment wired here — those can trigger dependency installation server-side (M4 scope).
struct AdminToolsetSummary: Equatable, Decodable, Sendable, Identifiable {
    let name: String
    let label: String
    let description: String
    let platform: String
    let platformLabel: String
    let enabled: Bool
    let available: Bool
    let configured: Bool
    let tools: [String]
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, label, description, platform
        case platformLabel = "platform_label"
        case enabled, available, configured, tools
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? name
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        platform = try values.decodeIfPresent(String.self, forKey: .platform) ?? ""
        platformLabel = try values.decodeIfPresent(String.self, forKey: .platformLabel) ?? ""
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        available = try values.decodeIfPresent(Bool.self, forKey: .available) ?? false
        configured = try values.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        tools = try values.decodeIfPresent([String].self, forKey: .tools) ?? []
    }
}

/// One row from `GET /api/mcp/servers`. Server pre-redacts env values (never raw secrets);
/// no add/remove/enable/test/auth wired here — those are explicit-consequence M4/M5 actions.
struct AdminMCPServerSummary: Equatable, Decodable, Sendable, Identifiable {
    let name: String
    let transport: String
    let url: String?
    let command: String?
    let args: [String]
    let env: [String: String]
    let auth: String?
    let enabled: Bool
    let tools: [String]?
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, transport, url, command, args, env, auth, enabled, tools }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        transport = try values.decodeIfPresent(String.self, forKey: .transport) ?? "unknown"
        url = try values.decodeIfPresent(String.self, forKey: .url)
        command = try values.decodeIfPresent(String.self, forKey: .command)
        args = try values.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try values.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        auth = try values.decodeIfPresent(String.self, forKey: .auth)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        tools = try values.decodeIfPresent([String].self, forKey: .tools)
    }
}

struct AdminHTTPResponse: Sendable {
    let status: Int
    let body: Data
}

/// One row from `GET /api/cron/jobs`. Read-only summary; no create/update/delete/pause/
/// resume/trigger wired here — trigger executes work and may deliver messages/spend money.
struct AdminCronJobSummary: Equatable, Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let enabled: Bool
    let scheduleDisplay: String
    let profile: String?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case scheduleDisplay = "schedule_display"
        case profile
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? "unknown"
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "cron job"
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        scheduleDisplay = try values.decodeIfPresent(String.self, forKey: .scheduleDisplay) ?? "?"
        profile = try values.decodeIfPresent(String.self, forKey: .profile)
    }
}

/// One row from `GET /api/messaging/platforms`. Read-only status; no platform config/env/test
/// wired here — env writes and connectivity tests are explicit-consequence M4/M5 actions.
struct AdminMessagingPlatformSummary: Equatable, Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let enabled: Bool
    let configured: Bool
    let gatewayRunning: Bool
    let state: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, configured
        case gatewayRunning = "gateway_running"
        case state
        case errorMessage = "error_message"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        configured = try values.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        gatewayRunning = try values.decodeIfPresent(Bool.self, forKey: .gatewayRunning) ?? false
        state = try values.decodeIfPresent(String.self, forKey: .state)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

/// One row from `GET /api/webhooks`. Read-only summary; no create/enable/delete wired here —
/// webhook bodies carry prompt/script/events/delivery/secret, a high-impact execution boundary.
struct AdminWebhookSummary: Equatable, Decodable, Sendable, Identifiable {
    let name: String
    let description: String
    let events: [String]
    let deliver: String
    let enabled: Bool
    let secretSet: Bool
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, description, events, deliver, enabled
        case secretSet = "secret_set"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        events = try values.decodeIfPresent([String].self, forKey: .events) ?? []
        deliver = try values.decodeIfPresent(String.self, forKey: .deliver) ?? "log"
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        secretSet = try values.decodeIfPresent(Bool.self, forKey: .secretSet) ?? false
    }
}

struct AdminWebhooksStatus: Equatable, Decodable, Sendable {
    let enabled: Bool
    let baseURL: String?
    let subscriptions: [AdminWebhookSummary]

    enum CodingKeys: String, CodingKey {
        case enabled
        case baseURL = "base_url"
        case subscriptions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL)
        subscriptions = try values.decodeIfPresent([AdminWebhookSummary].self, forKey: .subscriptions) ?? []
    }
}

/// Read-only view of `GET /api/pairing`. No approve/revoke/clear-pending wired here —
/// pairing authorizes messaging users, a distinct high-impact boundary from dashboard reads.
struct AdminPairingStatus: Equatable, Decodable, Sendable {
    let pending: [AdminPairingEntry]
    let approved: [AdminPairingEntry]

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pending = try values.decodeIfPresent([AdminPairingEntry].self, forKey: .pending) ?? []
        approved = try values.decodeIfPresent([AdminPairingEntry].self, forKey: .approved) ?? []
    }

    enum CodingKeys: String, CodingKey { case pending, approved }
}

/// Pairing entries are platform-defined dictionaries; decode leniently and surface only
/// display-safe fields rather than assuming a fixed schema across platforms.
struct AdminPairingEntry: Equatable, Decodable, Sendable, Identifiable {
    let id: String
    let source: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id, source, name
        case displayName = "display_name"
        case userID = "user_id"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallbackID = try values.decodeIfPresent(String.self, forKey: .userID)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? fallbackID ?? UUID().uuidString
        source = try values.decodeIfPresent(String.self, forKey: .source)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
            ?? values.decodeIfPresent(String.self, forKey: .name)
    }
}

/// One line from `GET /api/logs`. Read-only tail view; raw text, never treated as structured
/// editable data.
struct AdminLogsResult: Equatable, Decodable, Sendable {
    let file: String
    let lines: [String]

    enum CodingKeys: String, CodingKey { case file, lines }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        file = try values.decodeIfPresent(String.self, forKey: .file) ?? ""
        lines = try values.decodeIfPresent([String].self, forKey: .lines) ?? []
    }
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

    /// `GET /api/skills`. Read-only inventory; no create/content-edit/toggle wired here.
    func readSkills(target: AdminTarget) async throws -> [AdminSkillSummary] {
        let data = try await perform(get(
            path: "api/skills",
            target: target,
            query: [URLQueryItem(name: "profile", value: target.profile)]
        ))
        return try JSONDecoder().decode([AdminSkillSummary].self, from: data)
    }

    /// `GET /api/tools/toolsets`. Read-only; no enable/disable wired here.
    func readToolsets(target: AdminTarget) async throws -> [AdminToolsetSummary] {
        let data = try await perform(get(
            path: "api/tools/toolsets",
            target: target,
            query: [URLQueryItem(name: "profile", value: target.profile)]
        ))
        return try JSONDecoder().decode([AdminToolsetSummary].self, from: data)
    }

    /// `GET /api/mcp/servers`. Read-only; server pre-redacts env values. No add/remove/
    /// enable/test/auth wired here.
    func readMCPServers(target: AdminTarget) async throws -> [AdminMCPServerSummary] {
        let data = try await perform(get(
            path: "api/mcp/servers",
            target: target,
            query: [URLQueryItem(name: "profile", value: target.profile)]
        ))
        struct Envelope: Decodable { let servers: [AdminMCPServerSummary] }
        return try JSONDecoder().decode(Envelope.self, from: data).servers
    }

    /// `GET /api/cron/jobs`. Always binds to the reviewed target's exact profile; server
    /// defaults to "all" profiles when omitted, so profile is never left implicit.
    /// No create/update/delete/pause/resume/trigger wired here.
    func readCronJobs(target: AdminTarget) async throws -> [AdminCronJobSummary] {
        let data = try await perform(get(
            path: "api/cron/jobs",
            target: target,
            query: [URLQueryItem(name: "profile", value: target.profile)]
        ))
        return try JSONDecoder().decode([AdminCronJobSummary].self, from: data)
    }

    /// `GET /api/messaging/platforms`. Read-only; no config/env/test wired here.
    func readMessagingPlatforms(target: AdminTarget) async throws -> [AdminMessagingPlatformSummary] {
        let data = try await perform(get(
            path: "api/messaging/platforms",
            target: target,
            query: [URLQueryItem(name: "profile", value: target.profile)]
        ))
        struct Envelope: Decodable { let platforms: [AdminMessagingPlatformSummary] }
        return try JSONDecoder().decode(Envelope.self, from: data).platforms
    }

    /// `GET /api/webhooks`. Read-only; no create/enable/delete wired here.
    func readWebhooks(target: AdminTarget) async throws -> AdminWebhooksStatus {
        let data = try await perform(get(path: "api/webhooks", target: target))
        return try JSONDecoder().decode(AdminWebhooksStatus.self, from: data)
    }

    /// `GET /api/pairing`. Read-only; no approve/revoke/clear-pending wired here.
    func readPairing(target: AdminTarget) async throws -> AdminPairingStatus {
        let data = try await perform(get(
            path: "api/pairing",
            target: target,
            query: [URLQueryItem(name: "profile", value: target.profile)]
        ))
        return try JSONDecoder().decode(AdminPairingStatus.self, from: data)
    }

    /// `GET /api/logs`. Read-only tail view; `file`/`level`/`component`/`search` mirror the
    /// server's own filter vocabulary. No profile parameter server-side (serving-context only).
    func readLogs(
        target: AdminTarget,
        file: String = "agent",
        lines: Int = 100,
        search: String? = nil
    ) async throws -> AdminLogsResult {
        var query = [
            URLQueryItem(name: "file", value: file),
            URLQueryItem(name: "lines", value: String(min(max(lines, 1), 500)))
        ]
        if let search, !search.isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        let data = try await perform(get(path: "api/logs", target: target, query: query))
        return try JSONDecoder().decode(AdminLogsResult.self, from: data)
    }

    func write(_ resource: AdminResource, target: AdminTarget, value: String) async throws {
        let data = try await perform(request(resource, target: target, value: value))
        guard try JSONDecoder().decode(Receipt.self, from: data).ok else { throw AdminError.rejected }
    }

    /// `GET /api/config`, projected down to the hand-picked allowlist only. Unlisted keys
    /// (including anything provider/tts/stt/proxy-credential-shaped) are never decoded,
    /// stored, or displayed by this client.
    func readAllowlistedConfig(target: AdminTarget) async throws -> AdminConfigSnapshot {
        let data = try await perform(get(
            path: "api/config",
            target: target,
            query: [URLQueryItem(name: "profile", value: target.profile)]
        ))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AdminError.malformedResponse }
        var values: [AdminConfigField: AdminConfigValue] = [:]
        for field in AdminConfigField.allCases {
            values[field] = Self.extract(field, from: root)
        }
        return AdminConfigSnapshot(values: values)
    }

    /// `PUT /api/config` with a minimal nested body containing ONLY the one changed
    /// allowlisted field. The server deep-merges over disk, so every other key (including
    /// secret-bearing ones this client never reads) is left untouched.
    func writeAllowlistedConfig(_ field: AdminConfigField, value: AdminConfigValue, target: AdminTarget) async throws {
        let payload: [String: Any] = ["config": Self.nestedBody(field, value: value), "profile": target.profile]
        guard var components = URLComponents(url: target.baseURL.appendingPathComponent("api/config"), resolvingAgainstBaseURL: false)
        else { throw AdminError.invalidTarget }
        components.queryItems = nil
        guard let url = components.url else { throw AdminError.invalidTarget }
        var result = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        result.httpMethod = "PUT"
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await perform(result)
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (receipt["ok"] as? Bool) == true
        else { throw AdminError.rejected }
    }

    private static func extract(_ field: AdminConfigField, from root: [String: Any]) -> AdminConfigValue {
        var cursor: Any? = root
        for segment in field.path.split(separator: ".") {
            guard let dict = cursor as? [String: Any] else { return .null }
            cursor = dict[String(segment)]
        }
        switch cursor {
        case let s as String: return .string(s)
        case let b as Bool: return .boolean(b)
        case let n as NSNumber:
            // NSNumber from JSONSerialization can box a Bool too; Bool is checked above.
            return .number(n.doubleValue)
        case Optional<Any>.none, nil: return .null
        default: return .null
        }
    }

    private static func nestedBody(_ field: AdminConfigField, value: AdminConfigValue) -> [String: Any] {
        let leaf: Any
        switch value {
        case .string(let s): leaf = s
        case .number(let n): leaf = n
        case .boolean(let b): leaf = b
        case .null: leaf = NSNull()
        }
        var segments = field.path.split(separator: ".").map(String.init)
        var body: Any = leaf
        while let last = segments.popLast() {
            body = [last: body]
        }
        return body as? [String: Any] ?? [:]
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
