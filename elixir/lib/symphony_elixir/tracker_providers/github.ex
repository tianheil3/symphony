defmodule SymphonyElixir.TrackerProviders.GitHub do
  @moduledoc false

  @behaviour SymphonyElixir.TrackerProvider

  @impl true
  def key, do: "github"

  @impl true
  def adapter_module, do: SymphonyElixir.GitHub.Adapter

  @impl true
  def default_endpoint, do: "https://api.github.com"

  @impl true
  def api_key_env_var, do: "GITHUB_TOKEN"

  @impl true
  def assignee_env_var, do: "GITHUB_ASSIGNEE"

  @impl true
  def validate_config(tracker) when is_map(tracker) do
    cond do
      not is_binary(Map.get(tracker, :api_key) || Map.get(tracker, "api_key")) ->
        {:error, :missing_github_api_token}

      not is_binary(Map.get(tracker, :project_slug) || Map.get(tracker, "project_slug")) ->
        {:error, :missing_github_project_slug}

      true ->
        :ok
    end
  end
end
