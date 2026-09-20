"""Static guardrails, not execution or compilation of Swift. Native tests deferred."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "HermesMobile/LocalCapture/LocalCaptureStore.swift"


class LocalWorkspaceSourceTests(unittest.TestCase):
    def test_backup_counts_checklist_text_and_validates_constructed_metadata(self):
        backup = (ROOT / "HermesMobile/LocalCapture/LocalCaptureBackup.swift").read_text()
        store = STORE.read_text()
        self.assertIn("try capture.validateWorkspace()", backup)
        self.assertIn("capture.tasks.reduce(0) { $0 + $1.title.utf8.count }", backup)
        self.assertIn("func backupSources()", store)
        self.assertIn("textBytes(source.capture)", backup)

    def test_editor_opens_fresh_review_from_editable_snapshot(self):
        source = (ROOT / "HermesMobile/LocalCapture/LocalCaptureRoot.swift").read_text()
        editor = source.split("private struct LocalCaptureEditor: View")[1]
        for token in ["LocalCaptureIntelligenceCapabilityView()", "review = ReviewSnapshot(text: capture.text)",
                      ".sheet(item: $review)", "LocalCaptureIntelligenceReviewSheet(text: snapshot.text)",
                      "let id = UUID()", ".id(snapshot.id)"]:
            self.assertIn(token, editor)
        self.assertNotIn("model.start", editor)

    def test_intelligence_files_registered_in_correct_targets(self):
        import re
        project = (ROOT / "HermesMobile.xcodeproj/project.pbxproj").read_text()
        for name, phase in [
            *[("LocalCaptureIntelligence" + suffix + ".swift", "C30EAA427FABE72439E74689")
              for suffix in ["", "Views", "ReviewModel", "SystemProvider"]],
            ("LocalCaptureIntelligenceTests.swift", "C1B6E45123C8F8FCD73F69C1"),
        ]:
            with self.subTest(name=name):
                build = re.search(r"([A-F0-9]{24}) /\* " + re.escape(name) +
                                  r" in Sources \*/ = \{isa = PBXBuildFile; fileRef = ([A-F0-9]{24})", project)
                self.assertIsNotNone(build)
                build_id, file_id = build.groups()
                sources = re.search(phase + r" /\* Sources \*/ = \{(.*?)\n\t\t\};", project, re.S).group(1)
                self.assertEqual(sources.count(build_id), 1)
                self.assertRegex(project, file_id + r" /\* " + re.escape(name) + r" \*/ = \{isa = PBXFileReference;")
                groups = project.split("/* Begin PBXGroup section */")[1].split("/* End PBXGroup section */")[0]
                self.assertEqual(groups.count(file_id), 1)

    def test_transcription_cancel_remains_visible_outside_filtered_rows(self):
        source = (ROOT / "HermesMobile/LocalCapture/LocalCaptureRoot.swift").read_text()
        after_rows = source.split('if recognizing { ProgressView("Recognizing text on device") }')[1]
        self.assertIn('if audio.transcribingID != nil', after_rows)
        bottom_inset = after_rows.split('.safeAreaInset(edge: .bottom) {', 1)[1].split('.sheet(item: $editor)', 1)[0]
        self.assertIn('Button("Cancel transcription")', bottom_inset)
        self.assertIn('audio.cancelTranscription()', bottom_inset)
        self.assertIn('syncActivity()', bottom_inset)
        for state in ["editor", "checklist", "picker"]:
            self.assertIn(f".onChange(of: {state}?.id)", source)

    def test_old_captures_default_new_metadata(self):
        source = STORE.read_text()
        self.assertIn("decodeIfPresent(Bool.self, forKey: .isPinned) ?? false", source)
        self.assertIn("decodeIfPresent(Bool.self, forKey: .isArchived) ?? false", source)
        self.assertIn("decodeIfPresent([LocalCaptureTask].self, forKey: .tasks) ?? []", source)


    def test_workspace_ui_exposes_search_filters_and_user_actions(self):
        source = (ROOT / "HermesMobile/LocalCapture/LocalCaptureRoot.swift").read_text()
        for token in [".searchable(", '"capture.scope"', '"capture.kind"',
                      '"Pin capture"', '"Unpin capture"', '"Archive capture"',
                      '"Unarchive capture"', "LocalCaptureChecklist", '"Add checklist item"']:
            with self.subTest(token=token):
                self.assertIn(token, source)

    def test_import_copies_workspace_metadata(self):
        source = (ROOT / "HermesMobile/LocalCapture/LocalCaptureBackup.swift").read_text()
        for token in ["isPinned: old.isPinned", "isArchived: old.isArchived", "tasks: old.tasks"]:
            self.assertIn(token, source)


if __name__ == "__main__":
    unittest.main()
