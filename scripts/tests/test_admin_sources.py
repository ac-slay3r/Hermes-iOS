"""Source safety guards, not a substitute for native XCTest."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AdminSourceTests(unittest.TestCase):
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

    def test_dashboard_management_leads_navigation_and_local_experiments_are_frozen(self):
        text = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        for token in [
            'Section("Manage Hermes")', 'Overview & health', 'Configuration & models',
            'Profiles & sessions', 'Skills, tools & MCP', 'Memory & instructions',
            'Automation & connections', 'System & operations'
        ]:
            self.assertIn(token, text)
        for token in ['Section("Supporting tools")', 'admin.localWorkspace',
                      'LocalCaptureRoot()', 'ChatComposerLab()', '.fullScreenCover',
                      'inboxRoute.requestID']:
            self.assertNotIn(token, text)
        self.assertIn('Not connected', text)
        self.assertNotIn('AppContainer(', text)

    def test_admin_entry_does_not_start_capture_or_remote_container(self):
        text = (ROOT / "HermesMobile/AppEntry.swift").read_text()
        self.assertIn("AdminRoot()", text)
        self.assertNotIn("LocalCaptureRoot()", text)
        self.assertNotIn("AppContainer.", text)

    def test_no_raw_settings_or_credentials_transport(self):
        folder = ROOT / "HermesMobile/Administration"
        self.assertTrue(folder.is_dir(), "Administration slice not implemented")
        text = "\n".join(p.read_text() for p in folder.glob("*.swift"))
        for forbidden in ["/api/config", "/api/env", "UserDefaults", "URLSession.shared", "print(", "RelayAPIClient"]:
            self.assertNotIn(forbidden, text)
        self.assertIn("UnavailableAdminTransport", text)


if __name__ == "__main__":
    unittest.main()
