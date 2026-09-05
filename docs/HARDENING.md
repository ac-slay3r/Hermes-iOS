# Hardening and iteration runbook

## Security boundaries

- Production is the default environment. Set `RELAY_ENVIRONMENT=development` or `test` explicitly only for isolated local development.
- `/v1/device/register` is unavailable outside development/test. Phones enroll with validated, single-use pairing codes instead.
- Production startup requires a random connector setup secret: at least 32 characters, 8 distinct characters, no whitespace. The secret protects connector enrollment, not a replacement for device pairing.
- Keep production relay HTTP bound to loopback, credentials/state owner-only, and expose it through a deliberately configured HTTPS ingress.
- The checked-in Compose template does not publish PostgreSQL, publishes the relay only on `127.0.0.1`, requires real secrets, and runs the relay as a non-root user with a read-only filesystem.
- The Fly template has no public HTTP service. Existing remote deployments require their own inspection; editing a template does not change their exposure.

## Personal deployment posture

The current deployment is local systemd plus an **explicit public HTTPS fallback**, not VPN-only:

- API: `https://peripherals.n0thing.cool/v1`
- Relay origin: `127.0.0.1:8000`
- The existing peripheral service remains on `127.0.0.1:8787` and retains all non-`/v1` routing.
- Public connector setup and legacy device registration are denied at Cloudflare Tunnel ingress, in addition to application-level checks.
- Keep the bootstrap deny rule ahead of the general `/v1` rule. A suitable path expression is `^/v1/(?:device/register|connector/setup)(?:/.*)?$`, with `service: http_status:404`.
- Do not enable APNs without a separate notification privacy review. The current deployment does not configure APNs.

The Headscale node has no Tailscale-managed certificate domain. Moving to VPN-only iPhone access requires a private DNS name and an iOS-trusted TLS certificate, plus reachable private ingress. Plain HTTP or an untrusted self-signed certificate is not a substitute. Do not disable the working fallback until private pairing/chat/reconnect have been verified on the phone.

## Before a deployment

1. Run `./scripts/verify-local.sh` from the repository and require all backend and release-gate tests to pass. It uses the worktree's relay venv and can reuse the sibling upstream connector venv. To select other environments explicitly, set `RELAY_PYTHON` and `CONNECTOR_PYTHON` to absolute interpreter paths.
2. Independently review the diff, especially auth, job execution, and deployment boundaries.
3. Commit the exact validated source. Deploy an immutable `git archive` snapshot under `~/projects/hermes-ios/releases/<commit>/`, never a working tree that agents are editing.
4. Make a SQLite online backup with the SQLite backup API, not a raw copy of a possibly WAL-backed database. Back up the service units, relay env, connector state, and tunnel configuration in an owner-only directory. Never upload these backups as CI artifacts.
5. Check the message job queue. Do not restart the connector during an active tool execution without an explicit interruption decision.
6. Verify the deployed dependency environments remain compatible with the snapshot. The local deployment reuses the existing relay and connector virtual environments; do not upgrade those silently during a source rollout.

### Compose: migrate an existing PostgreSQL volume before redeploy

This applies only to Compose PostgreSQL deployments, not the local systemd/SQLite deployment. `POSTGRES_*` initializes an **empty** data directory; changing those variables does not change roles or passwords in an existing `postgres_data` volume. The template therefore preserves the legacy `postgres` user by default. If the volume was initialized with a different user, explicitly keep that existing name in `POSTGRES_USER`; do not rename the role as part of this upgrade. Use a URL-safe username with this URL/shell-based template.

**Before changing `.env`, switching Compose templates, or redeploying**, rotate any legacy/default password in the running database:

1. Use the currently working Compose file, project name, and environment throughout the migration (the commands below run from its `relay/` directory). Keep PostgreSQL running and stop **only the relay**. Do not run `docker compose down -v`, delete `postgres_data`, or change the project/volume identity.
2. Make an owner-only backup of the current environment and a logical database/role backup. In the commands below, replace `.env` with the actual old env file if the deployment still uses `.env.example`. The example uses the legacy `postgres` superuser; substitute the existing administrative user if different. Check each command succeeds before continuing; verify the dump is nonempty and keep a tested restore procedure. Backups contain sensitive data and role password hashes; never upload them as CI artifacts.

   ```sh
   docker compose stop relay
   umask 077
   backup_dir="$HOME/hermes-compose-backup-$(date -u +%Y%m%dT%H%M%SZ)"
   mkdir -m 700 "$backup_dir"
   cp .env "$backup_dir/relay.env"
   docker compose exec -T postgres pg_dumpall -U postgres > "$backup_dir/postgres.sql"
   test -s "$backup_dir/postgres.sql"
   ```

3. Generate/store a strong URL-safe random password in a password manager (for example, a random hex secret). Open interactive `psql` against the **existing** role, then use `\password` and enter the new password at its hidden prompts. Do not put the password in a shell command, SQL `ALTER ROLE` command, command-line URL, or shell history.

   ```sh
   docker compose exec postgres psql -U postgres -d hermes_mobile
   ```

   At the `psql` prompt (substitute the existing role if different):

   ```text
   \password postgres
   \q
   ```

4. While still using the old Compose configuration, verify the new password through TCP/password authentication, entering it only at the prompt:

   ```sh
   docker compose exec postgres psql -h postgres -U postgres -d hermes_mobile -W -c 'SELECT current_user;'
   ```

   Require successful authentication with the new password; `pg_isready` alone does not verify credentials. If migration or verification fails, leave the relay stopped and resolve it without deleting the volume.
5. **Only after the database password is changed and verified**, edit the owner-only `.env` using a secure editor: set `POSTGRES_PASSWORD` to that same new secret, preserve the existing `POSTGRES_USER` (`postgres` by default), and supply the other required production settings. Keep `.env` mode `0600`. Adopt the hardened template using the same Compose project/volume, then run `docker compose up -d --build`. Verify authenticated relay database operations as well as the post-deploy gates below. If rolling back source, retain the new credentials; restoring the old `.env` alone would break authentication.

## Rollout

- Point `~/projects/hermes-ios/releases/current` at the validated immutable snapshot.
- Relay: use that snapshot's `relay/` as the working directory and uvicorn app directory; keep the production EnvironmentFile and loopback-only listener.
- Connector: use that snapshot's `connector/` as the working directory and its `connector/src` as `PYTHONPATH`. Reusing an editable-install executable alone can silently load the old checkout, so verify the effective module path.
- Preserve existing credentials, database, and paired-device state. Bootstrap enrollment is not necessary for a source upgrade.
- Validate systemd unit syntax before daemon reload. Restart only the two mobile services; restart the shared tunnel only when its validated ingress configuration changed.
- Verify process cwd/module paths resolve to the intended snapshot, not the development checkout.

## Post-deploy gates

- Local `/v1/health`: 200; `/v1/version`: production relay.
- Local `/v1/device/register`: 404, even with a valid registration body.
- Local `/v1/connector/setup` without its secret: 403 for a valid request body.
- Public `/v1/device/register` and `/v1/connector/setup`: 404 at ingress.
- Unauthenticated local/public `/v1/admin/status`: 401.
- Public `/health`: the existing peripheral response remains healthy.
- Relay and connector units remain active; the connector has no current error and the database host heartbeat advances after restart.
- Repeated health checks alone do not prove chat/tool execution. Perform legitimate pairing and auth regression tests on an isolated database, then require physical-iPhone verification before calling the mobile release ready.

## Rollback

Preserve the bootstrap deny rule at ingress during rollback. Reverting to a vulnerable application revision must not reopen public registration. Prefer a fixed previous release; use the pre-hardening release only for emergency recovery while ingress restrictions remain enforced.

Restore the previous `current` snapshot target and the saved service units if needed, validate, reload, and restart only the mobile services. Source rollback does not ordinarily require database restoration. Restore a database backup only after a separate explicit data-loss decision; never overwrite newer conversations merely to roll back code.

## Iteration and TestFlight

- Linux backend tests are the fast iteration gate, not proof of native iOS correctness.
- Native build and XCTest require macOS/Xcode. CI includes the shared scheme's unit and UI tests.
- TestFlight must require successful CI for the **exact branch and commit**, including all four required jobs. Only `push` and `workflow_dispatch` CI evidence qualifies; PR runs can test a synthetic merge rather than the standalone release commit. A queued, skipped, cancelled, or billing-blocked job does not qualify. The gate rechecks the latest run and is repeated before signing credentials are accessed.
- Do not change GitHub billing, raise spending limits, or upload an unvalidated build as a workaround. If Actions refuses jobs for billing, the account owner must resolve that gate.

### Physical-iPhone checklist

1. Cold launch while VPN/network is unavailable: no permanent splash; pairing remains saved and recovery is accessible.
2. Restore the network and retry/foreground: initialization and host status recover.
3. Disconnect VPN after an online refresh: cached online state must not appear as current connectivity.
4. Send chat and run a deliberately slow, non-destructive task: streaming remains connected across quiet periods.
5. Relaunch, expire authentication, and reconnect: no duplicated messages or repeated tool execution.
6. Open the cockpit, refresh, and check both healthy and unavailable states.

No TestFlight upload, Apple processing, or physical-device success should be inferred from backend or source-review results.
