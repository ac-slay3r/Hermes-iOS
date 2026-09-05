# Fly.io deployment: private template only

The checked-in `fly.toml` deliberately has **no public HTTP service**. It does not expose an HTTPS endpoint at `your-app.fly.dev`. Fly is optional; the current personal deployment uses local systemd services, not Fly.

## Before deploying

- Set the app name and region in `fly.toml`.
- Provision and attach a PostgreSQL database; never rely on ephemeral SQLite storage.
- Configure a **private ingress with an iOS-trusted TLS certificate**, and set `PUBLIC_BASE_URL` to that HTTPS API URL ending in `/v1`.
- Store `DATABASE_URL`, a strong random `INTERNAL_API_KEY`, and `CONNECTOR_SETUP_SECRET` using Fly secrets, never source control. The setup secret must have at least 32 characters, at least 8 distinct characters, and no whitespace. Generate random values rather than human passwords.
- Keep `RELAY_ENVIRONMENT=production`. Development/test enables unauthenticated bootstrap and must never be publicly reachable.

The process listens on IPv6 for Fly private networking. Fly `.internal` networking is **not** the same network as your Headscale/Tailscale deployment. You must supply a private routing path to both connector and phone; the template alone does not do that.

## Deployment and verification

After configuring the prerequisites, deploy with `flyctl deploy -a YOUR_APP`. Maintain a running private machine; without a public service there is no public HTTP autostart route. Use `flyctl status -a YOUR_APP` and `flyctl logs -a YOUR_APP` for diagnostics.

From a host with access to your configured private HTTPS ingress, verify:

- `/v1/health` returns 200 and `/v1/version` identifies a production relay.
- `/v1/device/register` returns 404, including valid registration payloads.
- Unauthenticated `/v1/admin/status` returns 401.
- Connector enrollment requires the setup secret and is not publicly exposed.
- The connector maintains an authenticated heartbeat; then test single-use phone pairing, chat, and reconnect on the actual iPhone.

Do not allocate public addresses or add `[http_service]` as an implicit workaround. Public fallback is a separate explicit deployment decision requiring its own boundary review. Existing public Fly deployments are not made private simply by editing this file: inspect deployed services and allocated addresses separately.

APNs is optional and is not required for private pairing or chat. If enabled, review notification privacy and use the app's actual bundle ID, `cool.n0thing.hermes`.
