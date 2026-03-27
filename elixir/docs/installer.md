# Installer v1 Manifest and State Model

This document defines the installer-facing contract introduced for repo-first bootstrap flows.

## Repo-First Concierge Flow

The repo-first path is designed around a global `symphony-concierge` skill bundle:

1. Concierge scans the current repository once and caches discovery results.
2. Concierge asks setup questions in one batch (no hidden re-scan after each answer).
3. Concierge writes `.symphony/install/request.json`.
4. Concierge runs:

```bash
symphony install --manifest .symphony/install/request.json
```

5. Installer/apply phase: installer writes/updates repo-local state in `.symphony/install/`.
6. Post-install launch verification phase: concierge selects a free local port, runs Symphony from
   the target repo root with
   `--i-understand-that-this-will-be-running-without-the-usual-guardrails --port <selected_port> ./WORKFLOW.md`,
   and requires both:
   - a live spawned process
   - a successful API health response at `http://127.0.0.1:<selected_port>/api/v1/state`
   Dashboard reachability at `http://127.0.0.1:<selected_port>/` is recorded as additional signal.
7. For GitHub tracker setups, concierge verifies or creates the default workflow-state labels
   `Todo`, `In Progress`, and `Done`, and must explain that candidate issue pickup depends on those
   labels rather than generic GitHub `open` state alone.
8. Concierge reports either verified launch success or a precise blocker from either phase.

## Manifest Schema

`SymphonyElixir.Installer.Manifest.parse/1` accepts a manifest map and normalizes it into a typed
internal structure.

Required manifest fields:

- `schema_version` (positive integer)
- `capabilities` (list of non-empty strings)
- `target_repo` (non-empty string path)

Optional manifest fields:

- `installer_version_range` (SemVer requirement string, for example `>= 0.1.0`)
- `tooling_policy` (policy map; defaults to `Installer.Policy.tooling_policy_matrix/0`)
- `durable_assets` (map; defaults to `%{}`)
- `ephemeral_state_dir` (v1 only accepts `.symphony/install`; custom values are rejected)
- `machine_state` (map; defaults to policy machine-state settings)
- `tracker` (map; defaults to `%{}`)
- `forge` (map; defaults to `%{}`)

Compatibility checks are handled by `Manifest.ensure_compatible!/3` and currently verify:

- `schema_version` must match installer-supported schema (`1` in v1).
- installer binary version must satisfy `installer_version_range` when provided.
- all required capabilities are present in manifest capabilities.
- machine-local state paths must remain outside repo-local `.symphony/install`.

## Tooling Policy Matrix

`SymphonyElixir.Installer.Policy.tooling_policy_matrix/0` returns the v1 policy matrix:

- `installer_binary: :auto_install`
- `system_runtime: :prompt_before_act`
- `forge_cli: :verify_only`
- `repo_assets: :managed_repo_assets`
- `secrets: :user_provided`
- `machine_state: %{installer_cache_dir: "~/.cache/symphony", version_cache_file: "~/.cache/symphony/installer-version.json"}`

`Installer.Policy.classify_asset/1` classifies each policy key so apply/preflight code can enforce
ownership boundaries.

## Repo-Local Session State

`SymphonyElixir.Installer.SessionState` models resumable install state under the target repository:

- `.symphony/install/request.json`
- `.symphony/install/state.json`
- `.symphony/install/events.jsonl`

`SessionState.paths/1` always resolves these files beneath the target repo root. Machine-local cache
state remains outside the repo and is modeled through the policy `machine_state` section.

## Installer Acquisition Helper

The concierge bundle ships `scripts/ensure_symphony_installer.sh` to guarantee `symphony` is
available before invoking `symphony install --manifest ...`.

Behavior:

- If `symphony` already exists on `PATH`, it is reused after a `symphony --help` sanity check.
- Otherwise, the helper downloads a matching release asset from GitHub Releases and installs it to
  `~/.local/bin` (or `SYMPHONY_INSTALL_DIR` when set).
- The helper supports `darwin`/`linux` and `x86_64`/`arm64`.
- If no suitable release asset is found, the script exits with an explicit blocker.
