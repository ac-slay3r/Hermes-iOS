from __future__ import annotations

import asyncio
import os
from pathlib import Path

import pytest

from hermes_mobile_connector.client import HermesMobileConnector
from hermes_mobile_connector.hermes_runner import ConnectorHermesSettings, HermesCLIExecutor
from hermes_mobile_connector.projects import HostProjectStore
from hermes_mobile_connector.state import ConnectorState, ConnectorStateStore


def make_executor() -> HermesCLIExecutor:
    return HermesCLIExecutor(
        ConnectorHermesSettings(
            hermes_command="hermes",
            hermes_workdir=None,
            hermes_provider=None,
            hermes_model=None,
            hermes_toolsets=None,
            hermes_source="tool",
            hermes_history_limit=20,
        )
    )


class CanonicalProjectsRunner:
    def __init__(self) -> None:
        self.projects: list[dict] = []

    def __call__(self, operation: str, payload: dict) -> dict:
        if operation == "list":
            return {"projects": list(self.projects)}
        if operation == "create":
            if any(item["primary_path"] == payload["workspacePath"] for item in self.projects):
                raise ValueError("folder already belongs to project")
            project = {
                "id": f"p_{len(self.projects) + 1:08x}",
                "slug": payload["name"].lower().replace(" ", "-"),
                "name": payload["name"],
                "description": payload["brief"],
                "primary_path": payload["workspacePath"],
                "folders": [{"path": payload["workspacePath"], "is_primary": True}],
                "pinnedCommandIds": list(payload.get("pinnedCommandIds", [])),
            }
            self.projects.append(project)
            return {"project": project}
        raise AssertionError(operation)


def test_project_store_adapts_canonical_hermes_projects_and_persists_only_pins(tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    runner = CanonicalProjectsRunner()
    store = HostProjectStore(tmp_path / "connector-state", allowed_roots=[tmp_path], runner=runner)

    project = store.create(
        name="Hermes iOS",
        workspace_path=str(workspace / ".." / "workspace"),
        brief="Ship a useful native client.",
        pinned_command_ids=["status", "branch", "ios-ux-development"],
    )

    assert project.id == "p_00000001"
    assert project.workspace_path == str(workspace.resolve())
    assert project.pinned_command_ids == ["status", "branch", "ios-ux-development"]
    assert store.list() == [project]
    assert store.resolve_workspace(project.id) == workspace.resolve()
    assert not (tmp_path / "connector-state" / "projects.json").exists()
    assert not (tmp_path / "connector-state" / "project-command-pins.json").exists()


def test_project_and_pins_share_one_canonical_database_transaction() -> None:
    source = Path(__file__).parents[1] / "src/hermes_mobile_connector/projects.py"
    text = source.read_text(encoding="utf-8")
    transaction = text.split('with pdb.write_txn(conn):', 1)[1].split('project = pdb.get_project', 1)[0]
    assert 'INSERT INTO projects' in transaction
    assert 'INSERT INTO project_folders' in transaction
    assert 'INSERT INTO mobile_project_pins' in transaction


def test_project_store_rejects_unsafe_or_ambiguous_workspaces(tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    runner = CanonicalProjectsRunner()
    store = HostProjectStore(tmp_path / "connector-state", allowed_roots=[tmp_path], runner=runner)
    store.create(name="One", workspace_path=str(workspace), brief="", pinned_command_ids=[])

    with pytest.raises(ValueError, match="absolute"):
        store.create(name="Relative", workspace_path="workspace", brief="", pinned_command_ids=[])
    with pytest.raises(ValueError, match="existing directory"):
        store.create(name="Missing", workspace_path=str(tmp_path / "missing"), brief="", pinned_command_ids=[])
    with pytest.raises(ValueError, match="already belongs"):
        store.create(name="Duplicate", workspace_path=str(workspace), brief="", pinned_command_ids=[])
    with pytest.raises(ValueError, match="Unknown project"):
        store.resolve_workspace("missing-project")


def test_workspace_lease_keeps_validated_directory_after_path_replacement(tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    runner = CanonicalProjectsRunner()
    store = HostProjectStore(tmp_path / "connector-state", allowed_roots=[tmp_path], runner=runner)
    project = store.create(name="Stable", workspace_path=str(workspace), brief="", pinned_command_ids=[])

    with store.open_workspace(project.id) as lease:
        original_inode = os.fstat(lease.fd).st_ino
        workspace.rename(tmp_path / "workspace-original")
        workspace.symlink_to(outside, target_is_directory=True)

        assert os.fstat(lease.fd).st_ino == original_inode
        assert os.stat(workspace).st_ino != original_inode
        assert lease.subprocess_cwd.endswith(str(lease.fd))


def test_connector_project_rpc_creates_then_lists_projects(monkeypatch, tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    connector = HermesMobileConnector(
        state_store=ConnectorStateStore(state_dir=tmp_path / "connector-state"),
        executor=make_executor(),
    )
    runner = CanonicalProjectsRunner()
    store = HostProjectStore(connector.state_store.state_dir, allowed_roots=[tmp_path], runner=runner)
    monkeypatch.setattr(connector, "_project_store", lambda: store)

    created = asyncio.run(
        connector._handle_rpc_request(
            {
                "type": "rpc.request",
                "requestId": "create-1",
                "method": "projects.create",
                "params": {
                    "name": "Mobile",
                    "workspacePath": str(workspace),
                    "brief": "Organize mobile work.",
                    "pinnedCommandIds": ["status"],
                },
            }
        )
    )
    listed = asyncio.run(
        connector._handle_rpc_request(
            {
                "type": "rpc.request",
                "requestId": "list-1",
                "method": "projects.list",
                "params": {},
            }
        )
    )

    assert created["success"] is True
    assert created["result"]["project"]["id"] == "p_00000001"
    assert listed["success"] is True
    assert listed["result"]["projects"] == [created["result"]["project"]]


def test_project_scoped_job_uses_host_resolved_workspace(monkeypatch, tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    state_store = ConnectorStateStore(state_dir=tmp_path / "connector-state")
    state_store.save(
        ConnectorState(
            relay_url="https://relay.example.com/v1",
            web_socket_url="wss://relay.example.com/v1/hosts/ws",
            user_id="user-123",
            host_id="host-123",
            connector_credential="secret",
        )
    )
    runner = CanonicalProjectsRunner()
    store = HostProjectStore(state_store.state_dir, allowed_roots=[tmp_path], runner=runner)
    project = store.create(
        name="Scoped",
        workspace_path=str(workspace),
        brief="",
        pinned_command_ids=[],
    )
    connector = HermesMobileConnector(state_store=state_store, executor=make_executor())
    monkeypatch.setattr(connector, "_project_store", lambda: store)
    captured: dict[str, str | None] = {}

    class StreamingRuntime:
        supports_streaming = True

    def fake_runtime(_state, workdir, workdir_fd):
        captured["resolved_workdir"] = workdir
        captured["workdir_fd"] = workdir_fd
        return StreamingRuntime()

    async def fake_handle(_websocket, _job, _runtime, *, workdir=None):
        captured["workdir"] = workdir

    monkeypatch.setattr(connector, "runtime_adapter_for_project", fake_runtime)
    monkeypatch.setattr(connector, "_handle_job_streaming", fake_handle)

    asyncio.run(
        connector._handle_job(
            object(),
            {
                "id": "job-1",
                "latestUserMessage": "Inspect this project",
                "projectId": project.id,
            },
        )
    )

    assert captured["workdir"].startswith(("/proc/self/fd/", "/dev/fd/"))
    assert captured["resolved_workdir"] == captured["workdir"]
    assert isinstance(captured["workdir_fd"], int)


def test_unknown_project_job_fails_closed_without_default_workdir(monkeypatch, tmp_path: Path) -> None:
    state_store = ConnectorStateStore(state_dir=tmp_path / "connector-state")
    state_store.save(
        ConnectorState(
            relay_url="https://relay.example.com/v1",
            web_socket_url="wss://relay.example.com/v1/hosts/ws",
            user_id="user-123",
            host_id="host-123",
            connector_credential="secret",
        )
    )
    store = HostProjectStore(state_store.state_dir, allowed_roots=[tmp_path], runner=CanonicalProjectsRunner())
    connector = HermesMobileConnector(state_store=state_store, executor=make_executor())
    monkeypatch.setattr(connector, "_project_store", lambda: store)

    class RecordingWebSocket:
        def __init__(self) -> None:
            self.messages: list[dict] = []

        async def send(self, raw: str) -> None:
            import json
            self.messages.append(json.loads(raw))

    websocket = RecordingWebSocket()
    asyncio.run(
        connector._handle_job(
            websocket,
            {"id": "job-unknown", "latestUserMessage": "Do not run", "projectId": "p_deadbeef"},
        )
    )

    assert websocket.messages == [{
        "type": "job.failed",
        "jobId": "job-unknown",
        "retryable": False,
        "error": "Unknown project identifier.",
    }]
