defmodule SymphonyElixir.Installer.ForgeProviders.GitHub do
  @moduledoc false

  @behaviour SymphonyElixir.Installer.ForgeProvider

  @impl true
  def key, do: "github"

  @impl true
  def display_name, do: "GitHub"

  @impl true
  def automation_prompt(_provider), do: "Install GitHub PR workflow skills (`push` / `land`)?"

  @impl true
  def automated_skill_names, do: ["push", "land"]

  @impl true
  def related_skill_lines(%{merging_state: merging_state}) do
    [
      "- `push`: publish the current branch and create or update the PR.",
      "- `land`: merge the PR safely when the ticket reaches `#{merging_state}`."
    ]
  end

  @impl true
  def status_lines(%{merging_state: merging_state, done_state: done_state}) do
    [
      "- `#{merging_state}` -> use the `land` skill to merge, then move the issue to `#{done_state}`."
    ]
  end

  @impl true
  def execution_flow_lines(%{human_review_state: human_review_state, merging_state: merging_state}) do
    [
      "6. When a PR exists, attach or update the PR URL on the tracker issue and sweep all new PR review feedback before returning to `#{human_review_state}`.",
      "7. When the issue reaches `#{merging_state}`, open `.codex/skills/land/SKILL.md` and follow it."
    ]
  end

  @impl true
  def skill_artifacts(plan) do
    [
      skill_artifact(plan, "push", push_skill(plan)),
      skill_artifact(plan, "land", land_skill(plan))
    ]
  end

  @impl true
  def release_skill_routing_line(_plan) do
    "- Publish / docs refresh: use `gstack /ship` for PR/release flow and `gstack /document-release` after behavior or process docs change."
  end

  @impl true
  def pr_template_supported?(_plan), do: true

  @impl true
  def supports_automated_pr_flow?, do: true

  defp skill_artifact(plan, name, content) do
    %{
      path: Path.join([plan.target_root, ".codex", "skills", name, "SKILL.md"]),
      content: content
    }
  end

  defp push_skill(plan) do
    validation_step =
      case plan.validation_command do
        nil -> "2. Run the most relevant validation for the current scope before pushing."
        command -> "2. Run `#{command}` before pushing."
      end

    pr_body_step =
      "6. If `.github/pull_request_template.md` exists, fill it out completely when creating or updating the PR body."

    """
    ---
    name: push
    description:
      Push current branch changes to origin and create or update the corresponding pull request.
    ---

    # Push

    ## Goals

    - Push the current branch safely.
    - Create a PR if none exists for the branch, otherwise update the existing PR.

    ## Steps

    1. Identify the current branch and confirm the working tree is ready to publish.
    #{validation_step}
    3. Push the branch to `origin`, using upstream tracking if needed.
    4. If the push is rejected because the branch is stale, use the `pull` skill and push again.
    5. Ensure a PR exists for the branch with `gh pr create` or update the existing PR with `gh pr edit`.
    #{pr_body_step}
    7. Reply with the PR URL after publish succeeds.
    """
  end

  defp land_skill(plan) do
    validation_step =
      case plan.validation_command do
        nil -> "2. Confirm the full local validation bar for the changed scope is green before merging."
        command -> "2. Confirm `#{command}` is green before merging."
      end

    """
    ---
    name: land
    description:
      Land a pull request by checking mergeability, resolving conflicts, waiting for checks, and squash-merging when green.
    ---

    # Land

    ## Goals

    - Ensure the PR is conflict-free with `main`.
    - Wait for required checks and review feedback.
    - Squash-merge only when the branch is ready.

    ## Steps

    1. Locate the PR for the current branch with `gh pr view`.
    #{validation_step}
    3. If conflicts exist, use the `pull` skill, resolve them, and republish the branch.
    4. Watch PR checks with `gh pr checks --watch`.
    5. If checks fail, inspect the failure, fix it, validate again, and push updates.
    6. When checks are green and review feedback is addressed, squash-merge the PR with `gh pr merge --squash`.
    """
  end
end
