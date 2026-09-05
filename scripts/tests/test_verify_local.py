"""Local-command tests use explicit fake interpreter TEST FIXTURES."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LocalVerificationTests(unittest.TestCase):
    def test_runs_all_suites_with_worktree_sources_and_explicit_interpreters(self):
        script = ROOT / "scripts/verify-local.sh"
        self.assertTrue(script.exists(), "local verification command is missing")
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture-python"
            log = Path(directory) / "calls.jsonl"
            fixture.write_text(f"#!{sys.executable}\n" +
                "import json, os, sys\n"
                "with open(os.environ['FIXTURE_LOG'], 'a') as out:\n"
                "    out.write(json.dumps([sys.argv[1:], os.getcwd(), os.environ.get('PYTHONPATH')]) + '\\n')\n")
            fixture.chmod(0o755)
            env = dict(os.environ, RELAY_PYTHON=str(fixture), CONNECTOR_PYTHON=str(fixture), FIXTURE_LOG=str(log))
            result = subprocess.run([str(script)], cwd=directory, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(len(calls), 3)
            self.assertIn("unittest", calls[0][0])
            self.assertIn("scripts/tests", calls[0][0])
            self.assertEqual(calls[1][1:], [str(ROOT / "relay"), str(ROOT / "relay")])
            self.assertEqual(calls[2][1:], [str(ROOT / "connector"), str(ROOT / "connector/src")])

    def test_missing_explicit_interpreter_fails_without_fallback(self):
        script = ROOT / "scripts/verify-local.sh"
        self.assertTrue(script.exists(), "local verification command is missing")
        env = dict(os.environ, RELAY_PYTHON="/nonexistent/test-fixture-python")
        result = subprocess.run([str(script)], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RELAY_PYTHON", result.stderr)
