# Native Hermes iOS administration — capability and editing inventory

> **Integration update:** Administration remains primary. Explicitly authorized local features are now secondary supporting tools; automatic connected/sensor/voice startup remains disabled. This document preserves earlier milestone evidence and may describe superseded launch/scope or test counts. The [current build integration matrix](CURRENT_BUILD_INTEGRATION.md) is authoritative for reachability, gaps and release blockers.

## Decision and evidence boundary

**Build an administration client, not a capture or daily-life AI platform.** Retain the existing charcoal/gold native direction. Freeze and preserve existing capture, intake, intelligence, backup, chat and streaming work; this inventory neither deletes it nor authorizes runtime changes.

**The host already has a substantial administration backend. The existing mobile relay does not expose it.** Prefer a separately authenticated, explicitly host/profile-targeted native administration adapter to the existing dashboard API. Do not turn a chat message, slash command, streaming consent, or connector enrollment into general administrator authority.

Evidence is **static source verification**, not authenticated deployment verification. No host config values, credential files, memory contents, session databases, running endpoint responses, secrets, or service configuration were read. No runtime calls, restarts, installs or state-changing API requests were made. Official documentation was fetched using HTTPS after the web extractor reported that its configured backend could not extract pages.

Source snapshots:

- **H** = `/home/aconn/.hermes/hermes-agent`, Git HEAD `245e48008fa814b3251f50755eb656bd9fb86cb1`. References below are working-tree file lines, not a claim that every file is pristine or that a running service has loaded this revision.
- **I** = `/home/aconn/projects/hermes-ios/admin-cockpit-v2`, Git HEAD `8172af1170e20d0ade9f4279261b0adda16bf5ba`. This working tree already contained substantial uncommitted work; it is preserved.
- **R** = `H/hermes_cli/web_routers/`; **M** = `H/hermes_cli/web_models.py`.

The current official index identifies configuration, profiles, security, memory, MCP and dashboard management documentation.[1] The official dashboard guide describes configuration/API-key/session management and says configuration changes take effect on a subsequent agent session or gateway restart.[2] Local implementation details below take precedence over assumptions about a particular deployed version.

## 1. Transport, authentication and authority

| Surface | Verified contract | Consequence for iOS |
|---|---|---|
| Existing mobile relay | `I/relay/app/main.py:539–600`: `GET /v1/admin/status`, `GET /v1/admin/audit` are per-relay-user host/device status and audit summaries. `GET /v1/hosts/current` at 949–955; `GET /v1/commands` at 958–975 forwards only `commands.catalog`. | These are not Hermes settings, profiles or editing APIs. Relay online ≠ dashboard reachable ≠ authenticated administrator. |
| Relay auth | `I/relay/app/security.py:18–101`: opaque bearer access/refresh tokens, hashes stored in relay auth sessions; access expiry/revocation checked, user/device resolved. `main.py:1284–1328`: refresh/revoke. Internal routes use `X-Relay-Internal-Key` (`security.py:68–74`). | Keep relay and dashboard credentials isolated. Never put the internal key into the phone. No read-only/admin capability scope is demonstrated by relay `AuthContext`. |
| Connector RPC | `I/connector/src/hermes_mobile_connector/client.py:929–959` dispatches talk lifecycle/delegation and `commands.catalog`. | No verified admin RPC forwarding. Do not invent `/v1/config`, `/v1/profiles` or a generic relay admin proxy. |
| Dashboard REST | Mounted by `H/hermes_cli/web_server.py:939–974`; route tables below. Protected `/api/` requests use authentication middleware, with a public-path allowlist (`:623–654`). | A separate typed client is needed; existence in source does not establish reachability on the connected host. |
| Loopback dashboard auth | `web_server.py:379–419`: session-token validation, including `X-Hermes-Session-Token`/legacy bearer path; `:623–641`: API middleware. SPA bootstrap token only in ungated mode (`web_server_dashboard.py:140–161`). | Do not scrape bootstrap credentials or expose a loopback dashboard as an unauthenticated remote service. |
| Gated remote dashboard | Non-loopback binds require the gate (`web_server.py:444–465`). `dashboard_auth/middleware.py:148–204` accepts verified provider session bearer tokens or cookies; invalid presented bearer fails rather than silently falling back. | Use authenticated HTTPS. Relay bearer tokens are not interchangeable with provider-minted dashboard session tokens. |
| Native authentication | `GET /auth/native/authorize` requires S256 challenge and loopback redirect; `POST /auth/native/token` takes `code`, `code_verifier`; `POST /auth/native/refresh` takes `refresh_token`, optional `provider`. `GET /api/auth/me` returns identity; `POST /api/auth/ws-ticket` mints a short-lived single-use WS ticket (`dashboard_auth/routes.py:215–274,436–503`). | **iOS sign-in is not yet proven.** The existing native broker only accepts HTTP IP-literal loopback redirects, not custom schemes/universal links. A desktop-oriented native flow is not proof of an iOS-compatible callback. Validate an approved iOS flow before any admin writes. |
| Permissions | Main REST handlers rely on the dashboard gate; no per-field admin/read-only scope enforcement is demonstrated in these handlers. The separate token-provider seam is opt-in by route (`dashboard_auth/token_auth.py:1–27`; `base.py:26–30`). | Treat authenticated dashboard access as powerful host-user authority, not least privilege. UI disabling is not a security boundary. Need explicit target binding and, preferably, server-enforced capability restrictions. |

The existing Swift `HermesClientProtocol` is conversation-oriented (`I/HermesMobile/Services/Protocols/HermesClientProtocol.swift:4–14`). `RelayAPIClient` supplies GET/POST, bearer headers and relay `{data: ...}` decoding (`I/HermesMobile/Services/Support/RelayAPIClient.swift:60–73,111–165,252–281`). Dashboard responses are heterogeneous objects/lists and require PUT/PATCH/DELETE support, explicit query encoding, dashboard error handling, and a separate session lifecycle—not reuse of relay envelopes by assumption.

## 2. Settings and model/provider editing

### General settings

- **Read:** `GET /api/config?profile=...`, `/api/config/defaults`, `/api/config/schema?profile=...` (`R/config_env.py:76–99`). Schema returns `fields` keyed by dotted paths and `category_order`.
- **Write:** `PUT /api/config` with `{config: {...}, profile: "explicit-profile"}` (`M:11–13`; `R/config_env.py:109–139`). Body profile takes precedence over query. Incoming values are denormalized and **deep-merged**, not whole-document replaced. Omitted keys survive; omission is not deletion. Do not send an entire default-expanded GET as an edit.
- **Validation:** `ConfigUpdate.config` is merely a dictionary. Schema types/options describe UI controls; they are **not a complete server-side field-validation contract**. `save_config` canonicalizes, preserves environment references and existing explicit defaults, writes atomically and clears the raw-config cache (`H/hermes_cli/config.py:2328–2367`). Managed configuration is rejected/filtered there. Structural checks exist separately (`config.py:1219–1262`); PUT does not call a comprehensive schema validator.
- **Schema coverage:** constructed recursively from `DEFAULT_CONFIG`, skipping `_config_version`; overrides add select options/categories, plus virtual `model_context_length`; empty maps do not yield child controls (`web_server_config.py:198–239`). Dynamic voice/memory provider options are merged per request (`:327–370`). Appendix B inventories literal default-backed field paths without reading live configuration. Runtime plugins and arbitrary map entries require runtime discovery; no finite static list proves “every supported setting.”
- **Important serialization:** web `model` is flattened to a string and context length becomes top-level `model_context_length` (`web_server_config.py:479–491`). Prefer dedicated model routes for provider/model assignments; never round-trip the normalized record as a canonical raw YAML object.
- **Secrets warning:** GET config strips internal underscore keys, not every secret-bearing nested value (`R/config_env.py:82–84`; normalization `web_server_config.py:479–491`). Config can include custom-provider/MCP/auxiliary credentials or expanded references. Do not blindly log, persist, display or export its raw response. Add a server-side secret-safe read contract before presenting arbitrary fields.
- **Apply:** save is persistence, not universal live activation. Approval-mode changes broadcast refreshed session information for the serving profile (`R/config_env.py:130–135`), which is not a guarantee that every runtime subsystem reloaded. Use “Saved; runtime application pending/unknown” unless a field-specific effect is verified. A fresh session/restart is the documented general rule.[2]
- **Raw editor:** `GET/PUT /api/config/raw` (`R/analytics.py:32–70`; `M:486–488`) exists. Treat as advanced whole-document editing, not the first slice; it defeats narrow field review and increases secret/overwrite risk.

### Models and providers

- Reads: `GET /api/model/info`, `/api/model/options`, `/api/model/recommended-default`, `/api/model/auxiliary`, `/api/model/moa` (`R/models.py:52–226`). Options are discovery-driven; do not hardcode vendor/model lists or infer availability from a name.
- Assignment: `POST /api/model/set` accepts `scope`, `provider`, `model`, optional `task`, `base_url`, `api_key`, `confirm_expensive_model`, `profile` (`M:91–106`). Scope is checked against `main|auxiliary`; an expensive-model guard can return HTTP-success JSON with `ok:false, confirm_required:true, confirm_message` and **no assignment** (`R/models.py:283–314`). Inspect business outcome, not only HTTP status. `task=""` means all auxiliary slots; `task="__reset__"` resets all; never use these bulk meanings implicitly.
- Assignment writes apply to **new sessions**; running chat model switching is a separate slash-command action (`R/models.py:284–286`). `PUT /api/profiles/{name}/model` accepts nonempty provider/model for a named profile (`R/profiles.py:861–872`) but has a different narrower payload; do not assume every model guard is identical.
- Custom endpoints: GET/POST `/api/providers/custom-endpoints`, POST `/{endpoint_id}/activate`, DELETE `/{endpoint_id}`, POST `/api/providers/custom-endpoints/validate` (`R/config_env.py:520–635`). Request fields in `M:36–45`; validation probes may contact remote providers. Generic provider validation: POST `/api/providers/validate` (`:639–695`). Treat probes as explicit network operations, not harmless background reads.
- Provider OAuth: GET `/api/providers/oauth`, DELETE `/{provider_id}`, POST `/{provider_id}/start`, POST `/{provider_id}/submit`, GET `/{provider_id}/poll/{session_id}`, DELETE `/api/providers/oauth/sessions/{session_id}` (`R/oauth.py:496–666`). This is **model-provider account setup**, not dashboard sign-in.
- Credential administration exists: GET/PUT/DELETE `/api/env`, POST `/api/env/reveal`; GET/POST `/api/credentials/pool`, DELETE `/api/credentials/pool/{provider}/{index}` (`R/config_env.py:215–285,699–740`; `R/ops.py:292–424`). Do not call reveal or treat secret reads as settings discovery. API-key pool add takes provider/key/label; OAuth pooling is explicitly CLI-only in `M:357–360`. Credential write/reveal and rotation need a separate secure UX and authorization review; no credential values were inspected here.

## 3. Capability and editing matrix

All dashboard writes below require the dashboard authentication boundary described above. “Profile” is a target parameter, not an authorization grant. Explicitly pass the selected profile only where the handler supports it; disable wrong-profile operations rather than guessing.

| Domain | Verified read/write API | Validation, scope and effect |
|---|---|---|
| Profiles | GET/POST `/api/profiles`; GET/POST `/api/profiles/active`; PATCH/DELETE `/api/profiles/{name}`; PUT `/{name}/description`; GET `/{name}/setup-command`; POST `/{name}/open-terminal`, `/{name}/describe-auto`, `/{name}/export`; POST `/api/profiles/import` (`R/profiles.py:635–949`). | Bodies `M:400–441`. Active means sticky default for subsequent CLI/gateways, **not** retargeting the running dashboard (`:705–731`). Create can succeed while model/MCP/skill setup fails best-effort (`:672–701`); inspect subresults. Clone-all copies state; keep-skills has replacement semantics; delete can stop a gateway and remove profile data (`:800–804`). Export/import exchange host paths, not iOS files (`:896–897`). Keep destructive/bulk actions out of first slice. |
| Skills | GET `/api/skills`; GET `/api/skills/content?name=...&profile=...`; POST `/api/skills`; PUT `/api/skills/content`; PUT `/api/skills/toggle`; hub install/uninstall/update + discovery routes (`R/skills.py:98–438`). | `M:389–398,443–457`. Content write replaces SKILL.md via `_edit_skill`; create calls `_create_skill`; errors 400/404; prompt cache cleared. Authenticated dashboard create deliberately bypasses agent write-approval gate (`:414–424`). Toggle updates disabled set and is not a permission to run skill content. Do not assume support-file CRUD from SKILL.md edit. Skill provenance appears in list; a bundled/hub skill needs overwrite/update-conflict handling. |
| Tools | GET `/api/tools/toolsets`; PUT `/api/tools/toolsets/{name}`; GET `/{name}/config`, `/{name}/models`; PUT `/{name}/model`, `/{name}/provider`, `/{name}/env`; POST `/{name}/post-setup`; GET `/api/tools/terminal/backends`; PUT `/api/tools/terminal/backend` (`R/tools.py:217–663`). | Body types `M:459–484`; known-toolset guard; platform determined server-side, usually CLI but restricted sets target their own platform. **Enable can spawn dependency installation** and return `post_setup_started` (`:295–325`). Configured/available/enabled are not interchangeable. Need explicit installation consequence review. Existing conversations' tool schemas must not be rewritten silently. |
| MCP | GET/POST/PUT `/api/mcp/servers`; DELETE `/api/mcp/servers/{name}`; PUT `/{name}/enabled`; POST `/{name}/test`, `/{name}/auth`; OAuth flow polling/cancel; catalog GET/install POST (`R/mcp.py:77–451`). | `M:305–329`. Duplicate add returns 409; normalization/security rejection returns 400. PUT is **whole-map replacement**, unlike config merge (`:118–131`). Test can launch stdio processes or network connections, returns `ok:false` in JSON on failures. OAuth rejects inappropriate transport/auth; concurrent flow checks and profile-bound flow context exist (`:195–239`). Readback ≠ live tool registration; OAuth has an explicit own-process reconnect path, so neither “everything hot-reloads” nor “nothing hot-reloads” is justified. |
| Built-in memory and user information | GET `/api/learning/graph?profile=...`; GET `/api/learning/node?id=...&profile=...`; PUT `/api/learning/node` with `{id,content,profile}`; DELETE with `{id,profile}` (`R/status.py:568–612`; `M:206–213`). | Real correction API, not just a reset button. `H/agent/learning_mutations.py:3–63,149–157`: MEMORY.md/USER.md nodes use `memory:<source>:<index>`; validates source/range and nonempty replacement, atomically rewrites. **Index IDs are positional, not stable revisions**; simultaneous reorder can target different text even if index remains valid. Need read-before-apply and server compare-and-swap before claiming conflict-safe edits. Writes do not prove existing prompt snapshot changed. |
| Memory providers | GET `/api/memory`; PUT `/api/memory/provider`; POST `/api/memory/reset` (`R/ops.py:435–483`); GET/PUT `/api/memory/providers/{name}/config`, POST `/{name}/setup` (`R/memory_providers.py:513–576`). | Status/provider/reset handlers shown have **no profile parameter** and target serving context; do not pretend a query retargets them. Provider readiness checked on selection; reset target `all|memory|user` unlinks built-in files, not a universal external-provider erasure. Provider config/setup uses `values: dict` (`M:30–34`); individual external memory record correction is unverified. |
| Instructions | GET/PUT `/api/profiles/{name}/soul` (`R/profiles.py:809–843`), `{content:string}` (`M:427–428`). Generic GET `/api/fs/read-text?path=...`, POST `/api/fs/write-text` `{path,content}` (`R/files.py:631–688`). | SOUL write is atomic, creates file if absent, no content revision/If-Match shown. Project AGENTS/HERMES/CLAUDE rules do not have a dedicated typed management route verified here; generic filesystem editor is broader authority. File editor rejects oversized/nonregular targets and missing parent; read can be truncated, so never save a truncated preview. Apply to an existing session's prompt is not established. |
| Sessions | GET `/api/sessions`, `/search`, `/stats`, `/{session_id}`, `/{session_id}/messages`, `/{session_id}/export`; PATCH/DELETE `/{session_id}`; bulk delete/import/prune also exist (`R/sessions.py:166–693`). | PATCH fields `title, archived, hidden, pinned, unread, profile` (`M:241–248`), not message content. Rename/archive is supported correction of metadata. **No transcript-message rewrite endpoint verified.** Preserve original history; don't implement “correct memory” by rewriting chat records. Bulk prune has dry_run but defaults false (`M:256–281`): any future preview must set it explicitly. |
| Scheduled jobs | GET `/api/cron/jobs`, `/{job_id}`, `/{job_id}/runs`, `/api/cron/delivery-targets`; POST `/api/cron/jobs`; PUT/DELETE `/{job_id}`; POST `/{job_id}/pause`, `/resume`, `/trigger`; blueprint routes (`R/cron.py:212–420`). | Create `M:283–296`; update is `{updates:dict}`. Normalization `R/cron.py:42–66`; validation delegated to `web_server_cron` and cron core. **List defaults to all profiles**, job ownership may otherwise be discovered (`:69–101`): always pass explicit target. Trigger executes work and may deliver messages/spend money; pause/resume affects scheduling, not proof a running job was cancelled. Relay `/v1/jobs/{job_id}/events` is a streaming message job, not this cron API. |
| Messaging/integrations | GET `/api/messaging/platforms`; PUT `/api/messaging/platforms/{platform_id}`; POST `/{platform_id}/test`; Telegram/WhatsApp onboarding routes (`R/messaging.py:519–896`). Pairing GET `/api/pairing`; POST `/approve`, `/revoke`, `/clear-pending` (`R/ops.py:76–120`). Webhook GET/POST `/api/webhooks`, POST `/enable`, DELETE `/{name}`, PUT `/{name}/enabled` (`:146–244`). | Messaging body `enabled?`, `env`, `clear_env`, `profile` (`M:47–52`). Platform allowlist/values checked; multiplex port conflict 409 before writes (`R/messaging.py:823–869`). Multiple env writes are sequential: do not promise transactional rollback. Pairing authorizes messaging users, **not** shell approval or phone admin sign-in. Webhook bodies contain prompt/script/events/delivery/secret (`M:342–355`): high-impact execution boundary. Many ops handlers are serving-profile-only; inspect signature, never assume universal query support. |
| Approvals | Policy `approvals.mode` via config (`web_server_config.py:121`; config PUT above). Live **JSON-RPC** `approval.respond` via gateway WS (`H/tui_gateway/methods_prompt.py:1154–1168`; `R/chat_ws.py:542–554`). Hooks GET/POST/DELETE `/api/ops/hooks` (`R/ops.py:594–719`). | Modes manual/smart/off. Response RPC resolves session/request ID, `choice` defaults deny, `all` defaults false. Not a REST `/api/approvals` route. This inventory does not verify a complete pending-approval discovery/reconnect protocol or valid choice enumeration. Hook-create includes `approve:true` default (`M:377–383`): set explicitly and review. Relay inbox actions are a different system; no proof they resolve core approvals. |
| Operations | POST `/api/gateway/start`, `/stop`, `/restart`, `/drain`; GET `/api/actions/{name}/status`; update/doctor/audit/backup/import and curator operations exist (`R/actions.py:139–435`; `R/ops.py:252–262,492–590`; `R/status.py:530–564`). | Operating-system/service authority and running topology determine success. Async action accepted ≠ completed ≠ correct profile restarted. Require a separate explicit operation review and exact target readback; never automatically restart after a settings save. |

### Additional field-validation details

- Profile identifiers: host ingress normalization trims/lowercases, then validation uses `[a-z0-9][a-z0-9_-]{0,63}` and rejects reserved names, with `default` special-cased (`H/hermes_cli/profiles.py:169–217`). Preserve the exact operator-selected identifier in review; never silently substitute another target after validation fails.
- Session titles: empty string clears; an empty PATCH is 400; title persistence can reject excessive length, invalid characters or an already-used title (`R/sessions.py:619–648`). The numeric title limit was not verified here; do not invent a client limit.
- MCP create: nonempty name, exactly one URL or command, supported auth mode; HTTP rejects stdio args/env, header auth requires bearer input, stdio rejects HTTP auth; downstream security validation applies (`H/hermes_cli/web_server_mcp.py:17–70`). Whole-map update has its own validator and must not be equated with single-server create.
- Cron: script path must remain inside the selected profile's scripts directory and exist as a file; no-agent requires a script; agent jobs need prompt, skill or script (`H/hermes_cli/web_server_cron.py:35–67`). Context references and registration have additional checks (`:70–79,233–267`); provider registration can fail with HTTP 424 rather than merely a form-validation error. Schedule parsing constraints remain in cron core and are not exhaustively transcribed here.
- Raw YAML PUT uses safe YAML parsing, requires a mapping and performs full replacement, with explicit approval indicator refresh (`R/analytics.py:51–70`). General config context-length conversion can coerce invalid input to zero (`H/hermes_cli/web_server_config.py:793–799`), so client validation must not mistake permissive coercion for acceptance of a meaningful intended value.

## 4. What is CLI-only, absent, or still unverified

- **Verified existing APIs:** typed settings/model/profile/skill/MCP/session/job edits, SOUL replacement and memory-node correction exist in the host tree. It would be incorrect to say these are all CLI-only.
- **Verified CLI-only limitation:** OAuth credential **pooling** is called out in `M:357–360`; normal provider OAuth has REST routes and must not be conflated with pooling.
- **CLI/setup dependency:** egress proxy enablement alone is insufficient; schema explicitly requires `hermes egress setup` and `hermes egress start` (`web_server_config.py:84–99`). Arbitrary OS permission grants, service installation and provider-specific setup cannot be represented honestly by generic toggle success.
- **Unverified/absent from inspected mobile transport:** admin route forwarding, admin capability negotiation, a profile-scoped admin token, field-level rights, revision/ETag preconditions, per-edit audit receipts, transactional config-plus-secret edits, general rollback, and complete apply/restart metadata.
- **Editing gaps:** stable concurrency-safe memory IDs; full arbitrary skill support-file editing through the typed skill API; typed project-instruction discovery/write route; session transcript rewrite; external-memory-provider record CRUD. Generic filesystem write is not evidence that a safe dedicated editor exists.
- **Deployment gaps:** live dashboard version and reachability, configured auth provider, allowed iOS callback, TLS/base path, granted rights, current runtime profile, managed fields, and exact boot-vs-disk revision. None was inferred from local source or relay online state.
- **“All toggles” gap:** default-backed schema omits empty maps and fields absent from defaults, while plugins add dynamic fields/options. Full support needs live schema + dedicated capability APIs + per-version adapters, not a hardcoded static form. Unknown keys should remain untouched and clearly marked unsupported until validated.

## 5. Recommended first implementation slice

**Connection identity + profile-scoped settings inspection + two narrow correction editors.** This is a recommendation, not code or new invented routes.

1. Add a separate `HermesAdminClient` abstraction, without changing the frozen capture/intelligence/backup path. Keep dashboard base URL, auth identity, serving profile, selected target profile and supported surface distinct from relay connection. Use only an operator-approved authenticated dashboard connection; prove iOS sign-in before shipping editable controls. Do not tunnel privileged traffic through existing streaming consent.
2. Read auth identity and explicit profile identity, then schema/model metadata and a secret-safe allowlisted settings view. Show unsupported/unverified features disabled with a reason. The server-side secret-safe projection is a prerequisite for unrestricted config inspection, not an existing verified route.
3. Start writes with **session title correction** (`PATCH /api/sessions/{session_id}` with only title/profile) and **SOUL.md editing** (named profile GET/PUT). Both have narrow existing targets and avoid positional memory IDs, installers, credentials and bulk-map replacement. Add one low-impact scalar settings edit only after validating its actual schema type and documented apply effect.
4. Each edit: read target → retain original locally only for the explicit edit → show exact host/profile/resource and before/after diff → re-read target to detect changes → explicit Apply → inspect HTTP and business result → GET exact target → compare canonical saved value → show “Saved” separately from runtime-applied. A client re-read reduces risk but **is not atomic conflict protection**; concurrent editing requires a future server precondition contract.
5. Next add learned-memory correction after stable IDs/revision checks; skill content editing after origin/support-file policy; models after cost confirmation; then MCP/tools/jobs/integrations with action-specific permissions and apply effects. Hold credential reveal, bulk deletion/reset, arbitrary filesystem editing, external installations and automatic restart outside the first slice.

Acceptance gates before claiming administration works:

- Real iOS → approved host sign-in and authenticated read; wrong-host/wrong-profile/expired-token failure demonstrated, no secret-bearing logs.
- Real write + exact GET readback in a user-authorized disposable resource/profile; no test writes to the live default profile merely to verify connectivity.
- Preserve omitted fields; explicitly send booleans/destructive flags rather than relying on defaults; handle 400/401/403/404/409/413 and HTTP-200 `ok:false`/`confirm_required`.
- Profile switch invalidates pending edits and caches. Offline/save-timeout is “outcome unknown” until readback, never synthetic success or blind duplicate retry.
- Memory stale-index race and config concurrent update are explicitly tested before those editors are called conflict-safe. Native UI/device testing remains deferred; this discovery did not run it.


## Appendix A. Static route register
This mechanically extracted register distinguishes HTTP reads from writes and includes adjacent administration features (plugins, curator, operations). It is not a live OpenAPI result or a claim that every GET is side-effect-free. Individual unexpanded handlers still require payload/security review before implementation. Relay sensor/talk routes appear only to document existing frozen scope, not as product recommendations.

### `H/hermes_cli/dashboard_auth/routes.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/login` | `login_page` :174–177 |
| GET | `/api/auth/providers` | `api_auth_providers` :181–189 |
| GET | `/auth/login` | `auth_login` :195–210 |
| GET | `/auth/native/authorize` | `auth_native_authorize` :243–274 |
| GET | `/auth/callback` | `auth_callback` :278–318 |
| POST | `/auth/password-login` | `auth_password_login` :360–405 |
| POST | `/auth/logout` | `auth_logout` :409–424 |
| GET | `/api/auth/me` | `api_auth_me` :437–442 |
| POST | `/api/auth/ws-ticket` | `api_auth_ws_ticket` :446–453 |
| POST | `/auth/native/token` | `auth_native_token` :464–475 |
| POST | `/auth/native/refresh` | `auth_native_refresh` :484–503 |

### `H/hermes_cli/web_routers/actions.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| POST | `/api/gateway/restart` | `restart_gateway` :139–143 |
| POST | `/api/gateway/drain` | `gateway_drain` :147–189 |
| POST | `/api/hermes/update` | `update_hermes` :201–230 |
| GET | `/api/hermes/update/check` | `check_hermes_update` :270–322 |
| GET | `/api/actions/{name}/status` | `get_action_status` :342–387 |
| GET | `/api/hermes/update/receipt` | `get_update_receipt` :424–435 |

### `H/hermes_cli/web_routers/analytics.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/config/raw` | `get_config_raw` :32–47 |
| PUT | `/api/config/raw` | `update_config_raw` :51–70 |
| GET | `/api/analytics/usage` | `get_usage_analytics` :142–150 |
| GET | `/api/analytics/models` | `get_models_analytics` :303–308 |

### `H/hermes_cli/web_routers/config_env.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/config` | `get_config` :77–84 |
| GET | `/api/config/defaults` | `get_defaults` :88–89 |
| GET | `/api/config/schema` | `get_schema` :93–99 |
| GET | `/api/egress/status` | `get_egress_status` :103–106 |
| PUT | `/api/config` | `update_config` :110–139 |
| GET | `/api/env` | `get_env_vars` :215–218 |
| PUT | `/api/env` | `set_env_var` :275–285 |
| GET | `/api/providers/custom-endpoints` | `list_custom_endpoints` :520–529 |
| POST | `/api/providers/custom-endpoints` | `upsert_custom_endpoint` :533–543 |
| POST | `/api/providers/custom-endpoints/{endpoint_id}/activate` | `activate_custom_endpoint` :547–583 |
| DELETE | `/api/providers/custom-endpoints/{endpoint_id}` | `delete_custom_endpoint` :587–607 |
| POST | `/api/providers/custom-endpoints/validate` | `validate_custom_endpoint` :611–635 |
| POST | `/api/providers/validate` | `validate_provider_credential` :639–695 |
| DELETE | `/api/env` | `remove_env_var` :699–713 |
| POST | `/api/env/reveal` | `reveal_env_var` :717–740 |

### `H/hermes_cli/web_routers/cron.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/cron/jobs` | `list_cron_jobs` :212–213 |
| GET | `/api/cron/jobs/{job_id}` | `get_cron_job` :217–218 |
| GET | `/api/cron/jobs/{job_id}/runs` | `list_cron_job_runs` :222–223 |
| POST | `/api/cron/jobs` | `create_cron_job` :227–228 |
| GET | `/api/cron/delivery-targets` | `get_cron_delivery_targets` :232–243 |
| PUT | `/api/cron/jobs/{job_id}` | `update_cron_job` :247–248 |
| POST | `/api/cron/jobs/{job_id}/pause` | `pause_cron_job` :252–253 |
| POST | `/api/cron/jobs/{job_id}/resume` | `resume_cron_job` :257–258 |
| POST | `/api/cron/jobs/{job_id}/trigger` | `trigger_cron_job` :262–263 |
| DELETE | `/api/cron/jobs/{job_id}` | `delete_cron_job` :267–268 |
| POST | `/api/cron/fire` | `cron_fire_webhook` :272–359 |
| GET | `/api/cron/blueprints` | `list_cron_blueprints` :363–389 |
| POST | `/api/cron/blueprints/instantiate` | `instantiate_blueprint` :393–420 |

### `H/hermes_cli/web_routers/dashboard_ui.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/dashboard/themes` | `get_dashboard_themes` :47–63 |
| PUT | `/api/dashboard/theme` | `set_dashboard_theme` :67–70 |
| GET | `/api/dashboard/font` | `get_dashboard_font` :86–92 |
| PUT | `/api/dashboard/font` | `set_dashboard_font` :96–101 |
| GET | `/api/dashboard/plugins` | `get_dashboard_plugins` :127–141 |
| GET | `/api/dashboard/plugins/rescan` | `rescan_dashboard_plugins` :145–148 |
| GET | `/api/dashboard/plugins/hub` | `get_plugins_hub` :152–159 |
| POST | `/api/dashboard/agent-plugins/install` | `post_agent_plugin_install` :174–182 |
| POST | `/api/dashboard/agent-plugins/{name:path}/enable` | `post_agent_plugin_enable` :199–202 |
| POST | `/api/dashboard/agent-plugins/{name:path}/disable` | `post_agent_plugin_disable` :206–209 |
| POST | `/api/dashboard/agent-plugins/{name:path}/update` | `post_agent_plugin_update` :213–215 |
| DELETE | `/api/dashboard/agent-plugins/{name:path}` | `delete_agent_plugin` :219–221 |
| PUT | `/api/dashboard/plugin-providers` | `put_plugin_providers` :225–241 |
| POST | `/api/dashboard/plugins/{name:path}/visibility` | `post_plugin_visibility` :245–267 |
| GET | `/dashboard-plugins/{plugin_name}/{file_path:path}` | `serve_plugin_asset` :282–310 |

### `H/hermes_cli/web_routers/mcp.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/mcp/servers` | `list_mcp_servers` :77–81 |
| POST | `/api/mcp/servers` | `add_mcp_server` :85–114 |
| PUT | `/api/mcp/servers` | `replace_mcp_servers` :118–131 |
| DELETE | `/api/mcp/servers/{name}` | `remove_mcp_server` :135–144 |
| POST | `/api/mcp/servers/{name}/test` | `test_mcp_server` :148–191 |
| POST | `/api/mcp/servers/{name}/auth` | `auth_mcp_server` :195–244 |
| GET | `/api/mcp/oauth/flows/{flow_id}` | `mcp_oauth_flow_status` :248–256 |
| DELETE | `/api/mcp/oauth/flows/{flow_id}` | `cancel_mcp_oauth_flow` :260–270 |
| GET | `/api/mcp/oauth/callback/{server_name:path}` | `mcp_oauth_callback` :274–302 |
| PUT | `/api/mcp/servers/{name}/enabled` | `set_mcp_server_enabled` :306–321 |
| GET | `/api/mcp/catalog` | `list_mcp_catalog` :360–388 |
| POST | `/api/mcp/catalog/install` | `install_mcp_catalog_entry` :392–451 |

### `H/hermes_cli/web_routers/memory_providers.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/memory/providers/{name}/config` | `get_memory_provider_config` :513–529 |
| POST | `/api/memory/providers/{name}/setup` | `setup_memory_provider` :533–546 |
| PUT | `/api/memory/providers/{name}/config` | `update_memory_provider_config` :550–576 |

### `H/hermes_cli/web_routers/messaging.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| POST | `/api/messaging/whatsapp/onboarding/start` | `start_whatsapp_onboarding` :519–540 |
| GET | `/api/messaging/whatsapp/onboarding/{pairing_id}` | `get_whatsapp_onboarding_status` :553–558 |
| POST | `/api/messaging/whatsapp/onboarding/{pairing_id}/apply` | `apply_whatsapp_onboarding` :562–589 |
| DELETE | `/api/messaging/whatsapp/onboarding/{pairing_id}` | `cancel_whatsapp_onboarding` :593–599 |
| POST | `/api/messaging/telegram/onboarding/start` | `start_telegram_onboarding` :650–669 |
| GET | `/api/messaging/telegram/onboarding/{pairing_id}` | `get_telegram_onboarding_status` :673–708 |
| POST | `/api/messaging/telegram/onboarding/{pairing_id}/apply` | `apply_telegram_onboarding` :712–748 |
| DELETE | `/api/messaging/telegram/onboarding/{pairing_id}` | `cancel_telegram_onboarding` :752–755 |
| GET | `/api/messaging/platforms` | `get_messaging_platforms` :762–776 |
| PUT | `/api/messaging/platforms/{platform_id}` | `update_messaging_platform` :823–869 |
| POST | `/api/messaging/platforms/{platform_id}/test` | `test_messaging_platform` :873–896 |

### `H/hermes_cli/web_routers/models.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/model/info` | `get_model_info` :52–96 |
| GET | `/api/model/options` | `get_model_options` :100–129 |
| GET | `/api/model/recommended-default` | `get_recommended_default_model` :161–191 |
| GET | `/api/model/auxiliary` | `get_auxiliary_models` :195–215 |
| GET | `/api/model/moa` | `get_moa_models` :219–226 |
| PUT | `/api/model/moa` | `set_moa_models` :250–279 |
| POST | `/api/model/set` | `set_model_assignment` :283–314 |

### `H/hermes_cli/web_routers/ops.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/pairing` | `list_pairing` :76–78 |
| POST | `/api/pairing/approve` | `approve_pairing` :82–104 |
| POST | `/api/pairing/revoke` | `revoke_pairing` :108–115 |
| POST | `/api/pairing/clear-pending` | `clear_pending_pairing` :119–120 |
| GET | `/api/webhooks` | `list_webhooks` :146–157 |
| POST | `/api/webhooks/enable` | `enable_webhooks` :161–171 |
| POST | `/api/webhooks` | `create_webhook` :175–215 |
| DELETE | `/api/webhooks/{name}` | `delete_webhook` :230–234 |
| PUT | `/api/webhooks/{name}/enabled` | `set_webhook_enabled` :238–244 |
| POST | `/api/gateway/start` | `start_gateway` :252–255 |
| POST | `/api/gateway/stop` | `stop_gateway` :259–262 |
| GET | `/api/credentials/pool` | `list_credential_pool` :292–314 |
| POST | `/api/credentials/pool` | `add_credential_pool_entry` :318–372 |
| DELETE | `/api/credentials/pool/{provider}/{index}` | `remove_credential_pool_entry` :376–424 |
| GET | `/api/memory` | `get_memory_status` :435–447 |
| PUT | `/api/memory/provider` | `set_memory_provider` :451–464 |
| POST | `/api/memory/reset` | `reset_memory` :468–483 |
| POST | `/api/ops/doctor` | `run_doctor` :492–493 |
| POST | `/api/ops/security-audit` | `run_security_audit` :497–501 |
| POST | `/api/ops/backup` | `run_backup` :509–523 |
| GET | `/api/ops/backup/download` | `download_dashboard_backup` :527–542 |
| POST | `/api/ops/import` | `run_import` :553–559 |
| POST | `/api/ops/import-upload` | `run_import_upload` :571–590 |
| GET | `/api/ops/hooks` | `list_hooks` :594–631 |
| POST | `/api/ops/hooks` | `create_hook` :643–685 |
| DELETE | `/api/ops/hooks` | `delete_hook` :689–719 |
| GET | `/api/ops/checkpoints` | `list_checkpoints` :723–746 |
| POST | `/api/ops/checkpoints/prune` | `prune_checkpoints` :750–754 |

### `H/hermes_cli/web_routers/profiles.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/profiles/sessions` | `get_profiles_sessions` :363–412 |
| GET | `/api/profiles/sessions/sidebar` | `get_profiles_sessions_sidebar` :417–499 |
| GET | `/api/profiles/projects/tree` | `get_profiles_projects_tree` :560–588 |
| POST | `/api/profiles/sessions/pull-requests` | `post_profiles_sessions_pull_requests` :609–631 |
| GET | `/api/profiles` | `list_profiles_endpoint` :635–642 |
| POST | `/api/profiles` | `create_profile_endpoint` :646–701 |
| GET | `/api/profiles/active` | `get_active_profile_endpoint` :705–720 |
| POST | `/api/profiles/active` | `set_active_profile_endpoint` :724–731 |
| GET | `/api/profiles/{name}/setup-command` | `get_profile_setup_command` :735–736 |
| POST | `/api/profiles/{name}/open-terminal` | `open_profile_terminal_endpoint` :756–774 |
| PATCH | `/api/profiles/{name}` | `rename_profile_endpoint` :778–793 |
| DELETE | `/api/profiles/{name}` | `delete_profile_endpoint` :797–805 |
| GET | `/api/profiles/{name}/soul` | `get_profile_soul` :809–821 |
| PUT | `/api/profiles/{name}/soul` | `update_profile_soul` :825–843 |
| PUT | `/api/profiles/{name}/description` | `update_profile_description_endpoint` :847–857 |
| PUT | `/api/profiles/{name}/model` | `update_profile_model_endpoint` :861–872 |
| POST | `/api/profiles/{name}/describe-auto` | `describe_profile_auto_endpoint` :876–893 |
| POST | `/api/profiles/{name}/export` | `export_profile_endpoint` :907–921 |
| POST | `/api/profiles/import` | `import_profile_endpoint` :925–949 |
| GET | `/api/profiles/{name}/desktop-overlay` | `get_profile_desktop_overlay` :953–967 |

### `H/hermes_cli/web_routers/sessions.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/sessions` | `get_sessions` :166–241 |
| GET | `/api/sessions/search` | `search_sessions` :255–389 |
| POST | `/api/sessions/bulk-delete` | `bulk_delete_sessions_endpoint` :393–406 |
| POST | `/api/sessions/import` | `import_sessions_endpoint` :410–429 |
| GET | `/api/sessions/empty/count` | `count_empty_sessions_endpoint` :433–437 |
| DELETE | `/api/sessions/empty` | `delete_empty_sessions_endpoint` :441–454 |
| GET | `/api/sessions/stats` | `get_session_stats` :458–473 |
| GET | `/api/sessions/{session_id}` | `get_session_detail` :477–489 |
| GET | `/api/sessions/{session_id}/latest-descendant` | `get_session_latest_descendant` :493–500 |
| GET | `/api/sessions/{session_id}/messages` | `get_session_messages` :529–561 |
| DELETE | `/api/sessions/{session_id}` | `delete_session_endpoint` :565–576 |
| POST | `/api/sessions/owner-backfill` | `backfill_session_owner_profiles` :580–606 |
| PATCH | `/api/sessions/{session_id}` | `rename_session_endpoint` :619–648 |
| GET | `/api/sessions/{session_id}/export` | `export_session_endpoint` :656–687 |
| POST | `/api/sessions/prune` | `prune_sessions_endpoint` :691–693 |

### `H/hermes_cli/web_routers/skills.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| POST | `/api/skills/hub/install` | `install_skill_hub` :98–103 |
| POST | `/api/skills/hub/uninstall` | `uninstall_skill_hub` :107–112 |
| POST | `/api/skills/hub/update` | `update_skills_hub` :116–120 |
| GET | `/api/skills/hub/official` | `list_official_skills` :124–144 |
| GET | `/api/skills/hub/sources` | `list_skills_hub_sources` :148–182 |
| GET | `/api/skills/hub/search` | `search_skills_hub` :186–215 |
| GET | `/api/skills/hub/preview` | `preview_skill_hub` :228–262 |
| GET | `/api/skills/hub/scan` | `scan_skill_hub` :266–340 |
| GET | `/api/skills` | `get_skills` :344–371 |
| PUT | `/api/skills/toggle` | `toggle_skill` :375–389 |
| GET | `/api/skills/content` | `get_skill_content` :393–410 |
| POST | `/api/skills` | `create_skill` :414–424 |
| PUT | `/api/skills/content` | `update_skill_content` :428–438 |

### `H/hermes_cli/web_routers/status.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/ssh/ownership` | `get_ssh_ownership` :101–107 |
| GET | `/api/health` | `get_health` :111–114 |
| GET | `/api/status` | `get_status` :378–466 |
| GET | `/api/system/stats` | `get_system_stats` :470–523 |
| GET | `/api/curator` | `get_curator_status` :530–542 |
| PUT | `/api/curator/paused` | `set_curator_paused` :546–549 |
| POST | `/api/curator/run` | `run_curator` :562–564 |
| GET | `/api/learning/graph` | `get_learning_graph` :568–580 |
| GET | `/api/learning/node` | `get_learning_node` :593–596 |
| DELETE | `/api/learning/node` | `delete_learning_node` :600–604 |
| PUT | `/api/learning/node` | `update_learning_node` :608–612 |
| GET | `/api/portal` | `get_portal_status` :619–622 |
| POST | `/api/ops/prompt-size` | `run_prompt_size` :666–667 |
| POST | `/api/ops/dump` | `run_dump` :671–672 |
| POST | `/api/ops/config-migrate` | `run_config_migrate` :676–677 |
| POST | `/api/ops/debug-share` | `run_debug_share_endpoint` :681–698 |
| GET | `/api/logs` | `get_logs` :702–735 |

### `H/hermes_cli/web_routers/tools.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/api/tools/toolsets` | `get_toolsets` :217–260 |
| PUT | `/api/tools/toolsets/{name}` | `toggle_toolset` :264–325 |
| GET | `/api/tools/toolsets/{name}/config` | `get_toolset_config` :329–401 |
| GET | `/api/tools/toolsets/{name}/models` | `get_toolset_models` :405–441 |
| PUT | `/api/tools/toolsets/{name}/model` | `select_toolset_model` :445–473 |
| PUT | `/api/tools/toolsets/{name}/provider` | `select_toolset_provider` :477–554 |
| PUT | `/api/tools/toolsets/{name}/env` | `save_toolset_env` :558–595 |
| POST | `/api/tools/toolsets/{name}/post-setup` | `run_toolset_post_setup` :599–614 |
| GET | `/api/tools/terminal/backends` | `get_terminal_backends` :618–641 |
| PUT | `/api/tools/terminal/backend` | `select_terminal_backend` :645–663 |
| GET | `/api/tools/computer-use/status` | `get_computer_use_status` :667–672 |
| POST | `/api/tools/computer-use/permissions/grant` | `grant_computer_use_permissions` :676–685 |

### `I/relay/app/main.py`
| Method | Registered route | Handler source lines |
|---|---|---|
| GET | `/v1/health` | `health` :526–527 |
| GET | `/v1/version` | `version` :530–537 |
| GET | `/v1/admin/status` | `admin_status` :540–573 |
| GET | `/v1/admin/audit` | `admin_audit` :576–600 |
| POST | `/v1/connector/setup` | `connector_setup` :603–653 |
| POST | `/v1/connector/phone-pairing-codes` | `create_phone_pairing` :656–683 |
| POST | `/v1/phone-pairing/redeem` | `redeem_phone_pairing` :686–747 |
| POST | `/v1/device/sensor/location` | `sensor_location` :752–769 |
| POST | `/v1/device/sensor/health` | `sensor_health` :772–793 |
| POST | `/v1/pairing/redeem` | `redeem_pairing` :859–911 |
| POST | `/v1/hosts/enrollment-codes` | `create_host_enrollment_code` :914–946 |
| GET | `/v1/hosts/current` | `current_host` :949–955 |
| GET | `/v1/commands` | `command_catalog` :958–975 |
| POST | `/v1/hosts/current/revoke` | `revoke_current_host` :978–992 |
| GET | `/v1/talk/readiness` | `talk_readiness` :995–1037 |
| POST | `/v1/talk/session` | `create_talk_session` :1040–1107 |
| POST | `/v1/talk/session/{voice_session_id}/end` | `end_talk_session` :1110–1139 |
| POST | `/v1/talk/session/{voice_session_id}/turns` | `create_talk_turn` :1142–1175 |
| POST | `/v1/talk/session/{voice_session_id}/inject` | `inject_talk_transcript` :1178–1207 |
| POST | `/v1/hosts/redeem` | `redeem_host` :1210–1246 |
| GET | `/v1/session` | `session` :1249–1281 |
| POST | `/v1/auth/refresh` | `refresh_auth` :1284–1310 |
| POST | `/v1/auth/revoke` | `revoke_auth` :1313–1328 |
| POST | `/v1/push/register` | `register_push` :1331–1361 |
| POST | `/v1/push/deactivate` | `deactivate_push` :1364–1393 |
| POST | `/v1/device/app-state` | `device_app_state` :1396–1418 |
| POST | `/v1/push/send` | `send_push` :1421–1503 |
| GET | `/v1/conversations/current` | `current_conversation` :1506–1510 |
| POST | `/v1/conversations/current/clear` | `clear_current_conversation` :1513–1529 |
| POST | `/v1/messages` | `create_message` :1532–1642 |
| GET | `/v1/jobs/{job_id}/events` | `job_events_stream` :1649–1713 |
| GET | `/v1/inbox` | `inbox` :1720–1722 |
| POST | `/v1/inbox/{item_id}/action` | `inbox_action` :1725–1750 |
| POST | `/internal/inbox/create` | `internal_create_inbox` :1753–1781 |
| GET | `/internal/inbox/{item_id}/actions` | `internal_inbox_actions` :1784–1799 |
| WEBSOCKET | `/v1/hosts/ws` | `hosts_websocket` :1802–2066 |

## Appendix B. Default-backed setting field paths (no values)
Extracted from the literal `DEFAULT_CONFIG` AST in `H/hermes_cli/config_defaults.py`, without importing Hermes or loading any profile. Types below are default-expression types, not validation constraints; schema overrides and dynamic providers can change presentation. Each listed leaf is a candidate for the schema builder, not evidence it is safe to edit or immediately live. Common R/W mechanism: profile-scoped GET schema/config and partial PUT config. Unknown apply effect must stay unknown until field-specific runtime verification.
| Field path | Default-expression type | Source line |
|---|---|---|
| `model` | string | `config_defaults.py:22` |
| `fallback_providers` | list | `config_defaults.py:24` |
| `toolsets` | list | `config_defaults.py:26` |
| `database.journal_mode` | string | `config_defaults.py:30` |
| `database.wal_autocheckpoint` | null (UI inferred string) | `config_defaults.py:32` |
| `database.journal_size_limit` | null (UI inferred string) | `config_defaults.py:33` |
| `runtime.nofile_soft_limit` | number | `config_defaults.py:36` |
| `max_concurrent_sessions` | null (UI inferred string) | `config_defaults.py:38` |
| `max_live_sessions` | number | `config_defaults.py:42` |
| `session.terminal_continue` | boolean | `config_defaults.py:47` |
| `agent.max_turns` | null (UI inferred string) | `config_defaults.py:52` |
| `agent.run_budget_seconds` | null (UI inferred string) | `config_defaults.py:56` |
| `agent.gateway_timeout` | number | `config_defaults.py:59` |
| `agent.gateway_turn_lease_timeout` | number | `config_defaults.py:63` |
| `agent.agent_cache.max_size` | number | `config_defaults.py:67` |
| `agent.agent_cache.idle_ttl_secs` | number | `config_defaults.py:68` |
| `agent.agent_cache.memory_high_mb` | string | `config_defaults.py:72` |
| `agent.agent_cache.max_evictions_per_pass` | number | `config_defaults.py:75` |
| `agent.agent_cache.protect_recent` | number | `config_defaults.py:76` |
| `agent.restart_drain_timeout` | number | `config_defaults.py:82` |
| `agent.cron_drain_timeout` | number | `config_defaults.py:90` |
| `agent.restart_after_turn_timeout` | number | `config_defaults.py:96` |
| `agent.build_wait_timeout` | number | `config_defaults.py:102` |
| `agent.api_max_retries` | number | `config_defaults.py:106` |
| `agent.empty_response_guard.enabled` | boolean | `config_defaults.py:111` |
| `agent.empty_response_guard.cost_threshold_usd` | number | `config_defaults.py:114` |
| `agent.service_tier` | string | `config_defaults.py:118` |
| `agent.fast_auto_seconds` | number | `config_defaults.py:119` |
| `agent.tool_use_enforcement` | string | `config_defaults.py:123` |
| `agent.execution_guidance` | string | `config_defaults.py:129` |
| `agent.intent_ack_continuation` | string | `config_defaults.py:135` |
| `agent.stall_guards` | boolean | `config_defaults.py:140` |
| `agent.task_completion_guidance` | boolean | `config_defaults.py:143` |
| `agent.parallel_tool_call_guidance` | boolean | `config_defaults.py:147` |
| `agent.environment_probe` | boolean | `config_defaults.py:151` |
| `agent.bot_mode_protocol` | boolean | `config_defaults.py:153` |
| `agent.environment_hint` | string | `config_defaults.py:157` |
| `agent.coding_context` | string | `config_defaults.py:164` |
| `agent.coding_instructions` | string | `config_defaults.py:168` |
| `agent.verify_guidance` | boolean | `config_defaults.py:172` |
| `agent.max_verify_nudges` | number | `config_defaults.py:174` |
| `agent.verify_on_stop` | boolean | `config_defaults.py:180` |
| `agent.gateway_timeout_warning` | number | `config_defaults.py:182` |
| `agent.clarify_timeout` | number | `config_defaults.py:190` |
| `agent.gateway_notify_interval` | number | `config_defaults.py:193` |
| `agent.session_stall_timeout` | number | `config_defaults.py:200` |
| `agent.sanitizer_heal_escalation_threshold` | number | `config_defaults.py:206` |
| `agent.reconnect_attention_after` | number | `config_defaults.py:210` |
| `agent.gateway_auto_continue_freshness` | number | `config_defaults.py:215` |
| `agent.gateway_startup_restore_drain_timeout` | number | `config_defaults.py:221` |
| `agent.gateway_startup_warmup_timeout` | number | `config_defaults.py:226` |
| `agent.local_stream_stale_timeout` | number | `config_defaults.py:231` |
| `agent.image_input_mode` | string | `config_defaults.py:237` |
| `agent.disabled_toolsets` | list | `config_defaults.py:238` |
| `agent.reasoning_echo` | boolean | `config_defaults.py:247` |
| `agent.turn_liveness.timeout_s` | number | `config_defaults.py:253` |
| `agent.turn_liveness.poll_s` | number | `config_defaults.py:253` |
| `terminal.backend` | string | `config_defaults.py:257` |
| `terminal.modal_mode` | string | `config_defaults.py:258` |
| `terminal.degraded_mode` | string | `config_defaults.py:262` |
| `terminal.cwd` | string | `config_defaults.py:263` |
| `terminal.temp_dir` | string | `config_defaults.py:268` |
| `terminal.font_family` | string | `config_defaults.py:272` |
| `terminal.timeout` | number | `config_defaults.py:273` |
| `terminal.daemon_term_grace_seconds` | number | `config_defaults.py:276` |
| `terminal.oneshot_completion_wait_seconds` | number | `config_defaults.py:284` |
| `terminal.env_passthrough` | list | `config_defaults.py:287` |
| `terminal.home_mode` | string | `config_defaults.py:291` |
| `terminal.shell_init_files` | list | `config_defaults.py:297` |
| `terminal.auto_source_bashrc` | boolean | `config_defaults.py:303` |
| `terminal.docker_image` | string | `config_defaults.py:304` |
| `terminal.docker_forward_env` | list | `config_defaults.py:305` |
| `terminal.singularity_image` | string | `config_defaults.py:310` |
| `terminal.modal_image` | string | `config_defaults.py:311` |
| `terminal.daytona_image` | string | `config_defaults.py:312` |
| `terminal.vercel_runtime` | string | `config_defaults.py:313` |
| `terminal.container_cpu` | number | `config_defaults.py:315` |
| `terminal.container_memory` | number | `config_defaults.py:316` |
| `terminal.container_disk` | number | `config_defaults.py:317` |
| `terminal.container_persistent` | boolean | `config_defaults.py:318` |
| `terminal.docker_volumes` | list | `config_defaults.py:322` |
| `terminal.docker_mount_cwd_to_workspace` | boolean | `config_defaults.py:323` |
| `terminal.docker_network` | boolean | `config_defaults.py:324` |
| `terminal.docker_extra_args` | list | `config_defaults.py:325` |
| `terminal.docker_shm_size` | string | `config_defaults.py:329` |
| `terminal.docker_run_as_host_user` | boolean | `config_defaults.py:334` |
| `terminal.docker_snap_compat` | boolean | `config_defaults.py:338` |
| `terminal.docker_shared_container_key` | string | `config_defaults.py:340` |
| `terminal.persistent_shell` | boolean | `config_defaults.py:343` |
| `web.backend` | string | `config_defaults.py:347` |
| `web.search_backend` | string | `config_defaults.py:348` |
| `web.extract_backend` | string | `config_defaults.py:349` |
| `web.extract_char_limit` | number | `config_defaults.py:351` |
| `web.keyless_fallback` | boolean | `config_defaults.py:355` |
| `web.keyless_rescue` | boolean | `config_defaults.py:359` |
| `web.cache_enabled` | boolean | `config_defaults.py:369` |
| `web.cache_ttl_minutes` | number | `config_defaults.py:370` |
| `web.cache_exempt_hosts` | list | `config_defaults.py:374` |
| `browser.backend` | string | `config_defaults.py:382` |
| `browser.inactivity_timeout` | number | `config_defaults.py:383` |
| `browser.command_timeout` | number | `config_defaults.py:384` |
| `browser.snapshot_threshold` | number | `config_defaults.py:385` |
| `browser.record_sessions` | boolean | `config_defaults.py:386` |
| `browser.headed` | boolean | `config_defaults.py:388` |
| `browser.allow_private_urls` | boolean | `config_defaults.py:389` |
| `browser.engine` | string | `config_defaults.py:395` |
| `browser.auto_local_for_private_urls` | boolean | `config_defaults.py:397` |
| `browser.cdp_url` | string | `config_defaults.py:398` |
| `browser.use_real_profile` | boolean | `config_defaults.py:407` |
| `browser.real_profile_autoclose` | boolean | `config_defaults.py:413` |
| `browser.real_profile_pin` | string | `config_defaults.py:417` |
| `browser.allow_unsafe_evaluate` | boolean | `config_defaults.py:421` |
| `browser.restrict_evaluate` | boolean | `config_defaults.py:422` |
| `browser.dialog_policy` | string | `config_defaults.py:426` |
| `browser.dialog_timeout_s` | number | `config_defaults.py:427` |
| `browser.camofox.managed_persistence` | boolean | `config_defaults.py:431` |
| `browser.camofox.user_id` | string | `config_defaults.py:433` |
| `browser.camofox.session_key` | string | `config_defaults.py:434` |
| `browser.camofox.adopt_existing_tab` | boolean | `config_defaults.py:435` |
| `browser.camofox.rewrite_loopback_urls` | boolean | `config_defaults.py:438` |
| `browser.camofox.loopback_host_alias` | string | `config_defaults.py:439` |
| `browser.extension_control.enabled` | boolean | `config_defaults.py:445` |
| `browser.extension_control.developer_mode` | boolean | `config_defaults.py:445` |
| `checkpoints.enabled` | boolean | `config_defaults.py:451` |
| `checkpoints.max_snapshots` | number | `config_defaults.py:453` |
| `checkpoints.max_total_size_mb` | number | `config_defaults.py:456` |
| `checkpoints.max_file_size_mb` | number | `config_defaults.py:458` |
| `checkpoints.auto_prune` | boolean | `config_defaults.py:464` |
| `checkpoints.retention_days` | number | `config_defaults.py:465` |
| `checkpoints.min_interval_hours` | number | `config_defaults.py:466` |
| `context_file_max_chars` | null (UI inferred string) | `config_defaults.py:471` |
| `context_file_read_timeout` | number | `config_defaults.py:474` |
| `file_read_max_chars` | number | `config_defaults.py:477` |
| `mcp_discovery_timeout` | number | `config_defaults.py:483` |
| `mcp_single_query_discovery_timeout` | number | `config_defaults.py:488` |
| `mcp.auto_reload_on_config_change` | boolean | `config_defaults.py:494` |
| `tool_output.max_bytes` | number | `config_defaults.py:499` |
| `tool_output.max_lines` | number | `config_defaults.py:499` |
| `tool_output.max_line_length` | number | `config_defaults.py:499` |
| `tool_loop_guardrails.warnings_enabled` | boolean | `config_defaults.py:503` |
| `tool_loop_guardrails.hard_stop_enabled` | boolean | `config_defaults.py:504` |
| `tool_loop_guardrails.non_interactive_hard_stop_enabled` | boolean | `config_defaults.py:507` |
| `tool_loop_guardrails.warn_after.exact_failure` | number | `config_defaults.py:508` |
| `tool_loop_guardrails.warn_after.same_tool_failure` | number | `config_defaults.py:508` |
| `tool_loop_guardrails.warn_after.idempotent_no_progress` | number | `config_defaults.py:508` |
| `tool_loop_guardrails.hard_stop_after.exact_failure` | number | `config_defaults.py:510` |
| `tool_loop_guardrails.hard_stop_after.same_tool_failure` | number | `config_defaults.py:510` |
| `tool_loop_guardrails.hard_stop_after.idempotent_no_progress` | number | `config_defaults.py:510` |
| `tool_loop_guardrails.loop_caps.max_web_searches` | number | `config_defaults.py:516` |
| `tool_loop_guardrails.loop_caps.max_subagents` | number | `config_defaults.py:517` |
| `compression.enabled` | boolean | `config_defaults.py:522` |
| `compression.checkpoint_required` | boolean | `config_defaults.py:525` |
| `compression.progress_notices` | boolean | `config_defaults.py:529` |
| `compression.threshold` | number | `config_defaults.py:533` |
| `compression.threshold_tokens` | null (UI inferred string) | `config_defaults.py:536` |
| `compression.target_ratio` | number | `config_defaults.py:538` |
| `compression.tail_mode` | string | `config_defaults.py:543` |
| `compression.protect_last_n` | number | `config_defaults.py:544` |
| `compression.min_tail_user_messages` | number | `config_defaults.py:547` |
| `compression.max_attempts` | number | `config_defaults.py:550` |
| `compression.proactive_prune_tokens` | number | `config_defaults.py:556` |
| `compression.proactive_prune_min_result_chars` | number | `config_defaults.py:559` |
| `compression.proactive_prune_min_reclaim_tokens` | number | `config_defaults.py:562` |
| `compression.micro_compact` | boolean | `config_defaults.py:567` |
| `compression.micro_compact_every_n_turns` | number | `config_defaults.py:570` |
| `compression.micro_compact_defrag_threshold_tokens` | number | `config_defaults.py:572` |
| `compression.hygiene_hard_message_limit` | number | `config_defaults.py:574` |
| `compression.hygiene_timeout_seconds` | number | `config_defaults.py:577` |
| `compression.hygiene_total_ceiling_seconds` | number | `config_defaults.py:580` |
| `compression.hygiene_failure_cooldown_seconds` | number | `config_defaults.py:581` |
| `compression.hygiene_max_turn_hold_seconds` | number | `config_defaults.py:586` |
| `compression.context_timeout_seconds` | number | `config_defaults.py:590` |
| `compression.context_total_ceiling_seconds` | number | `config_defaults.py:595` |
| `compression.protect_first_n` | number | `config_defaults.py:598` |
| `compression.abort_on_summary_failure` | boolean | `config_defaults.py:602` |
| `compression.codex_gpt55_autoraise` | boolean | `config_defaults.py:607` |
| `compression.codex_gpt55_autoraise_notice` | boolean | `config_defaults.py:609` |
| `compression.codex_app_server_auto` | string | `config_defaults.py:613` |
| `compression.codex_responses_native` | boolean | `config_defaults.py:616` |
| `compression.codex_responses_compact_threshold` | null (UI inferred string) | `config_defaults.py:619` |
| `compression.in_place` | boolean | `config_defaults.py:625` |
| `compression.idle_compact_after_seconds` | number | `config_defaults.py:634` |
| `prompt_caching.cache_ttl` | string | `config_defaults.py:639` |
| `openrouter.response_cache` | boolean | `config_defaults.py:646` |
| `openrouter.response_cache_ttl` | number | `config_defaults.py:646` |
| `openrouter.min_coding_score` | number | `config_defaults.py:646` |
| `bedrock.region` | string | `config_defaults.py:648` |
| `bedrock.discovery.enabled` | boolean | `config_defaults.py:650` |
| `bedrock.discovery.provider_filter` | list | `config_defaults.py:651` |
| `bedrock.discovery.refresh_interval` | number | `config_defaults.py:652` |
| `bedrock.guardrail.guardrail_identifier` | string | `config_defaults.py:657` |
| `bedrock.guardrail.guardrail_version` | string | `config_defaults.py:658` |
| `bedrock.guardrail.stream_processing_mode` | string | `config_defaults.py:659` |
| `bedrock.guardrail.trace` | string | `config_defaults.py:660` |
| `auxiliary.transient_retries` | number | `config_defaults.py:679` |
| `auxiliary.free_only` | boolean | `config_defaults.py:683` |
| `auxiliary.openrouter_model` | string | `config_defaults.py:687` |
| `auxiliary.stream_only_base_urls` | list | `config_defaults.py:691` |
| `auxiliary.vision.provider` | string | `config_defaults.py:14` |
| `auxiliary.vision.model` | string | `config_defaults.py:14` |
| `auxiliary.vision.base_url` | string | `config_defaults.py:14` |
| `auxiliary.vision.api_key` | string | `config_defaults.py:14` |
| `auxiliary.vision.timeout` | number | `config_defaults.py:14` |
| `auxiliary.vision.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.vision.download_timeout` | number | `config_defaults.py:696` |
| `auxiliary.compression.provider` | string | `config_defaults.py:14` |
| `auxiliary.compression.model` | string | `config_defaults.py:14` |
| `auxiliary.compression.base_url` | string | `config_defaults.py:14` |
| `auxiliary.compression.api_key` | string | `config_defaults.py:14` |
| `auxiliary.compression.timeout` | number | `config_defaults.py:14` |
| `auxiliary.compression.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.compression.max_output_tokens` | number | `config_defaults.py:700` |
| `auxiliary.skills_hub.provider` | string | `config_defaults.py:14` |
| `auxiliary.skills_hub.model` | string | `config_defaults.py:14` |
| `auxiliary.skills_hub.base_url` | string | `config_defaults.py:14` |
| `auxiliary.skills_hub.api_key` | string | `config_defaults.py:14` |
| `auxiliary.skills_hub.timeout` | number | `config_defaults.py:14` |
| `auxiliary.skills_hub.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.approval.provider` | string | `config_defaults.py:14` |
| `auxiliary.approval.model` | string | `config_defaults.py:14` |
| `auxiliary.approval.base_url` | string | `config_defaults.py:14` |
| `auxiliary.approval.api_key` | string | `config_defaults.py:14` |
| `auxiliary.approval.timeout` | number | `config_defaults.py:14` |
| `auxiliary.approval.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.review.provider` | string | `config_defaults.py:706` |
| `auxiliary.review.model` | string | `config_defaults.py:706` |
| `auxiliary.review.base_url` | string | `config_defaults.py:706` |
| `auxiliary.review.api_key` | string | `config_defaults.py:706` |
| `auxiliary.review.api_mode` | string | `config_defaults.py:706` |
| `auxiliary.mcp.provider` | string | `config_defaults.py:14` |
| `auxiliary.mcp.model` | string | `config_defaults.py:14` |
| `auxiliary.mcp.base_url` | string | `config_defaults.py:14` |
| `auxiliary.mcp.api_key` | string | `config_defaults.py:14` |
| `auxiliary.mcp.timeout` | number | `config_defaults.py:14` |
| `auxiliary.mcp.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.title_generation.enabled` | boolean | `config_defaults.py:710` |
| `auxiliary.title_generation.provider` | string | `config_defaults.py:714` |
| `auxiliary.title_generation.model` | string | `config_defaults.py:715` |
| `auxiliary.title_generation.prefer_fast_model` | boolean | `config_defaults.py:716` |
| `auxiliary.title_generation.base_url` | string | `config_defaults.py:717` |
| `auxiliary.title_generation.api_key` | string | `config_defaults.py:718` |
| `auxiliary.title_generation.timeout` | number | `config_defaults.py:719` |
| `auxiliary.title_generation.reasoning_effort` | string | `config_defaults.py:721` |
| `auxiliary.title_generation.language` | string | `config_defaults.py:722` |
| `auxiliary.memory_query_rewrite.provider` | string | `config_defaults.py:14` |
| `auxiliary.memory_query_rewrite.model` | string | `config_defaults.py:14` |
| `auxiliary.memory_query_rewrite.base_url` | string | `config_defaults.py:14` |
| `auxiliary.memory_query_rewrite.api_key` | string | `config_defaults.py:14` |
| `auxiliary.memory_query_rewrite.timeout` | number | `config_defaults.py:14` |
| `auxiliary.tts_audio_tags.provider` | string | `config_defaults.py:14` |
| `auxiliary.tts_audio_tags.model` | string | `config_defaults.py:14` |
| `auxiliary.tts_audio_tags.base_url` | string | `config_defaults.py:14` |
| `auxiliary.tts_audio_tags.api_key` | string | `config_defaults.py:14` |
| `auxiliary.tts_audio_tags.timeout` | number | `config_defaults.py:14` |
| `auxiliary.tts_audio_tags.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.triage_specifier.provider` | string | `config_defaults.py:14` |
| `auxiliary.triage_specifier.model` | string | `config_defaults.py:14` |
| `auxiliary.triage_specifier.base_url` | string | `config_defaults.py:14` |
| `auxiliary.triage_specifier.api_key` | string | `config_defaults.py:14` |
| `auxiliary.triage_specifier.timeout` | number | `config_defaults.py:14` |
| `auxiliary.triage_specifier.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.kanban_decomposer.provider` | string | `config_defaults.py:14` |
| `auxiliary.kanban_decomposer.model` | string | `config_defaults.py:14` |
| `auxiliary.kanban_decomposer.base_url` | string | `config_defaults.py:14` |
| `auxiliary.kanban_decomposer.api_key` | string | `config_defaults.py:14` |
| `auxiliary.kanban_decomposer.timeout` | number | `config_defaults.py:14` |
| `auxiliary.kanban_decomposer.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.profile_describer.provider` | string | `config_defaults.py:14` |
| `auxiliary.profile_describer.model` | string | `config_defaults.py:14` |
| `auxiliary.profile_describer.base_url` | string | `config_defaults.py:14` |
| `auxiliary.profile_describer.api_key` | string | `config_defaults.py:14` |
| `auxiliary.profile_describer.timeout` | number | `config_defaults.py:14` |
| `auxiliary.profile_describer.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.goal_judge.provider` | string | `config_defaults.py:14` |
| `auxiliary.goal_judge.model` | string | `config_defaults.py:14` |
| `auxiliary.goal_judge.base_url` | string | `config_defaults.py:14` |
| `auxiliary.goal_judge.api_key` | string | `config_defaults.py:14` |
| `auxiliary.goal_judge.timeout` | number | `config_defaults.py:14` |
| `auxiliary.goal_judge.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.curator.provider` | string | `config_defaults.py:14` |
| `auxiliary.curator.model` | string | `config_defaults.py:14` |
| `auxiliary.curator.base_url` | string | `config_defaults.py:14` |
| `auxiliary.curator.api_key` | string | `config_defaults.py:14` |
| `auxiliary.curator.timeout` | number | `config_defaults.py:14` |
| `auxiliary.curator.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.monitor.provider` | string | `config_defaults.py:14` |
| `auxiliary.monitor.model` | string | `config_defaults.py:14` |
| `auxiliary.monitor.base_url` | string | `config_defaults.py:14` |
| `auxiliary.monitor.api_key` | string | `config_defaults.py:14` |
| `auxiliary.monitor.timeout` | number | `config_defaults.py:14` |
| `auxiliary.monitor.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.background_review.enabled` | boolean | `config_defaults.py:741` |
| `auxiliary.background_review.provider` | string | `config_defaults.py:14` |
| `auxiliary.background_review.model` | string | `config_defaults.py:14` |
| `auxiliary.background_review.base_url` | string | `config_defaults.py:14` |
| `auxiliary.background_review.api_key` | string | `config_defaults.py:14` |
| `auxiliary.background_review.timeout` | number | `config_defaults.py:14` |
| `auxiliary.background_review.reasoning_effort` | string | `config_defaults.py:16` |
| `auxiliary.background_review.max_input_tokens` | number | `config_defaults.py:741` |
| `auxiliary.moa_reference.provider` | string | `config_defaults.py:14` |
| `auxiliary.moa_reference.model` | string | `config_defaults.py:14` |
| `auxiliary.moa_reference.base_url` | string | `config_defaults.py:14` |
| `auxiliary.moa_reference.api_key` | string | `config_defaults.py:14` |
| `auxiliary.moa_reference.timeout` | number | `config_defaults.py:14` |
| `auxiliary.moa_aggregator.provider` | string | `config_defaults.py:14` |
| `auxiliary.moa_aggregator.model` | string | `config_defaults.py:14` |
| `auxiliary.moa_aggregator.base_url` | string | `config_defaults.py:14` |
| `auxiliary.moa_aggregator.api_key` | string | `config_defaults.py:14` |
| `auxiliary.moa_aggregator.timeout` | number | `config_defaults.py:14` |
| `display.compact` | boolean | `config_defaults.py:749` |
| `display.personality` | string | `config_defaults.py:750` |
| `display.resume_display` | string | `config_defaults.py:751` |
| `display.resume_exchanges` | number | `config_defaults.py:753` |
| `display.resume_max_user_chars` | number | `config_defaults.py:754` |
| `display.resume_max_assistant_chars` | number | `config_defaults.py:755` |
| `display.resume_max_assistant_lines` | number | `config_defaults.py:756` |
| `display.resume_skip_tool_only` | boolean | `config_defaults.py:759` |
| `display.busy_input_mode` | string | `config_defaults.py:760` |
| `display.busy_steer_ack_enabled` | boolean | `config_defaults.py:763` |
| `display.cli_multiline_shortcuts` | boolean | `config_defaults.py:767` |
| `display.interface` | string | `config_defaults.py:770` |
| `display.tui_auto_resume_recent` | boolean | `config_defaults.py:773` |
| `display.resume_last_session` | boolean | `config_defaults.py:775` |
| `display.tui_agents_nudge` | boolean | `config_defaults.py:777` |
| `display.bell_on_complete` | boolean | `config_defaults.py:778` |
| `display.bell_on_prompt` | boolean | `config_defaults.py:779` |
| `display.show_reasoning` | boolean | `config_defaults.py:782` |
| `display.reasoning_full` | boolean | `config_defaults.py:785` |
| `display.memory_notifications` | string | `config_defaults.py:789` |
| `display.background_process_notifications` | string | `config_defaults.py:793` |
| `display.streaming` | boolean | `config_defaults.py:794` |
| `display.timestamps` | boolean | `config_defaults.py:795` |
| `display.timestamp_format` | string | `config_defaults.py:796` |
| `display.final_response_markdown` | string | `config_defaults.py:797` |
| `display.persistent_output` | boolean | `config_defaults.py:800` |
| `display.persistent_output_max_lines` | number | `config_defaults.py:801` |
| `display.cli_rebuild_scrollback_on_redraw` | boolean | `config_defaults.py:804` |
| `display.persist_prompts` | boolean | `config_defaults.py:806` |
| `display.inline_diffs` | boolean | `config_defaults.py:807` |
| `display.file_mutation_verifier` | boolean | `config_defaults.py:811` |
| `display.credits_notices` | boolean | `config_defaults.py:814` |
| `display.turn_completion_explainer` | boolean | `config_defaults.py:818` |
| `display.show_cost` | boolean | `config_defaults.py:819` |
| `display.battery` | boolean | `config_defaults.py:820` |
| `display.focus_view` | boolean | `config_defaults.py:824` |
| `display.focus_saved_tool_progress` | string | `config_defaults.py:825` |
| `display.skin` | string | `config_defaults.py:826` |
| `display.language` | string | `config_defaults.py:829` |
| `display.tui_status_indicator` | string | `config_defaults.py:831` |
| `display.cli_refresh_interval` | number | `config_defaults.py:836` |
| `display.user_message_preview.first_lines` | number | `config_defaults.py:838` |
| `display.user_message_preview.last_lines` | number | `config_defaults.py:839` |
| `display.interim_assistant_messages` | boolean | `config_defaults.py:843` |
| `display.show_commentary` | boolean | `config_defaults.py:846` |
| `display.tool_progress_command` | boolean | `config_defaults.py:847` |
| `display.tool_preview_length` | number | `config_defaults.py:850` |
| `display.friendly_tool_labels` | boolean | `config_defaults.py:853` |
| `display.turn_summary` | boolean | `config_defaults.py:856` |
| `display.spinner_token_flow` | boolean | `config_defaults.py:858` |
| `display.tool_progress_grouping` | string | `config_defaults.py:862` |
| `display.reasoning_style` | string | `config_defaults.py:871` |
| `display.ephemeral_system_ttl` | number | `config_defaults.py:875` |
| `display.platforms.telegram.streaming` | boolean | `config_defaults.py:881` |
| `display.platforms.discord.streaming` | boolean | `config_defaults.py:882` |
| `display.platforms.slack.streaming` | boolean | `config_defaults.py:883` |
| `display.platforms.wecom.streaming` | boolean | `config_defaults.py:885` |
| `display.runtime_footer.enabled` | boolean | `config_defaults.py:890` |
| `display.runtime_footer.fields` | list | `config_defaults.py:891` |
| `display.status_bar.fields` | list | `config_defaults.py:900` |
| `display.copy_shortcut` | string | `config_defaults.py:902` |
| `display.pet.enabled` | boolean | `config_defaults.py:906` |
| `display.pet.slug` | string | `config_defaults.py:907` |
| `display.pet.render_mode` | string | `config_defaults.py:910` |
| `display.pet.scale` | number | `config_defaults.py:913` |
| `display.pet.unicode_cols` | number | `config_defaults.py:914` |
| `dashboard.theme` | string | `config_defaults.py:920` |
| `dashboard.turn_isolation` | boolean | `config_defaults.py:923` |
| `dashboard.compute_host_heartbeat_secs` | number | `config_defaults.py:924` |
| `dashboard.compute_host_respawn_max` | number | `config_defaults.py:925` |
| `dashboard.show_token_analytics` | boolean | `config_defaults.py:930` |
| `dashboard.trusted_proxies` | list | `config_defaults.py:933` |
| `dashboard.ws_ping_interval` | number | `config_defaults.py:936` |
| `dashboard.ws_ping_timeout` | number | `config_defaults.py:937` |
| `dashboard.ws_orphan_reap_grace_s` | number | `config_defaults.py:940` |
| `dashboard.ws_orphan_activity_stale_s` | number | `config_defaults.py:945` |
| `dashboard.startup_orphan_sweep` | boolean | `config_defaults.py:953` |
| `dashboard.oauth.client_id` | string | `config_defaults.py:958` |
| `dashboard.oauth.portal_url` | string | `config_defaults.py:959` |
| `dashboard.basic_auth.username` | string | `config_defaults.py:968` |
| `dashboard.basic_auth.password_hash` | string | `config_defaults.py:969` |
| `dashboard.basic_auth.password` | string | `config_defaults.py:970` |
| `dashboard.basic_auth.secret` | string | `config_defaults.py:971` |
| `dashboard.basic_auth.session_ttl_seconds` | number | `config_defaults.py:972` |
| `dashboard.drain_auth.scope` | string | `config_defaults.py:977` |
| `dashboard.drain_auth.min_secret_chars` | number | `config_defaults.py:977` |
| `dashboard.public_url` | string | `config_defaults.py:984` |
| `privacy.redact_pii` | boolean | `config_defaults.py:988` |
| `tts.provider` | string | `config_defaults.py:997` |
| `tts.edge.voice` | string | `config_defaults.py:1000` |
| `tts.elevenlabs.voice_id` | string | `config_defaults.py:1003` |
| `tts.elevenlabs.model_id` | string | `config_defaults.py:1004` |
| `tts.openai.model` | string | `config_defaults.py:1007` |
| `tts.openai.voice` | string | `config_defaults.py:1010` |
| `tts.gemini.model` | string | `config_defaults.py:1013` |
| `tts.gemini.voice` | string | `config_defaults.py:1014` |
| `tts.gemini.audio_tags` | boolean | `config_defaults.py:1016` |
| `tts.gemini.persona_prompt_file` | string | `config_defaults.py:1019` |
| `tts.xai.voice_id` | string | `config_defaults.py:1022` |
| `tts.xai.language` | string | `config_defaults.py:1023` |
| `tts.xai.speed` | number | `config_defaults.py:1024` |
| `tts.xai.auto_speech_tags` | boolean | `config_defaults.py:1025` |
| `tts.xai.optimize_streaming_latency` | number | `config_defaults.py:1026` |
| `tts.xai.sample_rate` | number | `config_defaults.py:1027` |
| `tts.xai.bit_rate` | number | `config_defaults.py:1028` |
| `tts.mistral.model` | string | `config_defaults.py:1031` |
| `tts.mistral.voice_id` | string | `config_defaults.py:1032` |
| `tts.minimax.model` | string | `config_defaults.py:1034` |
| `tts.minimax.voice_id` | string | `config_defaults.py:1034` |
| `tts.kittentts.model` | string | `config_defaults.py:1036` |
| `tts.kittentts.voice` | string | `config_defaults.py:1037` |
| `tts.neutts.ref_audio` | string | `config_defaults.py:1040` |
| `tts.neutts.ref_text` | string | `config_defaults.py:1041` |
| `tts.neutts.model` | string | `config_defaults.py:1042` |
| `tts.neutts.device` | string | `config_defaults.py:1043` |
| `tts.piper.voice` | string | `config_defaults.py:1050` |
| `tts.deepinfra.model` | string | `config_defaults.py:1053` |
| `tts.deepinfra.voice` | string | `config_defaults.py:1054` |
| `stt.enabled` | boolean | `config_defaults.py:1060` |
| `stt.echo_transcripts` | boolean | `config_defaults.py:1062` |
| `stt.language` | string | `config_defaults.py:1067` |
| `stt.cloud_trim_silence` | boolean | `config_defaults.py:1070` |
| `stt.cloud_trim_threshold_db` | number | `config_defaults.py:1071` |
| `stt.cloud_trim_keep_ms` | number | `config_defaults.py:1072` |
| `stt.local.model` | string | `config_defaults.py:1074` |
| `stt.local.language` | string | `config_defaults.py:1075` |
| `stt.local.initial_prompt` | string | `config_defaults.py:1076` |
| `stt.local.vad` | boolean | `config_defaults.py:1080` |
| `stt.local.vad_min_silence_ms` | number | `config_defaults.py:1081` |
| `stt.local.no_speech_prob_threshold` | number | `config_defaults.py:1082` |
| `stt.local.logprob_threshold` | number | `config_defaults.py:1083` |
| `stt.local.unload_after_idle_seconds` | number | `config_defaults.py:1084` |
| `stt.groq.model` | string | `config_defaults.py:1088` |
| `stt.groq.language` | string | `config_defaults.py:1089` |
| `stt.openai.model` | string | `config_defaults.py:1093` |
| `stt.openai.language` | string | `config_defaults.py:1094` |
| `stt.mistral.model` | string | `config_defaults.py:1097` |
| `stt.mistral.language` | string | `config_defaults.py:1098` |
| `stt.xai.language` | string | `config_defaults.py:1101` |
| `stt.elevenlabs.model_id` | string | `config_defaults.py:1104` |
| `stt.elevenlabs.language_code` | string | `config_defaults.py:1105` |
| `stt.elevenlabs.tag_audio_events` | boolean | `config_defaults.py:1106` |
| `stt.elevenlabs.diarize` | boolean | `config_defaults.py:1107` |
| `stt.deepinfra.model` | string | `config_defaults.py:1110` |
| `voice.record_key` | string | `config_defaults.py:1116` |
| `voice.submit_mode` | string | `config_defaults.py:1117` |
| `voice.max_recording_seconds` | number | `config_defaults.py:1118` |
| `voice.auto_tts` | boolean | `config_defaults.py:1119` |
| `voice.client_direct` | boolean | `config_defaults.py:1122` |
| `voice.beep_enabled` | boolean | `config_defaults.py:1123` |
| `voice.beep_volume` | number | `config_defaults.py:1124` |
| `voice.thinking_sound` | boolean | `config_defaults.py:1125` |
| `voice.silence_threshold` | number | `config_defaults.py:1126` |
| `voice.silence_duration` | number | `config_defaults.py:1127` |
| `voice.barge_in` | boolean | `config_defaults.py:1128` |
| `voice.barge_in_grace_seconds` | number | `config_defaults.py:1130` |
| `voice.barge_in_threshold_multiplier` | number | `config_defaults.py:1132` |
| `voice.stop_phrases` | list | `config_defaults.py:1135` |
| `wake_word.enabled` | boolean | `config_defaults.py:1140` |
| `wake_word.surface` | string | `config_defaults.py:1141` |
| `wake_word.input_device` | null (UI inferred string) | `config_defaults.py:1142` |
| `wake_word.capture` | string | `config_defaults.py:1143` |
| `wake_word.provider` | string | `config_defaults.py:1146` |
| `wake_word.phrase` | string | `config_defaults.py:1149` |
| `wake_word.sensitivity` | number | `config_defaults.py:1150` |
| `wake_word.confirmation_frames` | number | `config_defaults.py:1153` |
| `wake_word.start_new_session` | boolean | `config_defaults.py:1154` |
| `wake_word.profile_routing` | boolean | `config_defaults.py:1156` |
| `wake_word.openwakeword.model` | string | `config_defaults.py:1160` |
| `wake_word.openwakeword.inference_framework` | string | `config_defaults.py:1163` |
| `wake_word.sherpa.model_dir` | string | `config_defaults.py:1167` |
| `wake_word.porcupine.keyword` | string | `config_defaults.py:1171` |
| `human_delay.mode` | string | `config_defaults.py:1175` |
| `human_delay.min_ms` | number | `config_defaults.py:1175` |
| `human_delay.max_ms` | number | `config_defaults.py:1175` |
| `context.engine` | string | `config_defaults.py:1181` |
| `context.memory_trim.enabled` | boolean | `config_defaults.py:1184` |
| `context.memory_trim.cooldown_seconds` | number | `config_defaults.py:1185` |
| `context.memory_trim.log_every_n` | number | `config_defaults.py:1186` |
| `context.memory_trim.info_log_min_delta_mb` | number | `config_defaults.py:1188` |
| `memory.memory_enabled` | boolean | `config_defaults.py:1192` |
| `memory.user_profile_enabled` | boolean | `config_defaults.py:1193` |
| `memory.write_approval` | boolean | `config_defaults.py:1197` |
| `memory.memory_char_limit` | number | `config_defaults.py:1198` |
| `memory.user_char_limit` | number | `config_defaults.py:1199` |
| `memory.nudge_interval` | number | `config_defaults.py:1201` |
| `memory.provider` | string | `config_defaults.py:1204` |
| `delegation.model` | string | `config_defaults.py:1210` |
| `delegation.provider` | string | `config_defaults.py:1211` |
| `delegation.base_url` | string | `config_defaults.py:1212` |
| `delegation.api_key` | string | `config_defaults.py:1213` |
| `delegation.api_mode` | string | `config_defaults.py:1217` |
| `delegation.inherit_mcp_toolsets` | boolean | `config_defaults.py:1225` |
| `delegation.max_iterations` | number | `config_defaults.py:1227` |
| `delegation.max_summary_chars` | number | `config_defaults.py:1232` |
| `delegation.child_timeout_seconds` | number | `config_defaults.py:1235` |
| `delegation.reasoning_effort` | string | `config_defaults.py:1238` |
| `delegation.max_concurrent_children` | number | `config_defaults.py:1241` |
| `delegation.max_spawn_depth` | number | `config_defaults.py:1243` |
| `delegation.orchestrator_enabled` | boolean | `config_defaults.py:1244` |
| `delegation.subagent_auto_approve` | boolean | `config_defaults.py:1248` |
| `delegation.surface_child_process_notifications` | boolean | `config_defaults.py:1252` |
| `prefill_messages_file` | string | `config_defaults.py:1256` |
| `goals.max_turns` | number | `config_defaults.py:1263` |
| `loops.min_interval_seconds` | number | `config_defaults.py:1269` |
| `loops.max_ticks` | number | `config_defaults.py:1270` |
| `loops.self_paced_floor_seconds` | number | `config_defaults.py:1271` |
| `loops.self_paced_ceiling_seconds` | number | `config_defaults.py:1272` |
| `moa.default_preset` | string | `config_defaults.py:1278` |
| `moa.active_preset` | string | `config_defaults.py:1279` |
| `moa.save_traces` | boolean | `config_defaults.py:1282` |
| `moa.trace_dir` | string | `config_defaults.py:1283` |
| `moa.privacy_filter` | string | `config_defaults.py:1291` |
| `moa.presets.default.reference_models` | list | `config_defaults.py:1294` |
| `moa.presets.default.aggregator.provider` | string | `config_defaults.py:1298` |
| `moa.presets.default.aggregator.model` | string | `config_defaults.py:1298` |
| `moa.presets.default.max_tokens` | number | `config_defaults.py:1299` |
| `moa.presets.default.enabled` | boolean | `config_defaults.py:1300` |
| `skills.external_dirs` | list | `config_defaults.py:1307` |
| `skills.create_dir` | string | `config_defaults.py:1311` |
| `skills.project_discovery` | boolean | `config_defaults.py:1315` |
| `skills.trusted_project_dirs` | list | `config_defaults.py:1317` |
| `skills.template_vars` | boolean | `config_defaults.py:1319` |
| `skills.inline_shell` | boolean | `config_defaults.py:1322` |
| `skills.inline_shell_timeout` | number | `config_defaults.py:1323` |
| `skills.guard_agent_created` | boolean | `config_defaults.py:1327` |
| `skills.tier1_advisory` | boolean | `config_defaults.py:1332` |
| `skills.write_approval` | boolean | `config_defaults.py:1336` |
| `skills.ledger` | boolean | `config_defaults.py:1341` |
| `curator.enabled` | boolean | `config_defaults.py:1348` |
| `curator.interval_hours` | expression; runtime type unverified | `config_defaults.py:1349` |
| `curator.min_idle_hours` | number | `config_defaults.py:1350` |
| `curator.stale_after_days` | number | `config_defaults.py:1351` |
| `curator.archive_after_days` | number | `config_defaults.py:1352` |
| `curator.consolidate` | boolean | `config_defaults.py:1355` |
| `curator.prune_builtins` | boolean | `config_defaults.py:1359` |
| `curator.archive_ttl_days` | number | `config_defaults.py:1362` |
| `curator.backup.enabled` | boolean | `config_defaults.py:1366` |
| `curator.backup.keep` | number | `config_defaults.py:1367` |
| `timezone` | string | `config_defaults.py:1374` |
| `slack.require_mention` | boolean | `config_defaults.py:1377` |
| `slack.free_response_channels` | string | `config_defaults.py:1378` |
| `slack.allowed_channels` | string | `config_defaults.py:1379` |
| `slack.require_mention_channels` | string | `config_defaults.py:1380` |
| `slack.ignore_other_user_mentions` | boolean | `config_defaults.py:1383` |
| `slack.thread_require_mention` | boolean | `config_defaults.py:1384` |
| `discord.require_mention` | boolean | `config_defaults.py:1389` |
| `discord.free_response_channels` | string | `config_defaults.py:1390` |
| `discord.allowed_channels` | string | `config_defaults.py:1391` |
| `discord.auto_thread` | boolean | `config_defaults.py:1392` |
| `discord.thread_require_mention` | boolean | `config_defaults.py:1393` |
| `discord.bots_require_inline_mention` | boolean | `config_defaults.py:1396` |
| `discord.history_backfill` | boolean | `config_defaults.py:1399` |
| `discord.history_backfill_limit` | number | `config_defaults.py:1400` |
| `discord.missed_message_backfill.enabled` | boolean | `config_defaults.py:1403` |
| `discord.missed_message_backfill.channels` | string | `config_defaults.py:1404` |
| `discord.missed_message_backfill.window_seconds` | number | `config_defaults.py:1405` |
| `discord.missed_message_backfill.limit` | number | `config_defaults.py:1406` |
| `discord.missed_message_backfill.max_dispatches` | number | `config_defaults.py:1407` |
| `discord.reactions` | boolean | `config_defaults.py:1409` |
| `discord.websocket_liveness_interval_seconds` | number | `config_defaults.py:1412` |
| `discord.websocket_liveness_failure_threshold` | number | `config_defaults.py:1413` |
| `discord.websocket_heartbeat_ack_max_age_seconds` | number | `config_defaults.py:1414` |
| `discord.websocket_max_latency_seconds` | number | `config_defaults.py:1415` |
| `discord.dm_role_auth_guild` | string | `config_defaults.py:1422` |
| `discord.server_actions` | string | `config_defaults.py:1427` |
| `discord.allow_any_attachment` | boolean | `config_defaults.py:1430` |
| `discord.max_attachment_bytes` | number | `config_defaults.py:1433` |
| `discord.approval_mentions` | boolean | `config_defaults.py:1436` |
| `discord.voice_channel_inactivity_timeout_seconds` | number | `config_defaults.py:1438` |
| `discord.voice_playback_timeout_seconds` | number | `config_defaults.py:1441` |
| `discord.voice_fx.enabled` | boolean | `config_defaults.py:1445` |
| `discord.voice_fx.ambient_enabled` | boolean | `config_defaults.py:1446` |
| `discord.voice_fx.ambient_path` | string | `config_defaults.py:1447` |
| `discord.voice_fx.ambient_gain` | number | `config_defaults.py:1448` |
| `discord.voice_fx.duck_gain` | number | `config_defaults.py:1449` |
| `discord.voice_fx.speech_gain` | number | `config_defaults.py:1450` |
| `discord.voice_fx.ack_enabled` | boolean | `config_defaults.py:1451` |
| `discord.voice_fx.ack_phrases` | list | `config_defaults.py:1452` |
| `telegram.reactions` | boolean | `config_defaults.py:1467` |
| `telegram.allowed_chats` | string | `config_defaults.py:1470` |
| `telegram.extra.rich_messages` | boolean | `config_defaults.py:1474` |
| `telegram.extra.rich_drafts` | boolean | `config_defaults.py:1477` |
| `mattermost.require_mention` | boolean | `config_defaults.py:1482` |
| `mattermost.free_response_channels` | string | `config_defaults.py:1483` |
| `mattermost.allowed_channels` | string | `config_defaults.py:1484` |
| `matrix.require_mention` | boolean | `config_defaults.py:1489` |
| `matrix.free_response_rooms` | string | `config_defaults.py:1490` |
| `matrix.allowed_rooms` | string | `config_defaults.py:1491` |
| `approvals.mode` | string | `config_defaults.py:1516` |
| `approvals.timeout` | number | `config_defaults.py:1517` |
| `approvals.cron_mode` | string | `config_defaults.py:1518` |
| `approvals.single_query_mode` | string | `config_defaults.py:1519` |
| `approvals.unattended_mode` | string | `config_defaults.py:1520` |
| `approvals.smart_policy` | string | `config_defaults.py:1523` |
| `approvals.denial_breaker_threshold` | number | `config_defaults.py:1526` |
| `approvals.deny` | list | `config_defaults.py:1530` |
| `approvals.mcp_reload_confirm` | boolean | `config_defaults.py:1533` |
| `approvals.destructive_slash_confirm` | boolean | `config_defaults.py:1537` |
| `command_allowlist` | list | `config_defaults.py:1540` |
| `plugins.hook_callback_timeout` | number | `config_defaults.py:1553` |
| `plugins.allow_deprecated_imports` | boolean | `config_defaults.py:1557` |
| `hooks_auto_accept` | boolean | `config_defaults.py:1567` |
| `security.allow_private_urls` | boolean | `config_defaults.py:1572` |
| `security.redact_secrets` | boolean | `config_defaults.py:1573` |
| `security.allow_data_training_tiers_noninteractive` | boolean | `config_defaults.py:1576` |
| `security.approval.transport` | string | `config_defaults.py:1581` |
| `security.approval.transport_fallback` | string | `config_defaults.py:1581` |
| `security.protected_instruction_files` | boolean | `config_defaults.py:1585` |
| `security.protected_instruction_extra_patterns` | list | `config_defaults.py:1586` |
| `security.tirith_enabled` | boolean | `config_defaults.py:1587` |
| `security.tirith_path` | string | `config_defaults.py:1588` |
| `security.tirith_timeout` | number | `config_defaults.py:1589` |
| `security.tirith_fail_open` | boolean | `config_defaults.py:1590` |
| `security.website_blocklist.enabled` | boolean | `config_defaults.py:1591` |
| `security.website_blocklist.domains` | list | `config_defaults.py:1591` |
| `security.website_blocklist.shared_files` | list | `config_defaults.py:1591` |
| `security.acked_advisories` | list | `config_defaults.py:1595` |
| `security.allow_lazy_installs` | boolean | `config_defaults.py:1599` |
| `cron.allow_agent_scheduling` | boolean | `config_defaults.py:1607` |
| `cron.preflight` | boolean | `config_defaults.py:1612` |
| `cron.model_drift_guard` | boolean | `config_defaults.py:1616` |
| `cron.model` | string | `config_defaults.py:1620` |
| `cron.model_provider` | string | `config_defaults.py:1623` |
| `cron.provider` | string | `config_defaults.py:1628` |
| `cron.chronos.portal_url` | string | `config_defaults.py:1634` |
| `cron.chronos.callback_url` | string | `config_defaults.py:1637` |
| `cron.chronos.expected_audience` | string | `config_defaults.py:1638` |
| `cron.chronos.nas_jwks_url` | string | `config_defaults.py:1641` |
| `cron.wrap_response` | boolean | `config_defaults.py:1645` |
| `cron.delivery.notify` | boolean | `config_defaults.py:1650` |
| `cron.mirror_delivery` | boolean | `config_defaults.py:1658` |
| `cron.max_parallel_jobs` | null (UI inferred string) | `config_defaults.py:1661` |
| `cron.output_retention` | number | `config_defaults.py:1664` |
| `cron.script_timeout_seconds` | number | `config_defaults.py:1667` |
| `cron.session_db_timeout_seconds` | number | `config_defaults.py:1671` |
| `cron.media_send_timeout_seconds` | number | `config_defaults.py:1675` |
| `kanban.auto_subscribe_on_create` | boolean | `config_defaults.py:1684` |
| `kanban.dispatch_in_gateway` | boolean | `config_defaults.py:1687` |
| `kanban.review_dispatch` | boolean | `config_defaults.py:1690` |
| `kanban.dispatch_interval_seconds` | number | `config_defaults.py:1692` |
| `kanban.failure_limit` | number | `config_defaults.py:1695` |
| `kanban.worker_log_rotate_bytes` | expression; runtime type unverified | `config_defaults.py:1698` |
| `kanban.worker_log_backup_count` | number | `config_defaults.py:1699` |
| `kanban.orchestrator_profile` | string | `config_defaults.py:1702` |
| `kanban.default_assignee` | string | `config_defaults.py:1705` |
| `kanban.max_in_progress` | null (UI inferred string) | `config_defaults.py:1716` |
| `kanban.max_in_progress_per_profile` | null (UI inferred string) | `config_defaults.py:1723` |
| `kanban.auto_decompose` | boolean | `config_defaults.py:1726` |
| `kanban.auto_decompose_per_tick` | number | `config_defaults.py:1729` |
| `kanban.dispatch_stale_timeout_seconds` | number | `config_defaults.py:1732` |
| `kanban.reconcile_orphans` | boolean | `config_defaults.py:1736` |
| `kanban.done_sub_retention_days` | number | `config_defaults.py:1740` |
| `bot_mode.envelope_ttl_seconds` | number | `config_defaults.py:1748` |
| `bot_mode.turn_wait_seconds` | number | `config_defaults.py:1752` |
| `code_execution.mode` | string | `config_defaults.py:1759` |
| `code_execution.kernel_idle_timeout` | number | `config_defaults.py:1767` |
| `code_execution.max_session_kernels` | number | `config_defaults.py:1768` |
| `tools.tool_search.enabled` | string | `config_defaults.py:1782` |
| `tools.tool_search.threshold_pct` | number | `config_defaults.py:1785` |
| `tools.tool_search.search_default_limit` | number | `config_defaults.py:1787` |
| `tools.tool_search.max_search_limit` | number | `config_defaults.py:1789` |
| `tools.tool_search.listing` | string | `config_defaults.py:1794` |
| `tools.tool_search.listing_max_tokens` | number | `config_defaults.py:1797` |
| `logging.level` | string | `config_defaults.py:1801` |
| `logging.max_size_mb` | number | `config_defaults.py:1802` |
| `logging.backup_count` | number | `config_defaults.py:1803` |
| `model_catalog.enabled` | boolean | `config_defaults.py:1809` |
| `model_catalog.url` | string | `config_defaults.py:1810` |
| `model_catalog.ttl_minutes` | number | `config_defaults.py:1814` |
| `models_dev.url` | string | `config_defaults.py:1835` |
| `network.force_ipv4` | boolean | `config_defaults.py:1841` |
| `monitoring.install_id` | string | `config_defaults.py:1850` |
| `monitoring.gateway_health_export.enabled` | boolean | `config_defaults.py:1852` |
| `monitoring.gateway_health_export.metrics_enabled` | boolean | `config_defaults.py:1853` |
| `monitoring.gateway_health_export.diagnostic_events_enabled` | boolean | `config_defaults.py:1854` |
| `monitoring.gateway_health_export.warning_error_events_enabled` | boolean | `config_defaults.py:1855` |
| `monitoring.gateway_health_export.export_interval_seconds` | number | `config_defaults.py:1856` |
| `monitoring.gateway_health_export.logs_export_interval_seconds` | number | `config_defaults.py:1857` |
| `monitoring.gateway_health_export.resource_attributes.service.name` | string | `config_defaults.py:1859` |
| `monitoring.gateway_health_export.resource_attributes.deployment.environment.name` | string | `config_defaults.py:1859` |
| `monitoring.export.otlp.enabled` | boolean | `config_defaults.py:1864` |
| `monitoring.export.otlp.endpoint` | string | `config_defaults.py:1864` |
| `gateway.multiplex_profile_allowlist` | null (UI inferred string) | `config_defaults.py:1868` |
| `gateway.signal_interrupt_grace_timeout` | number | `config_defaults.py:1871` |
| `gateway.delivery_ledger` | boolean | `config_defaults.py:1876` |
| `gateway.platform_connect_timeout` | number | `config_defaults.py:1885` |
| `gateway.loop_watchdog` | boolean | `config_defaults.py:1890` |
| `gateway.loop_watchdog_probe_interval_s` | number | `config_defaults.py:1895` |
| `gateway.loop_watchdog_probe_timeout_s` | number | `config_defaults.py:1896` |
| `gateway.loop_watchdog_max_strikes` | number | `config_defaults.py:1897` |
| `gateway.startup_watchdog` | boolean | `config_defaults.py:1902` |
| `gateway.startup_watchdog_timeout_seconds` | number | `config_defaults.py:1903` |
| `gateway.write_sessions_json` | boolean | `config_defaults.py:1907` |
| `gateway.scale_to_zero.idle_timeout_minutes` | number | `config_defaults.py:1913` |
| `gateway.restart_loop_guard.max_restarts` | number | `config_defaults.py:1919` |
| `gateway.restart_loop_guard.window_seconds` | number | `config_defaults.py:1919` |
| `gateway.restart_loop_guard.max_gap_seconds` | number | `config_defaults.py:1919` |
| `gateway.respawn_storm.max_starts` | number | `config_defaults.py:1924` |
| `gateway.respawn_storm.window_seconds` | number | `config_defaults.py:1924` |
| `gateway.message_timestamps.enabled` | boolean | `config_defaults.py:1928` |
| `gateway.max_inbound_media_bytes` | number | `config_defaults.py:1933` |
| `gateway.trust_env` | boolean | `config_defaults.py:1939` |
| `gateway.strict` | boolean | `config_defaults.py:1945` |
| `gateway.media_delivery_allow_dirs` | list | `config_defaults.py:1950` |
| `gateway.trust_recent_files` | boolean | `config_defaults.py:1955` |
| `gateway.trust_recent_files_seconds` | number | `config_defaults.py:1958` |
| `gateway.api_server.max_concurrent_runs` | number | `config_defaults.py:1963` |
| `streaming.enabled` | boolean | `config_defaults.py:1969` |
| `streaming.transport` | string | `config_defaults.py:1973` |
| `streaming.edit_interval` | number | `config_defaults.py:1975` |
| `streaming.buffer_threshold` | number | `config_defaults.py:1977` |
| `streaming.cursor` | string | `config_defaults.py:1978` |
| `streaming.fresh_final_after_seconds` | number | `config_defaults.py:1981` |
| `sessions.auto_prune` | boolean | `config_defaults.py:1990` |
| `sessions.retention_days` | number | `config_defaults.py:1999` |
| `sessions.auto_archive` | boolean | `config_defaults.py:2002` |
| `sessions.auto_archive_days` | number | `config_defaults.py:2004` |
| `sessions.vacuum_after_prune` | boolean | `config_defaults.py:2010` |
| `sessions.min_vacuum_interval_days` | number | `config_defaults.py:2012` |
| `sessions.min_interval_hours` | number | `config_defaults.py:2015` |
| `sessions.write_json_snapshots` | boolean | `config_defaults.py:2019` |
| `sessions.fts_optimize_notice` | string | `config_defaults.py:2025` |
| `sessions.cjk_fts` | boolean | `config_defaults.py:2030` |
| `sessions.search_slow_ms` | number | `config_defaults.py:2034` |
| `sessions.max_resume_messages` | number | `config_defaults.py:2038` |
| `sessions.max_export_messages` | number | `config_defaults.py:2041` |
| `onboarding.profile_build` | string | `config_defaults.py:2049` |
| `telemetry.shared_metrics.enabled` | boolean | `config_defaults.py:2056` |
| `telemetry.shared_metrics.send` | boolean | `config_defaults.py:2059` |
| `telemetry.shared_metrics.endpoint` | string | `config_defaults.py:2062` |
| `doctor.live_probe_timeout` | number | `config_defaults.py:2068` |
| `updates.pre_update_backup` | string | `config_defaults.py:2081` |
| `updates.backup_keep` | number | `config_defaults.py:2084` |
| `updates.non_interactive_local_changes` | string | `config_defaults.py:2089` |
| `updates.auto_switch_parked_branch` | boolean | `config_defaults.py:2094` |
| `updates.parked_branch_strategy` | string | `config_defaults.py:2099` |
| `updates.refresh_cua_driver` | boolean | `config_defaults.py:2102` |
| `lsp.enabled` | boolean | `config_defaults.py:2108` |
| `lsp.wait_mode` | string | `config_defaults.py:2111` |
| `lsp.wait_timeout` | number | `config_defaults.py:2112` |
| `lsp.install_strategy` | string | `config_defaults.py:2115` |
| `lsp.idle_timeout` | number | `config_defaults.py:2119` |
| `x_search.model` | string | `config_defaults.py:2129` |
| `x_search.reasoning_effort` | null (UI inferred string) | `config_defaults.py:2131` |
| `x_search.timeout_seconds` | number | `config_defaults.py:2133` |
| `x_search.retries` | number | `config_defaults.py:2135` |
| `secrets.bitwarden.enabled` | boolean | `config_defaults.py:2144` |
| `secrets.bitwarden.access_token_env` | string | `config_defaults.py:2147` |
| `secrets.bitwarden.project_id` | string | `config_defaults.py:2148` |
| `secrets.bitwarden.cache_ttl_seconds` | number | `config_defaults.py:2151` |
| `secrets.bitwarden.encrypted_cache.enabled` | boolean | `config_defaults.py:2154` |
| `secrets.bitwarden.encrypted_cache.max_stale_seconds` | number | `config_defaults.py:2154` |
| `secrets.bitwarden.override_existing` | boolean | `config_defaults.py:2157` |
| `secrets.bitwarden.auto_install` | boolean | `config_defaults.py:2159` |
| `secrets.bitwarden.server_url` | string | `config_defaults.py:2162` |
| `secrets.onepassword.enabled` | boolean | `config_defaults.py:2165` |
| `secrets.onepassword.account` | string | `config_defaults.py:2168` |
| `secrets.onepassword.service_account_token_env` | string | `config_defaults.py:2171` |
| `secrets.onepassword.binary_path` | string | `config_defaults.py:2173` |
| `secrets.onepassword.cache_ttl_seconds` | number | `config_defaults.py:2175` |
| `secrets.onepassword.override_existing` | boolean | `config_defaults.py:2177` |
| `paste_collapse_threshold` | number | `config_defaults.py:2184` |
| `paste_collapse_threshold_fallback` | number | `config_defaults.py:2185` |
| `paste_collapse_char_threshold` | number | `config_defaults.py:2186` |
| `computer_use.cua_telemetry` | boolean | `config_defaults.py:2191` |
| `computer_use.native_wayland` | boolean | `config_defaults.py:2192` |
| `computer_use.max_image_dimension` | number | `config_defaults.py:2195` |
| `computer_use.capture_after_mode` | string | `config_defaults.py:2198` |
| `computer_use.no_overlay` | null (UI inferred string) | `config_defaults.py:2205` |
| `computer_use.permission_mode` | string | `config_defaults.py:2209` |
| `computer_use.capability_manifest` | string | `config_defaults.py:2212` |
| `computer_use.allow_unsigned_driver` | boolean | `config_defaults.py:2216` |
| `proxy.enabled` | boolean | `config_defaults.py:2223` |
| `proxy.tunnel_port` | number | `config_defaults.py:2225` |
| `proxy.auto_install` | boolean | `config_defaults.py:2227` |
| `proxy.credential_source` | string | `config_defaults.py:2230` |
| `proxy.enforce_on_docker` | boolean | `config_defaults.py:2233` |
| `proxy.allow_env_fallback` | boolean | `config_defaults.py:2237` |
| `proxy.upstream_deny_cidrs` | null (UI inferred string) | `config_defaults.py:2240` |
| `proxy.extra_allowed_hosts` | list | `config_defaults.py:2243` |
| `desktop.repo_scan_enabled` | boolean | `config_defaults.py:2247` |
| `desktop.repo_scan_roots` | list | `config_defaults.py:2248` |
| `desktop.repo_scan_exclude_paths` | list | `config_defaults.py:2249` |
| `desktop.electron_flags` | list | `config_defaults.py:2252` |
| `desktop.ozone_platform_hint` | string | `config_defaults.py:2258` |
| `desktop.disable_gpu` | string | `config_defaults.py:2262` |
| `desktop.password_store` | string | `config_defaults.py:2267` |
| `desktop.macos_signing_identity` | string | `config_defaults.py:2271` |
| `desktop.auto_continue.enabled` | boolean | `config_defaults.py:2275` |
| `desktop.auto_continue.freshness_minutes` | number | `config_defaults.py:2277` |
| `desktop.auto_continue.max_attempts` | number | `config_defaults.py:2278` |
| `nous.keepalive_interval_seconds` | number | `config_defaults.py:2286` |
| `vertex.project_id` | string | `config_defaults.py:2293` |
| `vertex.region` | string | `config_defaults.py:2296` |
| `local_runtime.enabled` | boolean | `config_defaults.py:2302` |
| `local_runtime.tag` | string | `config_defaults.py:2304` |
| `local_runtime.backend` | string | `config_defaults.py:2307` |
| `local_runtime.models_max` | number | `config_defaults.py:2308` |
| `local_runtime.port` | number | `config_defaults.py:2309` |
| `local_runtime.detect_ports` | list | `config_defaults.py:2311` |

Empty-map configuration roots/branches (schema recursion yields no leaf control; dynamic/custom keys need separate discovery):

- `providers` — `config_defaults.py:23`
- `credential_pool_strategies` — `config_defaults.py:25`
- `agent.reasoning_overrides` — `config_defaults.py:241`
- `terminal.docker_env` — `config_defaults.py:309`
- `web.provider_tier` — `config_defaults.py:365`
- `compression.model_thresholds` — `config_defaults.py:629`
- `auxiliary.vision.extra_body` — `config_defaults.py:14`
- `auxiliary.compression.extra_body` — `config_defaults.py:14`
- `auxiliary.skills_hub.extra_body` — `config_defaults.py:14`
- `auxiliary.approval.extra_body` — `config_defaults.py:14`
- `auxiliary.mcp.extra_body` — `config_defaults.py:14`
- `auxiliary.title_generation.extra_body` — `config_defaults.py:720`
- `auxiliary.memory_query_rewrite.extra_body` — `config_defaults.py:14`
- `auxiliary.tts_audio_tags.extra_body` — `config_defaults.py:14`
- `auxiliary.triage_specifier.extra_body` — `config_defaults.py:14`
- `auxiliary.kanban_decomposer.extra_body` — `config_defaults.py:14`
- `auxiliary.profile_describer.extra_body` — `config_defaults.py:14`
- `auxiliary.goal_judge.extra_body` — `config_defaults.py:14`
- `auxiliary.curator.extra_body` — `config_defaults.py:14`
- `auxiliary.monitor.extra_body` — `config_defaults.py:14`
- `auxiliary.background_review.extra_body` — `config_defaults.py:14`
- `auxiliary.moa_reference.extra_body` — `config_defaults.py:14`
- `auxiliary.moa_aggregator.extra_body` — `config_defaults.py:14`
- `display.status_phrases` — `config_defaults.py:867`
- `delegation.request_overrides` — `config_defaults.py:1222`
- `honcho` — `config_defaults.py:1372`
- `slack.channel_prompts` — `config_defaults.py:1385`
- `discord.channel_prompts` — `config_defaults.py:1417`
- `whatsapp` — `config_defaults.py:1462`
- `telegram.channel_prompts` — `config_defaults.py:1469`
- `mattermost.channel_prompts` — `config_defaults.py:1485`
- `quick_commands` — `config_defaults.py:1542`
- `platform_hints` — `config_defaults.py:1547`
- `hooks` — `config_defaults.py:1563`
- `personalities` — `config_defaults.py:1570`
- `model_catalog.providers` — `config_defaults.py:1817`
- `model_overrides` — `config_defaults.py:1830`
- `monitoring.export.otlp.headers_env` — `config_defaults.py:1864`
- `onboarding.seen` — `config_defaults.py:2046`
- `lsp.servers` — `config_defaults.py:2123`
- `secrets.onepassword.env` — `config_defaults.py:2166`

Virtual field: `model_context_length` — `H/hermes_cli/web_server_config.py:228–239`. Model dict subkeys, custom providers, MCP server entries, profile metadata and provider setup are not exhaustively represented by this default-backed list.

## Appendix C. Request-body field register
Mechanically extracted declared field names/types from `H/hermes_cli/web_models.py`; no defaults or credential values copied. This does not imply field-level constraints are enforced beyond Pydantic annotations and handler-specific checks described above. Optional fields must be omitted unless deliberately changed; dangerous defaults must be set explicitly.
| Model | Declared fields and types | Source lines |
|---|---|---|
| `ConfigUpdate` | `config: dict`; `profile: Optional[str]` | :11–13 |
| `EnvVarUpdate` | `key: str`; `value: str`; `profile: Optional[str]`; `api_key: str` | :15–21 |
| `EnvVarDelete` | `key: str`; `profile: Optional[str]` | :23–25 |
| `EnvVarReveal` |  | :27–28 |
| `MemoryProviderConfigUpdate` | `values: Dict[str, Any]` | :30–31 |
| `MemoryProviderSetupRequest` | `values: Dict[str, Any]` | :33–34 |
| `CustomEndpointUpdate` | `id: str`; `name: str`; `base_url: str`; `model: str`; `api_key: Optional[str]`; `context_length: Optional[int]`; `discover_models: bool`; `make_default: bool`; `models: Optional[List[str]]` | :36–45 |
| `MessagingPlatformUpdate` | `enabled: Optional[bool]`; `env: Dict[str, str]`; `clear_env: List[str]`; `profile: Optional[str]` | :47–52 |
| `ModelAssignment` | `scope: str`; `provider: str`; `model: str`; `task: str`; `base_url: str`; `api_key: str`; `confirm_expensive_model: bool`; `profile: Optional[str]` | :91–106 |
| `FsWriteText` | `path: str`; `content: str` | :162–164 |
| `LearningNodeRef` | `id: str`; `profile: Optional[str]` | :206–208 |
| `LearningNodeEdit` | `id: str`; `content: str`; `profile: Optional[str]` | :210–213 |
| `SessionRename` | `title: Optional[str]`; `archived: Optional[bool]`; `hidden: Optional[bool]`; `pinned: Optional[bool]`; `unread: Optional[bool]`; `profile: Optional[str]` | :241–248 |
| `CronJobCreate` | `prompt: str`; `schedule: str`; `name: str`; `deliver: str`; `skills: Optional[List[str]]`; `model: Optional[str]`; `provider: Optional[str]`; `base_url: Optional[str]`; `script: Optional[str]`; `context_from: Optional[Any]`; `enabled_toolsets: Optional[List[str]]`; `workdir: Optional[str]`; `no_agent: bool` | :283–296 |
| `CronJobUpdate` | `updates: dict` | :298–299 |
| `MCPServerCreate` | `name: str`; `url: Optional[str]`; `command: Optional[str]`; `args: List[str]`; `env: Dict[str, str]`; `auth: Optional[str]`; `bearer_token: Optional[SecretStr]`; `profile: Optional[str]` | :305–314 |
| `MCPServersReplace` | `servers: Dict[str, Dict[str, Any]]`; `profile: Optional[str]` | :316–319 |
| `MCPEnabledToggle` | `enabled: bool`; `profile: Optional[str]` | :321–323 |
| `MCPCatalogInstall` | `name: str`; `env: Dict[str, str]`; `enable: bool`; `profile: Optional[str]` | :325–329 |
| `PairingApprove` | `platform: str`; `code: str`; `request_id: str`; `profile: Optional[str]` | :331–335 |
| `PairingRevoke` | `platform: str`; `user_id: str`; `profile: Optional[str]` | :337–340 |
| `WebhookCreate` | `name: str`; `description: Optional[str]`; `events: List[str]`; `prompt: Optional[str]`; `script: Optional[str]`; `skills: List[str]`; `deliver: str`; `deliver_only: bool`; `deliver_chat_id: Optional[str]`; `secret: Optional[str]` | :342–352 |
| `WebhookEnabledToggle` | `enabled: bool` | :354–355 |
| `CredentialPoolAdd` | `provider: str`; `api_key: str`; `label: Optional[str]` | :357–360 |
| `MemoryProviderSelect` | `provider: str` | :362–363 |
| `MemoryReset` | `target: str` | :365–366 |
| `HookCreate` | `event: str`; `command: str`; `matcher: Optional[str]`; `timeout: Optional[int]`; `approve: bool` | :377–383 |
| `HookDelete` | `event: str`; `command: str` | :385–387 |
| `ProfileCreate` | `name: str`; `clone_from: Optional[str]`; `clone_from_default: bool`; `clone_all: bool`; `no_skills: bool`; `description: Optional[str]`; `provider: Optional[str]`; `model: Optional[str]`; `mcp_servers: List['MCPServerCreate']`; `keep_skills: List[str]`; `hub_skills: List[str]` | :400–414 |
| `ProfileRename` | `new_name: str` | :416–417 |
| `ProfileSoulUpdate` | `content: str` | :427–428 |
| `ProfileActiveUpdate` | `name: str` | :430–431 |
| `ProfileDescriptionUpdate` | `description: str` | :433–434 |
| `ProfileModelUpdate` | `provider: str`; `model: str` | :436–438 |
| `SkillToggle` | `name: str`; `enabled: bool`; `profile: Optional[str]` | :443–446 |
| `SkillCreate` | `name: str`; `content: str`; `category: Optional[str]`; `profile: Optional[str]` | :448–452 |
| `SkillContentUpdate` | `name: str`; `content: str`; `profile: Optional[str]` | :454–457 |
| `ToolsetToggle` | `enabled: bool`; `profile: Optional[str]` | :459–461 |
| `ToolsetProviderSelect` | `provider: str`; `capability: Optional[str]`; `profile: Optional[str]` | :463–467 |
| `ToolsetModelSelect` | `model: str`; `provider: Optional[str]`; `profile: Optional[str]` | :469–472 |
| `ToolsetEnvUpdate` | `env: Dict[str, str]`; `profile: Optional[str]` | :474–476 |
| `ToolsetPostSetup` | `key: str`; `profile: Optional[str]` | :478–480 |
| `TerminalBackendSelect` | `backend: str`; `profile: Optional[str]` | :482–484 |
| `RawConfigUpdate` | `yaml_text: str`; `profile: Optional[str]` | :486–488 |

## Sources

[1] https://hermes-agent.nousresearch.com/docs/llms.txt
[2] https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
