import XCTest
@testable import HermesMobile

@MainActor
final class AdminClientTests: XCTestCase {
    func testAdminPKCEUsesRFC7636S256() throws {
        let pkce = try AdminPKCE(
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        )
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testNativeAuthorizationAndCallbackRemainBoundToExactTargetAndState() throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let pkce = try AdminPKCE(verifier: String(repeating: "a", count: 43))
        let attempt = try AdminAuthorizationAttempt(
            target: target,
            provider: "nous",
            pkce: pkce,
            state: "state-1"
        )
        let components = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/dashboard/auth/native/authorize")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") }), [
            "provider": "nous",
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
            "redirect_uri": "cool.n0thing.hermes:/oauth/callback",
            "state": "state-1"
        ])

        XCTAssertEqual(
            try attempt.authorizationCode(from: try XCTUnwrap(URL(string: "cool.n0thing.hermes:/oauth/callback?code=code-1&state=state-1"))),
            "code-1"
        )
        for callback in [
            "cool.n0thing.hermes:/oauth/callback?code=code-1&state=wrong",
            "cool.n0thing.hermes:/oauth/other?code=code-1&state=state-1",
            "cool.n0thing.hermes.evil:/oauth/callback?code=code-1&state=state-1",
            "cool.n0thing.hermes:/oauth/callback?code=code-1&state&state=state-1",
            "cool.n0thing.hermes:/oauth/callback?code&code=code-1&state=state-1",
            "cool.n0thing.hermes:/oauth/callback?error=denied&error=other&code=code-1&state=state-1",
            "cool.n0thing.hermes:/oauth/callback?error&code=code-1&state=state-1",
            "cool.n0thing.hermes:/oauth/callback?error=denied&state=wrong"
        ] {
            XCTAssertThrowsError(try attempt.authorizationCode(from: try XCTUnwrap(URL(string: callback))))
        }
    }

    func testNativeTokenExchangeUsesReviewedOriginAndDecodesBearerTokens() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"access_token":"access-1","refresh_token":"refresh-1","token_type":"Bearer","expires_at":1900000000,"provider":"nous","user_id":"user-1"}"#)
        ])
        let client = HermesAdminAuthClient(transport: transport)

        let tokens = try await client.exchangeCode("code-1", verifier: "verifier-1", target: target)

        XCTAssertEqual(tokens.accessToken, "access-1")
        XCTAssertEqual(tokens.refreshToken, "refresh-1")
        XCTAssertEqual(tokens.provider, "nous")
        XCTAssertEqual(tokens.userID, "user-1")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/auth/native/token")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["code": "code-1", "code_verifier": "verifier-1"])
    }

    func testAdminAuthSessionUsesSystemCallbackAndPersistsOnlyRefreshCredential() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"access_token":"access-1","refresh_token":"refresh-1","token_type":"Bearer","expires_at":1900000000,"provider":"nous","user_id":"user-1"}"#)
        ])
        let browser = AdminFixtureWebAuthentication()
        let credentials = AdminFixtureCredentialStore()
        let session = AdminAuthSession(
            browser: browser,
            client: HermesAdminAuthClient(transport: transport),
            credentialStore: credentials
        )

        try await session.signIn(target: target, provider: "nous")

        XCTAssertEqual(session.accessToken, "access-1")
        XCTAssertEqual(session.authenticatedTarget, target)
        XCTAssertEqual(browser.callbackScheme, "cool.n0thing.hermes")
        XCTAssertEqual(credentials.saved?.refreshToken, "refresh-1")
        XCTAssertEqual(credentials.saved?.provider, "nous")
        XCTAssertEqual(credentials.saved?.userID, "user-1")
        XCTAssertFalse(credentials.encodedPayload?.contains("access-1") == true)
        try await session.validate(identity: AdminIdentity(
            userID: "user-1",
            email: "admin@example.com",
            displayName: "Admin",
            organizationID: "org-1",
            provider: "nous",
            expiresAt: 1_900_000_000
        ))
        do {
            try await session.validate(identity: AdminIdentity(
                userID: "other-user",
                email: "admin@example.com",
                displayName: "Admin",
                organizationID: "org-1",
                provider: "nous",
                expiresAt: 1_900_000_000
            ))
            XCTFail("Expected token and identity endpoint mismatch to be rejected")
        } catch AdminError.wrongTarget {
            // Expected: mismatched credentials are removed rather than accepted.
        }
        XCTAssertNil(credentials.saved)
        XCTAssertNil(session.accessToken)
    }

    func testAdminAuthSessionRestoresByRotatingStoredRefreshCredential() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"access_token":"access-2","refresh_token":"refresh-2","token_type":"Bearer","expires_at":1900000100,"provider":"nous","user_id":"user-1"}"#)
        ])
        let credentials = AdminFixtureCredentialStore()
        credentials.saved = AdminStoredCredential(
            refreshToken: "refresh-1",
            provider: "nous",
            userID: "user-1",
            expiresAt: 1900000000
        )
        let session = AdminAuthSession(
            browser: AdminFixtureWebAuthentication(),
            client: HermesAdminAuthClient(transport: transport),
            credentialStore: credentials
        )

        let restored = try await session.restore(target: target)
        XCTAssertTrue(restored)

        XCTAssertEqual(session.accessToken, "access-2")
        XCTAssertEqual(credentials.saved?.refreshToken, "refresh-2")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/auth/native/refresh")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["refresh_token": "refresh-1", "provider": "nous"])
    }

    func testRefreshIdentityDriftDeletesStoredCredential() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"access_token":"access-2","refresh_token":"refresh-2","token_type":"Bearer","expires_at":1900000100,"provider":"nous","user_id":"other-user"}"#)
        ])
        let credentials = AdminFixtureCredentialStore()
        credentials.saved = AdminStoredCredential(
            refreshToken: "refresh-1", provider: "nous", userID: "user-1", expiresAt: 1_900_000_000
        )
        let session = AdminAuthSession(
            browser: AdminFixtureWebAuthentication(),
            client: HermesAdminAuthClient(transport: transport),
            credentialStore: credentials
        )

        do {
            _ = try await session.restore(target: target)
            XCTFail("Expected refresh identity drift to fail")
        } catch AdminAuthenticationError.malformedTokenResponse {
            // Expected: a rotated token cannot change credential identity.
        }
        XCTAssertNil(credentials.saved)
    }

    func testCancellationWhileCredentialLoadReturnsNilFailsClosed() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let credentials = SuspendedAdminCredentialStore()
        let session = AdminAuthSession(
            browser: AdminFixtureWebAuthentication(),
            client: HermesAdminAuthClient(transport: AdminFixtureTransport(responses: [])),
            credentialStore: credentials
        )
        let restore = Task { try await session.restore(target: target) }
        try await credentials.waitUntilLoading()

        session.cancel()
        credentials.finishLoad(with: nil)

        do {
            _ = try await restore.value
            XCTFail("Expected cancelled restore")
        } catch AdminAuthenticationError.cancelled {
            // Expected: nil load still revalidates the operation generation.
        }
    }

    func testSignOutClearsVolatileAuthorityWhenCredentialDeletionFails() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let credentials = AdminFixtureCredentialStore()
        let session = AdminAuthSession(
            browser: AdminFixtureWebAuthentication(),
            client: HermesAdminAuthClient(transport: AdminFixtureTransport(responses: [
                .json(#"{"access_token":"access-1","refresh_token":"refresh-1","token_type":"Bearer","expires_at":1900000000,"provider":"nous","user_id":"user-1"}"#)
            ])),
            credentialStore: credentials
        )
        try await session.signIn(target: target)
        credentials.failDelete = true

        do {
            try await session.signOut()
            XCTFail("Expected Keychain deletion failure")
        } catch {
            // Expected: persistence failure is surfaced after volatile authority is cleared.
        }
        XCTAssertNil(session.accessToken)
        XCTAssertNil(session.authenticatedTarget)
        XCTAssertNil(session.authenticatedProvider)
        XCTAssertNil(session.authenticatedUserID)
    }

    func testSignOutClearsAuthorityBeforeCredentialDeletionCompletes() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let credentials = SuspendedDeleteCredentialStore()
        let session = AdminAuthSession(
            browser: AdminFixtureWebAuthentication(),
            client: HermesAdminAuthClient(transport: AdminFixtureTransport(responses: [
                .json(#"{"access_token":"access-1","refresh_token":"refresh-1","token_type":"Bearer","expires_at":1900000000,"provider":"nous","user_id":"user-1"}"#)
            ])),
            credentialStore: credentials
        )
        try await session.signIn(target: target)

        let signOut = Task { try await session.signOut() }
        try await credentials.waitUntilDeleting()

        XCTAssertNil(session.accessToken)
        XCTAssertNil(session.authenticatedTarget)
        credentials.finishDelete()
        try await signOut.value
    }

    func testStaleCancellationCannotDeleteNewerCredentialRevision() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let credentials = RacingAdminCredentialStore()
        let staleSession = AdminAuthSession(
            browser: AdminFixtureWebAuthentication(),
            client: HermesAdminAuthClient(transport: AdminFixtureTransport(responses: [
                .json(#"{"access_token":"access-old","refresh_token":"refresh-old","token_type":"Bearer","expires_at":1900000000,"provider":"nous","user_id":"user-1"}"#)
            ])),
            credentialStore: credentials
        )
        let currentSession = AdminAuthSession(
            browser: AdminFixtureWebAuthentication(),
            client: HermesAdminAuthClient(transport: AdminFixtureTransport(responses: [
                .json(#"{"access_token":"access-new","refresh_token":"refresh-new","token_type":"Bearer","expires_at":1900000100,"provider":"nous","user_id":"user-1"}"#)
            ])),
            credentialStore: credentials
        )
        let staleSignIn = Task { try await staleSession.signIn(target: target) }
        try await credentials.waitUntilFirstSaveSuspends()
        staleSession.cancel()

        try await currentSession.signIn(target: target)
        credentials.finishFirstSave()
        do {
            try await staleSignIn.value
            XCTFail("Expected stale sign-in cancellation")
        } catch AdminAuthenticationError.cancelled {
            // Expected: conditional cleanup may not erase the current revision.
        }
        XCTAssertEqual(credentials.saved?.refreshToken, "refresh-new")
    }

    func testCancellingInFlightAuthenticationPreventsExchangeAndPersistence() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [])
        let browser = SuspendedAdminWebAuthentication()
        let credentials = AdminFixtureCredentialStore()
        let session = AdminAuthSession(
            browser: browser,
            client: HermesAdminAuthClient(transport: transport),
            credentialStore: credentials
        )
        let signIn = Task { try await session.signIn(target: target) }
        try await browser.waitUntilStarted()

        session.cancel()

        do {
            try await signIn.value
            XCTFail("Expected cancelled authentication")
        } catch AdminAuthenticationError.cancelled {
            // Expected: no token exchange or persistence after target invalidation.
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(credentials.saved)
    }

    func testAdminTransportScopeRejectsCrossOriginAndSiblingBasePaths() throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        XCTAssertNoThrow(try AdminTransportScope.validate(
            try XCTUnwrap(URL(string: "https://example.com/dashboard/api/auth/me")),
            target: target
        ))
        for address in [
            "https://evil.example/dashboard/api/auth/me",
            "https://example.com/dashboard-evil/api/auth/me",
            "http://example.com/dashboard/api/auth/me",
            "https://example.com:444/dashboard/api/auth/me",
            "https://user@example.com/dashboard/api/auth/me",
            "https://example.com/dashboard/%2e%2e/other",
            "https://example.com/dashboard%2Fother/api/auth/me",
            "https://example.com/dashboard%5Cother/api/auth/me"
        ] {
            XCTAssertThrowsError(try AdminTransportScope.validate(
                try XCTUnwrap(URL(string: address)),
                target: target
            ))
        }
    }

    func testPublicStatusDiscoveryStopsBeforeAuthenticatedEndpoints() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"version":"0.21.3","overall":"ok","gateway_running":true,"gateway_state":"running","active_agents":0,"active_sessions":0,"auth_required":true,"auth_flows":["cookie","native_pkce","native_ios_pkce"],"profiles":["default","work"]}"#)
        ])

        let status = try await HermesAdminClient(transport: transport).readStatus(target: target)

        XCTAssertTrue(status.authFlows.contains("native_ios_pkce"))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url?.path, "/dashboard/api/status")
        XCTAssertEqual(transport.requests[0].url?.query, "profile=work")
    }

    func testOverviewRefreshPolicyInvalidatesLostAuthorityAndAuthenticationFailures() throws {
        XCTAssertTrue(AdminOverviewRefreshPolicy.invalidatesSession(
            AdminError.wrongTarget,
            sessionHasAuthority: true
        ))
        XCTAssertTrue(AdminOverviewRefreshPolicy.invalidatesSession(
            AdminError.http(401),
            sessionHasAuthority: true
        ))
        XCTAssertTrue(AdminOverviewRefreshPolicy.invalidatesSession(
            AdminError.http(403),
            sessionHasAuthority: true
        ))
        XCTAssertTrue(AdminOverviewRefreshPolicy.invalidatesSession(
            URLError(.cancelled),
            sessionHasAuthority: false
        ))
        XCTAssertFalse(AdminOverviewRefreshPolicy.invalidatesSession(
            URLError(.notConnectedToInternet),
            sessionHasAuthority: true
        ))
        XCTAssertFalse(AdminOverviewRefreshPolicy.invalidatesSession(
            AdminError.http(500),
            sessionHasAuthority: true
        ))
    }

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

    func testOverviewRejectsSelectedProfileMissingFromHostInventory() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"version":"0.21.3","overall":"ok","gateway_running":true,"gateway_state":"running","active_agents":0,"active_sessions":0,"auth_required":true,"auth_flows":["native_ios_pkce"],"profiles":["default"]}"#),
            .json(#"{"user_id":"user-1","email":"admin@example.com","display_name":"Admin","org_id":"org-1","provider":"nous","expires_at":1900000000}"#),
            .json(#"{"active":"default","current":"default"}"#)
        ])

        do {
            _ = try await HermesAdminClient(transport: transport).readOverview(target: target)
            XCTFail("Expected selected profile rejection")
        } catch AdminError.wrongTarget {
            // Serving profile may differ; absence from inventory is the fail-closed condition.
        }
    }

    func testOverviewRejectsEmptyHostProfileInventory() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"version":"0.21.3","overall":"ok","gateway_running":true,"gateway_state":"running","active_agents":0,"active_sessions":0,"auth_required":true,"auth_flows":["native_ios_pkce"],"profiles":[]}"#)
        ])

        do {
            _ = try await HermesAdminClient(transport: transport).readOverview(target: target)
            XCTFail("Expected empty profile inventory rejection")
        } catch AdminError.wrongTarget {
            // Expected: overview cannot be bound without authoritative inventory.
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testOverviewDefaultsCapabilityFieldsMissingFromOlderStatus() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"version":"0.13.0","gateway_running":false,"active_sessions":0}"#),
            .json(#"{"user_id":"user-1","email":"","display_name":"Admin","org_id":"","provider":"nous","expires_at":1900000000}"#),
            .json(#"{"active":"default","current":"default"}"#)
        ])

        let status = try await HermesAdminClient(transport: transport).readStatus(target: target)

        XCTAssertEqual(status.overall, "unknown")
        XCTAssertEqual(status.activeAgents, 0)
        XCTAssertFalse(status.authRequired)
        XCTAssertEqual(status.authFlows, [])
        XCTAssertEqual(status.availableProfiles, [])
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

    func testEditorLoadFailureCallsOnAuthorityLostForExpiredSignIn() async throws {
        let transport = AdminFixtureTransport(responses: [.http(401, "")])
        let editor = try makeEditor(transport)
        var authorityLostCalls = 0
        editor.onAuthorityLost = { authorityLostCalls += 1 }
        await editor.load(.soul)
        XCTAssertEqual(editor.phase, .failed)
        XCTAssertEqual(authorityLostCalls, 1)
    }

    func testEditorLoadFailureDoesNotCallOnAuthorityLostForOtherErrors() async throws {
        let transport = AdminFixtureTransport(responses: [.failure])
        let editor = try makeEditor(transport)
        var authorityLostCalls = 0
        editor.onAuthorityLost = { authorityLostCalls += 1 }
        await editor.load(.soul)
        XCTAssertEqual(editor.phase, .failed)
        XCTAssertEqual(authorityLostCalls, 0)
    }

    func testEditorApplyPreflightFailureCallsOnAuthorityLostForExpiredSignIn() async throws {
        let transport = AdminFixtureTransport(responses: [.json(#"{"content":"a","exists":true}"#), .http(401, "")])
        let editor = try makeEditor(transport)
        var authorityLostCalls = 0
        editor.onAuthorityLost = { authorityLostCalls += 1 }
        await editor.load(.soul)
        editor.proposed = "b"
        editor.review()
        await editor.apply()
        XCTAssertEqual(editor.phase, .failed)
        XCTAssertEqual(authorityLostCalls, 1)
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

    // MARK: - Profiles & Sessions (M2 Batch 1, read-only)

    func testReadProfilesDecodesInventoryAndBindsNoMutationPath() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"profiles":[{"name":"default","is_default":true,"model":"gpt","provider":"openai","gateway_running":true,"display_name":"Default","description":"d"},{"name":"work","is_default":false,"model":null,"provider":null,"gateway_running":false,"display_name":"","description":""}]}"#)
        ])

        let profiles = try await HermesAdminClient(transport: transport).readProfiles(target: target)

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].name, "default")
        XCTAssertTrue(profiles[0].isDefault)
        XCTAssertEqual(profiles[0].model, "gpt")
        XCTAssertTrue(profiles[0].gatewayRunning)
        XCTAssertEqual(profiles[1].name, "work")
        XCTAssertNil(profiles[1].model)
        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/dashboard/api/profiles"])
        XCTAssertEqual(transport.requests[0].httpMethod, "GET")
    }

    func testReadSessionsAlwaysBindsExplicitProfileQuery() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"sessions":[{"id":"s1","title":"Hello","preview":"hi there","profile":"work","archived":false,"pinned":true,"unread":false,"is_active":true,"started_at":100,"last_active":200}],"total":1,"limit":20,"offset":0}"#)
        ])

        let page = try await HermesAdminClient(transport: transport).readSessions(target: target)

        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.sessions.first?.id, "s1")
        XCTAssertTrue(page.sessions.first?.pinned == true)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/sessions")
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["profile"], "work")
        XCTAssertEqual(query["archived"], "exclude")
    }

    func testReadSessionsClampsLimitToServerBound() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"sessions":[],"total":0,"limit":100,"offset":0}"#)
        ])

        _ = try await HermesAdminClient(transport: transport).readSessions(target: target, limit: 5000, offset: -5)

        let request = try XCTUnwrap(transport.requests.first)
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["limit"], "100")
        XCTAssertEqual(query["offset"], "0")
    }

    func testSearchSessionsPassesQueryAndProfile() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"sessions":[],"total":0,"limit":20,"offset":0}"#)
        ])

        _ = try await HermesAdminClient(transport: transport).searchSessions(target: target, query: "deploy")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/sessions/search")
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["q"], "deploy")
        XCTAssertEqual(query["profile"], "work")
    }

    func testReadSessionDetailRejectsMalformedIdentifierBeforeTransport() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let transport = AdminFixtureTransport(responses: [])
        let client = HermesAdminClient(transport: transport)
        for id in ["s1\n", "s1\u{2028}", ""] {
            do {
                _ = try await client.readSessionDetail(target: target, id: id)
                XCTFail("Expected invalid session identifier")
            } catch AdminError.invalidResource {
                // Expected.
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testReadSessionDetailFailsClosedOnProfileMismatch() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"id":"s1","title":"x","profile":"other","archived":false,"pinned":false}"#)
        ])

        do {
            _ = try await HermesAdminClient(transport: transport).readSessionDetail(target: target, id: "s1")
            XCTFail("Expected wrong-target rejection")
        } catch AdminError.wrongTarget {
            // Expected: a detail response for a different profile must not be trusted.
        }
    }

    func testReadSessionDetailDecodesRawIntBooleansFromRealServerShape() async throws {
        // GET /api/sessions/{id} (detail) returns archived/pinned as raw SQLite 0/1 ints,
        // unlike GET /api/sessions (list), which explicitly casts to real JSON booleans.
        // A prior bug decoded Bool-only, throwing a type-mismatch on every real session detail
        // fetch (verified directly against the live dashboard) — this reproduces that shape.
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"id":"s1","title":"x","profile":"default","archived":1,"pinned":0}"#)
        ])

        let detail = try await HermesAdminClient(transport: transport).readSessionDetail(target: target, id: "s1")

        XCTAssertTrue(detail.archived)
        XCTAssertFalse(detail.pinned)
    }

    func testReadSessionMessagesDecodesEnvelopeAndBareArrayShapes() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let envelopeTransport = AdminFixtureTransport(responses: [
            .json(#"{"messages":[{"id":"m1","role":"user","content":"hi"}]}"#)
        ])
        let envelopeMessages = try await HermesAdminClient(transport: envelopeTransport)
            .readSessionMessages(target: target, id: "s1")
        XCTAssertEqual(envelopeMessages.first?.role, "user")
        XCTAssertEqual(envelopeMessages.first?.content, "hi")

        let bareArrayTransport = AdminFixtureTransport(responses: [
            .json(#"[{"id":"m1","role":"assistant","display_content":"rendered"}]"#)
        ])
        let bareMessages = try await HermesAdminClient(transport: bareArrayTransport)
            .readSessionMessages(target: target, id: "s1")
        XCTAssertEqual(bareMessages.first?.role, "assistant")
        XCTAssertEqual(bareMessages.first?.displayContent, "rendered")
    }

    func testReadSessionMessagesRejectsMalformedIdentifierBeforeTransport() async throws {
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let transport = AdminFixtureTransport(responses: [])
        do {
            _ = try await HermesAdminClient(transport: transport).readSessionMessages(target: target, id: "s1\n")
            XCTFail("Expected invalid session identifier")
        } catch AdminError.invalidResource {
            // Expected.
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testReadSessionMessagesDecodesIntegerRowIDsFromRealServerShape() async throws {
        // The server's actual row id is a SQLite integer (e.g. 46639), not a string. A prior
        // bug decoded `id` as String-only, which throws a type-mismatch (not a missing-key
        // fallback) on every real message from every session — this reproduces that exact
        // shape to guard against the regression.
        let target = try AdminTarget(address: "https://example.com", profile: "default")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"messages":[{"id":46639,"role":"user","content":"hi"},{"id":46640,"role":"assistant","content":""}]}"#)
        ])
        let messages = try await HermesAdminClient(transport: transport)
            .readSessionMessages(target: target, id: "s1")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].id, "46639")
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[1].id, "46640")
    }

    // MARK: - Target persistence (address/profile only; no tokens)

    func testRestoredTargetPrefillsFieldsButDoesNotAutoConnect() async throws {
        let persistence = AdminFixtureTargetPersistence()
        persistence.saved = (address: "https://saved.example.com", profile: "work")

        let restored = persistence.loadLastAdminTarget()

        XCTAssertEqual(restored?.address, "https://saved.example.com")
        XCTAssertEqual(restored?.profile, "work")
    }

    func testSavingTargetPersistsExactAddressAndProfile() async throws {
        let persistence = AdminFixtureTargetPersistence()

        persistence.saveLastAdminTarget(address: "https://dashboard.example.com", profile: "default")

        XCTAssertEqual(persistence.saved?.address, "https://dashboard.example.com")
        XCTAssertEqual(persistence.saved?.profile, "default")
    }

    func testClearingTargetRemovesStoredValue() async throws {
        let persistence = AdminFixtureTargetPersistence()
        persistence.saved = (address: "https://dashboard.example.com", profile: "default")

        persistence.clearLastAdminTarget()

        XCTAssertNil(persistence.loadLastAdminTarget())
    }

    // MARK: - Read-screen authority-loss classification (Profiles/Sessions/detail)

    func testAdminSignalsAuthorityLostMatchesOverviewRefreshPolicy() throws {
        for error in [AdminError.wrongTarget, AdminError.http(401), AdminError.http(403)] as [Error] {
            XCTAssertTrue(adminSignalsAuthorityLost(error))
        }
        for error in [AdminError.http(500), AdminError.malformedResponse, AdminError.invalidResource, URLError(.notConnectedToInternet)] as [Error] {
            XCTAssertFalse(adminSignalsAuthorityLost(error))
        }
    }

    // MARK: - Skills, Tools, MCP (M2 Batch 2, read-only)

    func testReadSkillsDecodesInventoryWithDefaults() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"[{"name":"arxiv","description":"Search papers","category":"research","enabled":true,"usage":4,"provenance":"hub"},{"name":"custom","description":"","category":"","enabled":false}]"#)
        ])

        let skills = try await HermesAdminClient(transport: transport).readSkills(target: target)

        XCTAssertEqual(skills.count, 2)
        XCTAssertEqual(skills[0].name, "arxiv")
        XCTAssertEqual(skills[0].provenance, "hub")
        XCTAssertEqual(skills[0].usage, 4)
        XCTAssertFalse(skills[1].enabled)
        XCTAssertEqual(skills[1].usage, 0)
        XCTAssertEqual(skills[1].provenance, "agent")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/skills")
        XCTAssertEqual(request.url?.query, "profile=work")
    }

    func testReadToolsetsDecodesInventoryWithDefaults() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"[{"name":"web_search","label":"Web Search","description":"d","platform":"cli","platform_label":"CLI","enabled":true,"available":true,"configured":true,"tools":["search"]}]"#)
        ])

        let toolsets = try await HermesAdminClient(transport: transport).readToolsets(target: target)

        XCTAssertEqual(toolsets.count, 1)
        XCTAssertEqual(toolsets[0].name, "web_search")
        XCTAssertEqual(toolsets[0].label, "Web Search")
        XCTAssertTrue(toolsets[0].configured)
        XCTAssertEqual(toolsets[0].tools, ["search"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/tools/toolsets")
        XCTAssertEqual(request.url?.query, "profile=work")
    }

    func testReadMCPServersDecodesEnvelopeWithRedactedEnvAndDefaults() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"servers":[{"name":"github","transport":"http","url":"https://example.com/mcp","command":null,"args":[],"env":{"TOKEN":"***redacted***"},"auth":"header","enabled":true,"tools":["search_issues"]},{"name":"local-fs","transport":"stdio","command":"mcp-fs"}]}"#)
        ])

        let servers = try await HermesAdminClient(transport: transport).readMCPServers(target: target)

        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0].name, "github")
        XCTAssertEqual(servers[0].env["TOKEN"], "***redacted***")
        XCTAssertEqual(servers[0].tools, ["search_issues"])
        XCTAssertEqual(servers[1].transport, "stdio")
        XCTAssertNil(servers[1].tools)
        XCTAssertTrue(servers[1].enabled)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/mcp/servers")
        XCTAssertEqual(request.url?.query, "profile=work")
    }

    func testReadCronJobsDecodesArrayWithDefaults() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"[{"id":"job-1","name":"Nightly digest","enabled":true,"schedule_display":"Daily at 08:00","profile":"work"},{"id":"job-2","name":"Weekly sweep"}]"#)
        ])

        let jobs = try await HermesAdminClient(transport: transport).readCronJobs(target: target)

        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs[0].name, "Nightly digest")
        XCTAssertEqual(jobs[0].scheduleDisplay, "Daily at 08:00")
        XCTAssertTrue(jobs[1].enabled)
        XCTAssertNil(jobs[1].profile)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/cron/jobs")
        XCTAssertEqual(request.url?.query, "profile=work")
    }

    func testReadMessagingPlatformsDecodesEnvelopeWithDefaults() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"platforms":[{"id":"discord","name":"Discord","enabled":true,"configured":true,"gateway_running":true},{"id":"telegram","enabled":false,"configured":false,"gateway_running":false,"error_message":"missing token"}]}"#)
        ])

        let platforms = try await HermesAdminClient(transport: transport).readMessagingPlatforms(target: target)

        XCTAssertEqual(platforms.count, 2)
        XCTAssertEqual(platforms[0].name, "Discord")
        XCTAssertTrue(platforms[0].gatewayRunning)
        XCTAssertEqual(platforms[1].name, "telegram")
        XCTAssertEqual(platforms[1].errorMessage, "missing token")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/messaging/platforms")
        XCTAssertEqual(request.url?.query, "profile=work")
    }

    func testReadWebhooksDecodesStatusAndSubscriptionsWithDefaults() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"enabled":true,"base_url":"https://hook.example.com","subscriptions":[{"name":"deploy-notify","description":"d","events":["deploy.done"],"deliver":"log","enabled":true,"secret_set":true}]}"#)
        ])

        let status = try await HermesAdminClient(transport: transport).readWebhooks(target: target)

        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.baseURL, "https://hook.example.com")
        XCTAssertEqual(status.subscriptions.count, 1)
        XCTAssertEqual(status.subscriptions[0].name, "deploy-notify")
        XCTAssertTrue(status.subscriptions[0].secretSet)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/webhooks")
    }

    func testReadPairingDecodesPendingAndApprovedLeniently() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"pending":[{"user_id":"u1","source":"discord"}],"approved":[{"id":"u2","display_name":"Andrew","source":"telegram"}]}"#)
        ])

        let status = try await HermesAdminClient(transport: transport).readPairing(target: target)

        XCTAssertEqual(status.pending.count, 1)
        XCTAssertEqual(status.pending[0].id, "u1")
        XCTAssertEqual(status.approved[0].displayName, "Andrew")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/pairing")
        XCTAssertEqual(request.url?.query, "profile=work")
    }

    func testReadLogsClampsLinesAndPassesSearch() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [
            .json(#"{"file":"agent","lines":["line one","line two"]}"#)
        ])

        let result = try await HermesAdminClient(transport: transport).readLogs(
            target: target, file: "agent", lines: 9999, search: "error"
        )

        XCTAssertEqual(result.lines.count, 2)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/logs")
        let query = try XCTUnwrap(request.url?.query)
        XCTAssertTrue(query.contains("lines=500"))
        XCTAssertTrue(query.contains("search=error"))
    }

    func testReadAllowlistedConfigExtractsOnlyKnownFieldsFromFullDocument() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        // The server returns the FULL config document (including a secret-shaped key this
        // client never reads) — the allowlist projection must extract only its 8 named paths.
        let transport = AdminFixtureTransport(responses: [
            .json(#"""
            {
                "timezone": "America/New_York",
                "terminal": {"backend": "docker", "timeout": 240},
                "agent": {"gateway_timeout": 900, "max_turns": null},
                "checkpoints": {"enabled": true, "retention_days": 14},
                "browser": {"headed": false},
                "providers": {"anthropic": {"api_key": "sk-should-never-be-read"}}
            }
            """#)
        ])

        let snapshot = try await HermesAdminClient(transport: transport).readAllowlistedConfig(target: target)

        XCTAssertEqual(snapshot.values[.timezone], .string("America/New_York"))
        XCTAssertEqual(snapshot.values[.terminalBackend], .string("docker"))
        XCTAssertEqual(snapshot.values[.terminalTimeout], .number(240))
        XCTAssertEqual(snapshot.values[.agentGatewayTimeout], .number(900))
        XCTAssertEqual(snapshot.values[.agentMaxTurns], .null)
        XCTAssertEqual(snapshot.values[.checkpointsEnabled], .boolean(true))
        XCTAssertEqual(snapshot.values[.checkpointsRetentionDays], .number(14))
        XCTAssertEqual(snapshot.values[.browserHeaded], .boolean(false))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/dashboard/api/config")
        XCTAssertEqual(request.url?.query, "profile=work")
    }

    func testWriteAllowlistedConfigSendsMinimalNestedBodyForOneField() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [.json(#"{"ok":true}"#)])

        try await HermesAdminClient(transport: transport).writeAllowlistedConfig(
            .checkpointsRetentionDays, value: .number(30), target: target
        )

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/dashboard/api/config")
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(decoded["profile"] as? String, "work")
        let config = try XCTUnwrap(decoded["config"] as? [String: Any])
        // Only the ONE changed field is present, nested at its dotted path — never the whole document.
        XCTAssertEqual(config.count, 1)
        let checkpoints = try XCTUnwrap(config["checkpoints"] as? [String: Any])
        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertEqual(checkpoints["retention_days"] as? Int, 30)
    }

    func testWriteAllowlistedConfigRejectedWhenServerReturnsNotOK() async throws {
        let target = try AdminTarget(address: "https://example.com/dashboard", profile: "work")
        let transport = AdminFixtureTransport(responses: [.json(#"{"ok":false}"#)])
        do {
            try await HermesAdminClient(transport: transport).writeAllowlistedConfig(
                .browserHeaded, value: .boolean(true), target: target
            )
            XCTFail("Expected AdminError.rejected")
        } catch AdminError.rejected {
            // expected
        }
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

@MainActor
private final class AdminFixtureWebAuthentication: AdminWebAuthenticating {
    var callbackScheme: String?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        self.callbackScheme = callbackScheme
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let state = try XCTUnwrap(components.queryItems?.first { $0.name == "state" }?.value)
        return try XCTUnwrap(URL(string: "cool.n0thing.hermes:/oauth/callback?code=code-1&state=\(state)"))
    }

    func cancel() {}
}

@MainActor
private final class SuspendedAdminWebAuthentication: AdminWebAuthenticating {
    private var continuation: CheckedContinuation<URL, Error>?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async throws {
        let deadline = Date().addingTimeInterval(5)
        while continuation == nil {
            guard Date() < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }

    func cancel() {
        continuation?.resume(throwing: AdminAuthenticationError.cancelled)
        continuation = nil
    }
}

@MainActor
private final class AdminFixtureCredentialStore: AdminCredentialPersisting {
    var saved: AdminStoredCredential?
    var encodedPayload: String?
    var failDelete = false

    func save(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {
        saved = credential
        encodedPayload = String(data: try JSONEncoder().encode(credential), encoding: .utf8)
    }

    func load(for target: AdminTarget) async throws -> AdminStoredCredential? { saved }

    func delete(for target: AdminTarget) async throws {
        if failDelete { throw URLError(.cannotRemoveFile) }
        saved = nil
    }

    func delete(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {
        guard saved == credential else { return }
        try await delete(for: target)
    }
}

@MainActor
private final class AdminFixtureTargetPersistence: AdminTargetPersistenceProtocol {
    var saved: (address: String, profile: String)?

    func loadLastAdminTarget() -> (address: String, profile: String)? { saved }

    func saveLastAdminTarget(address: String, profile: String) {
        saved = (address: address, profile: profile)
    }

    func clearLastAdminTarget() {
        saved = nil
    }
}

@MainActor
private final class SuspendedAdminCredentialStore: AdminCredentialPersisting {
    private var loadContinuation: CheckedContinuation<AdminStoredCredential?, Never>?

    func save(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {}

    func load(for target: AdminTarget) async throws -> AdminStoredCredential? {
        await withCheckedContinuation { loadContinuation = $0 }
    }

    func delete(for target: AdminTarget) async throws {}
    func delete(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {}

    func waitUntilLoading() async throws {
        let deadline = Date().addingTimeInterval(5)
        while loadContinuation == nil {
            guard Date() < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }

    func finishLoad(with credential: AdminStoredCredential?) {
        loadContinuation?.resume(returning: credential)
        loadContinuation = nil
    }
}

@MainActor
private final class SuspendedDeleteCredentialStore: AdminCredentialPersisting {
    private var credential: AdminStoredCredential?
    private var deleteContinuation: CheckedContinuation<Void, Never>?

    func save(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {
        self.credential = credential
    }

    func load(for target: AdminTarget) async throws -> AdminStoredCredential? { credential }

    func delete(for target: AdminTarget) async throws {
        await withCheckedContinuation { deleteContinuation = $0 }
        credential = nil
    }

    func delete(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {
        guard self.credential == credential else { return }
        try await delete(for: target)
    }

    func waitUntilDeleting() async throws {
        let deadline = Date().addingTimeInterval(5)
        while deleteContinuation == nil {
            guard Date() < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }

    func finishDelete() {
        deleteContinuation?.resume()
        deleteContinuation = nil
    }
}

@MainActor
private final class RacingAdminCredentialStore: AdminCredentialPersisting {
    private(set) var saved: AdminStoredCredential?
    private var saveCount = 0
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?

    func save(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {
        saveCount += 1
        saved = credential
        if saveCount == 1 {
            await withCheckedContinuation { firstSaveContinuation = $0 }
        }
    }

    func load(for target: AdminTarget) async throws -> AdminStoredCredential? { saved }

    func delete(for target: AdminTarget) async throws { saved = nil }

    func delete(_ credential: AdminStoredCredential, for target: AdminTarget) async throws {
        if saved == credential { saved = nil }
    }

    func waitUntilFirstSaveSuspends() async throws {
        let deadline = Date().addingTimeInterval(5)
        while firstSaveContinuation == nil {
            guard Date() < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }

    func finishFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
    }
}
