---
name: symphony-concierge
description: |
  Repo-first Symphony concierge flow: scan the current repository once, ask setup
  questions, write `.symphony/install/request.json`, run
  `symphony install --manifest ...`, launch Symphony on a selected local port,
  verify API health while the spawned process is alive, and report launch
  success or a precise blocker.
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

Ask these questions in one message, with defaults from the one-pass scan:

1. Tracker provider: `linear`, `gitlab`, or `github` (default: `linear`)
2. Tracker project slug (required; for GitHub tracker use `owner/repo`)
3. Workspace root (default: `~/code/<repo-name>-workspaces`)
4. Workspace bootstrap command (default: `git clone --depth 1 <origin-remote> .`)
5. Codex command (default: `codex app-server`)
6. Validation command before handoff (optional)

Then continue with no additional hidden scan loops.

## Step 4: Build manifest and request state

1. Pick the tracker token env var:
   - `linear` -> `LINEAR_API_KEY`
   - `gitlab` -> `GITLAB_API_TOKEN`
   - `github` -> `GITHUB_TOKEN`
2. Build a valid `WORKFLOW.md` payload for that tracker.
3. Write `.symphony/install/request.json` with required installer fields.

Reference command shape:

```bash
mkdir -p "$repo_root/.symphony/install"

tmp_workflow="$(mktemp)"
cat >"$tmp_workflow" <<EOF
---
tracker:
  kind: ${tracker_provider}
  api_key: \$${tracker_token_env}
  project_slug: ${project_slug}
workspace:
  root: ${workspace_root}
hooks:
  after_create: |
    ${after_create_command}
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: ${codex_command}
---
You are working on a ${tracker_provider} issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}
EOF

jq -n \
  --arg target_repo "$repo_root" \
  --arg tracker_provider "$tracker_provider" \
  --arg project_slug "$project_slug" \
  --arg workflow "$(cat "$tmp_workflow")" \
  '{
    schema_version: 1,
    installer_version_range: ">= 0.1.0",
    capabilities: ["repo_first_bootstrap", "launch_verify_v1"],
    target_repo: $target_repo,
    tracker: {
      provider: $tracker_provider,
      project_slug: $project_slug
    },
    forge: {
      provider: "github"
    },
    durable_assets: {
      files: {
        "WORKFLOW.md": $workflow
      }
    }
  }' > "$repo_root/.symphony/install/request.json"

rm -f "$tmp_workflow"
```

If `jq` is unavailable, write equivalent JSON with another deterministic method.

## Step 5: Apply installer manifest

Run:

```bash
set +e
"$installer_bin" install --manifest "$repo_root/.symphony/install/request.json" 2>&1 | tee "$repo_root/.symphony/install/install.log"
install_exit=${PIPESTATUS[0]}
set -e
```

## Step 6: Launch Symphony and verify reachability

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

## Step 7: Summarize success or blocker precisely

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

When `install_exit != 0`:

- Report `Blocked`.
- Include the exact install error output and, when available, `state.json.reason`.
- Provide concrete next action tied to that blocker (missing tool, missing token, unsupported remote, invalid workflow, installer upgrade requirement).

When `install_exit == 0` but launch verification fails:

- Report `Blocked`.
- Include API health probe failures plus the last lines from `.symphony/install/launch.log`.
- If the process exited, include that fact and a concrete next action tied to the failure.
