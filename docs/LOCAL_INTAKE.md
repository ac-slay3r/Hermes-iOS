# Local Share Sheet and Shortcuts intake

> **Historical implementation:** Local intake is frozen and absent from the current dashboard-management navigation. This document preserves earlier engineering evidence; [current integration](CURRENT_BUILD_INTEGRATION.md) and the [dashboard parity roadmap](DASHBOARD_PARITY_ROADMAP.md) govern product scope and reachability.

## Scope and usage

This adds source for a real `HermesShareExtension` app-extension target, embedded by the main app, and two App Intents. It does not enable the legacy remote app container, agent, relay, uploads, sensors, or recording. No URL is fetched or automatically opened. Images, PDFs, file imports, webpage scraping, rich text, and multiple-item shares are **not implemented**.

- In another app, share **one** plain-text item or HTTP/HTTPS URL to **Save to Hermes**. Review the exact original in the read-only Preview, then choose **Save to local inbox** or **Cancel**. Nothing is persisted during preview. A successful Save completes the extension only after the queue write returns. Open Hermes to import.
- In Shortcuts, **Save text to local inbox** accepts an explicitly supplied, nonempty Text parameter. It opens the app, requires local device authentication, and requests confirmation showing the supplied text before saving. It does not inspect the clipboard or collect context. Canceling confirmation performs no save.
- **Open local inbox** only opens a local, read-only notes inbox; it performs no capture. The inbox also includes existing unarchived notes. Use the normal library to edit/organize them.
- In Hermes, **Open local inbox** and **Retry importing shared items** expose the same local-only flow. Import is attempted at startup and foreground activation. A failed import is visible with a retry action; the library is not reset.

## Accepted formats and bounds

| Input | Limit / behavior |
|---|---|
| Plain text (`public.plain-text`) | Non-whitespace, at most 65,536 UTF-8 bytes (64 KiB); preserved verbatim, including original whitespace |
| URL (`public.url`) | One HTTP/HTTPS URL with nonempty host, at most 8,192 UTF-8 bytes (8 KiB); original representation stored as note text |
| Encoded queue envelope | Version 1 JSON, at most 524,288 bytes; bounded read accounts for JSON escaping |
| Share request | Exactly one extension item with exactly one attachment/provider; no partial multi-item save |

Byte limits are not character limits. An over-limit or unsupported input is rejected, never silently truncated. Plain-text content that happens to look like a URL remains literal text, never an instruction. URL inputs with `file:`, `javascript:`, or custom schemes are rejected. No file representations are loaded. A host provider can allocate its payload before the callback checks size; this is not a pre-allocation guarantee against a malicious host or OS memory pressure. Pending queue count and lifetime are not automatically capped or expired, to avoid silently deleting saved inputs.

## Storage and trust boundary

The exact existing App Group is **`group.cool.n0thing.hermes`**. Only the dedicated **`LocalIntake-v1/`** subdirectory is used. This feature does not read or write legacy widget caches, shared defaults, or captured media. Group access is an entitlement boundary, not isolation from other targets entitled to the same group; such targets could access the queue if separately modified to do so.

The directory is fully file-protected and excluded from automatic backup. Queue files use UUID names and atomic, complete-file-protection writes. Payloads carry version, UUID, creation time, kind, and text—never import paths. Import verifies canonical UUID filenames, matching payload identity, format and byte limits. Reads use `O_NOFOLLOW`, `O_NONBLOCK`, `fstat`, regular-file and single-link checks, and bounded reads. Directory/symlink checks reject unsafe paths. The system-provided container base is canonicalized to allow the normal iOS `/var` alias; no user-supplied file path is accepted.

The app writes into its private protected `LocalCaptures` root, not back into widget storage. A `.staging-intake-<random UUID>/` contains a capture folder and a SHA-256 receipt. A single same-volume rename to `.batch-intake-<input UUID>/` commits both. The existing Store already discovers `.batch-` children, so no Store implementation changes are needed. The capture retains the input UUID. Existing-ID conflicts are rejected without resetting the library.

The SHA-256 receipt is over a canonical sorted-key envelope encoding. It contains no duplicate plaintext, remains app-private/protected, and survives later capture deletion so interrupted acknowledgments cannot resurrect a deleted capture. Receipts are not exported with capture backups. Duplicate delivery of the *same envelope ID* is idempotent; deliberately sharing identical text again creates a separate capture with a new ID.

## Recovery / process death

1. **Before Save:** the source app remains authoritative. Cancel or process death creates no capture.
2. **During queue publication:** atomic write exposes either a complete queue file or no final file. An interrupted pre-publication share may need to be shared again from its source.
3. **After Save / before import:** the protected shared original remains pending across app/extension termination.
4. **During private staging:** staging remains ignored by the library; the shared original remains pending. Retry creates a fresh stage, never replaces originals.
5. **After batch commit / before queue acknowledgment:** retry verifies the persistent receipt, skips duplicate creation, reopens the library, then removes only the matching queued envelope.
6. **After commit followed by capture deletion:** the receipt still prevents replay from recreating that capture.
7. **Corrupt, oversized, locked, conflicting, or unsafe pending items:** originals are retained; unrelated valid items can still import. The UI reports retained items and offers Retry. A failed library reload keeps the previous in-memory store, never an empty replacement.

No reset or automatic purge is offered. Ignored staging remnants and corrupt pending files may require a future explicit recovery/export tool; they are not silently discarded. Atomicity here is a process-termination design, **not a verified sudden-power-loss/fsync guarantee**. App deletion removes private captures; group-container lifetime also depends on installed entitled targets. Export wanted captures explicitly before uninstalling.

## Project / signing inventory

| Target | Bundle ID | App Group |
|---|---|---|
| HermesMobile (existing) | `cool.n0thing.hermes` | `group.cool.n0thing.hermes` |
| HermesMobileWidgets (existing, unchanged) | `cool.n0thing.hermes.Widgets` | same group |
| HermesShareExtension (new local target) | `cool.n0thing.hermes.Share` | same group |

`project.yml` and the checked-in `.pbxproj` include the new native target, its shared queue source, principal controller, build configurations, main-app dependency and embed product, and unit-test registration. The extension is iOS 26 / Swift 6.2, `APPLICATION_EXTENSION_API_ONLY`, and `SKIP_INSTALL`. The extension has **no configured signing team or profile**. Existing signing credentials/settings were not changed. No remote App ID, group association, certificate, provisioning profile, CI configuration, or deployment was created or modified. Signing the new target requires a later explicitly authorized setup; do not reuse the widget's provisioning profile.

## Verification and remaining gates

Written first: `HermesMobileTests/LocalIntakeTests.swift` covers original preservation, bounds and schemes, malformed pending files, symlinks, existing-ID conflicts, and retry after a post-commit failure (including deletion before retry). Native execution was explicitly deferred by the user: **Swift/Xcode compilation and XCTest/runtime have not been run or passed here.**

Executed locally: Python source guardrails, a structural OpenStep `.pbxproj` parser checking the real extension/dependency/embed/source membership, plist/entitlement parsing, and `git diff --check`. These are source/project checks only, not Apple SDK validation.

Before considering this native-ready, on an authorized Xcode 26+ Mac/device:

- Compile the main app, extension, App Intents metadata, and tests with strict concurrency; run all XCTest and UI tests.
- Compare XcodeGen output with the checked-in project without overwriting unrelated local work.
- With separate authorization, verify/register the exact extension App ID and associate the existing App Group; obtain its own profile. Inspect final signed app and `.appex` entitlements, principal class, embedding, matching version/build numbers, and group-container access.
- Exercise Share from Safari and selected text, whitespace, Unicode bounds, malformed/file URLs, unsupported images/PDFs, multiple providers, Cancel, Save failure/retry, and oversized host payloads under memory pressure.
- Exercise Shortcuts discovery, parameter prompting, confirmation/cancel, locked-device authentication, cold/warm launch and already-open inbox routing. Check presentation while existing editors, backup screens, playback/recording, or transcription are active; these actions must not discard work or obscure necessary stop controls.
- Kill processes before/after queue rename, before/after batch commit, and before queue removal. Verify exactly-once delivery by envelope ID, no resurrection, corrupted queue preservation, and partial-batch retries.
- Inspect actual file protection/backup exclusion and lock/unlock behavior on hardware. Observe networking to confirm the intake path performs none.
