"""Linux source guards only; native UI/data-protection evidence comes from Xcode."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]

class NativeFailureRegressions(unittest.TestCase):
    def test_xctest_autoclosures_do_not_contain_async_calls(self):
        source = (ROOT / "HermesMobileTests/AdminClientTests.swift").read_text()
        self.assertIsNone(re.search(r"XCTAssert\w*\([^\n]*\bawait\b", source))

    def test_frozen_local_capture_ui_suite_is_skipped_at_setup(self):
        source = (ROOT / 'HermesMobileUITests/LocalCaptureUITests.swift').read_text()
        self.assertIn(
            'throw XCTSkip("Local capture product is frozen; AdminLaunchUITests verifies the dashboard-management entry point.")',
            source,
        )

    def test_simulator_checks_effective_backup_boundary_without_claiming_file_protection(self):
        store_tests = (ROOT / 'HermesMobileTests/LocalCaptureTests.swift').read_text()
        backup_tests = (ROOT / 'HermesMobileTests/LocalCaptureBackupTests.swift').read_text()
        for source in (store_tests, backup_tests):
            self.assertNotIn('as? FileProtectionType', source)
            self.assertNotIn('targetEnvironment(simulator)', source)
        self.assertIn('FileProtectionType.complete.rawValue', store_tests)
        self.assertIn('testCaptureRootIsExcludedFromBackup', store_tests)
        self.assertIn('source.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])', backup_tests)
        self.assertNotIn('metadata.resourceValues(forKeys: [.isExcludedFromBackupKey])', backup_tests)
        self.assertNotIn('attributesOfItem(atPath: metadata.path)[.protectionKey]', backup_tests)

    def test_checklist_ui_taps_switch_control_and_asserts_changed_value(self):
        ui = (ROOT / 'HermesMobileUITests/LocalCaptureUITests.swift').read_text()
        view = (ROOT / 'HermesMobile/LocalCapture/LocalCaptureRoot.swift').read_text()
        self.assertIn('@FocusState private var draftFocused: Bool', view)
        self.assertIn('.focused($draftFocused)', view)
        self.assertIn('draftFocused = false', view)
        self.assertIn('app.keyboards.firstMatch.waitForNonExistence(timeout: 5)', ui)
        self.assertIn('coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()', ui)
        self.assertIn('XCTAssertEqual(toggle.value as? String, "1")', ui)

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
        self.assertIn('.accessibilityValue(overview?.identity.displayName ?? "Not authenticated")', source)
        self.assertIn('.accessibilityIdentifier("admin.signIn")', source)
        ui = (ROOT / 'HermesMobileUITests/AdminLaunchUITests.swift').read_text()
        self.assertIn('identity.value as? String, "Not authenticated"', ui)
