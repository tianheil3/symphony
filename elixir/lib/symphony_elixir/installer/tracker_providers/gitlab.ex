defmodule SymphonyElixir.Installer.TrackerProviders.GitLab do
  @moduledoc false

  @behaviour SymphonyElixir.Installer.TrackerProvider

  @impl true
  def key, do: "gitlab"

  @impl true
  def workflow_kind, do: "gitlab"

  @impl true
  def display_name, do: "GitLab"

  @impl true
  def required_secret_name, do: "GITLAB_API_TOKEN"

  @impl true
  def project_slug_prompt, do: "GitLab project path (`group/project`)"

  @impl true
  def related_skill_name, do: "gitlab"

  @impl true
  def related_skill_line(_plan) do
    "- `gitlab`: use `glab` issue and API operations for workpad comments, issue state moves, and issue links."
  end

  @impl true
  def workpad_label, do: "GitLab issue note"

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
        path: Path.join([plan.target_root, ".codex", "skills", "gitlab", "SKILL.md"]),
        content: gitlab_skill()
      }
    ]
  end

  defp maybe_add(list, true, state) when is_binary(state), do: list ++ [state]
  defp maybe_add(list, _include?, _state), do: list

  defp gitlab_skill do
    """
    ---
    name: gitlab
    description:
      Use `glab` and GitLab issue APIs for issue comments, state transitions, and issue/MR linking when the repository uses GitLab as its tracker or forge.
    ---

    # GitLab

    Use `glab` CLI for GitLab issue and merge-request workflows.

    ## Common operations

    - Read issue metadata with `glab issue view`.
    - Add issue notes with `glab api projects/:id/issues/:iid/notes`.
    - Update issue state or labels with `glab api projects/:id/issues/:iid`.
    - Read or update merge requests with `glab mr view` and `glab mr update`.
    """
  end
end
