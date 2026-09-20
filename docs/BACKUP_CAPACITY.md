# Local backup: file-streamed version 2

New exports are **one `.hermesbackup` file**, not a base64 JSON document. The
implementation is present; **Swift/Xcode compilation, XCTest and device execution
have not executed on this Linux host**. Do not describe capacity reliability as
verified until the native acceptance checklist below passes.

## Wire format and hard limits

- Bytes 0–7: ASCII `HLCB0002` (format/version discriminator).
- Bytes 8–11: unsigned 32-bit **big-endian** manifest byte length.
- Next bytes: UTF-8 JSON manifest, at most **8 MiB**, `format:
  HermesLocalCaptures`, `version: 2`, ordered `entries`. Each entry contains capture
  metadata and an ordered media list of `name`, nonnegative integer `size`, and
  32-byte SHA-256 `sha256` (JSON base64 for the digest only).
- Remaining bytes: **raw uncompressed media**, concatenated in entry/media order,
  exactly the declared sizes. No alignment/padding, trailers, embedded paths,
  ZIP extraction, encryption, or compression.
- Aggregate UTF-8 title/body/checklist titles plus media: **256 MiB = 268435456
  bytes**. Manifest and semantic payload ceilings are independent; metadata-heavy
  libraries may hit the manifest limit first. Wire length must equal
  `12 + manifestLength + sum(media.size)` and EOF must follow the final media byte.
- At most 1,000 captures, 100 attachments/capture, 64 KiB title, 1 MiB body,
  100 checklist items/capture, 1,024 UTF-8 bytes/nonblank checklist title, unique
  capture IDs and capture-scoped task IDs. Dates must be finite. Missing, duplicate,
  mismatched, wrong-kind or path-like attachment names are rejected.
- Before JSON decoding, a quote/escape-aware scan rejects nesting deeper than 32.
  JSON remains bounded in-memory metadata, **not constant-memory parsing**. The
  manifest bound limits input, not Foundation parser/model overhead or peak RSS.

## Data flow, safety and ownership

`LocalCaptureStore.backupSources()` snapshots value metadata and app-private file
URLs only. Export runs in `Task.detached`, validates metadata and regular source
files, hashes media using **64 KiB** FileHandle reads, then writes a protected
archive directly from those source files. A second streaming hash during writing
must match the first: changed, missing, growing or truncated media fails the entire
export. Nothing is silently omitted. Save edits and stop recording first.

The Files exporter uses `UIDocumentPickerViewController(forExporting:asCopy:)`
with a file URL, **not FileDocument or an archive-sized Data/FileWrapper**. A
lifetime owner retained through the picker delegate keeps its protected temporary
archive available until completion/cancel. Files providers can allocate their own
buffers; their memory use, completion semantics and copy retention need device
verification and are not controlled by this implementation.

Imports retain security-scoped provider access across an NSFileCoordinator read.
A detached worker checks the manifest/total file length, then streams and hashes
media into app-private `.backup-import-UUID` directories. Source files are opened
with `O_NOFOLLOW`, checked with `fstat` for regular-file type and capped size;
export source directories must not be symlinks. Only validated attachment
basenames are used under freshly generated UUID directories. Truncation, trailing
bytes, bad checksums, unsupported versions, invalid metadata and limit violations
reject the complete operation. Empty archives and zero-byte media are valid.

All staging folders, metadata, media and temporary exports have complete file
protection and backup exclusion before payload writes. File writes synchronize
before the worker returns a prepared owner. **Only after complete validation and
staging** does the UI offer confirmation. No Files URL is retained for confirmation.
On confirmation the store checks ownership/ID collisions and publishes with one
same-volume directory rename to `.batch-UUID`. No throwing work follows the
rename. Capture IDs are regenerated; titles, body, dates, pin/archive state,
checklist IDs/completion and media order/bytes survive. Repeated imports duplicate
all records, not merge or replace them. Intake receipts are not backed up or
rewritten; existing share/intents intake handling is unchanged.

Cancellation is checked between reads/writes/records and before returning the
prepared result; progress is a lock-protected byte counter polled by the UI, not a
queue of per-chunk tasks. Cancellation cannot interrupt a blocked provider read,
coordination wait or a single filesystem operation; cleanup finishes when that
operation returns. A cancelled worker cannot publish a preview/export later.
Failure/cancel/declined confirmation release temporary ownership; startup scavenges
only UUID-suffixed `.backup-import-`/`.backup-export-` copies. It never scavenges
original capture `.staging-` recovery folders, committed batches, saved captures,
intake queues/receipts or Files destinations. Cleanup failure leaves invisible
copies for next-start retry, not lost originals. Recursive owner/startup cleanup is
queued off-main on a serial utility queue, so releasing a preview does not delete
thousands of files on the UI thread. The app still has one store/window;
startup scavenging must not be run concurrently with active backup jobs.

This is **atomic visibility**, not a power-loss durability guarantee. Individual
files are synchronized, but directory fsync/power-loss/APFS behavior is not verified.
Private protection does not encrypt the exported file; checksums detect damage,
not malicious editing or authenticity. No network client, credentials, agent,
automatic transfer or backup schedule is introduced. Files/iCloud/third-party
providers may upload/download at the user's selection. An app-owned On My iPhone
folder may disappear at uninstall: choose an independent destination and verify it.

## Disk admission is advisory, not a reservation

Before creating output, check volume free capacity (prefer ordinary available
capacity; use important-usage capacity only if that is unavailable). Compare only
**additional output bytes** against free space, adding a **16 MiB reserve**, 4 KiB
per media file and 16 KiB per record for small-file/directory/metadata overhead.
Export budgets archive bytes; import budgets staged media and manifest metadata.
Existing originals/input files are already reflected in free space and are not
subtracted again. Unknown/insufficient free capacity refuses the operation.
This is not a reservation or precise APFS allocation estimator: other writers,
allocation units, provider copies and purging can invalidate the estimate. Every
write/synchronize/rename failure still aborts without replacing originals.

## Legacy version 1 compatibility

Import-only compatibility remains for `HermesLocalCaptures` version-1 JSON:
**8 MiB whole document and 4 MiB decoded text/media**. The independent input cap
and nesting check apply before JSONDecoder; semantic/checksum validation follows.
This still has parser/base64 amplification and is deliberately small; it is NOT
safe to decode old 384 MiB JSON on-device merely because a decoded-size cap exists.
Large previously exported v1 backups are refused, not deleted or truncated.
Keep those copies intact. If originals remain in the app, make a v2 export.
If only a larger v1 backup remains, a separately tested off-device migration tool
is still needed; one is not supplied or claimed here. Old app builds cannot read v2.

## Verification and required native acceptance

Tests were written before implementation under the explicitly authorized native
execution exception. The four updated Python backup source guardrails were
observed failing first. All `scripts/tests` checks are run again after integration;
they inspect source / execute existing Python scripts, **not the Swift archiver**.
Observed Linux results: `bash scripts/verify-local.sh` passed **43 script/source
checks, 70 relay tests, and 88 connector tests**. The relay suite emitted 12
existing deprecation/duplicate-operation-ID warnings. A final system-Python source
rerun also passed 43 checks; `git diff --check` and a separate whitespace scan of
all 10 changed feature/test/doc files (including untracked files) passed. These
are not Swift, Files-provider or full-capacity execution results. Existing checked-in
PBX and recursive XcodeGen inputs already register the modified app/test files;
no extra Swift source files or target membership changes were required.

Native XCTest source covers empty and all-kind round trips, repeated fresh IDs,
workspace metadata/media retention, editing/deletion/re-export, protection flags,
every-byte truncations on a tiny archive, trailing bytes, checksum corruption,
malformed metadata/version/path/size, task-title payload boundaries, cancellation,
pre-rename rollback, preview lifetime cleanup, symlink rejection, startup cleanup
scope, small/overlimit legacy JSON, directory-URL spelling and a sparse-file
256 MiB round trip without a giant Data allocation. These cases are **not executed** here.

Before release on an authorized Xcode/iOS host:

1. Compile app and tests with Swift 6 strict concurrency; run all local capture,
   backup, intelligence and intake XCTest/UI suites. Source checks cannot validate
   Darwin/Foundation signatures, isolation or SwiftUI/picker lifecycle ordering.
2. Round-trip exact 256 MiB media/text libraries and one-byte-over cases on the
   oldest supported device, measure RSS and responsiveness during both hash passes,
   staging, confirmation and cleanup. Test escaped/metadata-heavy manifests at 8 MiB.
3. Exercise picker local/iCloud/third-party copy, cancel, failure, offline download,
   sheet/navigation dismissal and task cancellation. Confirm no stale presentation,
   use-after-cleanup, frozen Cancel UI, or temporary leftovers after restart.
4. Test low/free-disk races, locked data, media changing between hash passes,
   permission failures, corrupt/checksum/truncated inputs and unexpected process
   termination before/after rename. Verify saved captures/intake receipts unchanged.
5. Inspect complete protection and backup exclusion on real devices and verify
   exported copies independently. No full-capacity reliability, provider retention,
   uninstall survival or power-loss durability claim is justified by source review.
