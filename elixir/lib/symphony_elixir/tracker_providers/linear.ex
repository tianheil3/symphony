defmodule SymphonyElixir.TrackerProviders.Linear do
  @moduledoc false

  @behaviour SymphonyElixir.TrackerProvider

  @impl true
  def key, do: "linear"

  @impl true
  def adapter_module, do: SymphonyElixir.Linear.Adapter

  @impl true
  def default_endpoint, do: "https://api.linear.app/graphql"

  @impl true
  def api_key_env_var, do: "LINEAR_API_KEY"

  @impl true
  def assignee_env_var, do: "LINEAR_ASSIGNEE"

  @impl true
  def validate_config(tracker) when is_map(tracker) do
    cond do
      not is_binary(Map.get(tracker, :api_key) || Map.get(tracker, "api_key")) ->
        {:error, :missing_linear_api_token}

      not is_binary(Map.get(tracker, :project_slug) || Map.get(tracker, "project_slug")) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end
end
