# Current Hermes iOS dashboard-management integration

This document is authoritative for current launch reachability and validation boundaries. The detailed product sequence and acceptance gates live in [DASHBOARD_PARITY_ROADMAP.md](DASHBOARD_PARITY_ROADMAP.md).

## Current product contract

Hermes iOS is the native client for Hermes web-dashboard features and configuration. The dashboard's shipped capability set and source-verified APIs define the roadmap. The app preserves the charcoal/gold native visual system and translates dashboard tasks into mobile workflows.

Local capture, OCR, recording, local intelligence, intake, sensors, timeline, composer-lab, legacy chat, and voice implementations are preserved historical work. They are frozen and absent from normal-launch primary navigation unless explicitly reauthorized.

## Reachability from the current source

| Surface | Current state | Boundary |
| --- | --- | --- |
| Administration launch | Reachable at normal launch | Does not construct `AppContainer`, start sensors/voice/relay, register push, or open legacy remote deep links. |
| Dashboard target review | Reachable | Validates an exact HTTPS base URL and lowercase profile identifier. Review is not authentication. |
| Dashboard management map | Reachable | Shows Overview, Configuration, Profiles/Sessions, Skills/Tools/MCP, Memory/Instructions, Automation/Connections, and System/Operations as the product hierarchy. No controls are falsely unlocked. |
| Status/identity/profile client boundary | Reachable after target review and sign-in | Requests selected-profile `/api/status`, requires the host's `native_ios_pkce` capability, then verifies `/api/auth/me` before `/api/profiles/active`. |
| Authenticated overview | Reachable after verified sign-in | `Overview & health` opens a read-only native screen for exact target/profile context, host health, version, gateway, activity counts, identity, profile inventory, and guarded live refresh. Unimplemented areas are marked `Planned`. |
| Session-title and SOUL correction engines | Implemented with authored XCTest fixtures, unreachable | Review/apply/readback behavior remains locked until approved authentication and transport exist; XCTest has not run on this Linux host. |
| Production dashboard networking | Implemented; compatible host required | Uses an ephemeral, no-cookie/no-cache, redirect-rejecting transport bound to the reviewed HTTPS origin/base path. Access tokens stay in memory; rotating refresh credentials use this-device-only Keychain storage. No copied token or relay credential reuse. |
| Local-only experiments | Source preserved, unreachable from `AdminRoot` | Share/Shortcuts targets may still exist structurally; normal launch does not route into local workspace or composer lab. |
| Legacy connected app | Source preserved, unreachable | Chat, approval inbox, voice overlay, pairing, sensor pipeline, push, CarPlay, and remote containers remain gated off. |

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
- Previous product-correction SHA `36fcbc31c44dfc051bd9c5065e9cc2e4144a3124`: native build and tests passed in GitHub Actions.
- Current authentication SHA `9e1b09b7b8dc431f66b5f64d60da02b3bebd2f62`: simulator build, native XCTest/UI tests, relay tests, and connector tests passed in exact-SHA GitHub Actions run `35521639784`.
- Live host authentication: verified by the owner from TestFlight build 17 against `https://dashboard.n0thing.cool`; the replacement build with navigable overview remains pending native CI and TestFlight delivery.
- Native write/readback: not run and not authorized by this scope decision.
- TestFlight/release: authentication build 17 is valid and ready for internal testing; any overview replacement requires its own exact-SHA native and signed release gates.

## Signing and retained targets

The project still contains the main app, widget, and Share extension from the preserved codebase. Their presence does not make local intake part of the active product. Any future release must decide intentionally whether frozen extension/widget targets remain in the product, then validate the corresponding identifiers, entitlements, profiles, archive contents, signatures, and App Store processing for that exact target set.
