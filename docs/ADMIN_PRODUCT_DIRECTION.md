# Approved Hermes iOS administration scope

> **Current direction:** Hermes iOS is the native client for Hermes web-dashboard features and configuration. The dashboard capability set and source-verified APIs define the product map. Local capture/voice/intake/sensor experiments are frozen and absent from primary navigation. See [current integration](CURRENT_BUILD_INTEGRATION.md) and the [dashboard parity roadmap](DASHBOARD_PARITY_ROADMAP.md).

The sole primary purpose is a native iOS client for the Hermes web dashboard: expose its supported configuration, capabilities, operations, connections, sessions, and stored-information workflows through native mobile interaction. Preserve the original charcoal/gold visual foundation.

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

Implement connection/status, authenticated identity, and exact profile context first; then build the read-only dashboard hierarchy before enabling writes. Distinguish dashboard, mobile relay, CLI-only and unverified capabilities without exposing secret values. No configuration or production writes are authorized merely by this product decision.

Native build/device testing and earlier code integration remain pending. This document records scope, not delivery.
