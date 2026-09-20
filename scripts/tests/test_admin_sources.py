"""Source safety guards, not a substitute for native XCTest."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AdminSourceTests(unittest.TestCase):
    def test_secondary_local_tools_are_reachable_without_unlocking_admin(self):
        text = (ROOT / "HermesMobile/Administration/AdminRoot.swift").read_text()
        for token in ['Section("Supporting tools")', 'admin.localWorkspace',
                      'LocalCaptureRoot()', 'ChatComposerLab()', '.fullScreenCover',
                      'inboxRoute.requestID', 'onAppear']:
            self.assertIn(token, text)
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
