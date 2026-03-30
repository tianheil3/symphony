# Tracker Agent Shared Console Design

## Goal

When Symphony dispatches an agent from the tracker, operators need a shared, real-time console they can attach to from either:

- local `tmux`
- the web dashboard through `xterm`

The console must support controlled operator takeover through a small whitelist of commands instead of arbitrary stdin passthrough.

## Confirmed Constraints

- Scope is local worker only for the first version.
- Every tracker-dispatched agent run automatically gets a shared console session.
- `tmux` and web attach to the same shared session.
- Operator takeover is controlled, not a raw interactive shell into the running agent.
- Supported operator intents include:
  - explain current progress
  - continue
  - submit an additional prompt or note, then continue

## Existing Runtime Reality

Symphony does not currently run agents as a human-facing terminal CLI. It runs `codex app-server` and consumes structured JSON-RPC-like events through `SymphonyElixir.Codex.AppServer`.

That means the shared console cannot be implemented as "attach directly to the true Codex terminal", because the current execution path is protocol-oriented, not TTY-oriented.

The design therefore keeps the app-server execution model intact and adds a console runtime around it.

## Architecture

### Source of Truth

The orchestrator and app-server remain the source of truth for agent execution:

- `SymphonyElixir.Orchestrator`
- `SymphonyElixir.AgentRunner`
- `SymphonyElixir.Codex.AppServer`

The new console layer is an observability and control surface around those components, not a replacement for them.

### Shared Console Session

Each issue gets a stable local `tmux` session, for example:

- `sym-<issue_identifier>`

The session is created automatically when a run starts and reused across continuation turns and retries for the same issue while it remains active.

The session layout is fixed:

- top pane: transcript view backed by a log file
- bottom pane: a controlled REPL for operator commands

Suggested workspace-local console artifact directory:

- `<workspace>/.symphony/console/`

Files:

- `transcript.log`
- `events.ndjson`
- `commands.ndjson`
- `state.json`

### Web Attachment

The dashboard does not emulate a fake transcript. It attaches to the same `tmux` session through a PTY-backed bridge so that:

- local `tmux attach -t sym-...`
- dashboard `xterm`

see the same shared session.

Borrowed ideas from Kanban:

- server-side session ownership
- separate IO and control channels
- per-viewer identity for reconnect handling
- restore support after reconnect

Unlike Kanban, Symphony should use `tmux` as the shared session carrier instead of introducing a new PTY-managed agent runtime.

## Control Model

### Controlled Takeover

The bottom-pane REPL accepts only a whitelist of commands. It is not a shell and does not forward arbitrary terminal bytes to the running app-server process.

Initial command set:

- `help`
- `status`
- `explain`
- `continue`
- `prompt <text>`
- `cancel`

### Command Semantics

`status`

- Prints the current run state from orchestrator state and recent app-server events.
- Does not start a new turn.

`explain`

- Queues a structured operator note asking the agent to explain completed work, remaining work, and the next step, then continue.

`continue`

- Starts the next eligible continuation turn without adding a new operator note.

`prompt <text>`

- Queues an operator note that should be incorporated on the next safe boundary before continuing work.

`cancel`

- Stops the active run without deleting the workspace or transcript history.

### Safe-Boundary Injection

Operator commands do not inject text into an already-running turn.

Instead, Symphony maintains an operator queue per active issue. Queued instructions are consumed only at safe boundaries:

- after a turn completes
- when the issue is between continuation turns
- when a run is explicitly held for operator input

This preserves compatibility with the `codex app-server` protocol and prevents corrupting an active session.

## Runtime Data Flow

1. `AgentRunner` starts a run.
2. `AgentConsoleService.ensure_session/2` creates or reuses the `tmux` session and console artifact directory.
3. `Codex.AppServer` emits runtime events.
4. Events continue flowing to the orchestrator as they do today.
5. The console layer also records those events to `events.ndjson` and renders them into `transcript.log`.
6. Operator REPL commands are appended to `commands.ndjson` and forwarded to the orchestrator as structured operator actions.
7. The orchestrator merges queued operator instructions into the next turn prompt at a safe boundary.

## Web and API Surface

### Dashboard

The running-session table should expose:

- an `Open Console` action
- the `tmux attach -t ...` command or copy affordance

### Issue API

Issue payloads should gain a `console` object containing at least:

- `session_name`
- `attach_command`
- `web_path`
- `allowed_commands`
- `pending_operator_notes`
- `state`

### Web Terminal Transport

The web terminal layer should expose:

- an IO stream for terminal bytes
- a control stream for resize, restore, and stop-like actions

Restore can be implemented using `tmux capture-pane` rather than a headless xterm mirror.

## State Model

The console control plane should explicitly model operator-relevant states:

- `running`
- `between_turns`
- `operator_queued`
- `operator_held`
- `completed`
- `failed`

Default behavior should favor forward progress:

- if the issue is still active and no explicit hold exists, Symphony should continue automatically
- queued operator notes are consumed at the next safe boundary

## Failure Handling

Console failures should degrade observability, not block agent execution, when possible.

Examples:

- If `tmux` session creation fails, the run may continue, but the dashboard should show console unavailable.
- If transcript rendering fails, log a warning and keep the agent running.
- If web attach fails, local `tmux` attach should still work.
- If command parsing fails, reject the command locally and do not mutate the operator queue.

The console becomes read-only once the issue leaves active states.

## Testing Strategy

Tests should cover:

- console session creation and reuse
- operator command parsing
- queue merge semantics for `explain`, `continue`, and `prompt`
- next-turn prompt injection rules
- dashboard payload and API fields for console metadata
- web terminal attach, reconnect, and restore behavior
- read-only behavior after terminal tracker states

## Implementation Plan Shape

The implementation should likely be split into these areas:

1. Console runtime and `tmux` session management
2. Orchestrator/operator queue integration
3. API and dashboard exposure
4. Web `xterm` attach path
5. Tests and documentation
