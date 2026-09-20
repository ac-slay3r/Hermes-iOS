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


if __name__ == "__main__":
    unittest.main()
