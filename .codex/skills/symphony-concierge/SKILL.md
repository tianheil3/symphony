---
name: symphony-concierge
description: |
  Use when setting up Symphony from inside a target repository, especially when
  the repository needs a repo-owned WORKFLOW.md, tracker wiring, installer
  manifest, launch verification, or a real-project workflow profile.
---

# Symphony Concierge

Use this skill from inside the target repository root.

## Guardrails

- Run one repo scan at the start and cache those results.
- Ask setup questions in one batch message.
- After answers are provided, do not run hidden re-scans after each answer.
- Do not use `symphony bootstrap` for this flow; use manifest-driven install.

## Step 1: One-pass repository scan

Run exactly once:

```bash
repo_root="$(git rev-parse --show-toplevel)"
repo_name="$(basename "$repo_root")"
origin_remote="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
has_workflow="false"
if [ -f "$repo_root/WORKFLOW.md" ]; then has_workflow="true"; fi
```

Immediate blocker rules:

- If `repo_root` cannot be resolved, stop: `Blocked: current directory is not a Git repository`.
- If `origin_remote` is empty or does not contain `github.com`, stop with a precise blocker and note that v1 supports GitHub ordinary repositories only.

## Step 2: Ensure installer availability

Resolve the bundled helper from the target repository and run it:

```bash
installer_helper=""
for candidate in \
  "$repo_root/.codex/skills/symphony-concierge/scripts/ensure_symphony_installer.sh" \
  "${CODEX_HOME:-$HOME/.codex}/skills/symphony-concierge/scripts/ensure_symphony_installer.sh"; do
  if [ -f "$candidate" ]; then
    installer_helper="$candidate"
    break
  fi
done

if [ -z "$installer_helper" ]; then
  echo "Blocked: installer helper not found in repo-local or CODEX_HOME skill paths"
  exit 1
fi
if ! installer_bin="$(bash "$installer_helper")"; then
  echo "Blocked: installer helper failed to resolve a usable symphony binary"
  exit 1
fi
installer_bin="$(printf '%s\n' "$installer_bin" | tail -n 1)"
if [ -z "$installer_bin" ] || [ ! -x "$installer_bin" ]; then
  echo "Blocked: installer helper returned non-executable symphony path: ${installer_bin:-<empty>}"
  exit 1
fi
```

If this helper cannot provide `symphony`, stop and report the exact blocker.

## Step 3: Ask setup questions (single batch)

Ask these questions in one message, with defaults from the one-pass scan. Do not ask follow-up
questions unless a required answer is unusable.

1. Workflow profile:
   - `starter` (default): real-project first install, conservative concurrency, PR handoff, no auto-merge.
   - `review-gated`: adds explicit review/rework states and PR/MR feedback sweep before handoff.
   - `symphony-dev`: only for this repository or when the operator explicitly asks for Symphony's internal heavy workflow.
2. Existing `WORKFLOW.md` policy when `has_workflow=true`: `stop` (default), `keep`, or `replace`.
   - Never overwrite an existing `WORKFLOW.md` unless the answer is exactly `replace`.
   - If the answer is `keep`, do not generate a `WORKFLOW.md` durable asset; still write installer state and launch the existing file.
3. Tracker provider: `github`, `linear`, or `gitlab` (default: `github` for GitHub remotes).
4. Tracker project slug:
   - GitHub: `owner/repo` (default from the origin remote when parseable).
   - Linear/GitLab: require an explicit project slug.
5. Workspace root (default: `~/code/<repo-name>-workspaces`).
6. Workspace bootstrap command (default: `git clone --depth 1 <origin-remote> .`).
7. Codex command (default: `codex app-server`).
8. Validation command before handoff.
   - For `starter` and `review-gated`, require either a concrete command or the literal answer `none`.
   - If `none`, the generated workflow must require the agent to choose a targeted validation command and record why no repository-wide command exists.
9. Agent limits (default: `max_concurrent_agents: 1`, `max_turns: 10`; allow explicit override).

Then continue with no additional hidden scan loops.

## Step 4: Build workflow content from the selected profile

1. Pick the tracker token env var:
   - `github` -> `GITHUB_TOKEN`
   - `linear` -> `LINEAR_API_KEY`
   - `gitlab` -> `GITLAB_API_TOKEN`
2. Resolve profile defaults:
   - `starter`
     - active states: `Todo`, `In Progress`
     - terminal states: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`
     - max agents: `1`
     - max turns: `10`
     - no automated merge step
   - `review-gated`
     - active states: `Todo`, `In Progress`, `Human Review`, `Rework`
     - terminal states: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`
     - max agents: `1`
     - max turns: `12`
     - no automated merge step unless the operator explicitly asks for one
   - `symphony-dev`
     - require explicit confirmation that this is for Symphony itself or for a repo intentionally adopting Symphony's internal Linear flow
     - do not copy this repository's `elixir/WORKFLOW.md` blindly; regenerate project-specific clone, setup, state, and validation settings
3. Generate a `WORKFLOW.md` that is self-contained and repo-specific. It must include:
   - the chosen tracker provider and token env var
   - workspace root and bootstrap hook
   - conservative agent limits unless overridden
   - the Codex app-server command
   - `turn_sandbox_policy.networkAccess: true` so tracker CLIs/APIs can update labels, comments, states, and PR/MR handoff
   - GitHub pickup writeback as a runtime gate: `Todo` -> `In Progress` plus `## Codex Workpad` must succeed before agent code starts
   - a prompt body with status routing, workpad/comment rules, validation, PR/MR handoff, and provider-specific tool restrictions
4. The generated prompt body must preserve these behavioral requirements:
   - Work only inside the Symphony-created issue workspace.
   - Use the tracker matching `tracker.kind` as the source of truth for comments, labels/states, and handoff.
   - Maintain one persistent workpad comment per issue and update it instead of posting scattered progress comments.
   - Mirror issue-provided acceptance criteria, `Validation`, `Test Plan`, or `Testing` sections into the workpad.
   - Reproduce or inspect the issue signal before changing code when the issue describes a bug.
   - Run the configured validation command before handoff; if validation is `none`, choose the narrowest meaningful validation and record the rationale.
   - Create or update a PR/MR for code changes, attach/link it to the issue when the tracker supports it, and wait for CI/check evidence before marking work complete.
   - Do not auto-merge by default.
5. Provider-specific restrictions:
   - GitHub workflows must use `gh issue comment`, `gh api`, `gh pr view`, and `gh pr checks` patterns, and must never use Linear-only tools.
   - Linear workflows may use Linear MCP or `linear_graphql`, and must not use GitHub labels as workflow state.
   - GitLab workflows must use `glab`/GitLab API patterns, and must not use Linear-only tools.

## Step 5: Build manifest and request state

Write `.symphony/install/request.json` with required installer fields.

Required durable asset behavior:

- If no `WORKFLOW.md` exists, include generated `WORKFLOW.md` under `durable_assets.files`.
- If `has_workflow=true` and existing policy is `replace`, include generated `WORKFLOW.md` under `durable_assets.files`.
- If `has_workflow=true` and existing policy is `keep`, omit `WORKFLOW.md` from `durable_assets.files`.
- If `has_workflow=true` and existing policy is `stop`, stop before writing installer state:
  `Blocked: WORKFLOW.md already exists; rerun with keep or replace`.

Reference manifest shape:

```json
{
  "schema_version": 1,
  "installer_version_range": ">= 0.1.0",
  "capabilities": ["repo_first_bootstrap", "launch_verify_v1"],
  "target_repo": "<repo_root>",
  "tracker": {
    "provider": "<tracker_provider>",
    "project_slug": "<project_slug>"
  },
  "forge": {
    "provider": "github"
  },
  "durable_assets": {
    "files": {
      "WORKFLOW.md": "<generated workflow, unless keeping an existing file>"
    }
  }
}
```

If `jq` is unavailable, write equivalent JSON with another deterministic method.

## Step 6: For GitHub tracker, ensure workflow-state labels exist

GitHub candidate issues are driven by workflow-state labels, not by the repository's generic open/closed state alone. The concierge flow MUST make this explicit and MUST ensure the required labels exist before reporting setup success.

Required labels:

- `Todo`
- `In Progress`
- `Done`
- `Human Review` when `workflow_profile=review-gated`
- `Rework` when `workflow_profile=review-gated`

Reference command shape:

```bash
if [ "$tracker_provider" = "github" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "Blocked: GitHub tracker setup requires gh to create or verify workflow-state labels"
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "Blocked: GitHub tracker setup requires gh auth to create or verify workflow-state labels"
    exit 1
  fi

  label_specs="Todo:0E8A16:Ready for Symphony pickup
In Progress:1D76DB:Actively being worked by Symphony
Done:8250DF:Completed by Symphony"
  if [ "$workflow_profile" = "review-gated" ]; then
    label_specs="$label_specs
Human Review:6F42C1:Waiting for human review
Rework:D93F0B:Reviewer requested changes"
  fi

  printf '%s\n' "$label_specs" | while IFS= read -r spec; do
    label_name="${spec%%:*}"
    rest="${spec#*:}"
    label_color="${rest%%:*}"
    label_desc="${rest#*:}"
    gh label create "$label_name" --repo "$project_slug" --color "$label_color" --description "$label_desc" 2>/dev/null || true
  done

  existing_labels="$(gh label list --repo "$project_slug" --limit 200 --json name --jq '.[].name')"
  required_labels="Todo
In Progress
Done"
  if [ "$workflow_profile" = "review-gated" ]; then
    required_labels="$required_labels
Human Review
Rework"
  fi

  printf '%s\n' "$required_labels" | while IFS= read -r required_label; do
    if ! printf '%s\n' "$existing_labels" | grep -Fx -- "$required_label" >/dev/null; then
      echo "Blocked: required GitHub workflow-state label missing after setup: $required_label"
      exit 1
    fi
  done
fi
```

When `tracker_provider=github`, the concierge summary MUST also state:

- workflow-state labels were verified or created
- new GitHub issues must carry an active-state label such as `Todo` to be picked up by Symphony
- the generated `WORKFLOW.md` explicitly routes issue comments and state transitions through GitHub tools, not Linear tools

## Step 7: Apply installer manifest

Run:

```bash
set +e
"$installer_bin" install --manifest "$repo_root/.symphony/install/request.json" 2>&1 | tee "$repo_root/.symphony/install/install.log"
install_exit=${PIPESTATUS[0]}
set -e
```

## Step 8: Launch Symphony and verify reachability

Only continue when install succeeded:

```bash
launch_ok="false"
launch_pid=""
dashboard_ok="false"
selected_port=""
health_url=""
dashboard_url=""

if [ "$install_exit" -eq 0 ]; then
  if [ ! -f "$repo_root/WORKFLOW.md" ]; then
    echo "Blocked: install completed but $repo_root/WORKFLOW.md is missing, cannot launch Symphony"
    exit 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Blocked: python3 is required to select a free local port for launch verification"
    exit 1
  fi

  selected_port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  if [ -z "$selected_port" ]; then
    echo "Blocked: failed to select a free local port"
    exit 1
  fi

  health_url="http://127.0.0.1:${selected_port}/api/v1/state"
  dashboard_url="http://127.0.0.1:${selected_port}/"
  launch_log="$repo_root/.symphony/install/launch.log"
  (
    cd "$repo_root" || exit 1
    "$installer_bin" --i-understand-that-this-will-be-running-without-the-usual-guardrails --port "$selected_port" ./WORKFLOW.md
  ) >"$launch_log" 2>&1 &
  launch_pid=$!

  for _ in $(seq 1 45); do
    if ! kill -0 "$launch_pid" >/dev/null 2>&1; then
      break
    fi
    if curl -fsS "$health_url" >/dev/null 2>&1; then
      launch_ok="true"
      if curl -fsS "$dashboard_url" >/dev/null 2>&1; then
        dashboard_ok="true"
      fi
      break
    fi
    sleep 1
  done
fi
```

## Step 9: Summarize success or blocker precisely

When `install_exit == 0` and `launch_ok == "true"`:

- Report verified launch success.
- Confirm these files exist:
  - `.symphony/install/request.json`
  - `.symphony/install/state.json`
  - `.symphony/install/events.jsonl`
- Confirm the running command and port:
  - `"$installer_bin" --i-understand-that-this-will-be-running-without-the-usual-guardrails --port "$selected_port" ./WORKFLOW.md`
- Provide:
  - selected port: `$selected_port`
  - required API health URL (verified): `$health_url`
  - dashboard URL (optional signal): `$dashboard_url`
  - dashboard probe status: `$dashboard_ok`
  - launch PID and `.symphony/install/launch.log` path
- Confirm the selected workflow profile and whether `WORKFLOW.md` was generated, kept, or replaced.
- When `tracker_provider=github`, also confirm:
  - required workflow-state labels for the selected profile exist
  - new GitHub issues must be created or updated with an active-state label such as `Todo` before Symphony will pick them up

When `install_exit != 0`:

- Report `Blocked`.
- Include the exact install error output and, when available, `state.json.reason`.
- Provide concrete next action tied to that blocker (missing tool, missing token, unsupported remote, invalid workflow, installer upgrade requirement).

When `install_exit == 0` but launch verification fails:

- Report `Blocked`.
- Include API health probe failures plus the last lines from `.symphony/install/launch.log`.
- If the process exited, include that fact and a concrete next action tied to the failure.
