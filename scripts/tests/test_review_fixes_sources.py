"""Source guardrails only: these do NOT compile or run Swift."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class IndependentReviewFixSources(unittest.TestCase):
    def test_intake_attempt_cleanup_is_scoped_and_has_native_regression(self):
        importer = (ROOT / "HermesMobile/LocalCapture/LocalIntakeImporter.swift").read_text()
        backup_tests = (ROOT / "HermesMobileTests/LocalCaptureBackupTests.swift").read_text()

        self.assertIn("beforeCommit: () throws -> Void = {}", importer)
        self.assertRegex(
            importer,
            re.compile(
                r"let stage = .*?\.staging-intake-.*?defer\s*\{.*?removeItem\(at: stage\).*?\}"
                r".*?try beforeCommit\(\).*?try fm\.moveItem\(at: stage, to: destination\)",
                re.S,
            ),
        )
        self.assertNotIn("cleanupAbandoned", importer)
        for token in [
            "testIntakePreCommitFailureRemovesOnlyAttemptStageAndRetrySucceeds",
            "beforeCommit:",
            "XCTAssertTrue(FileManager.default.fileExists(atPath: historical.path))",
            "XCTAssertTrue(try LocalCaptureStore(root: root).captures.isEmpty)",
            "XCTAssertEqual(try queue.pending().count, 1)",
            "XCTAssertEqual(try LocalIntakeImporter.drain(queue: queue, root: root), 1)",
        ]:
            self.assertIn(token, backup_tests)

    def test_task_limit_is_generated_and_validated_before_ready(self):
        provider = (ROOT / "HermesMobile/LocalCapture/LocalCaptureIntelligenceSystemProvider.swift").read_text()
        intelligence = (ROOT / "HermesMobile/LocalCapture/LocalCaptureIntelligence.swift").read_text()
        model = (ROOT / "HermesMobile/LocalCapture/LocalCaptureIntelligenceReviewModel.swift").read_text()
        native_tests = (ROOT / "HermesMobileTests/LocalCaptureIntelligenceTests.swift").read_text()

        self.assertRegex(
            provider,
            re.compile(
                r'@Guide\(description: "Zero to five short tasks[^\n]+",\s*\.maximumCount\(5\)\)\s*var tasks: \[String\]'
            ),
        )
        self.assertIn("static let maximumTasks = 5", intelligence)
        self.assertIn("guard tasks.count <= Self.maximumTasks", intelligence)
        validated = model.index("try result.validated()")
        ready = model.index("self.phase = .ready")
        self.assertLess(validated, ready)
        self.assertIn("testOverLimitProviderResultNeverReachesReady", native_tests)
        self.assertIn("LocalCaptureIntelligenceSuggestions.maximumTasks + 1", native_tests)


if __name__ == "__main__":
    unittest.main()
