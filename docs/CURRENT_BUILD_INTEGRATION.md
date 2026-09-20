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
| Status/identity/profile client boundary | Implemented with authored XCTest fixtures | Requests selected-profile `/api/status`, then requires `/api/auth/me` before `/api/profiles/active`. No production transport constructs it yet; XCTest has not run on this Linux host. |
| Session-title and SOUL correction engines | Implemented with authored XCTest fixtures, unreachable | Review/apply/readback behavior remains locked until approved authentication and transport exist; XCTest has not run on this Linux host. |
| Production dashboard networking | Disabled | The current Hermes native auth route accepts desktop HTTP loopback callbacks only. No copied token, relay credential reuse, embedded secret, or fake host state is used. |
| Local-only experiments | Source preserved, unreachable from `AdminRoot` | Share/Shortcuts targets may still exist structurally; normal launch does not route into local workspace or composer lab. |
| Legacy connected app | Source preserved, unreachable | Chat, approval inbox, voice overlay, pairing, sensor pipeline, push, CarPlay, and remote containers remain gated off. |

## First active vertical slice

The source now defines an immutable `AdminOverview` bound to the reviewed target. It decodes:

- host version, overall health, gateway state, active agents/sessions, advertised auth flows, and available profiles;
- authenticated user identity and provider;
- sticky active and serving profile context.

Request order is intentional: public target-specific status → authenticated identity → protected profile context. A `401` stops before profile discovery. Existing base paths and the exact selected profile query are preserved.

This is a client contract, not a claim of live connectivity. `UnavailableAdminTransport` remains the normal production boundary.

## Authentication blocker

Hermes currently advertises `native_pkce`, but `/auth/native/authorize` accepts only `http://127.0.0.1[:port]/…` or `http://[::1][:port]/…` callbacks. That contract was designed for Desktop and is not yet an approved, device-verified iOS callback flow.

Before networking is enabled:

1. Add and test an iOS-compatible system-browser PKCE callback contract in Hermes.
2. Bind authorization and tokens to the exact reviewed HTTPS origin.
3. Reject cross-origin redirects and malformed callback state.
4. Store refresh material in Keychain and handle expiry/rotation without logs.
5. Verify `/api/auth/me`, selected profile, and serving profile before unlocking management reads.
6. Exercise wrong-host, wrong-profile, expiry, cancellation, background/resume, and unknown-network outcomes on a physical device.

Relay bearer tokens remain separate and cannot authorize dashboard administration.

## Settings safety blocker

The general dashboard configuration response is not a proven secret-safe projection. Hermes iOS must not fetch, log, persist, or display arbitrary raw configuration as its first settings implementation. A server-side allowlisted/typed projection is required before schema-driven configuration inspection is unlocked.

## Verification status

- Linux executable source/regression suite: passing after the product correction and first client slice.
- Swift XCTest/UI test source: added for dashboard hierarchy, request ordering/decoding, exact target binding, and `401` fail-closed behavior.
- Native compilation, XCTest, and UI tests: not run locally because this host has no Swift/Xcode toolchain.
- Live host authentication/read: not run; production transport remains disabled.
- Native write/readback: not run and not authorized by this scope decision.
- TestFlight/release: not attempted; exact-SHA native and signing gates remain required.

## Signing and retained targets

The project still contains the main app, widget, and Share extension from the preserved codebase. Their presence does not make local intake part of the active product. Any future release must decide intentionally whether frozen extension/widget targets remain in the product, then validate the corresponding identifiers, entitlements, profiles, archive contents, signatures, and App Store processing for that exact target set.
