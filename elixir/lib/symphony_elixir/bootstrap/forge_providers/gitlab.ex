defmodule SymphonyElixir.Bootstrap.ForgeProviders.GitLab do
  @moduledoc false

  @behaviour SymphonyElixir.Bootstrap.ForgeProvider

  @impl true
  def automation_prompt(_provider), do: "Install GitLab MR workflow skills (`push` / `land`)?"

  @impl true
  def automated_skill_names, do: ["push", "land"]

  @impl true
  def related_skill_lines(%{merging_state: merging_state}) do
    [
      "- `push`: publish the current branch and create or update the merge request.",
      "- `land`: merge the MR safely when the ticket reaches `#{merging_state}`."
    ]
  end

  @impl true
  def status_lines(%{merging_state: merging_state, done_state: done_state}) do
    [
      "- `#{merging_state}` -> use the `land` skill to merge the MR, then move the issue to `#{done_state}`."
    ]
  end

  @impl true
  def execution_flow_lines(%{human_review_state: human_review_state, merging_state: merging_state}) do
    [
      "6. When an MR exists, attach or update the MR URL on the tracker issue and sweep all new merge-request feedback before returning to `#{human_review_state}`.",
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
    "- Publish / docs refresh: use `gstack /ship` for MR/release flow and `gstack /document-release` after behavior or process docs change."
  end

  @impl true
  def pr_template_supported?(_plan), do: false

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

    """
    ---
    name: push
    description:
      Push current branch changes to origin and create or update the corresponding GitLab merge request.
    ---

    # Push

    ## Prerequisites

    - `glab` CLI is installed and available in `PATH`.
    - `glab auth status` succeeds for GitLab operations in this repo.

    ## Goals

    - Push the current branch safely.
    - Create an MR if none exists for the branch, otherwise update the existing MR.

    ## Steps

    1. Identify the current branch and confirm the working tree is ready to publish.
    #{validation_step}
    3. Push the branch to `origin`, using upstream tracking if needed.
    4. If the push is rejected because the branch is stale, use the `pull` skill and push again.
    5. Ensure an MR exists for the branch with `glab mr create` or update the existing MR with `glab mr update`.
    6. Write a concise MR description that covers context, summary, acceptance criteria, and test plan.
    7. Reply with the MR URL after publish succeeds.
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
      Land a GitLab merge request by checking mergeability, resolving conflicts, waiting for pipelines, and merging when green.
    ---

    # Land

    ## Goals

    - Ensure the MR is conflict-free with the target branch.
    - Wait for required pipelines and review feedback.
    - Merge only when the branch is ready.

    ## Steps

    1. Locate the MR for the current branch with `glab mr view`.
    #{validation_step}
    3. If conflicts exist, use the `pull` skill, resolve them, and republish the branch.
    4. Watch MR pipelines and review status with `glab mr view`.
    5. If pipelines fail, inspect the failure, fix it, validate again, and push updates.
    6. When pipelines are green and review feedback is addressed, merge the MR with `glab mr merge`.
    """
  end
end
