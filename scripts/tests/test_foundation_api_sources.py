"""Linux source regression for a diagnosed native compiler failure, not native evidence."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FoundationAPISourceTests(unittest.TestCase):
    def test_file_protection_uses_foundation_set_attributes_label(self):
        paths = (
            'SharedIntake/LocalIntakeQueue.swift',
            'HermesMobile/LocalCapture/LocalCaptureStore.swift',
            'HermesMobile/LocalCapture/LocalCaptureBackup.swift',
        )
        for path in paths:
            with self.subTest(path=path):
                self.assertRegex(
                    (ROOT / path).read_text(),
                    r'setAttributes\(\[\.protectionKey:\s*FileProtectionType\.complete\],\s*ofItemAtPath:\s*url\.path\)',
                )

    def test_no_swift_set_attributes_calls_use_at_path_label(self):
        for directory in ROOT.iterdir():
            if directory.name.startswith('Hermes') or directory.name == 'SharedIntake':
                for path in directory.rglob('*.swift'):
                    with self.subTest(path=str(path.relative_to(ROOT))):
                        self.assertIsNone(re.search(r'\.setAttributes\([^;]*?\batPath\s*:', path.read_text()))


if __name__ == '__main__':
    unittest.main()
