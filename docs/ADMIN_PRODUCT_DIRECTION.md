# Approved Hermes iOS administration scope

> **Integration update:** Administration remains primary. Explicitly authorized local features are now secondary supporting tools; automatic connected/sensor/voice startup remains disabled. This document preserves earlier milestone evidence and may describe superseded launch/scope or test counts. The [current build integration matrix](CURRENT_BUILD_INTEGRATION.md) is authoritative for reachability, gaps and release blockers.

The sole primary purpose is a native client for users to administer their Hermes agent: supported toggles, settings, capabilities, operations, and inspection/editing/correction of stored information. Preserve the original native charcoal/gold visual foundation.

This supersedes the capture-first, daily-life assistant, timeline, and assisted-session product directions. Prior implementations are frozen and preserved, not removed or automatically activated. Prior mockups are historical, not current product specifications.

## Interaction contract

Find → inspect → change → review → apply → verify.

Every operation identifies the selected host and profile, current state, proposed changes, scope and relevant effects. Distinguish unsaved, applying, verified saved, and failed/unknown. Read back the exact target after mutation. Reversibility and restart requirements must reflect actual backend behavior. Never expose an unsupported operation as a working control.

## Scope inventory

- Configuration: models/providers, profiles, defaults and behavior settings.
- Capabilities: skills, tools, MCP/integrations and permissions.
- Knowledge: memories and persistent instructions; inspect, correct, remove as explicitly requested.
- Operations: sessions, active work, schedules, failures and approvals.
- Connections/access: host identity, service connections, authentication status and access controls.

Navigation proposals (Overview, Manage, Knowledge) remain subject to capability inventory, not an implemented contract. Chat is secondary for explanation/testing. Capture/transcription/translation/timeline feature development is out of primary scope.

## Immediate work

Read-only inventory of documented and implemented Hermes settings/editing APIs. Distinguish dashboard, mobile relay, CLI-only and unverified capabilities; inspect source and schemas without exposing secret values. No configuration or production writes are authorized merely by this product decision.

Native build/device testing and earlier code integration remain pending. This document records scope, not delivery.
