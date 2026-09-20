# Integrated local intelligence review

> **Integration update:** Administration remains primary. Explicitly authorized local features are now secondary supporting tools; automatic connected/sensor/voice startup remains disabled. This document preserves earlier milestone evidence and may describe superseded launch/scope or test counts. The [current build integration matrix](CURRENT_BUILD_INTEGRATION.md) is authoritative for reachability, gaps and release blockers.

## Boundary

This feature uses only Apple's default **on-device** Foundation Models language model. It has no server, custom model, tools, networking, legacy service initialization, capture-store reference, attachment access, persistence, or automatic application of results. Ordinary local capture remains usable when intelligence is unavailable.

The sheet accepts a **String value snapshot**, the editor’s current `capture.text`, including unsaved edits and previously extracted OCR/transcript text when present. It never receives a capture/store binding, attachment, image, recording, URL or identifier. It does not perform OCR or transcription itself. Existing title and body remain untouched. Generated title, short summary and proposed task strings are ephemeral, editable suggestions; tasks are not created or scheduled.

## Integrated presentation and build membership

The four `LocalCaptureIntelligence{,Views,ReviewModel,SystemProvider}.swift` app sources and `LocalCaptureIntelligenceTests.swift` are registered in checked-in `project.pbxproj` file references, groups and their correct target source phases. `project.yml` already includes app/test folders recursively.

`LocalCaptureEditor` displays `LocalCaptureIntelligenceCapabilityView()`. An explicit **Open AI review** action captures its current editable text in a `ReviewSnapshot`, including unsaved changes. Every opening creates a fresh UUID and presents `LocalCaptureIntelligenceReviewSheet(text: snapshot.text)` with that identity. There is no binding back to the capture and no store, attachment or identifier passed to the review sheet.

The sheet contains its own NavigationStack. Opening it checks capability only; a second explicit **Review on device** button initiates generation. Editing its temporary excerpt or suggestions does not modify the editor, capture or checklist. Dismiss/reopen starts from a new snapshot of the editor text. Capability refresh, capture, import and background hooks never initiate generation.

The existing remote-disable policy is unchanged. No permission, model download manager, entitlement, network endpoint or legacy service initialization was added.

## Availability and limits

- `#if canImport(FoundationModels)` guards the import, implementation and generated schema. Older SDK builds expose a clear unavailable fallback rather than guessed framework symbols.
- Runtime use additionally requires `#available(iOS 26.0, *)`.
- `SystemLanguageModel.default.availability` is checked on entry, manual refresh, foreground return, and before each generation. The UI distinguishes ineligible device, Apple Intelligence disabled, model not ready and unknown/unavailable reasons.
- `supportsLocale(Locale.current)` checks the current locale, not the language of arbitrary pasted text. A supported device locale does **not** guarantee every input language is supported. Unsupported input languages, safety refusal, context exhaustion and other generation failures show a safe retry message. Raw framework errors are not displayed or logged because they might contain input content.
- Model availability also depends on Apple's device, region and system state. The system may need to download/prepare Apple Intelligence assets. This app does not initiate a download or send capture text to a cloud fallback.
- Input must contain non-whitespace text and fit **2,000 UTF-8 bytes**. Oversize input is rejected, never silently truncated. The exact accepted string is passed unchanged to the provider. A byte budget is conservative but not a tokenizer guarantee; the framework may still reject context length.
- Each review creates a fresh, single-turn session with an explicitly empty tools array and Apple's default guardrails. Structured output uses `@Generable`, `@Guide`, `respond(to:generating:)` and `response.content`. Field guides request a short title, one/two-sentence summary and zero to five tasks, but prose/semantic quality and those descriptive length preferences are not deterministic guarantees.
- Source text is placed in the lower-priority prompt, never in session instructions. Instructions treat it as untrusted data. Prompt injection can still affect suggestions; no tools, execution, writes or automatic application exist.

## Lifecycle and privacy

The MainActor observable review model has idle, reviewing, ready, unavailable, failed and cancelled phases. Starting another request cancels the previous task and rotates a request UUID. Cancel, sheet dismissal, disappearance and leaving the active scene all cancel and invalidate generation. A cancelled/older generation cannot publish either a late success or late failure, even if its provider ignores cancellation. Foreground return refreshes capability only and never resumes generation automatically. Physical model work termination is controlled by Apple's implementation; the app guarantees task cancellation requests and stale-result suppression, not immediate hardware shutdown.

Suggestions are discarded on cancellation/dismissal/background. The temporary text draft remains while the sheet remains presented. These controls are not a secure-memory erasure or app-switcher snapshot-redaction guarantee.

Only an explicit Copy action writes to the clipboard: `localOnly: true` prevents Universal Clipboard transfer for that item and an expiration is set to two minutes. Other apps on the same device may read copied text. Native text-editing copy commands follow the system's normal clipboard behavior. No clipboard is read. Edits/copies do not persist suggestions into captures.

## Verification sources

API verification used Apple's official DocC JSON (downloaded directly because the configured web extractor was search-only), before writing the system provider:

- [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models): availability, fresh sessions, trusted instructions, `LanguageModelSession(instructions:)`, context constraints, on-device behavior.
- [Generating Swift data structures with guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation): `@Generable`, `@Guide`, typed `respond(to:generating:)`.
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel): `.default`, runtime availability and locale support.
- [UnavailableReason](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason): `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`.
- [supportsLocale(_:)](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/supportslocale(_:)): signature and iOS 26.0 introduction.
- [LanguageModelSession initializer](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/init(model:tools:instructions:)): system-model/String-instructions overload and explicit tools argument.
- [LanguageModelSession.Response](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/response): typed `.content`.

For any documentation URL above, the accessible JSON form is `https://developer.apple.com/tutorials/data/documentation/... .json` (without the space). No newer custom/remote LanguageModel abstraction is used.

## Integrated checks

- `python3 -m unittest discover -s scripts/tests -v`: **36 tests passed** after integration. Guards cover app/test target registration, fresh editor text snapshot presentation, backup/task integration and local-only launch dependencies. This is source/script validation, not Swift execution.
- `git diff --check`: passed; a separate whitespace scan covers untracked local feature sources/tests/docs.
- Added a native UI case before wiring the editor: unsaved text arrives verbatim, changing the review copy leaves the editor unchanged, and dismiss/reopen starts a fresh copy without automatic generation. It has **not run**.
- Backup validation/export now include checklist titles in the aggregate budget; native boundary/adversarial/import-fidelity cases are also unexecuted. See [LOCAL_WORKSPACE.md](LOCAL_WORKSPACE.md).

## Tests and pending validation

XCTest source was written before the corresponding implementation slices. **Native compile/test execution is deferred by the user's explicit approval**; no Swift/Xcode execution, simulator, CI, device install, commit or push occurred. This is test-first source, not an observed RED/GREEN run.

The mockable `LocalCaptureIntelligenceProviding` seam supports deterministic continuation-driven tests without loading/generating from the real model. Tests cover:

- empty, exact-boundary, oversized and multibyte input; preservation of original input;
- capability inspection without generation;
- unavailable/input-invalid paths never invoking review;
- exact text delivery and editable successful suggestions;
- cancellation/dismissal ignoring a cancellation-uncooperative provider;
- stale old errors not overwriting a newer result;
- background cancellation clearing suggestions and refresh not generating;
- visible failure and retry/cancellation state.

Executed Linux source checks passed for four isolated Swift sources: no network/store/persistence dependencies, conditional/runtime Foundation Models guards, typed generation, stale success/error suppression, a single user-action generation site, lifecycle cancellation, and local-only expiring clipboard options. Nine XCTest methods were enumerated (not executed). `git diff --check` passed for tracked changes; a separate whitespace check covered these new Swift files. These are source checks only; they cannot validate Swift typing, macro expansion, actor isolation, linking, SwiftUI behavior or Foundation Models runtime.

Before shipping, on an approved Mac/Xcode 26+ setup: compile both targets, run these XCTest cases, and manually exercise the sheet on a supported physical device with Apple Intelligence enabled and ready, disabled and not-ready scenarios, unsupported device fallback, locale/input-language mismatch, airplane-mode generation, safety refusal, large excerpts, cancellation, rapid dismiss/reopen, background during generation, editable suggestions, clipboard behavior and VoiceOver/Dynamic Type. The current checked-in project and generator target iOS 26.0. Older SDK/OS source guards are defensive, not a shipped older-iOS support claim; lowering that target would require separate SDK/linking validation. Verify that no legacy app boot path/network request is invoked by presentation. Do not claim availability or offline generation has been device-verified until that run occurs.
