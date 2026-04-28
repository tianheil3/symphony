defmodule SymphonyElixir.Installer.Render do
  @moduledoc false

  alias SymphonyElixir.Installer.WorkflowProfile

  @default_todo_state "Todo"
  @default_in_progress_state "In Progress"
  @default_rework_state "Rework"
  @default_merging_state "Merging"
  @default_done_state "Done"
  @default_error_doc_path "docs/agent-troubleshooting.md"
  @always_installed_skills ["commit", "pull"]

  @spec planned_artifacts(map()) :: [%{path: String.t(), content: iodata()}]
  def planned_artifacts(plan) do
    plan = WorkflowProfile.apply_defaults(plan)

    workflow = %{path: Path.join(plan.target_root, "WORKFLOW.md"), content: workflow_content(plan)}

    troubleshooting = %{
      path: Path.join(plan.target_root, plan.error_doc_path),
      content: troubleshooting_doc_content(plan)
    }

    common_skill_artifacts =
      plan.skills
      |> Enum.filter(&common_skill_name?/1)
      |> Enum.map(fn skill_name ->
        %{
          path: Path.join([plan.target_root, ".codex", "skills", skill_name, "SKILL.md"]),
          content: skill_content(skill_name, plan)
        }
      end)

    tracker_skill_artifacts = tracker_provider_module(plan).related_skill_artifacts(plan)

    forge_skill_artifacts =
      if plan.hosted_review_flow? do
        forge_provider_module(plan).skill_artifacts(plan)
      else
        []
      end

    base =
      [workflow, troubleshooting]
      |> maybe_append(plan.create_agents?, %{path: Path.join(plan.target_root, "AGENTS.md"), content: agents_content(plan)})
      |> maybe_append(plan.create_pr_template?, %{
        path: Path.join(plan.target_root, ".github/pull_request_template.md"),
        content: pull_request_template_content(plan)
      })

    base ++ common_skill_artifacts ++ tracker_skill_artifacts ++ forge_skill_artifacts
  end

  defp maybe_append(list, true, value), do: [value | list]
  defp maybe_append(list, false, _value), do: list

  defp workflow_content(plan) do
    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_provider_module(plan).workflow_kind())}",
        "  api_key: #{yaml_value("$" <> tracker_provider_module(plan).required_secret_name())}",
        "  project_slug: #{yaml_value(plan.project_slug)}",
        "  active_states: #{yaml_value(plan.active_states)}",
        "  terminal_states: #{yaml_value(plan.terminal_states)}",
        "polling:",
        "  interval_ms: 5000",
        "workspace:",
        "  root: #{yaml_value(plan.workspace_root)}",
        "hooks:",
        "  timeout_ms: 60000",
        hook_entry("after_create", plan.after_create_command),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(plan.agent_max_concurrent_agents)}",
        "  max_turns: #{yaml_value(plan.agent_max_turns)}",
        "codex:",
        "  command: #{yaml_value(plan.codex_command)}",
        "  approval_policy: \"never\"",
        "  thread_sandbox: \"workspace-write\"",
        "  turn_sandbox_policy:",
        "    type: \"workspaceWrite\"",
        "---",
        workflow_prompt(plan)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n") <> "\n"
  end

  defp workflow_prompt(plan) do
    [
      "You are working on a #{tracker_provider_module(plan).display_name()} ticket `{{ issue.identifier }}` in the `#{plan.repo_name}` repository.",
      "",
      "{% if attempt %}",
      "Continuation context:",
      "",
      "- This is retry attempt #" <> "{{ attempt }} because the ticket is still active.",
      "- Resume from the existing workspace and current `## Codex Workpad` comment.",
      "- Re-read new #{String.downcase(tracker_provider_module(plan).display_name())} comments and review feedback before making more changes.",
      "{% endif %}",
      "",
      "Issue context:",
      "Identifier: {{ issue.identifier }}",
      "Title: {{ issue.title }}",
      "Current status: {{ issue.state }}",
      "Labels: {{ issue.labels }}",
      "URL: {{ issue.url }}",
      "",
      "Description:",
      "{% if issue.description %}",
      "{{ issue.description }}",
      "{% else %}",
      "No description provided.",
      "{% endif %}",
      "",
      "Repository defaults:",
      "- Workflow profile: #{plan.workflow_profile}",
      "- Validation command before handoff: #{plan.validation_command || "No default validation command configured."}",
      "- Forge provider: #{plan.forge_provider.display_name}",
      "- Hosted review automation: #{bool_label(plan.hosted_review_flow?)}",
      "- Human Review polling: #{human_review_mode_label(plan)}",
      "- Error knowledge base: `#{plan.error_doc_path}`",
      gstack_defaults_line(plan),
      "",
      "Project requirements:",
      optional_markdown_text(plan.project_requirements, "No additional repository-wide requirements were configured."),
      "",
      "Default acceptance criteria:",
      optional_markdown_text(plan.acceptance_criteria, "No default repository-wide acceptance criteria were configured."),
      "",
      "Additional instructions:",
      optional_markdown_text(plan.additional_instructions, "No extra autonomous instructions were configured."),
      "",
      "Operating rules:",
      "1. This is an unattended orchestration session. Never ask a human to do follow-up work for you.",
      "2. Use exactly one persistent #{tracker_provider_module(plan).workpad_label()} named `## Codex Workpad` as the working plan, acceptance checklist, validation log, and blocker brief.",
      "3. Update the workpad before new work, after each meaningful milestone, and before every handoff.",
      "4. Reproduce or capture the baseline behavior before changing code.",
      "5. Every time you hit a meaningful error or discover a reusable fix, append it to `#{plan.error_doc_path}`.",
      "6. Before any handoff, run the required validation for the current scope and record the result in the workpad.",
      "7. Stop early only for true blockers such as missing auth, permissions, or secrets.",
      "8. Work only inside the provided repository copy.",
      "9. Create or update a PR/MR for code changes, attach or link it to the tracker issue when available, and wait for CI/check evidence before marking work complete.",
      "10. Do not auto-merge by default.",
      "",
      "Progress SLA:",
      "- Create or refresh `## Codex Workpad` within 5 minutes of starting the run, before long investigation or implementation work.",
      "- While the issue remains active, update the same workpad at least every 20 minutes, even if the only update is current investigation, command, blocker, or next planned validation.",
      "- Before starting any command, build, test, browser run, or investigation expected to take more than 10 minutes, add a workpad note with the command/purpose and expected signal.",
      "- After a long-running step finishes or fails, update the workpad with the result, next action, and any changed risk or blocker.",
      "- If tracker writes fail, stop after recording the exact blocker in the final response; do not continue silently for more than one attempted fallback.",
      "",
      "Related skills:"
    ]
    |> Kernel.++(gstack_skill_lines(plan))
    |> Kernel.++([
      tracker_provider_module(plan).related_skill_line(plan),
      "- `commit`: create clear commits when needed.",
      "- `pull`: merge the latest `origin/main` before final handoff or when conflicts appear."
    ])
    |> maybe_append_lines(plan.hosted_review_flow?, forge_provider_module(plan).related_skill_lines(plan))
    |> Kernel.++([
      "",
      "Skill routing:",
      skill_routing_discovery_line(plan),
      skill_routing_investigate_line(plan),
      skill_routing_qa_line(plan),
      skill_routing_review_line(plan),
      skill_routing_release_line(plan),
      "",
      "Status map:",
      "- `#{@default_todo_state}` -> move immediately to `#{@default_in_progress_state}` and begin execution.",
      "- `#{@default_in_progress_state}` -> implementation is actively underway.",
      status_line_for_human_review(plan),
      "- `#{plan.rework_state}` -> re-read all new human feedback, update the workpad, implement changes, and revalidate."
    ])
    |> maybe_append_lines(plan.hosted_review_flow?, forge_provider_module(plan).status_lines(plan))
    |> Kernel.++([
      "- `#{plan.done_state}` -> terminal state; stop.",
      "",
      "Execution flow:",
      "1. Determine the current issue state and follow the matching branch above.",
      "2. Find or create the single `## Codex Workpad` comment and keep it current in place.",
      "3. Keep `Plan`, `Acceptance Criteria`, `Validation`, and `Notes` sections accurate as reality changes.",
      "4. If the issue is `#{plan.rework_state}`, start by reading all new #{tracker_provider_module(plan).display_name()} comments and any review feedback before editing code.",
      gstack_workflow_line(4, plan),
      execution_flow_line_for_validation(plan)
    ])
    |> Kernel.++(provider_execution_flow_lines(plan))
    |> Kernel.++([
      final_workflow_line(plan)
    ])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp agents_content(plan) do
    sections =
      [
        "# Agent Guide",
        "",
        "## Operating Defaults",
        "",
        gstack_agents_line(plan),
        "- Treat the #{tracker_provider_module(plan).display_name()} issue and the `## Codex Workpad` comment as the source of truth during execution.",
        "- Keep scope tight and document blockers in the workpad instead of asking for manual follow-up work.",
        "- Before handoff, run #{plan.validation_command || "the most relevant validation for the current scope"} and record the result.",
        "- Re-read new human feedback before making more changes after a handoff or review cycle.",
        "- Every meaningful error and fix belongs in `#{plan.error_doc_path}`."
      ]
      |> maybe_append_section("## Project Requirements", plan.project_requirements)
      |> maybe_append_section("## Default Acceptance Criteria", plan.acceptance_criteria)
      |> maybe_append_section("## Additional Instructions", plan.additional_instructions)

    Enum.join(sections, "\n") <> "\n"
  end

  defp pull_request_template_content(plan) do
    validation_line =
      case plan.validation_command do
        nil -> "- [ ] Describe the validation run for this change"
        command -> "- [ ] `#{command}`"
      end

    criteria_lines =
      plan.acceptance_criteria
      |> checklist_lines("- [ ] Define the acceptance criteria for this PR")

    [
      "#### Context",
      "",
      "- Why is this change needed?",
      "",
      "#### Summary",
      "",
      "- What changed?",
      "- What is the user-visible outcome?",
      "",
      "#### Acceptance Criteria",
      "",
      criteria_lines,
      "",
      "#### Test Plan",
      "",
      validation_line,
      "- [ ] Any additional targeted checks for this change"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp skill_content("commit", _plan), do: commit_skill()
  defp skill_content("pull", _plan), do: pull_skill()

  defp commit_skill do
    """
    ---
    name: commit
    description:
      Create a well-formed git commit from current changes using session history for rationale and summary.
    ---

    # Commit

    ## Goals

    - Produce a commit that matches the actual code changes.
    - Use a conventional short subject and a wrapped explanatory body.
    - Include validation results or note when validation was not run.

    ## Steps

    1. Inspect `git status`, `git diff`, and `git diff --staged`.
    2. Stage only the intended files.
    3. Write a conventional commit subject in imperative mood.
    4. In the body, summarize what changed, why it changed, and which validation ran.
    5. Create the commit with a literal multi-line message.

    ## Output

    - One commit whose message reflects the staged change set.
    """
  end

  defp pull_skill do
    """
    ---
    name: pull
    description:
      Pull latest origin/main into the current branch with a merge-based update.
    ---

    # Pull

    ## Workflow

    1. Confirm the working tree is clean or commit first.
    2. Enable rerere locally when available.
    3. Run `git fetch origin`.
    4. Pull the remote branch with `git pull --ff-only origin $(git branch --show-current)`.
    5. Merge `origin/main` with `git -c merge.conflictstyle=zdiff3 merge origin/main`.
    6. Resolve conflicts carefully, rerun validation, and summarize the resolution.
    """
  end

  defp execution_flow_line_for_validation(%{validation_command: nil}) do
    "5. Run the most relevant validation for the current scope before any handoff."
  end

  defp execution_flow_line_for_validation(%{validation_command: command}) do
    "5. Run `#{command}` before any handoff and record the exact result."
  end

  defp provider_execution_flow_lines(%{hosted_review_flow?: true} = plan) do
    forge_provider_module(plan).execution_flow_lines(plan)
  end

  defp provider_execution_flow_lines(%{workflow_profile: "review-gated"} = plan) do
    [
      "6. When a PR/MR exists, attach or update the PR/MR URL on the tracker issue and sweep all new #{review_feedback_label(plan)} review feedback before returning to `#{plan.human_review_state}`.",
      "7. Leave the final merge to humans unless a separate repository workflow explicitly enables automated merge."
    ]
  end

  defp provider_execution_flow_lines(_plan) do
    ["6. Use tracker comments and state transitions as the primary handoff surface."]
  end

  defp maybe_append_lines(lines, true, extra), do: lines ++ extra
  defp maybe_append_lines(lines, false, _extra), do: lines

  defp maybe_append_section(lines, _heading, nil), do: lines

  defp maybe_append_section(lines, heading, body) do
    lines ++ ["", heading, "", body]
  end

  defp forge_provider_module(%{forge_provider: %{module: module}}), do: module
  defp tracker_provider_module(%{tracker_provider: %{module: module}}), do: module

  defp review_feedback_label(%{forge_provider: %{key: "github"}}), do: "PR"
  defp review_feedback_label(%{forge_provider: %{key: "gitlab"}}), do: "MR"
  defp review_feedback_label(_plan), do: "PR/MR"

  defp common_skill_name?(skill_name) when is_binary(skill_name) do
    skill_name in @always_installed_skills
  end

  defp gstack_defaults_line(%{vendor_gstack?: true, gstack_target_root: gstack_target_root}) do
    "- gstack vendored at `#{gstack_target_root}` and should be used at the appropriate lifecycle stage."
  end

  defp gstack_defaults_line(_plan), do: "- gstack is not vendored for this repo."

  defp gstack_skill_lines(%{vendor_gstack?: true}) do
    [
      "- `gstack /office-hours`: use before coding when the problem, wedge, or acceptance criteria are still fuzzy.",
      "- `gstack /plan-eng-review` and `/plan-design-review`: use after discovery to harden architecture, UX, and test coverage.",
      "- `gstack /investigate`: use when you hit a real bug or runtime error before attempting speculative fixes.",
      "- `gstack /qa` and `/browse`: use for UI, runtime, and end-to-end verification.",
      "- `gstack /review`, `/ship`, and `/document-release`: use before handoff or merge to harden code, publish safely, and refresh docs."
    ]
  end

  defp gstack_skill_lines(_plan), do: []

  defp gstack_workflow_line(step_number, %{vendor_gstack?: true}) do
    "#{step_number}a. Use gstack skills at the appropriate stage: `/office-hours` before coding ambiguous work, `/investigate` for real failures, `/qa` or `/browse` for runtime validation, `/review` before merge, and `/document-release` after shipped behavior changes."
  end

  defp gstack_workflow_line(_step_number, _plan), do: nil

  defp final_workflow_line(%{vendor_gstack?: true}) do
    "8. When work is complete, run any relevant final gstack skills (`/review`, `/ship`, `/document-release`) before moving the issue to the appropriate next state."
  end

  defp final_workflow_line(_plan) do
    "7. When work is complete, move the issue to the appropriate next state instead of posting a separate completion comment."
  end

  defp gstack_agents_line(%{vendor_gstack?: true}) do
    "- gstack is vendored in `.codex/skills/gstack`. Prefer `/office-hours`, `/plan-eng-review`, `/plan-design-review`, `/investigate`, `/qa`, `/browse`, `/review`, `/ship`, and `/document-release` at their matching workflow stages. Use `/browse` for web browsing instead of browser MCP helpers. If the gstack skills stop working, rerun `cd .codex/skills/gstack && ./setup --host codex`."
  end

  defp gstack_agents_line(_plan), do: "- Use the repo-local skills and workflow prompt as the primary operating contract."

  defp skill_routing_discovery_line(%{vendor_gstack?: true}) do
    "- Discovery / ambiguous scope: use `gstack /office-hours` before coding, then `gstack /plan-eng-review` or `/plan-design-review` before implementation."
  end

  defp skill_routing_discovery_line(_plan) do
    "- Discovery / ambiguous scope: update the workpad plan and clarify acceptance criteria before coding."
  end

  defp skill_routing_investigate_line(%{vendor_gstack?: true}) do
    "- Runtime bug / flaky failure / unclear root cause: use `gstack /investigate` before speculative fixes."
  end

  defp skill_routing_investigate_line(_plan) do
    "- Runtime bug / flaky failure / unclear root cause: reproduce first, then investigate before fixing."
  end

  defp skill_routing_qa_line(%{vendor_gstack?: true}) do
    "- UI or end-to-end validation: use `gstack /qa` or `/browse` and record the outcome in the workpad and `#{@default_error_doc_path}` when relevant."
  end

  defp skill_routing_qa_line(_plan) do
    "- UI or end-to-end validation: run the most direct runtime proof available for the changed behavior."
  end

  defp skill_routing_review_line(%{vendor_gstack?: true}) do
    "- Pre-merge hardening: use `gstack /review` after implementation and before final handoff."
  end

  defp skill_routing_review_line(_plan) do
    "- Pre-merge hardening: review the final diff, rerun validation, and make the handoff reviewer-ready."
  end

  defp skill_routing_release_line(%{vendor_gstack?: true, hosted_review_flow?: true} = plan) do
    forge_provider_module(plan).release_skill_routing_line(plan)
  end

  defp skill_routing_release_line(_plan) do
    "- Publish / docs refresh: attach the PR, keep docs current, and move the issue to the right handoff state."
  end

  defp status_line_for_human_review(%{human_review_polling?: true, human_review_state: human_review_state}) do
    "- `#{human_review_state}` -> do not make code changes unless new review feedback requires it; poll comments and review signals, then move to `#{@default_rework_state}` or the next handoff state."
  end

  defp status_line_for_human_review(%{human_review_state: human_review_state, hosted_review_flow?: true}) do
    "- `#{human_review_state}` -> passive human handoff; no agent runs in this state. Humans must move the issue to `#{@default_rework_state}` or `#{@default_merging_state}`."
  end

  defp status_line_for_human_review(%{human_review_state: human_review_state}) do
    "- `#{human_review_state}` -> passive human handoff; no agent runs in this state. Humans must move the issue to `#{@default_rework_state}` or `#{@default_done_state}`."
  end

  defp bool_label(true), do: "enabled"
  defp bool_label(false), do: "disabled"

  defp human_review_mode_label(%{human_review_polling?: true}), do: "active polling enabled"
  defp human_review_mode_label(_plan), do: "passive handoff only"

  defp optional_markdown_text(nil, fallback), do: fallback
  defp optional_markdown_text(text, _fallback), do: text

  defp checklist_lines(nil, fallback), do: fallback

  defp checklist_lines(text, _fallback) do
    text
    |> String.split(~r/\R/, trim: true)
    |> Enum.map_join("\n", fn line -> "- [ ] #{String.trim_leading(line, "- ")}" end)
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"
  defp yaml_value(values) when is_list(values), do: "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"

  defp troubleshooting_doc_content(plan) do
    [
      "# Agent Troubleshooting Knowledge Base",
      "",
      "Capture meaningful errors here so future agent runs can reuse the fix instead of rediscovering it.",
      "",
      "## How To Use",
      "",
      "- Add one entry per distinct failure pattern.",
      "- Record the symptom, the root cause, the fix or workaround, and how it was validated.",
      "- Update an existing entry when the same issue appears again.",
      "",
      "## Entry Template",
      "",
      "### YYYY-MM-DD - short title",
      "",
      "- Symptom:",
      "- Root cause:",
      "- Fix or workaround:",
      "- Validation:",
      "- Related files / commands:",
      "",
      "## Bootstrap Defaults",
      "",
      "- Validation command: #{plan.validation_command || "not configured"}",
      "- Tracker provider: #{tracker_provider_module(plan).display_name()}",
      "- Forge provider: #{plan.forge_provider.display_name}",
      "- Hosted review automation: #{bool_label(plan.hosted_review_flow?)}",
      "- gstack vendored: #{yes_no(plan.vendor_gstack?)}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end
