# Symphony

[English](README.md) | [中文](README.zh-CN.md)

Run coding agents from real tracker issues to verified pull requests.

Symphony turns issue-driven engineering work into a repeatable local runtime: it picks up work from
GitHub, Linear, or GitLab; creates an isolated workspace; starts Codex in app-server mode; enforces
your repo workflow; and hands back a branch, PR, or tracker update only after validation.

| Connect work | Isolate execution | Verify handoff |
| --- | --- | --- |
| Poll GitHub issues, Linear issues, or GitLab work items. | Create one workspace per task and run Codex inside it. | Run repo-defined checks before PRs, comments, or state transitions. |

<p align="center">
  <a href="#github-issues-to-pr"><strong>GitHub Issues -&gt; PR</strong></a>
  ·
  <a href="#linear-issues-to-pr"><strong>Linear Issues -&gt; PR</strong></a>
  ·
  <a href="#repo-first-concierge">Install with the skill</a>
  ·
  <a href="#common-commands">Run locally</a>
</p>

This repository is an independent fork of
[`openai/symphony`](https://github.com/openai/symphony) with substantial changes around repo-first
onboarding, release packaging, and GitHub-backed setup flows. It is not affiliated with or endorsed
by OpenAI.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

> [!WARNING]
> Symphony is still an engineering preview. Use it in trusted repositories and with clear operational
> boundaries.

## Choose A Setup Path

[English](#choose-a-setup-path) | [中文](README.zh-CN.md#选择接入路径)

The fastest real-project path is the repo-first `symphony-concierge` skill. Run it from the target
repository root and it will generate the install manifest, write `WORKFLOW.md`, launch Symphony, and
verify the local dashboard/API.

| If your work starts in... | Use this tracker | Typical outcome |
| --- | --- | --- |
| GitHub Issues | `github` | Symphony moves labels, comments on the issue, pushes a branch, and opens a PR. |
| Linear | `linear` | Symphony moves Linear states, writes Linear comments, pushes a GitHub branch, and opens a PR. |
| GitLab | `gitlab` | Supported by the runtime; the concierge path is narrower than GitHub/Linear today. |

### GitHub Issues To PR

Ask Codex from inside the target repository:

```text
Use symphony-concierge to set up Symphony for this repository. Use GitHub as the tracker and use npm run check as the validation command.
```

Default GitHub states are labels:

| Label | Meaning |
| --- | --- |
| `Todo` | Ready for Symphony pickup |
| `In Progress` | Claimed and being worked |
| `Done` | Validated and handed off |

New GitHub issues must have an active-state label such as `Todo`. An open issue with no active label
will not be picked up by the default workflow.

### Linear Issues To PR

Ask Codex from inside the target repository:

```text
Use symphony-concierge to set up Symphony for this repository. Use Linear as the tracker, use my Linear project slug, and use npm run check as the validation command.
```

Default Linear states are issue workflow states:

| State | Meaning |
| --- | --- |
| `Todo` | Ready for Symphony pickup |
| `In Progress` | Claimed and being worked |
| `Done` | Validated and handed off |
| `Canceled` / `Duplicate` | Terminal states Symphony should ignore |

Linear controls work intake and status. GitHub still controls code review and merge when the code
forge is GitHub, so Linear-backed runs commonly end with a GitHub PR linked from a Linear comment.

## How It Runs

```text
Tracker issue -> isolated workspace -> Codex app-server -> validation -> PR / tracker update
```

1. Symphony polls the configured tracker for active work.
2. It creates or reuses a task-specific workspace.
3. It launches `codex app-server` inside that workspace.
4. It sends a prompt built from `WORKFLOW.md` plus the issue context.
5. It monitors events, console output, validation, and tracker state until completion or blockage.

## Repo-First Concierge

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

### Install The Skill

From inside the target repository, ask Codex to install and run the concierge skill:

```text
Install the symphony-concierge skill from https://github.com/tianheil3/symphony.git path .codex/skills/symphony-concierge, then use it to set up Symphony for this repository.
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

### What The Skill Asks

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

<details>
<summary>Example GitHub WORKFLOW.md</summary>

Use this shape when GitHub Issues are the tracker:

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

</details>

<details>
<summary>Example Linear WORKFLOW.md</summary>

Use this shape when Linear is the tracker and GitHub is the code forge:

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

</details>

## Workflow Rules

The generated `WORKFLOW.md` is the contract that keeps runs predictable.

| Tracker | Agent should use | Agent should avoid |
| --- | --- | --- |
| GitHub | `gh issue comment`, `gh api`, `gh issue edit`, branch/PR commands | `linear_graphql` and Linear-only closeout helpers |
| Linear | `linear_graphql` for issue reads, comments, workpad updates, and state changes | GitHub issue-label commands for tracker state |

For every tracker, the agent should work only inside the Symphony-created issue workspace and run the
configured validation command before handoff.

## Operating Model

For real projects, the safest default is PR-only automation: Symphony may push branches and open PRs,
but humans, CI, and branch protection decide whether code lands on the protected branch.

| Step | GitHub tracker | Linear tracker |
| --- | --- | --- |
| 1 | Create or choose a GitHub issue. | Create or choose a Linear issue. |
| 2 | Add `Todo`. | Move it to `Todo` or another active state. |
| 3 | Start or keep Symphony running. | Start or keep Symphony running. |
| 4 | Symphony moves the issue to `In Progress` and creates/refreshes `## Codex Workpad` before any agent code starts. If either write fails, dispatch stops. | Symphony moves the issue to `In Progress`. |
| 5 | Review the generated branch and PR. | Review the generated GitHub branch and PR. |
| 6 | Move to `Done` after validation, PR handoff, and check evidence; the GitHub label update removes `Todo`/`In Progress`. | Move to `Done` after validation and handoff. |

## What To Commit

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

## Operator Surfaces

Tracker-dispatched local runs expose:

- a dashboard with active agents, tokens, status, and event summaries,
- an API at `/api/v1/state`,
- a stable local `tmux` session per active issue,
- a web console at `/console/<issue_identifier>`,
- controlled operator commands: `help`, `status`, `explain`, `continue`, `prompt <text>`, and
  `cancel`.

## Common Commands

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

## Safety Checklist

Before using Symphony on high-value work:

- start with one low-risk issue,
- keep `max_concurrent_agents: 1`,
- require CI on PRs,
- require human review before merge,
- keep secrets out of issue bodies and workflow prompts,
- use trusted repositories and trusted local workspaces,
- inspect the first few generated PRs carefully before increasing scope.

## Current Scope

Current runtime scope:

- Elixir-based reference runtime
- tracker support for Linear, GitLab, and GitHub
- repo-first concierge v1 aimed at ordinary GitHub repositories
- release assets for `linux/x86_64` and `darwin/arm64`

Current limitations:

- the concierge path is intentionally narrow in v1 and is most polished for GitHub and Linear-backed
  GitHub repositories,
- this remains prototype software rather than a hardened production control plane.

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
