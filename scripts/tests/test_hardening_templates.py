"""Static regression guards for release wiring and checked-in deploy templates.

These do not assert anything about the running deployment or native CI.
"""
from pathlib import Path
import re
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WorkflowTests(unittest.TestCase):
    def test_native_ci_conserves_minutes_without_bypassing_gates(self):
        text = (ROOT / ".github/workflows/ios-ci.yml").read_text()
        build = text.split("  native-build:\n", 1)[1].split("  native-tests:\n", 1)[0]
        tests = text.split("  native-tests:\n", 1)[1].split("  relay-tests:\n", 1)[0]
        self.assertIn("    needs: native-build\n", tests)
        self.assertIn("timeout-minutes: 20", build)
        self.assertIn("timeout-minutes: 35", tests)
        self.assertNotIn("continue-on-error", build + tests)
        self.assertNotIn("-skip-testing", build + tests)

    def test_signing_job_depends_on_separate_read_only_gate(self):
        text = (ROOT / ".github/workflows/testflight.yml").read_text()
        gate = text.split("  release-gate:\n", 1)[-1].split("  archive-and-upload:\n", 1)[0]
        self.assertIn("  release-gate:\n", text)
        self.assertIn("actions: read", gate)
        self.assertIn("scripts/release_gate.py", gate)
        self.assertIn("GH_TOKEN: ${{ github.token }}", gate)
        self.assertIn("github.ref_type == 'branch'", gate)
        self.assertNotIn("secrets.", gate)
        signing = text.split("  archive-and-upload:\n", 1)[1]
        self.assertIn("    needs: release-gate\n", signing)
        self.assertNotIn("if: always()", signing.split("    steps:", 1)[0])

    def test_archive_rechecks_read_only_gate_before_credentials(self):
        text = (ROOT / ".github/workflows/testflight.yml").read_text()
        signing = text.split("  archive-and-upload:\n", 1)[1]
        header, steps = signing.split("    steps:\n", 1)
        self.assertIn("    permissions:\n      contents: read\n      actions: read\n", header)
        before_credentials = steps.split("      - name: Check required credentials\n", 1)[0]
        self.assertIn("run: python3 scripts/release_gate.py", before_credentials)
        self.assertIn("GH_TOKEN: ${{ github.token }}", before_credentials)
        self.assertNotIn("secrets.", before_credentials)
        self.assertNotIn("continue-on-error", before_credentials)
        self.assertNotIn("if:", before_credentials)

    def test_ci_preserves_required_names_and_runs_script_tests(self):
        text = (ROOT / ".github/workflows/ios-ci.yml").read_text()
        for name in ("Native iOS simulator build", "Native iOS unit tests", "Relay tests", "Connector tests"):
            self.assertEqual(text.count(f"    name: {name}\n"), 1)
        self.assertIn("-m unittest discover -s scripts/tests", text)
        self.assertIn("working-directory: .", text)


class DeploymentTemplateTests(unittest.TestCase):
    def test_compose_has_no_database_publish_and_relay_is_loopback_only(self):
        text = (ROOT / "relay/docker-compose.yml").read_text()
        postgres = text.split("  postgres:\n", 1)[1].split("  relay:\n", 1)[0]
        self.assertNotRegex(postgres, r"(?m)^\s+ports:")
        self.assertNotRegex(text, r"(?m)^\s+network_mode:")
        ports = re.findall(r"(?m)^    ports:\n((?:      .+\n)+)", text)
        self.assertEqual(ports, ['      - "127.0.0.1:8000:8000"\n'])
        self.assertIn("RELAY_ENVIRONMENT: production", text)
        for name in ("POSTGRES_PASSWORD", "PUBLIC_BASE_URL", "INTERNAL_API_KEY", "CONNECTOR_SETUP_SECRET"):
            self.assertIn("${" + name + ":?", text)

    def test_compose_preserves_existing_database_user_and_requires_password(self):
        text = (ROOT / "relay/docker-compose.yml").read_text()
        self.assertIn("POSTGRES_USER: ${POSTGRES_USER:-postgres}", text)
        self.assertIn("pg_isready -U ${POSTGRES_USER:-postgres} -d hermes_mobile", text)
        self.assertIn(
            "DATABASE_URL: postgresql+psycopg://${POSTGRES_USER:-postgres}:"
            "${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD}@postgres:5432/hermes_mobile",
            text,
        )
        passwords = re.findall(r"\$\{POSTGRES_PASSWORD([^}]*)\}", text)
        self.assertEqual(len(passwords), 2)
        self.assertTrue(all(value.startswith(":?") for value in passwords))
        self.assertIn("- postgres_data:/var/lib/postgresql/data", text)
        self.assertRegex(text, r"(?m)^volumes:\n  postgres_data:\s*$")

    def test_docker_final_user_is_nonroot(self):
        text = (ROOT / "relay/Dockerfile").read_text()
        users = re.findall(r"(?m)^USER\s+(\S+)", text)
        self.assertTrue(users)
        self.assertEqual(users[-1], "relay")
        self.assertIn("--uid 10001", text)

    def test_fly_has_no_public_ingress(self):
        data = tomllib.loads((ROOT / "relay/fly.toml").read_text())
        self.assertNotIn("http_service", data)
        self.assertNotIn("services", data)
        self.assertEqual(data["env"]["RELAY_ENVIRONMENT"], "production")
