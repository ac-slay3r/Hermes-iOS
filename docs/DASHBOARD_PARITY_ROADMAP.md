# Hermes iOS dashboard parity roadmap

## Product definition

Hermes iOS is the native iPhone and iPad client for the Hermes web dashboard. The dashboard's shipped capabilities and source-verified APIs define the product map. The app translates those capabilities into compact native workflows; it is not a separate local-first assistant with administration attached.

The current charcoal/gold visual system remains. Every mutation follows: find → inspect → change → review → apply → exact readback. Host, authenticated identity, serving profile, selected target profile, persistence, and runtime application are distinct states.

## Scope boundaries

### In scope

- Dashboard connection, authentication, host identity, and explicit profile targeting
- Overview, health, versions, gateway state, sessions, and system status
- Configuration, models, providers, and profiles
- Skills, toolsets, MCP servers, plugins, and memory providers
- Built-in memory, user information, SOUL/instructions, and session metadata
- Cron jobs, messaging integrations, pairing, and webhooks
- Logs, analytics, backup/import, doctor/security audit, updates, and gateway operations
- Credential setup only through purpose-built guarded workflows that never persist or log revealed values

### Frozen outside the primary roadmap

- Local capture workspace, OCR, recording, local intelligence, intake, sensor collection, timeline, and composer lab
- Legacy chat/pairing/voice paths
- Widgets and Share extension behavior unrelated to dashboard administration

Their source remains preserved. They do not appear in primary navigation and are not reactivated without an explicit product decision.

## Capability and safety rules

1. Use live dashboard capability/schema discovery where available; do not hardcode a claim of complete parity.
2. Keep dashboard and relay credentials separate. Relay pairing is not administrator authorization.
3. Bind every request to the reviewed HTTPS origin and exact profile. Reject credentials, query strings, fragments, redirects to another origin, malformed identifiers, and silent target changes.
4. Establish authenticated identity before any protected management read. Store refresh credentials only in Keychain with device-appropriate accessibility.
5. Do not fetch unrestricted raw configuration or reveal credentials for general settings display. Introduce a server-side secret-safe projection before arbitrary config inspection.
6. Treat HTTP success and business success separately. A write is saved only after exact readback; runtime application/restart remains a separate state.
7. Preserve drafts on failure. A dispatched timeout is an unknown result and must reconcile the original target before retry.
8. Require explicit review for installs, tests/probes, triggers, restarts, imports, resets, deletes, secrets, and other consequential operations.

## Milestones

### M0 — Product correction and contract inventory

- Remove local-only experiments from primary navigation.
- Keep the administration launch isolated from sensors, voice, relay startup, push, and legacy containers.
- Maintain a route/capability matrix against the current Hermes dashboard source and docs.

**Gate:** first-launch hierarchy unambiguously describes a dashboard management app.

### M1 — Connection, authentication, and identity

- Validate an exact HTTPS dashboard origin and selected profile.
- Read public `/api/status?profile=…` capability/auth metadata.
- Add an iOS-compatible system-browser PKCE flow to Hermes; the current native route accepts desktop loopback callbacks only.
- Exchange and refresh bearer tokens; store refresh material in Keychain; keep access tokens memory-only where practical.
- Read `/api/auth/me` and `/api/profiles/active`, then show host, identity, serving profile, active profile, selected target, token expiry, and connection state.
- Reject cross-origin redirects and fail closed on expired/mismatched identity.

**Gate:** physical iOS device signs into an approved host, reads identity/profile state, and demonstrates wrong-host, wrong-profile, redirect, and expired-token failures without secret-bearing logs.

### M2 — Native read-only dashboard

- Overview and component health
- Profile list and gateway topology
- Session list/search/detail metadata
- Skills, toolsets, MCP, memory-provider, cron, messaging, webhook, logs, and analytics summaries
- Capability-aware empty/unavailable/error states

**Gate:** native screens agree with the web dashboard for the same host/profile, with no mutation paths enabled.

### M3 — Configuration and low-risk corrections

- Server-side secret-safe configuration projection
- Schema-driven native controls with managed/unsupported fields distinguished
- Session-title and SOUL editors using existing review/apply/readback machinery
- Low-impact scalar settings edits with field-specific apply semantics

**Gate:** authorized disposable-profile writes preserve omitted fields and verify exact readback; concurrent/unknown outcomes remain visible and recoverable.

### M4 — Profiles and capabilities

- Profile lifecycle and model/provider selection
- Skill enable/content management
- Toolset configuration and setup consequences
- MCP server lifecycle, tests, and OAuth flows
- Stable/revision-aware built-in-memory correction

**Gate:** every action exposes scope, side effects, business receipts, readback, and supported recovery. Install/network/process effects require confirmation.

### M5 — Automation, connections, and operations

- Cron jobs and run history
- Messaging onboarding/configuration and pairing
- Webhooks and hooks
- Doctor, security audit, backup/import, updates, curator, gateway lifecycle, and approvals where discovery is complete

**Gate:** triggers, delivery, imports, restart/stop/update, destructive actions, and credentials have dedicated high-impact review flows and real-host verification.

### M6 — Release validation

- Native compile, XCTest, and UI tests on the exact commit
- Device authentication and authorized disposable-resource write/readback
- Accessibility, Dynamic Type, offline/expiry/background/restore testing
- Signed three-target archive and exported-IPA verification only for intentionally retained targets
- App Store processing readback

## Current implementation slice

Work started with the M1 client boundary:

1. Read the selected profile's public status from `/api/status?profile=…`.
2. Require authenticated `/api/auth/me` identity before protected management context.
3. Read active and serving profiles from `/api/profiles/active`.
4. Return one immutable overview bound to the reviewed `AdminTarget`.
5. Keep production networking disabled until the iOS callback/authentication contract is implemented and verified.

Native XCTest defines request ordering, decoding, exact base-path preservation, profile query binding, and fail-closed behavior on `401`. Linux source guards cover structural inclusion only; native execution still requires Xcode CI.
