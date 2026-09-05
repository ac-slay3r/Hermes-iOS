"""Offline TEST FIXTURES, not evidence of actual GitHub CI success."""
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "release_gate.py"
SHA = "a" * 40
NAMES = ("Native iOS simulator build", "Native iOS unit tests", "Relay tests", "Connector tests")


def load_gate():
    assert SCRIPT.exists(), "release gate implementation is missing"
    spec = importlib.util.spec_from_file_location("release_gate", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_fixture(**changes):
    return dict(id=123, run_number=7, run_attempt=1, head_sha=SHA,
                head_branch="main", status="completed", conclusion="success", event="push", **changes)


class ReleaseGateTests(unittest.TestCase):
    def test_rejects_successful_pull_request_or_untrusted_event(self):
        gate = load_gate()
        for event in ("pull_request", "pull_request_target", "schedule", None):
            run = run_fixture() | {"event": event}
            def fetch(path):
                if "/workflows/" in path:
                    return {"total_count": 1, "workflow_runs": [run]}
                if "/jobs?" in path:
                    return {"total_count": 4, "jobs": [
                        dict(name=name, status="completed", conclusion="success") for name in NAMES]}
                return run
            with self.subTest(event=event), self.assertRaises(gate.GateError):
                gate.verify("owner/repo", SHA, "main", fetch)

    def test_rejects_incomplete_failed_or_wrong_revision(self):
        gate = load_gate()
        for changes in ({"status": "queued"}, {"conclusion": "failure"},
                        {"head_sha": "b" * 40}, {"head_branch": "other"}):
            with self.subTest(changes=changes):
                run = run_fixture() | changes
                def fetch(path):
                    if "/workflows/" in path:
                        return {"total_count": 1, "workflow_runs": [run]}
                    return {"total_count": 0, "jobs": []}
                with self.assertRaises(gate.GateError):
                    gate.verify("owner/repo", SHA, "main", fetch)

    def test_rejects_missing_duplicate_skipped_failed_or_unfinished_jobs(self):
        gate = load_gate()
        good = [dict(name=name, status="completed", conclusion="success") for name in NAMES]
        variants = [good[:-1], good + [good[0]]]
        for conclusion in ("skipped", "failure", "cancelled", "neutral", None):
            variants.append([good[0] | {"conclusion": conclusion}] + good[1:])
        variants.append([good[0] | {"status": "in_progress"}] + good[1:])
        for jobs in variants:
            with self.subTest(jobs=jobs):
                def fetch(path):
                    if "/workflows/" in path:
                        return {"total_count": 1, "workflow_runs": [run_fixture()]}
                    return {"total_count": len(jobs), "jobs": jobs}
                with self.assertRaises(gate.GateError):
                    gate.verify("owner/repo", SHA, "main", fetch)

    def test_empty_malformed_or_truncated_run_lists_fail_closed(self):
        gate = load_gate()
        for payload in ({}, {"total_count": 0, "workflow_runs": []},
                        {"total_count": 2, "workflow_runs": [run_fixture()]}):
            with self.subTest(payload=payload), self.assertRaises(gate.GateError):
                gate.verify("owner/repo", SHA, "main", lambda path: payload)

    def test_latest_failure_is_not_hidden_by_older_success(self):
        gate = load_gate()
        runs = [run_fixture(), run_fixture() | {"id": 124, "run_number": 8, "conclusion": "failure"}]
        with self.assertRaises(gate.GateError):
            gate.verify("owner/repo", SHA, "main", lambda path: {"total_count": 2, "workflow_runs": runs})

    def test_rejects_truncated_jobs_and_rerun_race(self):
        gate = load_gate()
        jobs = [dict(name=name, status="completed", conclusion="success") for name in NAMES]
        for truncated in (True, False):
            def fetch(path):
                if "/workflows/" in path:
                    return {"total_count": 1, "workflow_runs": [run_fixture()]}
                if "/jobs?" in path:
                    self.assertIn("/attempts/1/jobs", path)
                    return {"total_count": 5 if truncated else 4, "jobs": jobs}
                return run_fixture() | {"run_attempt": 2, "status": "queued"}
            with self.subTest(truncated=truncated), self.assertRaises(gate.GateError):
                gate.verify("owner/repo", SHA, "main", fetch)

    def test_rejects_event_change_on_selected_run_reread(self):
        gate = load_gate()
        for event in ("pull_request", "workflow_dispatch", None):
            def fetch(path):
                if "/workflows/" in path:
                    return {"total_count": 1, "workflow_runs": [run_fixture()]}
                if "/jobs?" in path:
                    return {"total_count": 4, "jobs": [
                        dict(name=name, status="completed", conclusion="success") for name in NAMES]}
                return run_fixture() | {"event": event}
            with self.subTest(event=event), self.assertRaises(gate.GateError):
                gate.verify("owner/repo", SHA, "main", fetch)

    def test_rejects_changed_newest_run_on_final_list_read(self):
        gate = load_gate()
        variants = [
            [run_fixture(), run_fixture() | {"id": 124, "run_number": 8, "status": status,
                                           "conclusion": conclusion}]
            for status, conclusion in (("queued", None), ("completed", "failure"),
                                       ("completed", "success"))
        ]
        variants.extend([[run_fixture() | change] for change in (
            {"id": 124}, {"run_number": 8}, {"run_attempt": 2}, {"status": "in_progress"},
            {"conclusion": "failure"}, {"event": "pull_request"})])
        variants.append([])
        for final_runs in variants:
            list_reads = 0
            def fetch(path):
                nonlocal list_reads
                if "/workflows/" in path:
                    list_reads += 1
                    runs = [run_fixture()] if list_reads == 1 else final_runs
                    return {"total_count": len(runs), "workflow_runs": runs}
                if "/jobs?" in path:
                    return {"total_count": 4, "jobs": [
                        dict(name=name, status="completed", conclusion="success") for name in NAMES]}
                return run_fixture()
            with self.subTest(final_runs=final_runs), self.assertRaises(gate.GateError):
                gate.verify("owner/repo", SHA, "main", fetch)

    def test_invalid_inputs_are_rejected_before_api_access(self):
        gate = load_gate()
        for repo, sha, branch in (("owner/repo", "short", "main"),
                                  ("../repo", SHA, "main"), ("owner/repo", SHA, "")):
            with self.subTest(repo=repo, sha=sha, branch=branch), self.assertRaises(gate.GateError):
                gate.verify(repo, sha, branch, lambda path: self.fail("API must not be called"))

    def test_cli_api_errors_fail_closed_without_printing_response(self):
        from unittest.mock import patch
        import subprocess
        gate = load_gate()
        with patch.object(gate.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "gh", stderr="private error")):
            with self.assertRaisesRegex(gate.GateError, "GitHub API request failed"):
                gate.gh_api("repos/owner/repo/actions/runs")
        with patch.object(gate.subprocess, "run", return_value=subprocess.CompletedProcess("gh", 0, "not json")):
            with self.assertRaises(gate.GateError):
                gate.gh_api("repos/owner/repo/actions/runs")

    def test_success_requires_complete_run_and_four_successful_jobs(self):
        gate = load_gate()
        jobs = [dict(name=name, status="completed", conclusion="success") for name in NAMES]
        for event in ("push", "workflow_dispatch"):
            run = run_fixture() | {"event": event}
            calls = []
            def fetch(path):
                calls.append(path)
                if "/workflows/" in path:
                    return {"total_count": 1, "workflow_runs": [run]}
                if "/jobs?" in path:
                    return {"total_count": 4, "jobs": jobs}
                return run
            with self.subTest(event=event):
                self.assertEqual(gate.verify("owner/repo", SHA, "main", fetch), 123)
                self.assertEqual(len(calls), 4)
                self.assertEqual(calls[-1], calls[0])


if __name__ == "__main__":
    unittest.main()
