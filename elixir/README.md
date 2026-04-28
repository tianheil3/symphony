# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls when using Linear-backed workflows.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Choose a tracker and export the corresponding API token:
   - Linear: `LINEAR_API_KEY`
   - GitLab: `GITLAB_API_TOKEN`
   - GitHub Issues: `GITHUB_TOKEN`
3. Use the `symphony-concierge` skill from your target repo, or create a repo-specific
   `WORKFLOW.md` from the service spec.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and tracker-specific skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
   - GitHub-backed workflows should use a `github` skill built on `gh`.
   - GitLab-backed workflows should use a `gitlab` skill built on `glab`.
5. Customize the generated `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - Do not copy this repository's `WORKFLOW.md` verbatim for a new project. It is Symphony's
     internal Linear workflow and depends on project-specific setup, status names, and review
     conventions.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Repo-first concierge path

The fastest setup path is the global `symphony-concierge` skill bundle:

1. Open your target GitHub repository in your coding agent.
2. Invoke `symphony-concierge`.
3. The skill performs one repo scan, asks setup questions, selects a workflow profile, writes
   `.symphony/install/request.json`, and runs:
   - `symphony install --manifest .symphony/install/request.json`
4. Installer/apply phase: the installer writes repo-local state under `.symphony/install/*`.
5. Post-install launch verification phase: the skill starts Symphony from the repo root with
   a selected free local port, requires both a live spawned process and API health response, and
   records dashboard reachability as an additional signal before reporting completion.
6. If either phase fails, the skill reports an explicit blocker.

The concierge skill supports three workflow profiles:

- `starter`: default for real projects. It uses conservative agent limits, PR handoff, and no
  automatic merge.
- `review-gated`: adds explicit `Human Review` and `Rework` states plus PR/MR feedback sweep rules.
- `symphony-dev`: only for this repository or repositories that intentionally adopt Symphony's
  heavier internal workflow.

After setup, use the `symphony-task` skill to submit natural-language work to Symphony through
GitHub Issues or Linear. It formats requests with problem context, acceptance criteria, validation,
and the correct pickup state, then can check status, add context, or move the issue through the
configured workflow.

The same skill bundle includes `scripts/ensure_symphony_installer.sh`, which reuses an existing
`symphony` binary when available or downloads a matching release asset from GitHub Releases when
it is missing.

See [docs/installer.md](docs/installer.md) for the manifest model, session-state files, and
concierge/installer handoff contract.

## Installer release assets

Version tags (`v*`) trigger `.github/workflows/release-escript.yml`, which:

- enforces `vX.Y.Z` tag version == `mix.exs` project version,
- runs focused installer tests,
- builds release artifacts on pinned runners:
  - `ubuntu-24.04` -> `linux/x86_64`
  - `macos-14` -> `darwin/arm64`
- publishes GitHub Release assets for:

- `symphony-<version>-<os>-<arch>.tar.gz` (contains `symphony` installer binary)
- `symphony-concierge-<version>.tar.gz` (contains `.codex/skills/symphony-concierge`)

For v1, CI guarantees exactly these installer tuples: `linux/x86_64` and `darwin/arm64`.

To build the same artifact format locally from the repository root:

```bash
bash scripts/build_release_artifacts.sh
```

Local packaging defaults to the host tuple (`uname` OS/arch). To enforce a specific tuple label,
set `SYMPHONY_TARGET_OS` and `SYMPHONY_TARGET_ARCH`; the script fails if they do not match the
actual runner tuple.

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: github
  project_slug: "your-org/your-repo"
  active_states:
    - Todo
    - In Progress
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 1
  max_turns: 10
codex:
  command: codex app-server
---

You are working on a GitHub issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Supported `tracker.kind` values: `linear`, `gitlab`, `github`.
- For `tracker.kind: github`, set `tracker.project_slug` to `owner/repo`.
- The GitHub tracker implementation uses GitHub Issues plus workflow labels for Symphony states; GitHub Projects v2 is not currently used as the tracker surface.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- `tracker.api_key` also reads from `GITLAB_API_TOKEN` for `gitlab` and `GITHUB_TOKEN` for `github` when unset or expressed as the matching `$ENV_VAR`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/console/<issue_identifier>`, `/api/v1/state`, `/api/v1/<issue_identifier>`,
  `/api/v1/<issue_identifier>/console`, `/api/v1/<issue_identifier>/console/command`, and
  `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- LiveView for the shared console at `/console/<issue_identifier>`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

### Shared tmux console

For local worker runs, Symphony now exposes a shared console around the existing `codex app-server`
session instead of replacing the app-server transport.

- Each active issue can have a stable local `tmux` session such as `sym-MT-123`.
- The dashboard exposes an `Open Console` link plus the matching `tmux attach -t ...` command.
- The web console restores transcript state from the shared tmux session with `tmux capture-pane`.
- Operator input is controlled through a small command set rather than raw terminal passthrough:
  `help`, `status`, `explain`, `continue`, `prompt <text>`, and `cancel`.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Use the `symphony-concierge` skill in your target repo. It asks setup questions, selects a workflow
profile (`starter`, `review-gated`, or `symphony-dev`), writes `.symphony/install/request.json`,
runs `symphony install --manifest ...`, then launches Symphony on a selected free local port and
verifies API health while the spawned process remains alive before declaring success. For GitHub
tracker setups, it must verify or create the workflow-state labels required by the selected profile
and tell the operator that new GitHub issues must carry an active-state label such as `Todo` before
Symphony will pick them up. The generated `WORKFLOW.md` should also make GitHub comment/state
handling explicit and forbid Linear-only closeout tools in GitHub mode. If setup cannot finish, it
reports a precise blocker to fix.

Use the `symphony-task` skill when you want an agent to turn a natural-language request into a
GitHub or Linear issue for Symphony, check whether Symphony picked it up, append new context, or move
the issue to another configured workflow state.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
