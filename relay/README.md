# Hermes iOS Relay

The relay is the public control plane for Hermes iOS. It handles pairing, auth, jobs, SSE, push registration, and the connector WebSocket, but it does **not** run Hermes itself in connector mode.

## What the relay does

- device registration, auth, refresh, and session lifecycle
- connector-first pairing and host management
- durable message jobs with SSE progress streaming
- talk readiness and voice-session bootstrap
- inbox APIs and APNs registration/delivery

In production, Hermes execution stays on the user-owned host through the connector.

## Requirements

- Python 3.11+
- PostgreSQL for production
- HTTPS base URL for public deployments
- a strong `INTERNAL_API_KEY`

## Quick start (local development)

```bash
cd relay
python -m venv .venv
source .venv/bin/activate
pip install -e .[dev]
cp .env.example .env
export RELAY_ENVIRONMENT=development
uvicorn app.main:app --reload
```

You can also use Docker Compose from the same directory if you want a local Postgres-backed stack.

For same-network device testing, see [docs/local-dev.md](docs/local-dev.md).

## Production checklist

> [!IMPORTANT]
> The relay refuses startup outside explicit `development`/`test` without a strong `CONNECTOR_SETUP_SECRET`, or with `INTERNAL_API_KEY=replace-me`. An unset `RELAY_ENVIRONMENT` defaults to `production`; never use development/test on a public deployment.

Minimum production configuration:

```bash
export RELAY_ENVIRONMENT=production
export PUBLIC_BASE_URL=https://your-relay.example.com/v1
export DATABASE_URL=postgresql+psycopg://...
export INTERNAL_API_KEY=replace-with-a-real-secret
export CONNECTOR_SETUP_SECRET="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
export HERMES_ADAPTER=connector
```

Store this generated setup secret securely and provide the same value during `hermes-mobile setup`. It is required outside development/test: at least 32 characters, at least 8 distinct characters, and no whitespace. These checks reject obvious weak values but cannot prove randomness; use a cryptographic generator. Existing connector credentials and paired phone sessions do not need this secret for normal operation. Do not rotate it merely on each process restart.

The full variable matrix lives in [../docs/CONFIGURATION.md](../docs/CONFIGURATION.md).

## Deploy to Fly.io

The tracked [fly.toml](fly.toml) contains placeholders only. Replace the app name and `PUBLIC_BASE_URL`, then deploy.

Two supported paths:

- **Guided path**: run `hermes-mobile setup` on the connector host and choose the Fly deployment option
- **Manual path**: follow [docs/fly-io.md](docs/fly-io.md)

The relay docs assume Fly Managed Postgres for new deployments.

## Local Hermes execution modes

The relay supports three modes:

- `HERMES_ADAPTER=mock`
  - deterministic demo behavior
- `HERMES_ADAPTER=cli`
  - runs Hermes locally from the relay process
- `HERMES_ADAPTER=connector`
  - production-oriented path where a connected host claims and executes jobs

For public/self-hosted users, `connector` mode is the intended deployment model.

## API overview

### Core and auth

- `GET /v1/health`
- `GET /v1/version`
- `GET /v1/session`
- `POST /v1/auth/refresh`
- `POST /v1/auth/revoke`
- `POST /v1/device/register` (explicit development/test only; absent and returns 404 elsewhere)

### Pairing and hosts

- `POST /v1/connector/setup`
- `POST /v1/connector/phone-pairing-codes`
- `POST /v1/phone-pairing/redeem`
- `GET /v1/hosts/current`
- `POST /v1/hosts/current/revoke`
- `GET /v1/hosts/ws` (WebSocket)

### Chat and jobs

- `GET /v1/conversations/current`
- `POST /v1/messages`
- `GET /v1/jobs/{job_id}/events`

### Talk mode

- `GET /v1/talk/readiness`
- `POST /v1/talk/session`
- `POST /v1/talk/session/{voice_session_id}/end`
- `POST /v1/talk/session/{voice_session_id}/turns`

### Inbox and push

- `GET /v1/inbox`
- `POST /v1/inbox/{id}/action`
- `POST /v1/push/register`
- `POST /v1/push/deactivate`
- `POST /v1/push/send` *(internal)*
- `POST /internal/inbox/create`
- `GET /internal/inbox/{id}/actions`

## Security notes

- Use HTTPS in any deployment the phone will reach over the internet.
- Set a strong `INTERNAL_API_KEY`.
- Set a strong `CONNECTOR_SETUP_SECRET` before deploying. Missing/weak production configuration fails startup; runtime misconfiguration returns 503 from connector setup. Missing/wrong installation secrets return 403, compared with `secrets.compare_digest`.
- Production phones use connector-issued phone pairing codes, not `/v1/device/register`. Connector setup remains secret-gated; creating phone codes requires a connector credential. Legacy pairing/host redemption requires valid single-use invites, and host enrollment-code creation requires user authentication.
- Keep APNs secrets on the relay only, never on the connector.

## APNs and CarPlay

APNs and CarPlay are optional platform features. They are documented in [../docs/CONFIGURATION.md](../docs/CONFIGURATION.md).

- APNs is fully optional for base setup
- CarPlay requires Apple approval for the entitlement and is inert when not configured

## Troubleshooting

### Relay won’t start

- confirm `DATABASE_URL`
- confirm `PUBLIC_BASE_URL`
- confirm `INTERNAL_API_KEY` is not the default in production
- confirm `CONNECTOR_SETUP_SECRET` is configured and meets the requirements above

### Connector can’t claim jobs

- verify the host is connected through `/v1/hosts/ws`
- confirm the relay and connector are using the same base URL
- for initial enrollment, confirm `CONNECTOR_SETUP_SECRET` matches on both sides

### Push registration works but no alerts arrive

- check APNs config on the relay
- verify bundle ID and environment match the device registration
- confirm the app is not foregrounded when testing reply-triggered alerts

## Related docs

- [../README.md](../README.md)
- [../docs/CONFIGURATION.md](../docs/CONFIGURATION.md)
- [docs/fly-io.md](docs/fly-io.md)
- [docs/local-dev.md](docs/local-dev.md)
