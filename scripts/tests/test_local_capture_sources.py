"""Source guardrails only: these do NOT compile or execute Swift/iOS behavior."""
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LocalCaptureSourceTests(unittest.TestCase):
    def source(self, relative):
        return (ROOT / relative).read_text()

    def test_launch_has_no_remote_initialization(self):
        source = self.source("HermesMobile/AppEntry.swift")
        self.assertNotIn("AppContainer.sharedDefault()", source)
        self.assertNotIn(".registerForRemoteNotifications()", source)
        self.assertIn("AdminRoot()", source)
        self.assertIn("completionHandler(.noData)", source)
        self.assertIn(".onOpenURL { _ in }", source)
        self.assertIn("unregisterForRemoteNotifications()", source)

    def test_carplay_is_gated_before_manager_creation(self):
        source = self.source("HermesMobile/CarPlay/CarPlaySceneDelegate.swift")
        self.assertLess(source.index("guard AdminLaunchPolicy.legacyRemoteEnabled"),
                        source.index("let manager = CarPlayVoiceManager"))
        self.assertIn("static let remoteEnabled = false", self.source("HermesMobile/LocalCapture/LocalCaptureStore.swift"))

    def test_local_sources_have_no_network_or_legacy_dependencies(self):
        for path in (ROOT / "HermesMobile/LocalCapture").glob("*.swift"):
            with self.subTest(path=path.name):
                self.assertNotRegex(path.read_text(), r"URLSession|AppContainer|SensorUploadService|RelayAPIClient|import WebRTC")

    def test_speech_is_offline_only_and_recording_is_independent(self):
        source = self.source("HermesMobile/LocalCapture/LocalCaptureAudio.swift")
        self.assertIn("recognizer.supportsOnDeviceRecognition", source)
        self.assertIn("request.requiresOnDeviceRecognition = true", source)
        self.assertNotIn("requiresOnDeviceRecognition = false", source)
        self.assertLess(source.index("recognizer.supportsOnDeviceRecognition"), source.index("recognizer.recognitionTask"))
        self.assertIn("UIApplication.didEnterBackgroundNotification", source)
        self.assertIn("AVAudioSession.interruptionNotification", source)
        self.assertNotIn("removeItem", source)

    def test_plist_disables_remote_background_and_carplay(self):
        with (ROOT / "HermesMobile/Resources/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertEqual(info["UIBackgroundModes"], [])
        self.assertFalse(info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"])
        self.assertNotIn("UISceneConfigurations", info["UIApplicationSceneManifest"])
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"]:
            self.assertTrue(info[key])

    def test_project_registers_each_new_swift_source(self):
        project = self.source("HermesMobile.xcodeproj/project.pbxproj")
        paths = list((ROOT / "HermesMobile/LocalCapture").glob("*.swift")) + [
            ROOT / "HermesMobileTests/LocalCaptureTests.swift",
            ROOT / "HermesMobileTests/LocalCaptureBackupTests.swift",
            ROOT / "HermesMobileUITests/LocalCaptureUITests.swift",
        ]
        definitions = re.findall(r"^\s*([A-F0-9]{24}) /\*.*?\*/ =", project, re.M)
        self.assertEqual(len(definitions), len(set(definitions)), "Duplicate project IDs")
        for path in paths:
            with self.subTest(path=path.name):
                self.assertIn(f"path = {path.relative_to(ROOT)}; sourceTree = SOURCE_ROOT", project)
                self.assertEqual(project.count(f"/* {path.name} in Sources */"), 2)
        specification = self.source("project.yml")
        for folder in ["HermesMobile", "HermesMobileTests", "HermesMobileUITests"]:
            self.assertIn(f"- path: {folder}\n", specification)

    def test_protection_and_transaction_boundaries_present(self):
        source = self.source("HermesMobile/LocalCapture/LocalCaptureStore.swift")
        self.assertIn("isExcludedFromBackup = true", source)
        self.assertIn("[.atomic, .completeFileProtection]", source)
        self.assertIn("FileProtectionType.complete", source)
        self.assertIn('".trash-"', source)
        self.assertIn('".staging-"', source)


if __name__ == "__main__":
    unittest.main()
