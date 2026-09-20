# Integrated local workspace

> **Historical implementation:** The local workspace is frozen and absent from the current dashboard-management navigation. This document preserves earlier engineering evidence; [current integration](CURRENT_BUILD_INTEGRATION.md) and the [dashboard parity roadmap](DASHBOARD_PARITY_ROADMAP.md) govern product scope and reachability.

## Implemented

- Search saved titles and capture text (including OCR/transcripts), case/diacritic insensitive, trimming search whitespace. Search never rewrites source content.
- Kind filter: all kinds, note, photo, document, voice. Independent Active, Pinned and Archived scopes; archived captures are excluded from Active and Pinned.
- Pinned-first ordering, then newest capture, with UUID tie-breaking. Archive/unarchive retains pin state and original content/media. Reset clears all filters.
- Capture actions menu: pin/unpin, archive/unarchive, permanent delete with confirmation. Filtering stops playback. Opening editor/checklist/picker or Storage & backup also stops playback instead of hiding its stop control.
- Offline transcription progress/cancel lives in a bottom inset outside filtered rows, so search/kind/scope changes cannot hide cancellation.
- A separate local checklist sheet per capture: explicitly add, complete/reopen and remove with confirmation. Changes persist immediately. New titles are trimmed; blank titles are rejected. No scheduling, agent execution, networking or automatic uploads.
- Checklist writes resolve the latest capture by ID and publish only after a successful protected atomic metadata save. Original text, timestamps and attachments are untouched. Failed writes retain published state and show an error; failed additions retain the draft.
- Checklist bounds: 100 items per capture, 1,024 UTF-8 bytes per title, nonblank titles and unique IDs within a capture. Decoding, metadata writes and backup validation reject malformed checklist data rather than silently dropping it.
- Capture editor shows on-device AI capability and an explicit **Open AI review** action. It snapshots the current editable body, including unsaved edits, into a fresh sheet identity. Opening the sheet does not generate; **Review on device** is a second explicit action. Suggestions remain editable temporary copies, never capture/checklist writes. See [LOCAL_INTELLIGENCE.md](LOCAL_INTELLIGENCE.md).
- Accessible text-labelled controls, not swipe-only actions. Native VoiceOver/Dynamic Type verification remains pending.

## Coding and backup compatibility

`LocalCapture` adds `isPinned`, `isArchived` and `tasks`. Custom decoding supplies false/false/empty when additive keys are absent, including older capture files and version-1 backups. Encoding retains all fields. Task IDs are scoped to the owning capture; copied/imported captures may retain them safely.

Import assigns new capture IDs while preserving organization, task IDs/completion, title/body, timestamp and attachments. Existing records are not replaced. Export includes archived records and all checklist data, not just visible/filtered records. Repeated imports intentionally create duplicates with unique capture IDs.

Streaming export and archive validation count UTF-8 checklist-title bytes toward the same 256 MiB aggregate text/media budget. Version-2 file-backed backups have an independent 8 MiB manifest limit; legacy version-1 JSON is import-only under 8 MiB encoded / 4 MiB payload bounds. Validation calls `capture.validateWorkspace()` for constructed and decoded metadata. Batch commit, checksums and explicit Files confirmation preserve organization/checklist content. See [BACKUP_CAPACITY.md](BACKUP_CAPACITY.md) for the new format, legacy migration limits and pending native verification; older builds cannot read v2.

## Files and build integration

- `LocalCaptureStore.swift`: additive decoding, library projection, organization/checklist operations, import preservation and aggregate export accounting.
- `LocalCaptureRoot.swift`: search/filter/actions/checklist UI, persistent transcription cancellation control and isolated AI review presentation.
- `LocalCaptureBackup.swift` / `LocalCaptureStorageView.swift`: aligned payload/task validation and disclosure.
- Four `LocalCaptureIntelligence*.swift` app sources and `LocalCaptureIntelligenceTests.swift` are registered in the checked-in PBX file references, groups and correct target source phases. Existing recursive `project.yml` inputs already include them; no generator change is needed.
- `LocalCaptureTests.swift`: migration, projection, persistence/failure, original-media preservation and import/re-export/repeated-copy metadata fidelity.
- `LocalCaptureBackupTests.swift`: aggregate exact-limit/one-byte-over tests with multibyte checklist titles; malformed direct/decoded archives, duplicate task/capture IDs and unchanged originals after rejection.
- `LocalCaptureUITests.swift`: workspace interactions and an unsaved-body AI snapshot/edit/discard/reopen case that never requests model generation.
- `scripts/tests/test_local_workspace_sources.py`: source-only migration/import/UI/accounting and target registration guardrails.

## Actual integration checks

Native regression source was added before the related integration/accounting changes. **Native compilation, XCTest/UI execution and native RED/GREEN remain explicitly deferred under user permission.** No Swift/Xcode commands were run. Python guards do not execute Swift, Foundation Models or SwiftUI.

- Observed source-guard RED for absent task accounting/validation, missing editor integration, missing app/test registrations and cancellation hidden in filtered rows; GREEN after fixes.
- `python3 -m unittest discover -s scripts/tests -v`: **36 tests passed** after integration, including the previously failing four app-registration subtests.
- `git diff --check`: passed for tracked changes. A separate Python whitespace scan covered 19 local feature/test/doc files, including untracked files: zero whitespace errors.
- PBX object-ID scan: 400 unique definitions, no duplicates. Correct intelligence target source membership is separately guarded by the Python tests.
- Static scan of added tracked lines and local Swift/Python sources found no matches for the checked hardcoded credential, shell-execution or pickle-deserialization patterns. This is not a security audit.
- Read-only source review covered launch/remote gating, audio/OCR callbacks, search/filter/checklist interactions, backup import/export and the AI provider/model/views. This was not an independent reviewer run or runtime QA.

## Pending validation and limitations

1. On an authorized Xcode host, compile app/test targets and run LocalCaptureTests, LocalCaptureBackupTests, LocalCaptureIntelligenceTests and LocalCaptureUITests. Native tests have not been observed red or green. Swift 6 isolation, Foundation Models macros/API typing and nested sheet behavior remain unverified.
2. Device: relaunch; pin/filter/archive/unarchive composition; checklist add/complete/reopen/remove and write failure; legacy/new backup import/re-export; media bytes unchanged; exact aggregate boundaries and duplicate-ID rejection.
3. Device: capability/unavailability, current unsaved-text snapshot, explicit generation/cancel/background/dismiss/reopen, suggestion editing and clipboard expiry. No automatic apply or cloud fallback is implemented.
4. Device: VoiceOver, largest Dynamic Type, small-screen keyboard/scrolling, menus and nested sheets; filter during offline transcription (cancel stays available); playback stops when covered; capture/OCR/transcription regressions, protection/lock, Files providers and crash durability.
5. Near-limit streaming backup/manifest decoding and large image previews still require hardware memory/latency profiling. Uninstall deletes app-private records; exported copies are not encrypted by Hermes. Ordinary native text-selection copy uses system clipboard behavior.
6. Current project deployment target is iOS 26.0; source fallbacks for older SDK/OS are not a shipped older-iOS compatibility claim. Legacy remote code/frameworks remain compiled but are not initialized through local launch. Widgets can retain stale legacy cache data.

No commits, pushes, deployment, CI execution or secrets access were performed.
