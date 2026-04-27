# Symphony

[English](README.md) | [中文](README.zh-CN.md)

Symphony is a work orchestration system for coding agents. Instead of supervising one terminal session
at a time, you define how work should be pulled, executed, verified, and landed, then let Symphony
run that loop repeatedly.

This repository is an independent fork of
[`openai/symphony`](https://github.com/openai/symphony) with substantial changes around repo-first
onboarding, release packaging, and GitHub-backed setup flows. It is not affiliated with or endorsed
by OpenAI.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

> [!WARNING]
> Symphony is still an engineering preview. Use it in trusted repositories and with clear operational
> boundaries.

## What This Project Is

Symphony is for teams and individuals who want to manage work at the issue or ticket layer instead
of manually driving every coding-agent turn.

At a high level, Symphony gives you:

- a tracker-driven work loop,
- per-task isolated workspaces,
- Codex app-server execution inside those workspaces,
- verification and observability around each run,
- a repo-first concierge path for onboarding an existing repository.

## Why It Exists

Most coding-agent workflows still depend on a human to:

- read the issue,
- open the right repository,
- bootstrap the environment,
- remember the workflow rules,
- monitor execution,
- verify output quality,
- land the change safely.

Symphony moves that repetitive coordination into a reusable runtime and workflow contract.

## Vision

The goal is not just "run an agent on an issue." The goal is to make project work operational:

- work enters from a real tracker,
- execution happens in isolated environments,
- every run follows repo-specific workflow rules,
- verification is part of the system rather than an afterthought,
- onboarding a new repository becomes repeatable instead of artisanal.

## System Architecture

The runtime loop is intentionally simple:

1. Symphony polls a tracker for candidate work.
2. For each claimed issue, Symphony creates or reuses an isolated workspace.
3. It launches Codex in app-server mode inside that workspace.
4. It sends a workflow prompt derived from `WORKFLOW.md` plus the issue context.
5. It monitors progress, verification signals, and tracker state until the work is done or blocked.

The main system pieces are:

- `tracker`: where work comes from. The current Elixir runtime supports `linear`, `gitlab`, and
  `github`.
- `workspace`: where each task gets its own checkout and bootstrap commands.
- `codex runtime`: the agent execution engine, typically `codex app-server`.
- `workflow contract`: the YAML front matter and prompt body in `WORKFLOW.md`.
- `observability`: the local dashboard, API, and shared console surfaces used to inspect state and health.

## Shared Console

Tracker-dispatched local runs now expose a shared console surface:

- a stable local `tmux` session per active issue
- an `Open Console` link in the dashboard
- a web console at `/console/<issue_identifier>`
- controlled operator commands instead of raw stdin passthrough: `help`, `status`, `explain`, `continue`, `prompt <text>`, and `cancel`

## Use Symphony With A Real Project

[English](#use-symphony-with-a-real-project) | [中文](README.zh-CN.md#在真实项目中使用-symphony)

The recommended real-project path is the repo-first `symphony-concierge` skill. It is designed to be
run from inside the target repository, generate the install manifest, install `WORKFLOW.md`, launch
Symphony, and verify the local dashboard/API before handing the setup back to you.

### Prerequisites

Before onboarding a real project, make sure:

- the target project is a Git repository,
- `origin` points at an ordinary GitHub repository,
- `gh` is installed and authenticated,
- `GITHUB_TOKEN` is available when you want Symphony agents to comment on issues, push branches, and
  create pull requests,
- `LINEAR_API_KEY` is available when Linear is the tracker,
- Codex is available as `codex app-server`,
- the project has a clear validation command, for example `npm run check`, `npm test`, or `make test`.

For GitHub, the token should have enough permission to read/write issues, push branches, and create
pull requests. Keep branch protection and required CI checks enabled on important repositories.

For Linear, the API key should be able to read issues in the selected project and write comments or
state changes. Symphony still uses GitHub as the code forge for branches and pull requests, so a
Linear-tracked project usually needs both `LINEAR_API_KEY` and GitHub push/PR credentials.

### Install And Invoke The Skill

From inside the target repository, ask Codex to install and run the concierge skill:

```text
Install the symphony-concierge skill from https://github.com/tianheil3/symphony.git path .codex/skills/symphony-concierge, then use it to set up Symphony for this repository.
```

If the skill is already installed, you can ask directly:

```text
Use symphony-concierge to set up Symphony for this repository. Use GitHub as the tracker and use npm run check as the validation command.
```

For a Linear-tracked project, ask for Linear explicitly:

```text
Use symphony-concierge to set up Symphony for this repository. Use Linear as the tracker, use my Linear project slug, and use npm run check as the validation command.
```

The concierge flow will:

1. scan the current repository once,
2. ask setup questions in one batch,
3. write `.symphony/install/request.json`,
4. run `symphony install --manifest .symphony/install/request.json`,
5. create or verify GitHub workflow-state labels when the tracker is GitHub,
6. start Symphony on a selected local port,
7. verify both process liveness and API health before reporting success.

If `symphony` is not already installed, the bundled helper will download a matching release asset
from this repository's GitHub Releases.

### Setup Questions

The skill asks for these values:

- tracker provider: `github`, `linear`, or `gitlab`,
- tracker project slug: for GitHub, use `owner/repo`; for Linear, use the Linear project slug,
- workspace root: where Symphony creates per-issue workspaces,
- workspace bootstrap command: usually `git clone --depth 1 <origin-url> .`,
- Codex command: usually `codex app-server`,
- validation command before handoff: the command agents must run before claiming completion.

For first production-like runs, keep the workflow conservative:

```yaml
agent:
  max_concurrent_agents: 1
  max_turns: 10
codex:
  command: codex app-server
```

Increase concurrency only after you have reviewed several completed PRs and understand the failure
modes for your repository.

### Example Workflow Configs

GitHub tracker example:

```yaml
---
tracker:
  kind: github
  api_key: $GITHUB_TOKEN
  project_slug: owner/repo
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
    - Canceled
workspace:
  root: ~/code/my-project-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/owner/repo.git .
    npm install
agent:
  max_concurrent_agents: 1
  max_turns: 10
codex:
  command: codex app-server
---
Work only inside the Symphony-created issue workspace.
Run `npm run check` before handoff.
```

Linear tracker example:

```yaml
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: MYPROJECT
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Canceled
workspace:
  root: ~/code/my-project-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/owner/repo.git .
    npm install
agent:
  max_concurrent_agents: 1
  max_turns: 10
codex:
  command: codex app-server
---
You are working on a Linear issue.
Use the `linear_graphql` tool for Linear comments and state changes.
Run `npm run check` before handoff.
Open a GitHub pull request for code review when code changes are ready.
```

### GitHub Issue Workflow

For GitHub tracker setups, Symphony uses workflow-state labels as the source of truth:

- `Todo`: ready for Symphony pickup
- `In Progress`: claimed by Symphony
- `Done`: implementation and handoff completed

GitHub issue pickup depends on those labels. A newly created GitHub issue that is merely `open`
but has no active-state label such as `Todo` will not be treated as candidate work by the default
Symphony workflow.

The generated `WORKFLOW.md` should explicitly instruct agents to:

- use `gh issue comment` for the persistent workpad,
- use `gh api` or `gh issue edit` for workflow-state label changes,
- avoid `linear_graphql` or other Linear-only closeout tools when `tracker.kind=github`,
- work only inside the Symphony-created issue workspace,
- run the configured validation command before creating a handoff or PR.

### Linear Issue Workflow

For Linear tracker setups, Symphony uses Linear issue states as the source of truth. Configure
`active_states` to the states Symphony may pick up and continue, and configure `terminal_states` to
states that mean the issue should not be worked by Symphony anymore.

A common Linear setup is:

- `Todo`: ready for Symphony pickup
- `In Progress`: claimed by Symphony
- `Done`: completed by Symphony after validation and handoff
- `Canceled` or `Duplicate`: terminal states Symphony should ignore

For Linear, the generated `WORKFLOW.md` should explicitly instruct agents to:

- use the `linear_graphql` dynamic tool for Linear comments, workpad updates, issue reads, and state
  transitions,
- query the issue by id before final closeout when state correctness matters,
- avoid GitHub issue-label commands for tracker state because Linear is the source of truth,
- still use GitHub branches and pull requests for code review when the code forge is GitHub,
- work only inside the Symphony-created issue workspace,
- run the configured validation command before creating a handoff or PR.

The Linear tracker controls work intake and status. GitHub still controls code review and merge. In
practice, a Linear-backed run often ends with a GitHub PR linked from a Linear comment.

### Operating Model

After setup, the normal GitHub-tracker loop is:

1. create or choose a GitHub issue,
2. add the `Todo` label,
3. start or keep Symphony running,
4. watch the dashboard URL reported by the concierge flow,
5. let Symphony move the issue to `In Progress`,
6. review the generated branch and PR,
7. rely on CI and human review before merging,
8. let the issue move to `Done` only after validation and handoff are complete.

For real projects, the safest default is PR-only automation: Symphony may push branches and open PRs,
but humans and branch protection decide whether code lands on the protected branch.

The normal Linear-tracker loop is:

1. create or choose a Linear issue in the configured project,
2. move it to an active state such as `Todo`,
3. start or keep Symphony running,
4. watch the dashboard URL reported by the concierge flow,
5. let Symphony move the issue to `In Progress`,
6. review the generated GitHub branch and PR,
7. rely on CI and human review before merging,
8. let the Linear issue move to `Done` only after validation and handoff are complete.

### What To Commit To Your Project

The target repository should usually commit:

- `WORKFLOW.md`, because it is the repo-specific execution contract,
- any project documentation explaining how your team feeds issues to Symphony.

The target repository should usually avoid committing local runtime state:

- `.symphony/install/state.json`,
- `.symphony/install/events.jsonl`,
- `.symphony/install/launch.log`,
- per-run workspace directories.

Add project-specific ignore rules when needed so local Symphony state does not leak into normal code
reviews.

### Common Commands

Launch from the target repository after setup:

```sh
symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 49190 ./WORKFLOW.md
```

Check API health:

```sh
curl -fsS http://127.0.0.1:49190/api/v1/state
```

Open the dashboard:

```text
http://127.0.0.1:49190/
```

List candidate GitHub issues:

```sh
gh issue list --repo owner/repo --label Todo --state open
```

For Linear, candidate work is visible in the Linear project view by filtering to the configured
active states such as `Todo` and `In Progress`. Inside an agent run, Linear reads and writes should go
through the `linear_graphql` tool exposed by Symphony's Codex app-server session.

### Safety Checklist

Before using Symphony on high-value work:

- start with one low-risk issue,
- keep `max_concurrent_agents: 1`,
- require CI on PRs,
- require human review before merge,
- keep secrets out of issue bodies and workflow prompts,
- use trusted repositories and trusted local workspaces,
- inspect the first few generated PRs carefully before increasing scope.

## Releases

Release assets are published from `.github/workflows/release-escript.yml`.

Current installer distribution model:

- `symphony-<version>-linux-x86_64.tar.gz`
- `symphony-<version>-darwin-arm64.tar.gz`
- `symphony-concierge-<version>.tar.gz`

Latest release:

- <https://github.com/tianheil3/symphony/releases/latest>

These assets are what make the repo-first concierge path practical for other repositories without
requiring a manual local build first.

## Current Scope

Current runtime scope:

- Elixir-based reference runtime
- tracker support for Linear, GitLab, and GitHub
- repo-first concierge v1 aimed at ordinary GitHub repositories
- release assets for `linux/x86_64` and `darwin/arm64`

Current limitations:

- the concierge path is intentionally narrow in v1 and assumes a GitHub-hosted target repository,
- this remains prototype software rather than a hardened production control plane.

## Relationship To The Upstream Fork

This repository started from `openai/symphony`, but it is no longer just a mirror.

The most visible changes in this fork are:

- repo-first installer and manifest flow,
- `symphony-concierge` onboarding skill,
- GitHub release packaging for the installer and concierge bundle,
- GitHub-backed tracker setup path,
- documentation oriented around "connect this to my repo" instead of only "run the reference
  implementation."

If you want the original upstream specification and framing, start here:

- <https://github.com/openai/symphony/blob/main/SPEC.md>

## Documentation

Use these docs depending on what you are trying to do:

- [README.zh-CN.md](README.zh-CN.md): Chinese project overview and onboarding path
- [elixir/README.md](elixir/README.md): runtime setup, workflow format, and operator docs
- [elixir/docs/installer.md](elixir/docs/installer.md): installer manifest, session state, and
  concierge handoff contract

## License

This project is licensed under the [Apache License 2.0](LICENSE).
