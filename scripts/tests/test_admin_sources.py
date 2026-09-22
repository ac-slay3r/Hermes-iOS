"""Source safety guards, not a substitute for native XCTest."""
from pathlib import Path
import plistlib
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


class AdminSourceTests(unittest.TestCase):
    def test_native_auth_contract_has_pkce_callback_and_token_exchange(self):
        text = (ROOT / "HermesMobile/Administration/AdminAuthentication.swift").read_text()
        for token in [
            "struct AdminPKCE", "SHA256.hash", "struct AdminAuthorizationAttempt",
            'cool.n0thing.hermes:/oauth/callback', 'code_challenge_method',
            "func authorizationCode(from", "struct HermesAdminAuthClient",
            'path: "auth/native/token"', '"code_verifier"',
            "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", "func cancel()",
            "func signOut() async throws"
        ]:
            self.assertIn(token, text)

    def test_sign_in_invalidates_stale_targets_and_binds_identity_readback(self):
        auth = (ROOT / "HermesMobile/Administration/AdminAuthentication.swift").read_text()
        root = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        for token in [
            "authenticatedProvider = tokens.provider",
            "authenticatedUserID = tokens.userID",
            "func validate(identity: AdminIdentity) async throws",
        ]:
            self.assertIn(token, auth)
        self.assertIn(
            "let status = try await publicClient.readStatus(target: reviewedTarget)\n"
            "            guard target == reviewedTarget else { return }",
            root,
        )
        self.assertIn("try await session.validate(identity: verified.identity)", root)

    def test_authentication_edges_fail_closed(self):
        auth = (ROOT / "HermesMobile/Administration/AdminAuthentication.swift").read_text()
        client = (ROOT / "HermesMobile/Administration/HermesAdminClient.swift").read_text()
        root = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        for token in [
            'let errorItems = items.filter { $0.name == "error" }',
            "guard errorItems.count <= 1",
            "clearAuthenticationState()",
            "try await credentialStore.delete(for: target)",
        ]:
            self.assertIn(token, auth)
        self.assertIn(
            "guard !status.availableProfiles.isEmpty, status.availableProfiles.contains(target.profile)",
            client,
        )
        self.assertGreaterEqual(root.count("guard target == reviewedTarget else { return }"), 3)
        self.assertLess(
            auth.index('guard exactlyOne("state") == state'),
            auth.index("if let errorItem = errorItems.first"),
        )
        self.assertIn("func delete(_ credential: AdminStoredCredential, for target: AdminTarget)", auth)
        self.assertIn(
            "let target = authenticatedTarget\n        generation += 1\n        browser.cancel()\n"
            "        clearAuthenticationState()",
            auth,
        )
        self.assertIn(
            "let session = authSession\n        authSession = nil\n        overview = nil",
            root,
        )

    def test_production_transport_is_ephemeral_target_bound_and_rejects_redirects(self):
        text = (ROOT / "HermesMobile/Administration/AdminTransport.swift").read_text()
        for token in [
            "struct AdminTransportScope", "URLSessionConfiguration.ephemeral",
            "httpCookieStorage = nil", "urlCache = nil", "completionHandler(nil)",
            "AdminTransportScope.validate", '"Authorization"'
        ]:
            self.assertIn(token, text)

    def test_native_auth_callback_scheme_matches_checked_in_project_and_generator(self):
        plist = plistlib.loads((ROOT / "HermesMobile/Resources/Info.plist").read_bytes())
        schemes = [
            scheme
            for entry in plist.get("CFBundleURLTypes", [])
            for scheme in entry.get("CFBundleURLSchemes", [])
        ]
        self.assertEqual(schemes, ["cool.n0thing.hermes"])
        generated = yaml.safe_load((ROOT / "project.yml").read_text())
        generated_types = generated["targets"]["HermesMobile"]["info"]["properties"]["CFBundleURLTypes"]
        self.assertEqual(generated_types[0]["CFBundleURLSchemes"], schemes)

    def test_overview_reads_status_then_authenticated_identity_and_profile_context(self):
        text = (ROOT / "HermesMobile/Administration/HermesAdminClient.swift").read_text()
        for token in [
            "struct AdminOverview", "struct AdminHostStatus", "struct AdminIdentity",
            "struct AdminProfileContext", "func readOverview(target:",
            'path: "api/status"', 'path: "api/auth/me"',
            'path: "api/profiles/active"', 'URLQueryItem(name: "profile"'
        ]:
            self.assertIn(token, text)

    def test_status_capability_fields_are_backward_compatible(self):
        text = (ROOT / "HermesMobile/Administration/HermesAdminClient.swift").read_text()
        for token in [
            'decodeIfPresent(String.self, forKey: .overall) ?? "unknown"',
            'decodeIfPresent(Int.self, forKey: .activeAgents) ?? 0',
            'decodeIfPresent(Bool.self, forKey: .authRequired) ?? false',
            'decodeIfPresent([String].self, forKey: .authFlows) ?? []',
            'decodeIfPresent([String].self, forKey: .availableProfiles) ?? []'
        ]:
            self.assertIn(token, text)

    def test_dashboard_management_leads_combined_navigation(self):
        text = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        for token in [
            'Section("Manage Hermes")', 'Overview & health', 'Configuration & models',
            'Profiles & sessions', 'Skills, tools & MCP', 'Memory & instructions',
            'Automation & connections', 'System & operations'
        ]:
            self.assertIn(token, text)
        for token in ['Section("Supporting tools")', 'admin.localWorkspace',
                      'LocalCaptureRoot()', 'ChatComposerLab()',
                      'inboxRoute.requestID']:
            self.assertNotIn(token, text)
        self.assertIn('Not connected', text)
        self.assertNotIn('AppContainer(', text)

    def test_combined_shell_keeps_dashboard_default_and_companion_explicit(self):
        entry = (ROOT / "HermesMobile/AppEntry.swift").read_text()
        root = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        self.assertIn("CombinedAppRoot()", entry)
        self.assertIn("AppContainer.sharedDefault()", entry)
        for token in ['case dashboard', 'case chat', 'case device', 'TabView(selection:', 'AdminRoot()', 'AppRootView()', 'DeviceAccessRoot()']:
            self.assertIn(token, root)
        self.assertIn('private var selectedSection: CombinedAppSection = .dashboard', root)
        self.assertIn('await container.activateCompanionRuntime()', root)
        self.assertNotIn('.task { await container.initialize() }', entry)

    def test_device_services_require_explicit_persisted_opt_in(self):
        settings = (ROOT / "HermesMobile/Models/UserSettings.swift").read_text()
        container = (ROOT / "HermesMobile/Stores/AppContainer.swift").read_text()
        screen = (ROOT / "HermesMobile/Features/Settings/SettingsScreen.swift").read_text()
        self.assertIn('var deviceServicesEnabled: Bool', settings)
        self.assertIn('deviceServicesEnabled: Bool = false', settings)
        self.assertIn('var notificationConsentEstablished: Bool', settings)
        self.assertIn('notificationConsentEstablished = try container.decodeIfPresent', settings)
        self.assertIn('func setDeviceServicesEnabled(_ enabled: Bool) async', container)
        self.assertIn('guard settingsStore.settings.deviceServicesEnabled else', container)
        self.assertIn('title: "Device Data Sync"', screen)
        self.assertNotIn('AppContainer.sharedDefault()', screen)
        self.assertIn('await container.setNotificationsEnabled(granted)', screen)
        self.assertIn('await container.setNotificationsEnabled(false)', screen)

    def test_reauthorized_companion_ui_suite_and_destructive_confirmations(self):
        ui = (ROOT / "HermesMobileUITests/AppTemplateUITests.swift").read_text()
        host = (ROOT / "HermesMobile/Features/Settings/ConnectHermesHostScreen.swift").read_text()
        self.assertNotIn("XCTSkip", ui)
        self.assertIn('app.tabBars.buttons["Chat"]', ui)
        self.assertIn('app.tabBars.buttons["Device"]', ui)
        self.assertIn('app.switches["Device Data Sync"]', ui)
        self.assertIn('.confirmationDialog(', host)
        self.assertIn('Button("Revoke Host", role: .destructive)', host)
        self.assertIn('Button("Disconnect Device", role: .destructive)', host)

    def test_no_raw_settings_or_credentials_transport(self):
        folder = ROOT / "HermesMobile/Administration"
        self.assertTrue(folder.is_dir(), "Administration slice not implemented")
        text = "\n".join(p.read_text() for p in folder.glob("*.swift"))
        for forbidden in ["/api/config", "/api/env", "UserDefaults", "URLSession.shared", "print(", "RelayAPIClient"]:
            self.assertNotIn(forbidden, text)
        self.assertIn("UnavailableAdminTransport", text)

    def test_last_reviewed_target_persists_address_and_profile_only(self):
        root = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        protocol_text = (ROOT / "HermesMobile/Services/Protocols/AdminTargetPersistenceProtocol.swift").read_text()
        persistence = (ROOT / "HermesMobile/Services/Support/UserDefaultsAdminTargetPersistence.swift").read_text()
        for token in [
            "targetPersistence.saveLastAdminTarget(address: address, profile: profile)",
            "private func restoreLastTarget()",
            "guard address.isEmpty, let saved = targetPersistence.loadLastAdminTarget()",
        ]:
            self.assertIn(token, root)
        self.assertIn("func loadLastAdminTarget() -> (address: String, profile: String)?", protocol_text)
        self.assertIn("func saveLastAdminTarget(address: String, profile: String)", protocol_text)
        # Only the plain host/profile strings persist here; credentials remain Keychain-only
        # via AdminAuthentication.swift's KeychainAdminCredentialStore, untouched by this file.
        for forbidden in ["access_token", "accessToken", "refresh_token", "refreshToken", "Keychain"]:
            self.assertNotIn(forbidden, persistence)

    def test_profiles_sessions_screens_distinguish_authority_loss_from_other_errors(self):
        views = (ROOT / "HermesMobile/Administration/ProfilesSessionsViews.swift").read_text()
        root = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        self.assertIn("func adminSignalsAuthorityLost(_ error: Error) -> Bool", views)
        self.assertIn("case .wrongTarget, .http(401), .http(403):", views)
        # All three read paths (profiles list, sessions list+search, session detail) must call the
        # classifier and route it through onAuthorityLost rather than a single generic error string.
        self.assertEqual(views.count("if adminSignalsAuthorityLost(error) {"), 4)
        self.assertEqual(views.count("onAuthorityLost()"), 4)
        self.assertIn("var onAuthorityLost: @MainActor () -> Void = {}", views)
        self.assertIn("private func handleAuthorityLost(for reviewedTarget: AdminTarget, session: AdminAuthSession)", root)

    def test_automation_connections_screens_reuse_authority_loss_classifier(self):
        views = (ROOT / "HermesMobile/Administration/AutomationConnectionsViews.swift").read_text()
        root = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        # Batch 3 must reuse the shared classifier rather than re-implement its own ad hoc
        # error matching, and every one of its five screens must route through it.
        self.assertIn("if adminSignalsAuthorityLost(error) {", views)
        self.assertEqual(views.count("classify(error, onAuthorityLost: onAuthorityLost)"), 5)
        self.assertIn("onAuthorityLost: @MainActor () -> Void", views)
        self.assertIn('Label("Automation & connections"', root)
        self.assertIn("handleAuthorityLost(for: overview.target, session: authSession) }", root)

    def test_batch3_screens_are_strictly_read_only(self):
        views = (ROOT / "HermesMobile/Administration/AutomationConnectionsViews.swift").read_text()
        # No trigger/pause/resume/approve/revoke/config/test verbs wired anywhere in this
        # file yet — those carry real side effects (execute work, deliver messages, authorize
        # users) and belong to a later, explicit-consequence milestone.
        for forbidden in ["func trigger", "func pause", "func resume", "func approve",
                           "func revoke", "func enable", "func disable", "func testConnection",
                           "\"POST\"", "\"PUT\"", "\"DELETE\"", "\"PATCH\""]:
            self.assertNotIn(forbidden, views)

    def test_skills_tools_mcp_screens_are_read_only_and_reuse_authority_loss_classifier(self):
        views = (ROOT / "HermesMobile/Administration/SkillsToolsMCPViews.swift").read_text()
        root = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        client = (ROOT / "HermesMobile/Administration/HermesAdminClient.swift").read_text()
        # Read-only: no mutation routes wired for skills/tools/MCP in this batch.
        for forbidden in [
            "PUT \"api/skills", "POST \"api/skills", "PUT \"api/tools/toolsets",
            "POST \"api/mcp/servers", "DELETE \"api/mcp/servers", "PUT \"api/mcp/servers",
        ]:
            self.assertNotIn(forbidden, client)
        for token in [
            'path: "api/skills"', 'path: "api/tools/toolsets"', 'path: "api/mcp/servers"',
            "func readSkills(target: AdminTarget) async throws -> [AdminSkillSummary]",
            "func readToolsets(target: AdminTarget) async throws -> [AdminToolsetSummary]",
            "func readMCPServers(target: AdminTarget) async throws -> [AdminMCPServerSummary]",
        ]:
            self.assertIn(token, client)
        # Each of the three list screens reuses the same authority-loss classifier as Batch 1,
        # rather than reintroducing a separate generic catch-all.
        self.assertEqual(views.count("if adminSignalsAuthorityLost(error) {"), 3)
        self.assertEqual(views.count("onAuthorityLost()"), 3)
        self.assertIn("struct SkillsListView: View", views)
        self.assertIn("struct ToolsetsListView: View", views)
        self.assertIn("struct MCPServersListView: View", views)
        self.assertIn("struct SkillsToolsMCPHubView: View", views)
        self.assertIn("SkillsToolsMCPHubView(", root)
        self.assertIn("onAuthorityLost: { handleAuthorityLost(for: overview.target, session: authSession) }", root)
        self.assertEqual(root.count("onAuthorityLost: { handleAuthorityLost(for: overview.target, session: authSession) }"), 3)

    def test_memory_and_session_title_editors_reuse_existing_editor_and_authority_loss_classifier(self):
        editor = (ROOT / "HermesMobile/Administration/AdminEditor.swift").read_text()
        root = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        views = (ROOT / "HermesMobile/Administration/ProfilesSessionsViews.swift").read_text()
        # M3 batch (b) reuses the M1-built AdminEditor/AdminCorrectionView review->apply->
        # readback pipeline rather than building a parallel one; it must route load/apply
        # failures through the same shared classifier used everywhere else.
        self.assertIn("var onAuthorityLost: @MainActor () -> Void = {}", editor)
        self.assertEqual(editor.count("if adminSignalsAuthorityLost(error) { onAuthorityLost() }"), 2)
        self.assertIn("AdminCorrectionView(", root)
        self.assertIn("resource: .soul", root)
        self.assertIn('Label("Memory & instructions", systemImage: "brain.head.profile")', root)
        self.assertIn("editor.onAuthorityLost = { handleAuthorityLost(for: overview.target, session: authSession) }", root)
        self.assertIn("resource: .sessionTitle(sessionID)", views)
        self.assertIn('Label("Edit title", systemImage: "pencil")', views)
        self.assertIn("editor.onAuthorityLost = onAuthorityLost", views)


if __name__ == "__main__":
    unittest.main()
