from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Callable


_COMMAND_ID_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]+$")
_PROJECT_ID_PATTERN = re.compile(r"^p_[a-f0-9]{8}$")


@dataclass(frozen=True)
class HostProject:
    id: str
    name: str
    workspace_path: str
    brief: str
    pinned_command_ids: list[str]

    def to_payload(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "workspacePath": self.workspace_path,
            "brief": self.brief,
            "pinnedCommandIds": list(self.pinned_command_ids),
        }


class HostProjectStore:
    """Adapter over Hermes's canonical per-profile projects.db.

    Project definitions stay in Hermes Agent so Desktop and iOS share one project
    inventory. Only iOS command pins are stored beside connector state, keyed by
    canonical Hermes project ID.
    """

    def __init__(
        self,
        state_dir: Path,
        *,
        hermes_home: Path | None = None,
        allowed_roots: list[Path] | None = None,
        runner: Callable[[str, dict], dict] | None = None,
    ) -> None:
        self.state_dir = state_dir.expanduser()
        self.hermes_home = (hermes_home or Path(os.getenv("HERMES_HOME", "~/.hermes"))).expanduser()
        self.pins_path = self.state_dir / "project-command-pins.json"
        self._injected_runner = runner
        configured = os.getenv("HERMES_PROJECT_ROOTS", "")
        roots = allowed_roots if allowed_roots is not None else [Path(value) for value in configured.split(os.pathsep) if value]
        self.allowed_roots = [root.expanduser().resolve() for root in roots if root.expanduser().is_absolute()]

    def list(self) -> list[HostProject]:
        result = self._run("list", {})
        pins = self._load_pins()
        projects = [self._from_canonical(item, pins.get(str(item.get("id")), [])) for item in result.get("projects", [])]
        return sorted(projects, key=lambda project: project.name.casefold())

    def create(
        self,
        *,
        name: str,
        workspace_path: str,
        brief: str,
        pinned_command_ids: list[str],
    ) -> HostProject:
        normalized_name = name.strip()
        if not normalized_name or len(normalized_name) > 80:
            raise ValueError("Project name must contain 1 to 80 characters.")

        raw_workspace = Path(workspace_path).expanduser()
        if not raw_workspace.is_absolute():
            raise ValueError("Project workspace path must be absolute.")
        canonical_workspace = raw_workspace.resolve()
        if not canonical_workspace.is_dir():
            raise ValueError("Project workspace path must be an existing directory.")
        self._require_allowed_workspace(canonical_workspace)

        normalized_brief = brief.strip()
        if len(normalized_brief) > 4_000:
            raise ValueError("Project brief must not exceed 4000 characters.")
        normalized_pins = self._normalize_pins(pinned_command_ids)

        result = self._run(
            "create",
            {
                "name": normalized_name,
                "workspacePath": str(canonical_workspace),
                "brief": normalized_brief,
            },
        )
        canonical = result.get("project")
        if not isinstance(canonical, dict):
            raise RuntimeError("Hermes did not return the created project.")
        project_id = str(canonical.get("id") or "")
        if not _PROJECT_ID_PATTERN.fullmatch(project_id):
            raise RuntimeError("Hermes returned an invalid project identifier.")
        pins = self._load_pins()
        pins[project_id] = normalized_pins
        self._save_pins(pins)
        return self._from_canonical(canonical, normalized_pins)

    def get(self, project_id: str) -> HostProject:
        if not _PROJECT_ID_PATTERN.fullmatch(project_id):
            raise ValueError("Unknown project identifier.")
        project = next((item for item in self.list() if item.id == project_id), None)
        if project is None:
            raise ValueError("Unknown project identifier.")
        return project

    def resolve_workspace(self, project_id: str) -> Path:
        project = self.get(project_id)
        workspace = Path(project.workspace_path).resolve()
        if not workspace.is_dir():
            raise ValueError("Project workspace is no longer an existing directory.")
        self._require_allowed_workspace(workspace)
        return workspace

    def _require_allowed_workspace(self, workspace: Path) -> None:
        if not self.allowed_roots:
            raise ValueError("Project workspaces are disabled until HERMES_PROJECT_ROOTS is configured.")
        if not any(workspace == root or workspace.is_relative_to(root) for root in self.allowed_roots):
            raise ValueError("Project workspace is outside the configured project roots.")

    def _run(self, operation: str, payload: dict) -> dict:
        if self._injected_runner is not None:
            return self._injected_runner(operation, payload)

        python = self.hermes_home / "hermes-agent" / "venv" / "bin" / "python3"
        agent_dir = self.hermes_home / "hermes-agent"
        if not python.is_file() or not agent_dir.is_dir():
            raise RuntimeError("Hermes Agent project support is unavailable on this host.")

        script = r'''
import json, os, sys
from hermes_cli import projects_db as pdb
request = json.loads(os.environ["HERMES_MOBILE_PROJECT_REQUEST"])
with pdb.connect_closing() as conn:
    if request["operation"] == "list":
        result = {"projects": [p.to_dict() for p in pdb.list_projects(conn, include_archived=False)]}
    elif request["operation"] == "create":
        body = request["payload"]
        project_id = pdb.create_project(
            conn,
            name=body["name"],
            primary_path=body["workspacePath"],
            description=body.get("brief") or None,
        )
        project = pdb.get_project(conn, project_id)
        result = {"project": project.to_dict() if project else None}
    else:
        raise ValueError("Unsupported project operation")
print(json.dumps(result, separators=(",", ":")))
'''
        env = os.environ.copy()
        env["HERMES_HOME"] = str(self.hermes_home)
        env["HERMES_MOBILE_PROJECT_REQUEST"] = json.dumps({"operation": operation, "payload": payload})
        completed = subprocess.run(
            [str(python), "-c", script],
            cwd=str(agent_dir),
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if completed.returncode != 0:
            message = completed.stderr.strip().splitlines()[-1] if completed.stderr.strip() else "Hermes project operation failed."
            raise RuntimeError(message)
        return json.loads(completed.stdout)

    @staticmethod
    def _from_canonical(item: dict, pins: list[str]) -> HostProject:
        project_id = str(item.get("id") or "")
        workspace = str(item.get("primary_path") or "")
        if not _PROJECT_ID_PATTERN.fullmatch(project_id) or not workspace:
            raise RuntimeError("Hermes returned an invalid project record.")
        return HostProject(
            id=project_id,
            name=str(item.get("name") or item.get("slug") or project_id),
            workspace_path=workspace,
            brief=str(item.get("description") or ""),
            pinned_command_ids=list(pins),
        )

    @staticmethod
    def _normalize_pins(values: list[str]) -> list[str]:
        result: list[str] = []
        for value in values:
            command_id = value.strip().removeprefix("/")
            if not command_id or len(command_id) > 120 or not _COMMAND_ID_PATTERN.fullmatch(command_id):
                raise ValueError(f"Invalid pinned command identifier: {value}")
            if command_id not in result:
                result.append(command_id)
        if len(result) > 24:
            raise ValueError("A project may pin at most 24 commands.")
        return result

    def _load_pins(self) -> dict[str, list[str]]:
        if not self.pins_path.exists():
            return {}
        raw = json.loads(self.pins_path.read_text(encoding="utf-8"))
        return {
            str(project_id): self._normalize_pins([str(value) for value in values])
            for project_id, values in raw.items()
            if _PROJECT_ID_PATTERN.fullmatch(str(project_id)) and isinstance(values, list)
        }

    def _save_pins(self, pins: dict[str, list[str]]) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.state_dir, 0o700)
        except PermissionError:
            pass
        temporary_path = self.pins_path.with_suffix(".tmp")
        temporary_path.write_text(json.dumps(pins, indent=2, sort_keys=True), encoding="utf-8")
        os.replace(temporary_path, self.pins_path)
        try:
            os.chmod(self.pins_path, 0o600)
        except PermissionError:
            pass
