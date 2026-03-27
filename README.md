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
- `observability`: the local dashboard and API used to inspect state and health.

## Fastest Way To Use It

The fastest path is the repo-first `symphony-concierge` skill.

From inside your target repository, ask Codex to:

```text
Install the symphony-concierge skill from https://github.com/tianheil3/symphony.git path .codex/skills/symphony-concierge, then use it to set up Symphony for this repository.
```

The concierge flow will:

1. scan the current repository once,
2. ask setup questions in one batch,
3. write `.symphony/install/request.json`,
4. run `symphony install --manifest .symphony/install/request.json`,
5. start Symphony on a selected local port,
6. verify both process liveness and API health before reporting success.

For GitHub tracker setups, the concierge flow must also verify or create the default workflow-state
labels:

- `Todo`
- `In Progress`
- `Done`

GitHub issue pickup depends on those labels. A newly created GitHub issue that is merely `open`
but has no active-state label such as `Todo` will not be treated as candidate work by the default
Symphony workflow.

For GitHub tracker setups, the generated `WORKFLOW.md` should also explicitly instruct agents to:

- use `gh issue comment` for the persistent workpad
- use `gh api` for workflow-state label changes
- avoid `linear_graphql` or other Linear-only closeout tools entirely

If `symphony` is not already installed, the bundled helper will download a matching release asset
from this repository's GitHub Releases.

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
