defmodule SymphonyElixir.Installer.TrackerProviders.Linear do
  @moduledoc false

  @behaviour SymphonyElixir.Installer.TrackerProvider

  @impl true
  def key, do: "linear"

  @impl true
  def workflow_kind, do: "linear"

  @impl true
  def display_name, do: "Linear"

  @impl true
  def required_secret_name, do: "LINEAR_API_KEY"

  @impl true
  def project_slug_prompt, do: "Linear project slug"

  @impl true
  def related_skill_name, do: "linear"

  @impl true
  def related_skill_line(_plan) do
    "- `linear`: use Linear GraphQL operations for workpad comments, status moves, and attachments."
  end

  @impl true
  def workpad_label, do: "Linear comment"

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
        path: Path.join([plan.target_root, ".codex", "skills", "linear", "SKILL.md"]),
        content: linear_skill()
      }
    ]
  end

  defp maybe_add(list, true, state) when is_binary(state), do: list ++ [state]
  defp maybe_add(list, _include?, _state), do: list

  defp linear_skill do
    """
    ---
    name: linear
    description:
      Use Symphony's `linear_graphql` client tool for raw Linear GraphQL operations such as comment editing and issue state changes.
    ---

    # Linear GraphQL

    Use the `linear_graphql` dynamic tool exposed by Symphony app-server sessions.

    Tool input:

    ```json
    {
      "query": "query or mutation document",
      "variables": {
        "optional": "graphql variables object"
      }
    }
    ```

    ## Common operations

    - Query an issue by `id` or identifier.
    - Create or update the persistent `## Codex Workpad` comment with `commentCreate` / `commentUpdate`.
    - Move an issue between workflow states with `issueUpdate`.
    - Attach a hosted review URL to the issue when one exists.
    """
  end
end
