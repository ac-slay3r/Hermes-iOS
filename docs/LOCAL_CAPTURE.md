# Local capture milestone

> **Historical implementation:** Local capture is frozen and absent from the current dashboard-management navigation. This document preserves earlier engineering evidence; [current integration](CURRENT_BUILD_INTEGRATION.md) and the [dashboard parity roadmap](DASHBOARD_PARITY_ROADMAP.md) govern product scope and reachability.

## Product contract

The default and only reachable app experience is **Local captures**. No account,
relay, pairing, agent, sensor upload, or remote feature toggle is required or
provided. Existing remote implementation files remain in the repository but are
not constructed from this launch path. Existing pairing credentials/settings are
not read, migrated, or deleted.

- Create text notes; review and explicitly save title/text edits; delete captures
  with confirmation. Cancel abandons edits, not the already-created capture.
- Take a photo, import one selected photo, or scan a multipage document. Review
  captured page images; run Apple's Vision OCR explicitly and edit the result.
  Scans are ordered JPEG pages, **not PDFs**. Images are orientation-normalized,
  capped at 3000 pixels on the longest side, and re-encoded without source EXIF.
- Record voice with an in-app microphone indicator and pinned stop control. Stop
  on app background or audio interruption; never automatically resume. Play/stop
  recordings and explicitly request offline Speech transcription.
- Speech first checks `supportsOnDeviceRecognition`, requests permission, and sets
  `requiresOnDeviceRecognition = true`. There is **no server fallback**. Device,
  language, installed recognition resources, permissions, and OS availability can
  prevent transcription. Failures, cancellation, and the 90-second timeout retain
  the recording. Transcripts and OCR append to existing text rather than erase it.
- **System picker distinction:** selecting an iCloud-only photo can cause Apple's
  photo picker to download its original. This user-initiated system operation is
  disclosed in the UI; it is not an app upload or a promise of zero device-wide
  network traffic. Select an already-downloaded image or use the camera in airplane
  mode for fully offline acquisition. OCR and Speech processing are local.

Capture files are app-private, protected while locked, and excluded from backup.
There is no automatic sync. Explicit Files export/import is available under
**Storage & backup**. **Uninstalling the app loses app-private captures.** iOS permissions are requested only on the corresponding user
action; denial produces a message directing the user to Settings. No Health,
Location, Motion, push-notification, or broad photo-library authorization is requested.

## Explicit Files backup and restore

Open **Local captures → Storage & backup**. The screen shows saved capture file
bytes (metadata plus media; not temporary staging, filesystem overhead or exports).
Stop recording/processing and save pending image imports before opening it.

- Tap **Export all captures to Files**, then choose and save a destination in the
  system exporter. Nothing is exported on launch or in the background. Export is
  all-or-error, never a silently incomplete subset.
- Files destinations can be **iCloud Drive or third-party providers** and may
  upload data. For local storage choose **Browse → On My iPhone** (On My iPad).
  **A Hermes-owned On My iPhone folder may be removed when Hermes is uninstalled.**
  Choose an independent destination and verify the copy there. Local-only is not
  a guarantee of uninstall survival or protection from device loss; make an
  explicit off-device copy for that protection. Hermes cannot verify provider
  retention, completed cloud uploads, or survival after uninstall.
- Backups are **not encrypted by Hermes**. Destination permissions/provider
  protection govern the exported copy, not app-private protection/backup exclusion.
- Tap **Choose backup to import** and select a `.hermesbackup` file (or small
  legacy JSON document). Cloud providers may download it. A background worker
  holds coordinated, security-scoped access while streaming into protected private
  staging. The complete file is validated before **Import copies** is offered.
  Cancel discards only the staged copies. Confirmation commits one directory rename.
- **Every import creates new capture UUIDs**, even exact duplicates/repeated imports.
  Titles, text, timestamps, pin/archive state, checklist IDs/completion and ordered
  attachment bytes are retained. Existing records and intake receipts are untouched.
- Both preparation operations run off the main actor with byte progress and Cancel.
  The Files exporter receives an on-disk URL, not a complete in-memory JSON document.

### Version 2 streamed archive and legacy compatibility

See [BACKUP_CAPACITY.md](BACKUP_CAPACITY.md) for the complete wire format, validation,
resource budgets, lifecycle and pending native acceptance. New exports use
`Hermes-local-captures-<UUID>.hermesbackup`: magic `HLCB0002`, big-endian manifest
length, bounded version-2 JSON metadata, then ordered raw media. The **256 MiB
aggregate text/media** ceiling is independent of the **8 MiB manifest** ceiling.
Media hashing/copying uses **64 KiB chunks**; media are never accumulated as Data.
All saved records, including archived ones, are included or export fails visibly.
Existing bounds remain: 1,000 captures, 100 attachments/capture, 64 KiB title,
1 MiB body and 100 nonblank checklist titles of at most 1,024 UTF-8 bytes each.
Checklist text counts in the aggregate budget. Manifest decoding is bounded
in-memory metadata, not a constant-memory parser or a device peak-RAM guarantee.

Legacy version-1 base64 JSON is **import-only, at most 8 MiB encoded / 4 MiB
text/media**. Large old JSON backups are preserved but refused, because decoding
them on-device has unacceptable memory amplification. If originals remain, export
v2; otherwise a separately verified off-device converter is still needed.

Validation rejects malformed versions/metadata, duplicate IDs/media names,
non-finite dates, invalid task data, traversal/wrong-kind attachment names,
symlinks, nonregular files, declared-length errors, truncation, trailing bytes,
checksum failures and capacity violations. No decompression or path extraction is
performed. Checksums detect damage, not authenticity; exports are not encrypted.

Validated imports stage under `.backup-import-UUID` and become `.batch-UUID` by one
same-volume rename. No throwing work follows publication. Imported records support
editing, media access, deletion and re-export. Temporary ownership and startup
cleanup remove only reserved backup copies, never original `.staging-` capture
recovery data, batches or Files destinations. Failed cleanup can leave invisible
copies for next-start retry. Disk admission budgets additional output plus a safety
reserve but is not a free-space reservation. File synchronization and atomic rename
are not a guarantee against power loss, hardware failure or filesystem corruption.
Old app versions cannot read v2; preserve independently verified backups.

## Architecture and failure semantics

- `AppEntry.swift`: launches `LocalCaptureRoot` directly, without `AppContainer`.
  Unregisters legacy APNs registration; ignores token callbacks and deep links;
  remote wake always finishes with `.noData` and never initializes remote services.
- `CarPlaySceneDelegate`: hard-disabled before creating `CarPlayVoiceManager`.
  XcodeGen's CarPlay scene entry and background audio/location/remote-notification
  modes are removed. Multiple windows are disabled to avoid competing store and
  recorder instances. Widgets were inspected: they read the legacy shared cache
  and link into the app, not remote clients. Their links cannot escape local launch;
  they are not a local capture surface and may still show stale legacy cache data.
- `LocalCaptureStore`: main-actor observable store in Application Support/
  `LocalCaptures`, outside the shared widget container. One UUID directory per
  capture contains `capture.json` and attachment files. Metadata is atomically
  replaced using complete file protection. The protected root and capture folders
  are excluded from backup; image/audio files are explicitly protected too.
- New captures stage all files in `.staging-UUID` before an atomic same-volume
  rename makes the capture visible. Failed creation preserves staging files for
  recovery rather than deleting potentially captured bytes. Failed saves do not
  publish new state. Invalid metadata fails opening the library visibly; it does
  not silently reset storage. Unlock/retry is supported.
- Deletion first renames the entire capture directory to `.trash-UUID`, then removes
  all of it. Failure is reported; retry and next-open cleanup finish the operation.
  A committed deletion is not resurrected after an interrupted process.
- Voice commits metadata and its audio path before recording starts, so abrupt
  termination cannot leave an undiscoverable recording. Interrupted or failed
  recording files can be incomplete/unplayable; they are retained for review/delete,
  not claimed to be successfully recorded. The store never deletes audio because
  transcription is unavailable or failed.
- `LocalCaptureAudio`: AVAudioRecorder/AVAudioPlayer lifecycle and offline-only
  Speech. Generation tokens ignore stale transcription callbacks; recorder/player
  identity checks ignore late callbacks from prior sessions. Background/interruption
  notifications stop audio and cancel processing. Permissions do not auto-start
  recording if the app is no longer active.
- `LocalImagePicker`: camera, PHPicker and VisionKit bridges; cancellable system UI.
  `LocalCaptureOCR` performs Vision work off the main actor. Original saved images
  survive OCR failure. Image persistence happens before OCR is offered.
- `LocalCaptureRoot`: library, explicit save editor, preview, delete confirmation,
  action errors and retry. Failed image imports stay in memory for retry without
  replacing an earlier unsaved import. Text edits remain in the editor on save
  failure. Unsaved edits/imports are not guaranteed to survive app termination.

Metadata schema is internal/unversioned for this milestone. Future migrations must
preserve originals and handle unknown versions, not interpret failures as empty
storage. Staging recovery is presently manual (Xcode app-container inspection);
there is no in-app repair UI. Large scans/library reads run partly on the main
actor and need memory/latency profiling before a production-scale library release.
The inherited remote frameworks, entitlements and usage strings remain compiled;
this milestone disables reachable behavior rather than removing all legacy code.

## Build/test integration and validation status

New Swift files and XCTest files are explicitly included in the checked-in Xcode
project. `project.yml` already recursively includes their app/unit/UI directories,
so future XcodeGen generation also includes them. Plist and XcodeGen both disable
background modes and multiple scenes. No signing, CI, relay, or connector changes
are part of this milestone.

The initial XCTest store/policy cases were written **before** implementation.
Native RED/GREEN was explicitly deferred with user approval: this Linux host has
no Swift, Xcode, xcodebuild, or XcodeGen. **Swift compilation, XCTest, simulator,
and device validation have not run and are not claimed to pass.** Additional
source guardrails are not substitutes for compilation or runtime behavior.

Actual Linux checks:

```sh
python3 -m unittest discover -s scripts/tests -v
# Source/script checks only; see the latest task report for observed count.
git diff --check
# no whitespace errors
```

`HermesMobileTests/LocalCaptureTests.swift` covers note create/edit/reload/delete,
attachment removal, corrupt metadata preservation, failed-save published state,
attachment traversal rejection, audio persistence without a transcript, remote
policy/wake behavior, idle audio stop, and protection/backup attributes.
`LocalCaptureUITests` covers local launch and a persisted note across relaunch.
See [LOCAL_WORKSPACE.md](LOCAL_WORKSPACE.md) and [LOCAL_INTELLIGENCE.md](LOCAL_INTELLIGENCE.md)
for integrated search/filter/pin/archive/checklist, isolated AI review, new tests and
their still-pending native validation. The old pairing/chat UI test class is explicitly skipped because its UI is now
intentionally unreachable; model/store unit tests remain included.

On a Mac with the documented Xcode 26 / iOS 26 SDK, first build and run:

```sh
xcodebuild test -project HermesMobile.xcodeproj -scheme HermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Resolve any strict-concurrency/SDK issues before claiming this milestone usable
on hardware. Device-only APIs cannot be validated by the Linux source checks.

The initial `LocalCaptureBackupTests.swift` cases were added before implementation (native
execution deferred under the same approval). It covers all-kind round trip,
repeated imports with new IDs, malformed/version/name/list/checksum failures,
symlink and file-size rejection, and injected pre-commit failure/reload preservation.
Additional cases cover metadata/payload/count bounds and imported edit/delete/
re-export/protection/storage usage.
Python backup guardrails were observed failing before implementation and passing
with it. These inspect source only; they do not execute the Swift implementation.
The existing recursive `project.yml` source registration already covers the new
files; checked-in `.pbxproj` references and target source membership were added.

## Required native/device checklist (all pending)

- [ ] Build and execute new backup XCTest cases; verify Swift 6 concurrency and
      file-URL document picker/FileImporter SDK integration.
- [ ] Export all kinds, cancel exporter/importer/confirmation, reopen export and
      compare every media byte; verify import creates copies and imported records
      remain editable/deletable/re-exportable after relaunch.
- [ ] Files local/iCloud/third-party permissions, provider failure and offline
      download; check warnings with VoiceOver/Dynamic Type and iPad popovers.
- [ ] Test unknown versions, damaged/truncated archives/manifests, missing/duplicate media,
      traversal/control-character names, size/count boundaries, zero-byte original
      voice files, low disk and locked protected data. Confirm no existing loss.
- [ ] Force termination before and after batch rename; verify all-or-none import.
      Profile near-limit memory/latency and temporary-copy cleanup after cancel.
- [ ] Verify exported copies independently before uninstall; test Hermes-owned vs
      independent destinations without promising retention outside Hermes control.

- [ ] Fresh install and previously paired upgrade launch into local captures in
      airplane mode; no onboarding/agent UI or startup permission prompts.
- [ ] Instrument launch, active/background, APNs token/remote wake callbacks,
      `hermes://voice`, chat/health links, widget links, and CarPlay connection;
      verify no relay request, sensor start/upload, or `AppContainer` construction.
- [ ] Notes create/edit/cancel/save/relaunch/delete; VoiceOver, Dynamic Type,
      keyboard dismissal, dark mode, iPad layouts and delete confirmation.
- [ ] Camera deny/grant/restricted/unavailable, library cancellation and iCloud
      unavailable offline, multipage scan cancellation/error, page order/orientation,
      image preview, OCR no-text/error/unsupported scripts; source images retained.
- [ ] Mic deny/grant/revoke; record then stop/play/stop; background, screen lock,
      phone call, route interruption, force termination and relaunch. Indicator and
      stop remain visible; recording never silently resumes.
- [ ] Offline Speech supported device/language in airplane mode, unsupported locale,
      missing model, permission denial, recognition failure/timeout/cancel. Verify
      no fallback network transcription, audio retained and playable, text editable.
- [ ] Low disk, metadata write failure, attachment write failure, protected-data
      unavailable at launch, corrupt metadata, interrupted staging and deletion;
      no silent reset or loss of previously committed captures. Verify retry.
- [ ] Inspect app container protection/backup exclusion on real hardware after
      create/update/record/relaunch; delete removes all attachments. Confirm backup
      does not include captures and app-group/widget data never receives captures.
- [ ] Profile large scans/long recordings/large libraries, memory warnings, and
      callback ordering; inspect logs for private content (none intentionally logged).
