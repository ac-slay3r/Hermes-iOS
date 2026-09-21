from __future__ import annotations

import asyncio
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
    assert (tmp_path / "connector-state" / "project-command-pins.json").stat().st_mode & 0o777 == 0o600


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

    def fake_runtime(_state, workdir):
        captured["resolved_workdir"] = workdir
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

    assert captured["workdir"] == str(workspace.resolve())
    assert captured["resolved_workdir"] == str(workspace.resolve())


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
