from dataclasses import replace

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.config import Settings
from app.main import create_app
from app.models import Device
from test_hosts import connector_setup_payload, create_phone_pairing_code, phone_pairing_payload, redeem_phone

# Test-only value, not a deployment credential.
SETUP_SECRET = "0a742359bd16c83ef59a0846e7b132cd9e205a71fba9864c"


def production_settings(tmp_path, **overrides):
    return replace(Settings(
        environment="production",
        database_url=f"sqlite:///{tmp_path / 'auth.db'}",
        internal_api_key="test-internal-key",
        connector_setup_secret=SETUP_SECRET,
        hermes_adapter="connector",
    ), **overrides)


def test_environment_must_explicitly_opt_into_development(monkeypatch):
    monkeypatch.delenv("RELAY_ENVIRONMENT", raising=False)
    assert Settings().environment == "production"
    assert Settings.from_env().environment == "production"


@pytest.mark.parametrize("secret", [None, "", "short", "x" * 32, " " * 40, "replace-with-a-bootstrap-secret"])
def test_production_startup_rejects_unsafe_setup_secret(tmp_path, secret):
    with pytest.raises(RuntimeError, match="CONNECTOR_SETUP_SECRET"):
        create_app(production_settings(tmp_path, connector_setup_secret=secret))


@pytest.mark.parametrize("secret", [None, "short"])
def test_enrollment_fails_closed_if_runtime_configuration_is_unsafe(tmp_path, secret):
    with TestClient(create_app(production_settings(tmp_path))) as client:
        client.app.state.settings = production_settings(tmp_path, connector_setup_secret=secret)
        response = client.post("/v1/connector/setup", json={
            **connector_setup_payload(), "installationSecret": secret,
        })
        assert response.status_code == 503
        assert "connectorCredential" not in response.text
        from app.models import User
        with client.app.state.database.session() as db:
            assert db.scalar(select(func.count()).select_from(User)) == 0


@pytest.mark.parametrize("supplied", [None, "", "wrong", "é" * 32, SETUP_SECRET])
def test_enrollment_uses_constant_time_comparison(tmp_path, monkeypatch, supplied):
    import secrets
    original = secrets.compare_digest
    comparisons = []

    def compare(left, right):
        comparisons.append((left, right))
        return original(left, right)

    monkeypatch.setattr(secrets, "compare_digest", compare)
    with TestClient(create_app(production_settings(tmp_path))) as client:
        response = client.post("/v1/connector/setup", json={
            **connector_setup_payload(), "installationSecret": supplied,
        })
        assert response.status_code == (200 if supplied == SETUP_SECRET else 403)
        assert ((supplied or "").encode("utf-8"), SETUP_SECRET.encode("utf-8")) in comparisons


@pytest.mark.parametrize("environment", ["development", "test"])
def test_explicit_local_environment_retains_registration(tmp_path, environment):
    with TestClient(create_app(production_settings(
        tmp_path, environment=environment, connector_setup_secret=None,
    ))) as client:
        assert client.post("/v1/device/register", json=register_payload()).status_code == 200
        assert client.post("/v1/connector/setup", json=connector_setup_payload()).status_code == 200


def register_payload():
    payload = phone_pairing_payload("unused", "11111111-1111-1111-1111-111111111111")
    payload.pop("code")
    return payload


@pytest.mark.parametrize("environment", ["production", "staging", "", "dev", "TEST"])
def test_registration_cannot_steal_first_users_auth(tmp_path, environment):
    with TestClient(create_app(production_settings(tmp_path, environment=environment))) as client:
        setup = client.post("/v1/connector/setup", json={
            **connector_setup_payload(), "installationSecret": SETUP_SECRET,
        })
        assert setup.status_code == 200
        connector = setup.json()["data"]
        code = create_phone_pairing_code(client, connector["connectorCredential"])
        phone = redeem_phone(client, code["code"], "22222222-2222-2222-2222-222222222222")
        assert phone["user"]["id"] == connector["user"]["id"]
        response = client.post("/v1/device/register", json=register_payload())
        assert response.status_code == 404
        assert "auth" not in response.text
        assert "/v1/device/register" not in client.get("/openapi.json").json()["paths"]
        with client.app.state.database.session() as db:
            assert db.scalar(select(func.count()).select_from(Device)) == 1
        assert client.get("/v1/session", headers={
            "Authorization": f"Bearer {phone['auth']['accessToken']}",
        }).status_code == 200
