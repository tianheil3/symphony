defmodule SymphonyElixir.Installer.WorkflowProfile do
  @moduledoc false

  @default_todo_state "Todo"
  @default_in_progress_state "In Progress"
  @default_human_review_state "Human Review"
  @default_rework_state "Rework"
  @default_done_state "Done"
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", @default_done_state]

  @spec apply_defaults(map()) :: map()
  def apply_defaults(plan) when is_map(plan) do
    profile = normalize_profile(Map.get(plan, :workflow_profile))

    plan
    |> Map.put(:workflow_profile, profile)
    |> apply_profile_defaults(profile)
  end

  defp normalize_profile(nil), do: "custom"

  defp normalize_profile(profile) when is_binary(profile) do
    case String.downcase(String.trim(profile)) do
      "starter" -> "starter"
      "review-gated" -> "review-gated"
      "review_gated" -> "review-gated"
      "symphony-dev" -> "symphony-dev"
      "symphony_dev" -> "symphony-dev"
      _ -> "custom"
    end
  end

  defp normalize_profile(_profile), do: "custom"

  defp apply_profile_defaults(plan, "starter") do
    plan
    |> put_default(:active_states, [@default_todo_state, @default_in_progress_state])
    |> put_default(:terminal_states, @default_terminal_states)
    |> put_default(:agent_max_concurrent_agents, 1)
    |> put_default(:agent_max_turns, 10)
    |> put_default(:hosted_review_flow?, false)
    |> put_default(:human_review_polling?, false)
    |> put_default(:human_review_state, @default_human_review_state)
    |> put_default(:rework_state, @default_rework_state)
    |> put_default(:merging_state, nil)
    |> put_default(:done_state, @default_done_state)
  end

  defp apply_profile_defaults(plan, "review-gated") do
    plan
    |> put_default(:active_states, [
      @default_todo_state,
      @default_in_progress_state,
      @default_human_review_state,
      @default_rework_state
    ])
    |> put_default(:terminal_states, @default_terminal_states)
    |> put_default(:agent_max_concurrent_agents, 1)
    |> put_default(:agent_max_turns, 12)
    |> put_default(:hosted_review_flow?, false)
    |> put_default(:human_review_polling?, true)
    |> put_default(:human_review_state, @default_human_review_state)
    |> put_default(:rework_state, @default_rework_state)
    |> put_default(:merging_state, nil)
    |> put_default(:done_state, @default_done_state)
  end

  defp apply_profile_defaults(plan, "symphony-dev") do
    plan
    |> put_default(:terminal_states, @default_terminal_states)
    |> put_default(:agent_max_concurrent_agents, 5)
    |> put_default(:agent_max_turns, 20)
    |> put_default(:human_review_state, @default_human_review_state)
    |> put_default(:rework_state, @default_rework_state)
    |> put_default(:done_state, @default_done_state)
  end

  defp apply_profile_defaults(plan, _profile) do
    plan
    |> put_default(:agent_max_concurrent_agents, 5)
    |> put_default(:agent_max_turns, 20)
  end

  defp put_default(plan, key, value) do
    case Map.fetch(plan, key) do
      {:ok, nil} -> Map.put(plan, key, value)
      {:ok, _existing} -> plan
      :error -> Map.put(plan, key, value)
    end
  end
end
