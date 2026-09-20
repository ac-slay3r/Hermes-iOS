import XCTest
@testable import HermesMobile

@MainActor
final class AdminClientTests: XCTestCase {
    func testOverviewBindsStatusIdentityAndProfilesToReviewedTarget() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"version":"0.14.0","overall":"ok","gateway_running":true,"gateway_state":"running","active_agents":2,"active_sessions":4,"auth_required":true,"auth_flows":["cookie","native_pkce"],"profiles":["default","work"]}"#),
            .json(#"{"user_id":"user-1","email":"admin@example.com","display_name":"Admin","org_id":"org-1","provider":"nous","expires_at":1900000000}"#),
            .json(#"{"active":"default","current":"work"}"#)
        ])

        let overview = try await HermesAdminClient(transport: transport).readOverview(target: target)

        XCTAssertEqual(overview.target, target)
        XCTAssertEqual(overview.status.version, "0.14.0")
        XCTAssertTrue(overview.status.gatewayRunning)
        XCTAssertEqual(overview.status.activeAgents, 2)
        XCTAssertEqual(overview.status.activeSessions, 4)
        XCTAssertEqual(overview.status.authFlows, ["cookie", "native_pkce"])
        XCTAssertEqual(overview.status.availableProfiles, ["default", "work"])
        XCTAssertEqual(overview.identity.userID, "user-1")
        XCTAssertEqual(overview.identity.displayName, "Admin")
        XCTAssertEqual(overview.identity.provider, "nous")
        XCTAssertEqual(overview.profiles.active, "default")
        XCTAssertEqual(overview.profiles.current, "work")
        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/dashboard/api/status", "/dashboard/api/auth/me", "/dashboard/api/profiles/active"
        ])
        XCTAssertEqual(transport.requests[0].url?.query, "profile=work")
    }

    func testOverviewStopsWhenAuthenticatedIdentityIsRejected() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"version":"0.14.0","overall":"ok","gateway_running":true,"gateway_state":"running","active_agents":0,"active_sessions":0,"auth_required":true,"auth_flows":["native_pkce"],"profiles":["default"]}"#),
            .http(401, #"{"detail":"Unauthorized"}"#)
        ])

        do {
            _ = try await HermesAdminClient(transport: transport).readOverview(target: target)
            XCTFail("Expected authentication failure")
        } catch AdminError.http(401) {
            // Expected. Profile discovery must not run without verified identity.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testOverviewDefaultsCapabilityFieldsMissingFromOlderStatus() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"version":"0.13.0","gateway_running":false,"active_sessions":0}"#),
            .json(#"{"user_id":"user-1","email":"","display_name":"Admin","org_id":"","provider":"nous","expires_at":1900000000}"#),
            .json(#"{"active":"default","current":"default"}"#)
        ])

        let overview = try await HermesAdminClient(transport: transport).readOverview(target: target)

        XCTAssertEqual(overview.status.overall, "unknown")
        XCTAssertEqual(overview.status.activeAgents, 0)
        XCTAssertFalse(overview.status.authRequired)
        XCTAssertEqual(overview.status.authFlows, [])
        XCTAssertEqual(overview.status.availableProfiles, [])
    }

    func testTargetRejectsInsecureOrAmbiguousAuthority() throws {
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com/?token=x", "https://example.com/#x"] {
            XCTAssertThrowsError(try AdminTarget(address: url, profile: "default"))
        }
        XCTAssertThrowsError(try AdminTarget(address: "https://example.com", profile: "../other"))
        XCTAssertThrowsError(try AdminTarget(address: "https://example.com", profile: " Default "))
    }

    func testTargetRejectsProfileWithTerminalNewlineOrLineSeparator() {
        for profile in ["default\n", "default\u{2028}"] {
            XCTAssertThrowsError(try AdminTarget(address: "https://example.com", profile: profile))
        }
    }

    func testSessionRejectsIdentifierWithTerminalNewlineOrLineSeparator() async throws {
        let transport = AdminFixtureTransport(responses: [])
        let client = HermesAdminClient(transport: transport)
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        for id in ["session-1\n", "session-1\u{2028}"] {
            do {
                _ = try await client.read(.sessionTitle(id), target: target)
                XCTFail("Expected invalid session identifier")
            } catch AdminError.invalidResource {
                // Expected: malformed identifiers must fail before transport.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSessionCorrectionPreservesProfileAndOnlyWritesTitle() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"id":"session-1","profile":"work","title":"Before"}"#),
            .json(#"{"id":"session-1","profile":"work","title":"Before"}"#),
            .json(#"{"ok":true,"title":"After"}"#),
            .json(#"{"id":"session-1","profile":"work","title":"After"}"#)
        ])
        let editor = AdminEditor(client: HermesAdminClient(transport: transport), target: target)
        await editor.load(.sessionTitle("session-1"))
        editor.proposed = "After"
        editor.review()
        await editor.apply()
        XCTAssertEqual(editor.phase, .saved)
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["GET", "GET", "PATCH", "GET"])
        let request = transport.requests[2]
        XCTAssertEqual(request.url?.path, "/dashboard/api/sessions/session-1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["profile": "work", "title": "After"])
    }

    func testConcurrentSoulChangeStopsBeforeWrite() async throws {
        let transport = AdminFixtureTransport(responses: [.json(#"{"content":"original","exists":true}"#), .json(#"{"content":"changed elsewhere","exists":true}"#)])
        let editor = try makeEditor(transport)
        await editor.load(.soul)
        editor.proposed = "replacement"
        editor.review()
        await editor.apply()
        XCTAssertEqual(editor.phase, .conflict)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testWriteTimeoutRequiresReadbackNotRetry() async throws {
        let transport = AdminFixtureTransport(responses: [.json(#"{"content":"a","exists":true}"#), .json(#"{"content":"a","exists":true}"#), .failure, .json(#"{"content":"b","exists":true}"#)])
        let editor = try makeEditor(transport)
        await editor.load(.soul)
        editor.proposed = "b"
        editor.review()
        await editor.apply()
        XCTAssertEqual(editor.phase, .unknown)
        await editor.apply()
        XCTAssertEqual(transport.requests.count, 3)
        await editor.verify()
        XCTAssertEqual(editor.phase, .saved)
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testBusinessFailureIsNotSaved() async throws {
        let transport = AdminFixtureTransport(responses: [.json(#"{"content":"a","exists":true}"#), .json(#"{"content":"a","exists":true}"#), .json(#"{"ok":false}"#)])
        let editor = try makeEditor(transport)
        await editor.load(.soul)
        editor.proposed = "b"
        editor.review()
        await editor.apply()
        XCTAssertEqual(editor.phase, .rejected)
    }

    func testProfileSwitchDiscardsDraft() async throws {
        let editor = try makeEditor(AdminFixtureTransport(responses: [.json(#"{"content":"a","exists":true}"#)]))
        await editor.load(.soul)
        editor.proposed = "private draft"
        editor.review()
        editor.select(try AdminTarget(address: "https://example.com", profile: "other"))
        XCTAssertEqual(editor.phase, .idle)
        XCTAssertNil(editor.original)
        XCTAssertEqual(editor.proposed, "")
    }

    func testProfileSwitchDoesNotAbandonDraftWhileApplying() async throws {
        let transport = SuspendedAdminTransport(initial: #"{"content":"a","exists":true}"#)
        let editor = try makeEditor(transport)
        let originalTarget = editor.target
        await editor.load(.soul)
        editor.proposed = "private draft"
        editor.review()

        let application = Task { await editor.apply() }
        try await transport.waitUntilSuspended()
        XCTAssertEqual(editor.phase, .applying)

        editor.select(try AdminTarget(address: "https://example.com", profile: "other"))
        XCTAssertEqual(editor.target, originalTarget)
        XCTAssertEqual(editor.resource, .soul)
        XCTAssertEqual(editor.original, AdminSnapshot(value: "a", exists: true))
        XCTAssertEqual(editor.proposed, "private draft")
        XCTAssertEqual(editor.phase, .applying)

        transport.resume(throwing: URLError(.timedOut))
        await application.value
        XCTAssertEqual(editor.phase, .unknown)
        XCTAssertEqual(editor.target, originalTarget)
    }

    func testProfileSwitchDoesNotAbandonDraftWhileOutcomeUnknown() async throws {
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"content":"a","exists":true}"#),
            .json(#"{"content":"a","exists":true}"#),
            .failure
        ])
        let editor = try makeEditor(transport)
        let originalTarget = editor.target
        await editor.load(.soul)
        editor.proposed = "private draft"
        editor.review()
        await editor.apply()
        XCTAssertEqual(editor.phase, .unknown)

        editor.select(try AdminTarget(address: "https://example.com", profile: "other"))
        XCTAssertEqual(editor.target, originalTarget)
        XCTAssertEqual(editor.resource, .soul)
        XCTAssertEqual(editor.original, AdminSnapshot(value: "a", exists: true))
        XCTAssertEqual(editor.proposed, "private draft")
        XCTAssertEqual(editor.phase, .unknown)
    }

    func testWrongSessionProfileFailsClosed() async throws {
        let editor = try makeEditor(AdminFixtureTransport(responses: [.json(#"{"id":"s","profile":"other","title":"x"}"#)]))
        await editor.load(.sessionTitle("s"))
        XCTAssertEqual(editor.phase, .failed)
        XCTAssertNil(editor.original)
    }

    func testUnavailableTransportDoesNotPretendConnected() async throws {
        let editor = try makeEditor(UnavailableAdminTransport())
        await editor.load(.soul)
        XCTAssertEqual(editor.phase, .failed)
        XCTAssertNil(editor.original)
    }

    private func makeEditor(_ transport: any AdminTransport) throws -> AdminEditor {
        AdminEditor(client: HermesAdminClient(transport: transport), target: try AdminTarget(address: "https://example.com", profile: "default"))
    }
}

@MainActor
private final class SuspendedAdminTransport: AdminTransport {
    private let initial: String
    private var readsReturned = 0
    private var continuation: CheckedContinuation<AdminHTTPResponse, Error>?

    init(initial: String) {
        self.initial = initial
    }

    func send(_ request: URLRequest) async throws -> AdminHTTPResponse {
        // Complete load and preflight; suspend the actual mutation request.
        if readsReturned < 2 {
            readsReturned += 1
            return AdminHTTPResponse(status: 200, body: Data(initial.utf8))
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async throws {
        let deadline = Date().addingTimeInterval(5)
        while continuation == nil {
            guard Date() < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class AdminFixtureTransport: AdminTransport {
    enum Response {
        case json(String)
        case http(Int, String)
        case failure
    }
    var responses: [Response]
    var requests: [URLRequest] = []
    init(responses: [Response]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> AdminHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AdminError.unavailable }
        switch responses.removeFirst() {
        case .json(let value): return AdminHTTPResponse(status: 200, body: Data(value.utf8))
        case .http(let status, let value):
            return AdminHTTPResponse(status: status, body: Data(value.utf8))
        case .failure: throw URLError(.timedOut)
        }
    }
}
