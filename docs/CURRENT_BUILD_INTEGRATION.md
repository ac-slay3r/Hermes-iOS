# Current Hermes iOS dashboard-management integration

This document is authoritative for current launch reachability and validation boundaries. The detailed product sequence and acceptance gates live in [DASHBOARD_PARITY_ROADMAP.md](DASHBOARD_PARITY_ROADMAP.md).

## Current product contract

Hermes iOS combines native dashboard administration with the existing paired relay companion. Dashboard remains the default launch tab and its PKCE credentials remain isolated from relay/device pairing. Chat and Device are explicit secondary tabs.

Paired chat, voice entry, host connection, relay settings, notifications, and device permission controls are explicitly reauthorized. Device-data synchronization for location, health, and motion is independently persisted, off by default, and starts only after opt-in. Local capture, OCR, local intelligence, intake, timeline, and composer-lab remain frozen.

## Reachability from the current source

| Surface | Current state | Boundary |
| --- | --- | --- |
| Combined launch | Reachable at normal launch | Presents Dashboard, Chat, and Device with Dashboard selected. A fresh installation does not bootstrap relay, prompt permissions, register push, start voice, or monitor sensors. Previously persisted notification or Device Data Sync consent resumes only its corresponding companion service. |
| Relay chat | Reachable from Chat | Unpaired devices see QR/manual pairing. Paired devices initialize relay chat only after explicit Chat/Device entry. Dashboard credentials never satisfy relay pairing. |
| Device settings | Reachable from Device | Exposes connection, host, relay, notifications, haptics, location, permissions, system status, and about settings. Destructive host revoke/disconnect actions require confirmation. |
| Device data synchronization | Reachable from Device settings | Off by default. One explicit toggle controls the legacy location/HealthKit/motion pipeline; each channel also remains constrained by its individual iOS permission. Disabling it cancels in-flight work and clears queued samples. |
| Companion background execution | Available only for reauthorized features | The app declares only `audio`, `location`, and `remote-notification`: explicit live voice, opt-in background location, and consented silent push. Processing and CarPlay remain disabled. |
| Dashboard target review | Reachable | Validates an exact HTTPS base URL and lowercase profile identifier. Review is not authentication. |
| Dashboard management map | Reachable | Shows Overview, Configuration, Profiles/Sessions, Skills/Tools/MCP, Memory/Instructions, Automation/Connections, and System/Operations as the product hierarchy. No controls are falsely unlocked. |
| Status/identity/profile client boundary | Reachable after target review and sign-in | Requests selected-profile `/api/status`, requires the host's `native_ios_pkce` capability, then verifies `/api/auth/me` before `/api/profiles/active`. |
| Authenticated overview | Reachable after verified sign-in | `Overview & health` opens a read-only native screen for exact target/profile context, host health, version, gateway, activity counts, identity, profile inventory, and guarded live refresh. Unimplemented areas are marked `Planned`. |
| Session-title and SOUL correction engines | Implemented with authored XCTest fixtures, unreachable | Review/apply/readback behavior remains locked until approved authentication and transport exist; XCTest has not run on this Linux host. |
| Production dashboard networking | Implemented; compatible host required | Uses an ephemeral, no-cookie/no-cache, redirect-rejecting transport bound to the reviewed HTTPS origin/base path. Access tokens stay in memory; rotating refresh credentials use this-device-only Keychain storage. No copied token or relay credential reuse. |
| Local-only experiments | Source preserved, unreachable from `AdminRoot` | Share/Shortcuts targets may still exist structurally; normal launch does not route into local workspace or composer lab. |
| Still-frozen surfaces | Source preserved, unreachable | Local capture/workspace, intake UI, timeline experiments, composer lab, CarPlay, and placeholder capture remain outside primary navigation. |

## First active vertical slice

The source now defines an immutable `AdminOverview` bound to the reviewed target. It decodes:

- host version, overall health, gateway state, active agents/sessions, advertised auth flows, and available profiles;
- authenticated user identity and provider;
- sticky active and serving profile context.

Request order is intentional: public target-specific status → authenticated identity → protected profile context. A `401` stops before profile discovery. Existing base paths and the exact selected profile query are preserved.

Normal launch can now check an exact host/profile, restore a rotating native credential or open system-browser sign-in, render verified identity/profile context, and navigate into a read-only native overview with live refresh. Management mutations remain locked.

## Authentication deployment and device gate

The companion Hermes candidate adds the exact callback `cool.n0thing.hermes:/oauth/callback`, rejects near misses, and advertises `native_ios_pkce` separately from desktop `native_pkce`. An unpatched host is shown as incompatible rather than opening a flow it cannot complete.

Before claiming live authentication complete:

1. Land/deploy the companion Hermes gateway change on the intended dashboard host.
2. Pass exact-SHA native compilation and XCTest/UI tests for this source slice.
3. Exercise successful sign-in, wrong-host/profile, expiry, cancellation, background/resume, redirect rejection, and unknown-network outcomes on a physical device.

Relay bearer tokens remain separate and cannot authorize dashboard administration.

## Settings safety blocker

The general dashboard configuration response is not a proven secret-safe projection. Hermes iOS must not fetch, log, persist, or display arbitrary raw configuration as its first settings implementation. A server-side allowlisted/typed projection is required before schema-driven configuration inspection is unlocked.

## Verification status

- Linux executable source/regression suite: passing after the product correction and first client slice.
- Swift XCTest/UI test source: added for dashboard hierarchy, request ordering/decoding, exact target binding, and `401` fail-closed behavior.
- Dashboard authentication and overview SHA `a3e96c8e8f61ae26cd3ff1e67675d82950fc3f24`: simulator build, native XCTest/UI tests, relay tests, and connector tests passed in exact-SHA GitHub Actions run `35535969214`; TestFlight build 22 is valid and ready for internal testing.
- Live dashboard authentication and overview: verified by the owner from TestFlight build 22 against `https://dashboard.n0thing.cool`.
- Combined Dashboard/Chat/Device source: 102 source/project checks, 70 relay tests, and 88 connector tests pass locally; native compilation passes, while corrected native XCTest/UI behavior and signed delivery remain pending for the next exact-SHA run.
- Native dashboard write/readback: not run and not authorized by this scope decision.
- **M1 gate — closed 2026-09-21**: TestFlight build 27 (run #27, commit `608b06e`, CI green through `f3468b3`) sign-in verified live by the owner against `https://dashboard.n0thing.cool`, which advertises `auth_flows: ["cookie","native_pkce","native_ios_pkce"]`. Formal negative-case device testing (wrong-host, wrong-profile, expired-token, redirect-rejection) was explicitly deferred by owner decision and remains unverified — do not claim it as tested.

## Signing and retained targets

The project still contains the main app, widget, and Share extension from the preserved codebase. Their presence does not make local intake part of the active product. Any future release must decide intentionally whether frozen extension/widget targets remain in the product, then validate the corresponding identifiers, entitlements, profiles, archive contents, signatures, and App Store processing for that exact target set.
