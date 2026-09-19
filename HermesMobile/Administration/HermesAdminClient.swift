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
