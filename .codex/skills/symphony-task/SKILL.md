---
name: symphony-task
description: Use when a user wants to turn natural-language work into Symphony-managed GitHub or Linear tasks, inspect task status, add task context, or change task workflow state.
---

# Symphony Task

Use this skill to manage the tracker-facing task intake layer for Symphony. The goal is to create
or update issues that Symphony can pick up, not to implement the task directly.

## Operating Contract

- Prefer the target repository's `WORKFLOW.md` as the source of truth for tracker provider, project
  slug, active states, terminal states, and workflow labels.
- If `WORKFLOW.md` is unavailable, infer GitHub from the current repo remote and `gh repo view`; ask
  only for missing tracker/project information that cannot be inferred safely.
- Do not mix tracker tools. GitHub workflows use `gh`; Linear workflows use Linear MCP or
  `linear_graphql`.
- Do not mark work `Done`, `Closed`, `Cancelled`, or another terminal state unless the user
  explicitly asks for that state change.
- Treat `Todo` as the default pickup state for new work unless the workflow says otherwise.

## Intent Routing

Classify the user's request first:

- Create task: natural-language feature, bug, cleanup, investigation, QA, or docs request.
- Check status: ask for current tracker state, labels, Symphony workpad, PR/MR links, or latest
  comments.
- Add context: append acceptance criteria, validation, reproduction details, screenshots, links, or
  constraints.
- Change state: move between workflow states/labels such as `Todo`, `In Progress`, `Human Review`,
  `Rework`, or `Done`.
- Split task: convert one broad request into several smaller Symphony-pickup issues.

## Intake Shape

Convert natural language into this issue structure before creating or updating a tracker item:

```md
## Problem

<What is wrong or what capability is missing.>

## Desired Outcome

<The observable behavior or end state Symphony should produce.>

## Context

- Repository/path:
- Relevant files, URLs, logs, screenshots, or prior issues:
- Constraints:

## Acceptance Criteria

- [ ] <Concrete, reviewable outcome>
- [ ] <Concrete, reviewable outcome>

## Validation

- [ ] <Command, manual check, CI check, or targeted proof>

## Progress Expectations

- [ ] Create or update `## Codex Workpad` soon after pickup.
- [ ] Add heartbeat updates during long investigation, validation, or blocked work.

## Out of Scope

- <Anything the agent should not expand into>
```

Rules:

- If the user's wording is vague but enough to create a useful first task, create the issue with
  explicit assumptions in `Context`.
- If the request lacks a repository/tracker target, ask one concise question before creating.
- If acceptance criteria are missing, derive them from the desired outcome instead of leaving the
  issue empty.
- For bugs, include reproduction signal or an explicit checkbox requiring reproduction before code
  changes.
- For broad requests, propose a split and create multiple issues only when the user asked for
  multi-issue planning or explicitly approves the split.

## GitHub Workflow

Prerequisites:

- `gh` is available.
- `gh auth status` succeeds.
- Target repo is `owner/repo`.

Read workflow labels:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
workflow="$repo_root/WORKFLOW.md"
```

If parsing workflow labels is not practical, use these defaults:

- Active labels: `Todo`, `In Progress`
- Review labels when present: `Human Review`, `Rework`
- Terminal labels: `Done`, `Closed`, `Cancelled`, `Canceled`, `Duplicate`

Create a pickup issue:

```sh
tmp_body="$(mktemp)"
# Write the structured issue body to "$tmp_body".
issue_url="$(gh issue create \
  --repo "$repo" \
  --title "$title" \
  --body-file "$tmp_body" \
  --label "Todo")"
rm -f "$tmp_body"
```

Check status:

```sh
gh issue view "$issue" \
  --repo "$repo" \
  --json number,title,state,labels,assignees,url,comments
```

Add context:

```sh
gh issue comment "$issue" --repo "$repo" --body-file "$tmp_body"
```

Change workflow label:

```sh
for label in "Todo" "In Progress" "Human Review" "Rework" "Done"; do
  if [ "$label" != "$target_state" ]; then
    gh issue edit "$issue" --repo "$repo" --remove-label "$label" >/dev/null 2>&1 || true
  fi
done
gh issue edit "$issue" --repo "$repo" --add-label "$target_state"
```

GitHub status interpretation:

- Symphony pickup requires an active workflow label such as `Todo`.
- Generic GitHub `open` is not enough for Symphony pickup.
- If a PR exists, include PR URL/check status in the status summary.

## Linear Workflow

Preferred path:

- Use Linear MCP tools when available: `create_issue`, `get_issue`, `list_issue_statuses`,
  `update_issue`, `list_comments`, and `create_comment`.

Fallback path in Symphony app-server sessions:

- Use the repo-local `linear` skill and Symphony's `linear_graphql` tool.
- Resolve the issue by key or id before updates.
- Query the issue's team states before changing state.
- Use `issueUpdate(id: ..., input: {stateId: ...})` only after resolving the target state id.
- For issue creation through `linear_graphql`, introspect `IssueCreateInput` if the exact workspace
  schema is unclear, then call `issueCreate`.

Linear status interpretation:

- Symphony pickup depends on the configured active Linear states, commonly `Todo` and
  `In Progress`.
- `Done`, `Closed`, `Cancelled`, `Canceled`, and `Duplicate` are terminal by default and may cause
  Symphony to stop or clean up workspaces.
- Keep the Linear issue body as the canonical request; use comments for additions and status notes.

## Status Summary

After every create, update, or status check, report:

- Tracker provider and project/repo.
- Issue identifier and URL.
- Current Symphony workflow state or label.
- Whether Symphony should pick it up now.
- Latest PR/MR URL and check/review state when available.
- Any blocker such as missing auth, missing workflow labels, or unsupported tracker setup.

## Common Mistakes

- Creating a GitHub issue without the `Todo` label and expecting Symphony to pick it up.
- Using Linear GraphQL in a GitHub workflow because the tool happens to be available.
- Moving an issue to `Done` as a handoff instead of waiting for validation and explicit user intent.
- Writing a request body with no acceptance criteria or validation signal.
- Expanding one vague request into many issues without telling the user how scope was split.
