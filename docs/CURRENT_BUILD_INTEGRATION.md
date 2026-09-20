# Administration build: integrated supporting tools

This document supersedes earlier local-only launch and frozen-experiment scope statements. Administration remains the primary launch surface. Local features are explicitly supporting tools, not a return to a scrapbook-first product or authorization to resume historical sensor collection.

## Reachability from the installed app

| Feature | Entry path | Boundary |
| --- | --- | --- |
| Administration | Normal launch → Hermes | Disconnected; settings projection and approved native sign-in remain unavailable. No fake credentials or unlocked writes. |
| Text/photo/scan/OCR | Hermes → Supporting tools → Local workspace → New text note / Take photo / Import photo / Scan document; saved image → Recognize text on device | Explicit taps; original images retained. Photo picker may download a selected iCloud original. |
| Voice recording/playback/transcription | Local workspace → Record voice; saved voice → Play recording / Transcribe offline | Local microphone only after explicit permission/tap; offline speech required, no server fallback. |
| Search/pin/archive/checklist | Local workspace → search / Library filters / Capture actions / Checklist | Local organization only, no task execution or scheduling. |
| On-device AI review | Saved capture → Review capture → Open AI review → Review on device | Temporary editable copy, including unsaved text; no automatic generation/apply, remote fallback or capture upload. Device/model capability may be unavailable. |
| Files backup | Local workspace → Storage & backup | Explicit export destination and validated import confirmation; repeated imports create copies. See capacity warning below. |
| Shared text/link intake | Another app → Share → Save to Hermes → Preview → Save to local inbox; Hermes → Local workspace → Open local inbox | One plain-text or HTTP(S) URL item. No URL fetching. Extension target is embedded but **distribution signing is blocked**. |
| Shortcuts | Save text to local inbox / Open local inbox | App Intents registered, device authentication and save confirmation required; request routes into supporting workspace, never remote shell. Native discovery/execution still needs validation. |
| Composer/tool accessibility polish | Hermes → Supporting tools → Chat composer lab | Uses real polished composer and tool rail with clearly labelled sample activity. Draft-only lab; no sending, attachments, dictation or approval dispatch. |

**Still unreachable:** connected `ChatScreen`, legacy approval inbox, live voice overlay, remote pairing/sensor pipeline. Their preserved polish/source is included in the native target, not yet proven to compile or presented as a working connected feature. Restoring those paths requires independently verified session authorization and removal of automatic transport/sensing. The lab is not an authenticated chat or real tool-result viewer. The frozen `InboxItemRow` primary action still approves directly and its Details action is a no-op; keep it unreachable until a separate confirmation/details-flow fix and authorization review precede any reconnection.

## Integration invariants

- `AppEntry.swift` continues to launch `AdminRoot()`. CarPlay/deep links/push cannot initialize the legacy container. Remote notifications remain unregistered; background modes remain empty.
- Supporting tools reuse `Design` charcoal/gold tokens. Closing them returns to administration; no host/profile authority is inherited by local capture.
- Shared store refresh must publish only complete successful reads, in place, without recreating the store or scavenging live backup staging. Editors/audio/backup use the same store instance.
- Inbox requests must defer across editors, pickers, media, OCR and storage operations. Repeated Shortcuts calls must not be lost merely because an inbox was already open.
- Native sources and tests, Share extension dependency/embed, shared queue and App Intents are included in both the checked-in project and recursive XcodeGen inputs. Source membership checks are structural, not compilation.

## Backup reliability is not certified

The preserved implementation already uses streaming v2 `.hermesbackup` media rather than archive-sized base64 JSON. Its configured semantic payload bound is 256 MiB; manifest JSON is separately capped at 8 MiB. Legacy JSON is import-only with 8 MiB encoded / 4 MiB decoded bounds. This integration does not claim the old 256 MiB JSON memory problem is solved by a source-level size constant. Near-limit memory/latency, Foundation decoding overhead, Files providers, cancellation and device durability still require real native/hardware tests. Larger legacy JSON backups are refused intact; no off-device migration tool is supplied. See [BACKUP_CAPACITY.md](BACKUP_CAPACITY.md).

## Signing matrix and release blockers

| Target | Bundle ID | App Group | Release signing currently declared |
| --- | --- | --- | --- |
| HermesMobile | `cool.n0thing.hermes` | `group.cool.n0thing.hermes` | Team `VYJS7JMXU5`, manual `cool.n0thing.hermesZ` |
| HermesMobileWidgets | `cool.n0thing.hermes.Widgets` | same group | Team `VYJS7JMXU5`, manual `cool.n0thing.hermes` |
| HermesShareExtension | `cool.n0thing.hermes.Share` | same group | Empty team, automatic; **no verified distribution profile** |

Main app retains HealthKit/read/background-delivery entitlements from the existing project; local launch does not exercise them. Widgets and Share use the shared group only. App, widget and Share build numbers use `$(CURRENT_PROJECT_VERSION)`.

Read-only GitHub secret-name inventory exposes main/widget profile secrets but no Share profile secret. Names alone do not prove profile content, expiry or certificate match. No profile was invented/reused, and no signing credential or portal setting changed. The existing TestFlight workflow still provisions/exports/verifies main and widget only; it is **not ready for this three-target candidate and must not be dispatched**. A verified Share App ID/group/profile and complete three-target export/signature checks are required first. The Share target is not silently excluded to obtain an archive.

## Verification and CI resource policy

Native regression sources and executable source guards accompany integration; source guards do not execute Swift. Linux has no Xcode/Swift toolchain. The prior permission to proceed without local native execution remains disclosed, not treated as native success.

GitHub billing was reported resolved with 900 included minutes left. Finish local suites, project/plist checks, security scan and independent review before one candidate push. The `feat/**` push itself triggers the exact-SHA iOS CI run: do not additionally dispatch it or rerun the old baseline. Preserve all four required release-gate jobs. Native tests depend on the unsigned build, preventing a duplicate compile after a known build failure; build/test timeouts are bounded at 20/35 runner minutes rather than 45/45. No test selection or release-gate condition was removed. macOS usage is more expensive than Linux and the stated allowance is not 900 macOS runner minutes; do not enable paid overage or change billing settings. Inspect that run and report actual status. No TestFlight dispatch without exact-SHA native gate **and** the signing blocker resolved.

Detailed execution counts and commit/run IDs belong in the final handoff rather than a premature success claim here.
