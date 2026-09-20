"""Structural type-checker regression guards, NOT Swift compilation/runtime tests.

Native CI diagnosed LocalCaptureLibrary.body's inferred deletion Binding inside
an oversized view expression. Keep that constraint-solving scope bounded and
presentation bindings explicitly typed. Only an Xcode build proves the fix.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
CAPTURE = ROOT / "HermesMobile/LocalCapture/LocalCaptureRoot.swift"
STORAGE = ROOT / "HermesMobile/LocalCapture/LocalCaptureStorageView.swift"


def member(source, declaration):
    """Members here use four-space declarations and matching closing braces."""
    start = source.index(declaration)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


class SwiftUIExpressionSourceTests(unittest.TestCase):
    def test_capture_view_expressions_have_small_typechecking_scopes(self):
        source = CAPTURE.read_text()
        declarations = list(re.finditer(
            r"^    (?:@ViewBuilder )?(?:private )?(?:var|func) [^\n]*some View[^\n]*\{", source, re.M
        ))
        self.assertTrue(declarations)
        for match in declarations:
            declaration = match.group()
            with self.subTest(declaration=declaration.strip(), line=source[:match.start()].count("\n") + 1):
                self.assertLessEqual(len(member(source[match.start():], declaration).splitlines()), 80,
                                     "Split the view expression; do not raise compiler limits")

    def test_library_presentation_bindings_are_typed_and_dismiss_only(self):
        source = CAPTURE.read_text()
        self.assertIn("private var deletionPresented: Binding<Bool>", source)
        deletion = member(source, "private var deletionPresented: Binding<Bool>")
        self.assertIn("Binding<Bool>(", deletion)
        self.assertIn("get: { deleting != nil }", deletion)
        self.assertIn("if !isPresented { deleting = nil }", deletion)
        self.assertNotIn("store.delete", deletion)
        notice = member(source, "private var noticePresented: Binding<Bool>")
        self.assertIn("get: { errorMessage != nil || audio.notice != nil }", notice)
        self.assertIn("if !isPresented { errorMessage = nil; audio.notice = nil }", notice)
        self.assertIn("isPresented: deletionPresented", source)
        self.assertIn("isPresented: noticePresented", source)
        self.assertIn('Button("Delete permanently", role: .destructive)', source)
        self.assertIn("guard let capture = deleting else { return }", source)
        self.assertIn("try store.delete(capture)", source)

    def test_checklist_and_storage_analogous_bindings_are_typed(self):
        source = CAPTURE.read_text().split("private struct LocalCaptureChecklist: View", 1)[1]
        self.assertIn("private var removalPresented: Binding<Bool>", source)
        self.assertIn("private func completionBinding(for task: LocalCaptureTask) -> Binding<Bool>", source)
        self.assertIn("self.capture?.tasks.first(where: { $0.id == task.id })?.isCompleted ?? false", source)
        self.assertIn("try store.setTaskCompleted(completed, taskID: task.id, captureID: captureID)", source)
        self.assertIn("isPresented: removalPresented", source)
        storage = STORAGE.read_text()
        self.assertIn("private var noticePresented: Binding<Bool>", storage)
        self.assertIn("isPresented: noticePresented", storage)

    def test_library_retains_state_and_picker_generation_at_presentation(self):
        source = CAPTURE.read_text().split("private struct LocalCaptureLibrary: View", 1)[1].split(
            "private struct LocalCaptureChecklist: View", 1)[0]
        for state in ["editor", "deleting", "picker", "pendingImages", "recognitionTask", "lifecycleID"]:
            self.assertRegex(source, rf"@State private var {state}\b")
        self.assertRegex(source, r"\.sheet\(item: \$picker\) \{ choice in\s+let token = lifecycleID")
        self.assertIn("guard lifecycleID == token else { return }", source)
        self.assertIn("if picker == nil { deactivate() }", source)
        self.assertIn("else if phase == .background { deactivate() }", source)
        self.assertIn("activity.isDraftPresented = editor != nil || checklist != nil || deleting != nil", source)
        self.assertNotIn("AnyView", source)
        self.assertEqual(source.count("NavigationStack {"), 1)


if __name__ == "__main__":
    unittest.main()
