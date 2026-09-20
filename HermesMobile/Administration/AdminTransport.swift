import Foundation

struct AdminTransportScope {
    static func validate(_ url: URL, target: AdminTarget) throws {
        guard let requested = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let reviewed = URLComponents(url: target.baseURL, resolvingAgainstBaseURL: false),
              requested.scheme == "https",
              requested.scheme == reviewed.scheme,
              requested.host == reviewed.host,
              requested.port == reviewed.port,
              requested.user == nil,
              requested.password == nil,
              requested.fragment == nil
        else { throw AdminError.wrongTarget }

        for encodedPath in [requested.percentEncodedPath, reviewed.percentEncodedPath] {
            let lowered = encodedPath.lowercased()
            guard !["%2e", "%2f", "%5c", "%25"].contains(where: lowered.contains)
            else { throw AdminError.wrongTarget }
        }
        for path in [requested.path, reviewed.path] {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains("."), !components.contains(".."), !path.contains("\\")
            else { throw AdminError.wrongTarget }
        }

        let basePath = normalizedBasePath(reviewed.path)
        let requestedPath = requested.path
        guard basePath == "/" || requestedPath == basePath || requestedPath.hasPrefix(basePath + "/")
        else { throw AdminError.wrongTarget }
    }

    private static func normalizedBasePath(_ path: String) -> String {
        guard path != "/" else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

private final class AdminRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
final class URLSessionAdminTransport: AdminTransport {
    private let target: AdminTarget
    private let accessTokenProvider: @MainActor () -> String?
    private let redirectDelegate: AdminRedirectRejectingDelegate
    private let session: URLSession

    init(
        target: AdminTarget,
        accessTokenProvider: @escaping @MainActor () -> String? = { nil }
    ) {
        self.target = target
        self.accessTokenProvider = accessTokenProvider
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let redirectDelegate = AdminRedirectRejectingDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> AdminHTTPResponse {
        guard let url = request.url else { throw AdminError.invalidTarget }
        try AdminTransportScope.validate(url, target: target)
        var authorized = request
        if let accessToken = accessTokenProvider(), !accessToken.isEmpty {
            authorized.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: authorized)
        guard let response = response as? HTTPURLResponse else { throw AdminError.malformedResponse }
        return AdminHTTPResponse(status: response.statusCode, body: data)
    }
}
