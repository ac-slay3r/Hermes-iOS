"""Linux source guards only; native UI/data-protection evidence comes from Xcode."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class NativeFailureRegressions(unittest.TestCase):
    def test_protection_assertions_use_documented_string_value_without_skips(self):
        for name in ('LocalCaptureTests', 'LocalCaptureBackupTests'):
            source = (ROOT / 'HermesMobileTests' / (name + '.swift')).read_text()
            self.assertNotIn('as? FileProtectionType', source)
            self.assertIn('FileProtectionType.complete.rawValue', source)
            self.assertNotIn('targetEnvironment(simulator)', source)

    def test_nested_done_queries_are_navigation_scoped(self):
        source = (ROOT / 'HermesMobileUITests/LocalCaptureUITests.swift').read_text()
        self.assertNotIn('app.buttons["Done"]', source)
        self.assertIn('app.navigationBars["Review on device"].buttons["Done"]', source)
        self.assertIn('app.navigationBars["Local checklist"].buttons["Done"]', source)

    def test_offscreen_capture_controls_are_revealed(self):
        source = (ROOT / 'HermesMobileUITests/LocalCaptureUITests.swift').read_text()
        self.assertIn('reveal(', source)
        self.assertIn('isHittable', source)
        self.assertIn('app.debugDescription', source)

    def test_admin_authentication_asserts_explicit_accessibility_value(self):
        source = (ROOT / 'HermesMobile/Administration/AdminRoot.swift').read_text()
        self.assertIn('.accessibilityIdentifier("admin.identity")', source)
        self.assertIn('.accessibilityValue("Not authenticated")', source)
        ui = (ROOT / 'HermesMobileUITests/AdminLaunchUITests.swift').read_text()
        self.assertIn('identity.value as? String, "Not authenticated"', ui)
