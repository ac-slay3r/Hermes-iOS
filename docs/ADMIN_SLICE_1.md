# Administration slice 1 — disconnected client boundary

## Delivered source scope

Normal launch is administration-first, using the original charcoal/gold design tokens. It does not construct the conversation container, register push, start voice/sensors, or open old deep links. The operator can review an explicit HTTPS dashboard address and exact target profile. Neither is presented as authenticated identity; serving profile remains unknown.

The separate typed dashboard adapter implements only two source-verified contracts:

- Session title: GET `api/sessions/{exact-id}?profile={selected-profile}`, PATCH with **only** `title` and `profile`.
- SOUL instructions: GET/PUT `api/profiles/{selected-profile}/soul`; PUT contains **only** `content`.

The editor retains before/after values only in memory, reviews the exact target, reads again before apply, rejects detected changes, checks the business receipt, and reads the exact resource back. An uncertain write is reconciled by GET, never automatically retried. Read-before-write is **not atomic concurrency protection**. A verified disk save does not establish runtime application and never triggers restart.

## Intentionally not connected

The normal application uses no enabled dashboard network transport. Native editor tests inject fixtures; the app never presents fixture data as host state. Editor UI is implemented but not unlocked from the normal root. This is not evidence of working live administration or a release-ready TestFlight update.

Authentication discovery confirmed the existing native broker accepts only HTTP IP-literal loopback redirects with S256 PKCE. It does not currently accept an iOS custom-scheme callback. A properly implemented iOS loopback flow would need device verification; none was invented here. An existing configured password provider also has a supported `/auth/password-login` cookie flow, but its presence on the intended deployment is unverified and changing providers would not be an acceptable silent workaround. No supplied approved dashboard endpoint/provider or supported authenticated iOS callback was available for this slice. No bootstrap credentials, bearer tokens, cookies or host configuration values were retrieved.

Before enabling transport: prove an approved iOS sign-in, exact HTTPS origin/base-path binding, redirect rejection, ephemeral response storage, token expiry, authenticated identity and explicit profile identity. Do not reuse relay credentials. Validate wrong-host/profile and expired-auth failures, then perform a user-authorized disposable-resource write/readback.

Settings inspection is explicitly unavailable rather than fetching and redacting a potentially secret-bearing raw response. The existing general config endpoint is not a secret-safe projection; no fictional safe-config endpoint is introduced. Adding a server-side allowlisted read contract requires separately scoped backend work.

## Clean CI candidate and frozen experimental work

This candidate contains the committed baseline plus the bounded administration files, launch isolation, native tests and this scope note. Uncommitted capture/intake/intelligence/backup/share and UI-polish experiments are preserved in the local working tree, **not swept into the candidate commit**. No captured data is uploaded. The local working project may therefore contain more targets/sources than a clean checkout of the candidate.

Clean candidate signed targets remain the baseline main app and widget. The uncommitted Share extension is not a candidate target; it is preserved locally, not silently dropped during archive. It cannot join a future candidate until its own identifier, entitlements, profile and exported-IPA validation are configured. Always build a clean exact-SHA checkout; do not archive this mixed experimental working tree. No signing credentials or portal records were changed.

Legacy pairing/chat UI tests remain preserved but are explicitly frozen because that product entry point is unreachable. New admin launch UI tests replace the current-launch acceptance coverage; unit tests still exercise the existing underlying services. Local capture tests belong to the preserved experiment, not this clean candidate.

## Verification boundary

Native XCTest and UI tests were authored before native CI verification, but Linux has no Swift/Xcode. Source guard tests are not native compilation. The baseline hosted rerun failed before any job steps: GitHub reported failed recent account payments or a spending limit. A candidate CI attempt must be read back separately; billing failure is not a compiler result.

Signed upload remains gated on successful exact-SHA native CI, all included target signatures/profiles, exported IPA checks and App Store processing readback. Do not dispatch upload merely to bypass unsigned CI, and do not describe this disconnected foundation as completed TestFlight delivery.
