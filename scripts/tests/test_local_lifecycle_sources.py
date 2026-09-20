"""Executable source guards; these do not compile or execute Swift/iOS behavior."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class LocalLifecycleSourceTests(unittest.TestCase):
    def test_intake_validation_never_runs_startup_scavenging(self):
        importer = self.source("HermesMobile/LocalCapture/LocalIntakeImporter.swift")
        self.assertNotIn("LocalCaptureStore(root: root)", importer)
        self.assertEqual(importer.count("LocalCaptureStore(root: root, recoverAbandonedFiles: false)"), 2)

    def test_fullscreen_picker_and_permission_prompt_do_not_cancel_themselves(self):
        root = self.source("HermesMobile/LocalCapture/LocalCaptureRoot.swift")
        self.assertIn("else if phase == .background", root)
        self.assertIn("if picker == nil { deactivate() }", root)
        self.assertNotIn("if phase == .active { syncActivity() } else { deactivate() }", root)

    def source(self, relative: str) -> str:
        return (ROOT / relative).read_text()

    def test_store_refreshes_same_instance_transactionally_without_cleanup(self):
        store = self.source("HermesMobile/LocalCapture/LocalCaptureStore.swift")
        root = self.source("HermesMobile/LocalCapture/LocalCaptureRoot.swift")
        refresh = re.search(r"func refresh\(\) throws \{(?P<body>.*?)\n    \}", store, re.S)
        if refresh is None:
            self.fail("Missing LocalCaptureStore.refresh()")
        body = refresh.group("body")
        self.assertIn("loadSnapshot", body)
        self.assertNotIn("cleanupAbandoned", body)
        self.assertIn("captures = snapshot.captures", body)
        self.assertIn("locations = snapshot.locations", body)
        self.assertIn("try current.refresh()", root)
        self.assertNotIn("store = reopened", root)
        loader = re.search(r"private func loadSnapshot\(\) throws -> Snapshot \{(?P<body>.*?)\n    \}", store, re.S)
        if loader is None:
            self.fail("Missing transactional snapshot loader")
        self.assertNotIn("removeItem", loader.group("body"))

    def test_repeated_shortcut_requests_use_counter_and_consumption(self):
        intents = self.source("HermesMobile/LocalCapture/LocalCaptureIntents.swift")
        root = self.source("HermesMobile/LocalCapture/LocalCaptureRoot.swift")
        self.assertRegex(intents, r"private\(set\) var requestID = 0")
        self.assertIn("func requestInbox()", intents)
        self.assertGreaterEqual(intents.count("requestInbox()"), 3)
        self.assertNotIn("LocalInboxRoute.shared.isPresented = true", intents)
        self.assertIn("consumeRequest", root)
        self.assertIn(".onChange(of: inboxRoute.requestID)", root)

    def test_root_defers_intake_and_has_guarded_done(self):
        root = self.source("HermesMobile/LocalCapture/LocalCaptureRoot.swift")
        for token in ["activity.blocksInbox", "pendingIntake", "@Environment(\\.dismiss)",
                      'Button("Done")', ".disabled(activity.blocksDismiss)",
                      "Design.Brand.accent", ".interactiveDismissDisabled(activity.blocksDismiss)"]:
            self.assertIn(token, root)
        self.assertLess(root.index("guard !activity.blocksInbox"), root.index("LocalIntakeImporter.drain"))

    def test_media_and_permission_work_is_invalidated_on_exit(self):
        root = self.source("HermesMobile/LocalCapture/LocalCaptureRoot.swift")
        audio = self.source("HermesMobile/LocalCapture/LocalCaptureAudio.swift")
        for token in ["lifecycleID", "recognitionTask?.cancel()", "audio.stop()", ".onDisappear"]:
            self.assertIn(token, root)
        self.assertRegex(root, r"guard lifecycleID == token")
        self.assertIn("Task.detached(priority: .userInitiated)", root)
        self.assertIn("readTask.cancel()", root)
        self.assertIn("guard generation == token", audio)
        self.assertIn("isStarting = false", audio)
        self.assertLess(audio.index("let allowed = await AVAudioApplication.requestRecordPermission()"),
                        audio.index("guard generation == token"))

    def test_storage_reports_busy_and_preserves_streaming_backup(self):
        storage = self.source("HermesMobile/LocalCapture/LocalCaptureStorageView.swift")
        backup = self.source("HermesMobile/LocalCapture/LocalCaptureBackup.swift")
        for token in ["activity.isStoragePresented", "activity.isStorageWorking", "storageWorking"]:
            self.assertIn(token, storage)
        self.assertIn("LocalCaptureArchive.export(sources: sources", storage)
        self.assertIn("LocalCaptureArchive.prepare(url: readable", storage)
        self.assertIn("static let chunkBytes = 64 * 1024", backup)
        self.assertIn("private static func transfer", backup)
        self.assertNotIn("Data(contentsOf: archive.url)", storage)

    def test_capture_controls_share_one_conflict_gate(self):
        root = self.source("HermesMobile/LocalCapture/LocalCaptureRoot.swift")
        self.assertIn("private var controlsDisabled", root)
        self.assertGreaterEqual(root.count(".disabled(controlsDisabled"), 4)
        self.assertIn("hasPendingImages", root)


if __name__ == "__main__":
    unittest.main()