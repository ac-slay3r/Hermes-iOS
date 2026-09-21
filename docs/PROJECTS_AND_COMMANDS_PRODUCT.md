# Projects and command organization

## Product purpose

Projects are durable work contexts owned by the paired Hermes host and managed from iOS. A project is not a Dashboard profile and does not grant management authority.

Each project contains:

- a stable identifier;
- a user-facing name;
- an exact, host-validated workspace directory;
- a short brief that explains the desired outcome and durable project context;
- an ordered list of pinned command identifiers.

Hermes Agent's canonical per-profile `projects.db` is authoritative for project definitions, so Desktop and iOS share one project inventory. The connector keeps only iOS command-pin metadata keyed by canonical project ID. The relay authenticates the paired user and forwards project operations to that user's currently paired host.

## First useful workflow

1. Open Chat and choose a project.
2. Browse host-backed projects or create one by entering a name, exact workspace path, brief, and initial pinned commands.
3. Selecting a different project never mutates the current conversation silently. If Chat already contains work, the app requires an explicit new-conversation transition before changing context.
4. New messages include the selected project identifier.
5. The connector resolves that identifier against its own project store and runs the job from the canonical workspace directory. The phone never supplies an execution path with a message.
6. The command palette shows the selected project's pinned commands first, then groups the remaining host catalog by category. Raw slash entry remains supported.

## Trust and safety boundaries

- Project definitions are canonical Hermes projects; selected-project UI state is scoped to the paired host on each iOS installation and is not a host-global switch.
- Workspace paths must be absolute, exist, be directories, and resolve canonically on the host before a project can be saved.
- Message execution accepts only a project identifier. Unknown identifiers fail closed rather than falling back to the connector's default working directory.
- A conversation is bound to one project when its first project-scoped message is created. A later message cannot change that binding.
- Project selection does not alter the Dashboard target, Dashboard profile, relay pairing, global Hermes profile, model, or provider.
- Project briefs are context shown to the user and agent; they are not shell commands and are never executed.
- Pinned commands reference entries in the live host command catalog. Pins are a connector-side presentation overlay until Hermes's canonical Projects schema gains command pins; they do not bypass command authorization or dangerous-command confirmation.

## Initial API contract

### `GET /v1/projects`

Returns the paired host's project definitions and canonical workspace paths. If the host is offline, return a retryable host-unavailable error; do not return an empty list that could be mistaken for authoritative state.

### `POST /v1/projects`

Creates a project after connector-side validation. Request fields:

- `name`
- `workspacePath`
- `brief`
- `pinnedCommandIds`

Returns the canonical saved project. Duplicate canonical workspace paths are rejected in the first slice to prevent ambiguous context.

### `POST /v1/messages`

Accepts optional `projectId`. The relay binds it to a new conversation or verifies it matches the existing conversation binding. The connector resolves the project and supplies its canonical workspace as the job working directory.

## Deferred deliberately

- file browser or remote filesystem editing;
- automatic project inference from message text;
- host-global active-project state;
- silent reassignment of existing sessions;
- destructive project deletion;
- Dashboard profile switching;
- arbitrary command macros or shell snippets;
- multi-host project aggregation.
