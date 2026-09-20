# Approved Hermes iOS administration scope

> **Current direction:** Hermes iOS combines the native dashboard-management client with the preserved relay companion. Dashboard remains the default authority surface. Chat and Device are explicit secondary areas using separate relay/device credentials. Device-data synchronization is off by default and requires a persisted in-app opt-in in addition to individual iOS permissions. Local capture/intake experiments remain frozen. See [current integration](CURRENT_BUILD_INTEGRATION.md) and the [dashboard parity roadmap](DASHBOARD_PARITY_ROADMAP.md).

The primary purpose is a native iOS client for Hermes dashboard administration, with the established relay companion available alongside it for chat and explicitly consented device capabilities. Preserve the original charcoal/gold visual foundation.

This supersedes the capture-first, daily-life assistant, timeline, and assisted-session product directions. The existing paired chat, relay connection, host status, permission controls, voice entry, and device settings are reauthorized as companion functions, but they do not grant dashboard administration authority. Local capture/intake experiments remain preserved and frozen. Prior mockups are historical, not current product specifications.

## Interaction contract

Find → inspect → change → review → apply → verify.

Every operation identifies the selected host and profile, current state, proposed changes, scope and relevant effects. Distinguish unsaved, applying, verified saved, and failed/unknown. Read back the exact target after mutation. Reversibility and restart requirements must reflect actual backend behavior. Never expose an unsupported operation as a working control.

## Scope inventory

- Configuration: models/providers, profiles, defaults and behavior settings.
- Capabilities: skills, tools, MCP/integrations and permissions.
- Knowledge: memories and persistent instructions; inspect, correct, remove as explicitly requested.
- Operations: sessions, active work, schedules, failures and approvals.
- Connections/access: host identity, service connections, authentication status and access controls.

Primary navigation is Dashboard, Chat, and Device. Dashboard remains selected at launch. Chat is relay-backed conversation; Device owns pairing, host connection, permissions, notifications, location preference, and consented device-data synchronization. Capture/transcription/translation/timeline feature development remains out of primary scope.

## Immediate work

Implement connection/status, authenticated identity, and exact profile context first; then build the read-only dashboard hierarchy before enabling writes. Distinguish dashboard, mobile relay, CLI-only and unverified capabilities without exposing secret values. No configuration or production writes are authorized merely by this product decision.

Native build/device testing and earlier code integration remain pending. This document records scope, not delivery.
