# Native failure diagnosis and device protection gate

Baseline: `35490456382`, revision `0a03eb0`, Xcode 26.6 / iOS Simulator 26.4.1. Log: 78 passed, 6 failed, 6 skipped. GitHub reported zero artifacts; the log contains a sparse accessibility hierarchy for the ambiguous Done failure, but no full hierarchy for the other UI failures.

## File protection: do not turn nil into success

Both assertions conditionally cast `attributesOfItem()[.protectionKey]` to `FileProtectionType`. Apple documents the value as **NSString**:
https://developer.apple.com/documentation/foundation/fileattributekey/protectionkey

Read the documented String value and compare to `FileProtectionType.complete.rawValue`. The baseline's nil is the result of a conditional cast; it does **not** establish that the underlying attribute is absent, nor that protection is missing. Retain strict equality for metadata and every original/imported attachment. No simulator conditional, nil fallback, blanket skip, or production protection change is justified by that log. The next native result must establish whether the corrected readback succeeds on this simulator. A missing raw attribute still fails.

Apple describes passcode-enabled, hardware-accelerated data protection and Complete files as accessible only when unlocked:
https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files
Apple explicitly says simulator doesn't replicate physical-device features and requires physical-device testing:
https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices

These are **not** evidence that this specific simulator must return nil for protectionKey. Do not cite them as such. Attribute readback in a simulator is not evidence of real-device encryption or lock enforcement.

## Required physical-device gate — still unverified

Before claiming data protection verified, run `LocalCaptureTests/testFilesAreExcludedFromBackupAndProtected` and `LocalCaptureBackupTests/testRoundTripMultipleKindsMetadataRepeatedImportAndReexport` on a passcode-enabled physical iPhone at the release SHA, retaining the xcresult. Confirm Complete readback for fresh metadata, attachments, imported copies, and rewritten metadata; backup exclusion must remain true. Separately exercise locking/unlocking during capture/storage operations: protected reads/writes must be unavailable once protected data becomes unavailable, operations must report failure without overwriting existing data, and reopening after unlock must recover the originals. Record hardware, iOS, SHA, results, and the lock/unlock observations. Simulator CI cannot satisfy this gate.

## UI regressions

- The recorded tree contains two Done buttons: disabled library Done and active Review on device Done. Scope nested dismissals by navigation bar, including the previously unreached checklist Done.
- Saved rows/actions follow multiple large instructional and capture sections in a lazy SwiftUI List. Waiting for a nonexistent offscreen row does not materialize it. Reveal with bounded scrolls and require existence AND hittability; retain search/archive/checklist assertions. Persistence now reopens and verifies the body before and after relaunch, not merely any title-containing button.
- LabeledContent does not promise a separate staticText node for its value. Expose the signed-in-identity label/value explicitly with a stable identifier; assert the exact Not authenticated value. No authentication/transport is introduced.
- Capture full test results as a seven-day exact-SHA CI artifact even on failure. No baseline rerun is needed.

The Python source guards are red/green structural checks only, not native execution. TestFlight additionally remains blocked on the native gate and actual Share extension profile verification; this corrective work performs no signing, portal, backend, or secret changes.
