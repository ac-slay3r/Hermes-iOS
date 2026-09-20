# Connected Hermes iOS direction

> **Historical direction:** Connected chat/session work is frozen and absent from the current dashboard-management navigation. This document preserves earlier engineering evidence; [current integration](CURRENT_BUILD_INTEGRATION.md) and the [dashboard parity roadmap](DASHBOARD_PARITY_ROADMAP.md) govern product scope and reachability.

## Approved product direction

Hermes-connected by default. iOS is the native interface and permitted sensing layer for Hermes conversations, projects, memory, skills, tools, models, integrations, and scheduled work. Use on-device processing where useful for latency, OCR, transcription, translation, filtering, and offline continuity; do not require a separate local-only workflow.

## Session authorization

The user approved session-level authorization instead of approval for each individual payload:

- Starting a connected session authorizes only its explicitly selected inputs to flow to the selected Hermes host until pause or stop.
- Display host/destination and input scope when starting. Keep active capture/transfer state and pause/stop accessible.
- Other captures, phone data, and background sources are excluded unless separately enabled. Expanding scope requires explicit consent.
- Do not upload historical local captures automatically upon connecting.
- Consequential actions retain separate approval controls. Session input authorization is not administrative or execution authorization.
- Reconnection, buffering, retention, and whether pause stops capture as well as transmission need explicit design. Do not silently replay sensitive buffered inputs or auto-resume sensing.

## UX direction

Utility-focused integrated native client, not a scrapbook or feature checklist. Assistant, Workspace, and Manage are connected views. Contextual controls expose models, skills, tools, and project knowledge without forcing navigation into administration. Assisted sessions combine transcription, translation, working notes, and project context where supported.

## Implementation status

This document records the approved direction, not deployed behavior. Existing source still uses the local-only launch boundary. No host connection, sensing, uploading, permissions, or production configuration was enabled by this decision. Capability/API inventory and assisted-session implementation remain pending; native compilation and device verification remain pending.
