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


@dataclass
class WorkspaceLease:
    project: HostProject
    canonical_path: Path
    fd: int
    subprocess_cwd: str

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

    def __enter__(self) -> "WorkspaceLease":
        return self

    def __exit__(self, _exc_type, _exc, _traceback) -> None:
        self.close()


class HostProjectStore:
    """Adapter over Hermes's canonical per-profile projects.db.

    Project definitions stay in Hermes Agent so Desktop and iOS share one project
    inventory. Mobile command pins live in an extension table in the same database,
    so project creation and its organization metadata commit atomically.
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
        self._injected_runner = runner
        configured = os.getenv("HERMES_PROJECT_ROOTS", "")
        roots = allowed_roots if allowed_roots is not None else [Path(value) for value in configured.split(os.pathsep) if value]
        self.allowed_roots = [root.expanduser().resolve() for root in roots if root.expanduser().is_absolute()]

    def list(self) -> list[HostProject]:
        result = self._run("list", {})
        projects = [
            self._from_canonical(item, [str(value) for value in item.get("pinnedCommandIds", [])])
            for item in result.get("projects", [])
        ]
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
                "pinnedCommandIds": normalized_pins,
            },
        )
        canonical = result.get("project")
        if not isinstance(canonical, dict):
            raise RuntimeError("Hermes did not return the created project.")
        project_id = str(canonical.get("id") or "")
        if not _PROJECT_ID_PATTERN.fullmatch(project_id):
            raise RuntimeError("Hermes returned an invalid project identifier.")
        return self._from_canonical(
            canonical,
            [str(value) for value in canonical.get("pinnedCommandIds", [])],
        )

    def get(self, project_id: str) -> HostProject:
        if not _PROJECT_ID_PATTERN.fullmatch(project_id):
            raise ValueError("Unknown project identifier.")
        project = next((item for item in self.list() if item.id == project_id), None)
        if project is None:
            raise ValueError("Unknown project identifier.")
        return project

    def resolve_workspace(self, project_id: str) -> Path:
        with self.open_workspace(project_id) as lease:
            return lease.canonical_path

    def open_workspace(self, project_id: str) -> WorkspaceLease:
        project = self.get(project_id)
        workspace = Path(project.workspace_path).resolve()
        if not workspace.is_dir():
            raise ValueError("Project workspace is no longer an existing directory.")
        self._require_allowed_workspace(workspace)
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(workspace, flags)
        except OSError as error:
            raise ValueError("Project workspace could not be opened safely.") from error
        try:
            fd_path = Path(f"/proc/self/fd/{fd}")
            if not fd_path.exists():
                fd_path = Path(f"/dev/fd/{fd}")
            opened_path = fd_path.resolve()
            self._require_allowed_workspace(opened_path)
            opened_stat = os.fstat(fd)
            current_stat = os.stat(workspace, follow_symlinks=False)
            if (opened_stat.st_dev, opened_stat.st_ino) != (current_stat.st_dev, current_stat.st_ino):
                raise ValueError("Project workspace changed during authorization.")
            return WorkspaceLease(
                project=project,
                canonical_path=opened_path,
                fd=fd,
                subprocess_cwd=str(fd_path),
            )
        except Exception:
            os.close(fd)
            raise

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
import json, os, secrets
from hermes_cli import projects_db as pdb
request = json.loads(os.environ["HERMES_MOBILE_PROJECT_REQUEST"])
with pdb.connect_closing() as conn:
    conn.execute(
        "CREATE TABLE IF NOT EXISTS mobile_project_pins ("
        "project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, "
        "command_id TEXT NOT NULL, position INTEGER NOT NULL, "
        "PRIMARY KEY(project_id, command_id))"
    )
    conn.commit()

    def payload(project):
        item = project.to_dict()
        item["pinnedCommandIds"] = [
            row[0] for row in conn.execute(
                "SELECT command_id FROM mobile_project_pins WHERE project_id = ? ORDER BY position ASC",
                (project.id,),
            ).fetchall()
        ]
        return item

    if request["operation"] == "list":
        result = {"projects": [payload(p) for p in pdb.list_projects(conn, include_archived=False)]}
    elif request["operation"] == "create":
        body = request["payload"]
        name = str(body["name"]).strip()
        primary = pdb._normalize_path(body["workspacePath"])
        existing = pdb.find_by_primary_path(conn, primary)
        if existing is not None:
            raise ValueError(
                f"folder already belongs to project '{existing.slug}' ({existing.id}); "
                "switch to it instead of creating a duplicate"
            )
        project_id = "p_" + secrets.token_hex(4)
        now = pdb._now()
        with pdb.write_txn(conn):
            conn.execute(
                "INSERT INTO projects (id, slug, name, description, icon, color, board_slug, primary_path, created_at, archived) "
                "VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, ?, 0)",
                (
                    project_id,
                    pdb._unique_slug(conn, pdb._slugify(name)),
                    name,
                    body.get("brief") or None,
                    primary,
                    now,
                ),
            )
            conn.execute(
                "INSERT INTO project_folders (project_id, path, label, is_primary, added_at) VALUES (?, ?, NULL, 1, ?)",
                (project_id, primary, now),
            )
            conn.executemany(
                "INSERT INTO mobile_project_pins (project_id, command_id, position) VALUES (?, ?, ?)",
                [(project_id, command_id, position) for position, command_id in enumerate(body.get("pinnedCommandIds", []))],
            )
        project = pdb.get_project(conn, project_id)
        result = {"project": payload(project) if project else None}
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
