defmodule SymphonyElixir.Bootstrap.TrackerProviders.GitHub do
  @moduledoc false

  @behaviour SymphonyElixir.Bootstrap.TrackerProvider

  @impl true
  def workflow_kind, do: "github"

  @impl true
  def display_name, do: "GitHub"

  @impl true
  def required_secret_name, do: "GITHUB_TOKEN"

  @impl true
  def project_slug_prompt, do: "GitHub repository (`owner/repo`)"

  @impl true
  def related_skill_name, do: "github"

  @impl true
  def related_skill_line(_plan) do
    "- `github`: use `gh issue` and `gh api` for workpad comments, workflow-state labels, and issue or PR links."
  end

  @impl true
  def workpad_label, do: "GitHub issue comment"

  @impl true
  def initial_status_expectations(%{
        human_review_polling?: human_review_polling?,
        human_review_state: human_review_state,
        rework_state: rework_state,
        merging_state: merging_state
      }) do
    []
    |> maybe_add(human_review_polling?, human_review_state)
    |> maybe_add(true, rework_state)
    |> maybe_add(not is_nil(merging_state), merging_state)
  end

  @impl true
  def related_skill_artifacts(plan) do
    [
      %{
        path: Path.join([plan.target_root, ".codex", "skills", "github", "SKILL.md"]),
        content: github_skill()
      }
    ]
  end

  defp maybe_add(list, true, state) when is_binary(state), do: list ++ [state]
  defp maybe_add(list, _include?, _state), do: list

  defp github_skill do
    """
    ---
    name: github
    description:
      Use `gh` and GitHub issue APIs for issue comments, workflow-state labels, and issue or PR linking when the repository uses GitHub as its tracker.
    ---

    # GitHub

    Use `gh` CLI for GitHub issue and pull-request workflows.

    ## Common operations

    - Read issue metadata with `gh issue view`.
    - Add issue comments with `gh issue comment`.
    - Update issue labels or state with `gh api repos/<owner>/<repo>/issues/<number>`.
    - Read or update pull requests with `gh pr view` and `gh pr edit`.
    """
  end
end
