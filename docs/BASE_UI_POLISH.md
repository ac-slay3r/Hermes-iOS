# Base UI polish — first source slice

> **Integration update:** Administration remains primary. Explicitly authorized local features are now secondary supporting tools; automatic connected/sensor/voice startup remains disabled. This document preserves earlier milestone evidence and may describe superseded launch/scope or test counts. The [current build integration matrix](CURRENT_BUILD_INTEGRATION.md) is authoritative for reachability, gaps and release blockers.

## Delivery boundary

**Not reachable from normal app launch.** `AppEntry.swift` still launches `LocalCaptureRoot`; this slice deliberately does not change it. The polished production components belong to the retained legacy chat/inbox shell. This is source implementation, not a compiled, rendered, deployed or device-verified iOS experience.

An opt-in DEBUG Xcode canvas preview is provided in `Features/Chat/ChatInputBar.swift`, named **Base UI polish — no network or recording**. It composes the real `ChatInputBar` and `ToolActivityRail` with local sample state, not a replacement dashboard. It is a component preview, not a full connected shell or a launch argument. It has not been run here.

## Implemented scope

- Keep the original `Design` charcoal/gold tokens, composer, message layout and settings/voice architecture. No new navigation destinations or tabs.
- Compact **Assist** menu offers **Summarize** and **Find next steps**. Selecting one edits the draft only, preserving existing text and choosing attached-material wording only when attachments exist. The user still reviews and explicitly sends. No inference or transmission is triggered by selecting assistance.
- **Dictate** is visibly named, uses the existing speech service, and describes adding words to the draft rather than starting a conversation. Startup failures now show a typing fallback instead of silently failing. Microphone capture is still an explicit tap, not appearance-driven. Existing dictation lifecycle and device availability require native follow-up; this slice does not certify that service.
- Live conversation and note capture are explicitly **unavailable here** in the menu. The old direct waveform shortcut into an auto-starting voice overlay is removed from this composer. No fake recording, note saving or authorization UI is provided. Existing local capture features are retained, not grafted into the connected shell without a session/input policy.
- Composer buttons use existing minimum tap-target tokens; interrupt, dictation and attachment removal have specific accessibility labels. Interrupt wording expressly does not promise cancellation of an already-running remote tool.
- Tool activity maps common raw tool names to readable descriptions; unknown names replace underscores only for display. Original stored labels remain unchanged. Active streaming activity says **Working**, inactive activity says **Activity ended**, and stale active activity after streaming says **No longer updating**. The stream model has no authoritative success/failure result, so the rail no longer presents a success checkmark. Even one activity can expand for detail. This is activity history, not a new tool-result browser.
- Inbox secondary action accessibility now matches its actual action title rather than always saying Dismiss. Approval actions identify their request and have a review-details accessibility action; approval hints distinguish that request from future permissions. No authorization or action-dispatch semantics changed.

## Why normal launch remains unchanged

Inspection against base HEAD `8172af1170e20d0ade9f4279261b0adda16bf5ba` and current sources found:

- `AppContainer.initialize`, pairing activation and lifecycle entry points bootstrap connections and/or start sensor upload. Restoring the original shell is not a cosmetic routing change.
- `AppContainer`'s mock-pairing path substitutes remote clients but still constructs live location, health and motion services. Reusing that container would not prove a sensor-free preview.
- `VoiceOverlayScreen` starts its session in a view task. Opening it is not a safe authorization review step.
- `ChatScreen` refreshes hosts and polls conversations in tasks. The component preview deliberately does not instantiate it.

The preview therefore takes an explicit command catalog and callbacks rather than constructing a container. Production `ChatScreen` supplies the same dynamic catalog as before. Preview dictation is disabled (and guarded in its action), send/attachment/command callbacks only display honest preview notices, and tool progress is explicitly sample data controlled by a toggle. The composer constructs the existing speech object, whose initializer reads authorization status; it never requests permission or starts capture in the preview. There is no preview host, network client, persistence, sensor pipeline, voice transport or session.

## Remaining integration

Before promoting this shell to launch, implement and test selected-host / selected-input **session authorization**, explicit start/pause/stop, separately consented scope expansion, no historical capture upload, no silent reconnect/replay, and separate consequential-action approval. Gate every entry point, including lifecycle, pairing, deep links, voice, background and CarPlay. Do not merely switch `AppEntry` back or enable mock fallbacks. Full-screen voice can reuse existing visuals after automatic startup is removed and authorization is enforced. Notes need a real capture/review/association handoff, not a placeholder enabled button. Authoritative tool outcome/result details need a richer verified event contract.

## Validation and acceptance

Native XCTest source was written first in the existing registered `HermesMobileTests/AppTemplateTests.swift`: draft preservation/context and honest tool status/label cases. **XCTest has not executed; no Swift/Xcode compile was attempted**, per the deferred native-build boundary. Python source guardrails were observed failing for missing polish, then passing; they are structural checks, not substitutes for native behavior.

Executed locally:

```sh
python3 -m unittest discover -s scripts/tests -v
# 47 tests passed, including four new base-polish source checks.
git diff --check
# clean
```

Pending native acceptance (after build approval):

1. Compile and run `BaseUIPolishTests`; open the named DEBUG component preview. Verify charcoal/gold appearance at small phone and accessibility text sizes; no clipped labels.
2. Type a draft, choose each Assist action with and without attachments, verify original text remains and nothing sends until Send. Verify slash catalog behavior remains intact in an authorized shell.
3. In the component preview verify Dictate is disabled, unavailable voice/notes cannot start anything, attachment/Send actions report preview-only status, and no permission prompts, capture, network or persistence effects occur.
4. Expand a single activity, then multiple activities; verify status is readable with VoiceOver and no success claim is made after interruption. Toggle preview progress and exercise Interrupt response.
5. In an authorized native test harness verify dictation denial/start failure preserves typing, explicit start/stop and edit-before-send work, and interrupt labels do not promise remote tool rollback.
6. Verify approval primary/secondary labels match the request and action; details can be opened with VoiceOver without approving. Verify backend approval scope before enabling a production route.
7. Confirm normal launch remains local and all local capture/backup/intake/intelligence tests continue passing. Audit session authorization and network/sensor effects before any connected-launch change.

No commits, pushes, CI runs, deployments, signing/configuration changes or production service changes were made by this slice. Pre-existing uncommitted local capture, backup, intake, intelligence and project changes are retained.
