defmodule SymphonyElixir.TrackerProviders.GitLab do
  @moduledoc false

  @behaviour SymphonyElixir.TrackerProvider

  @impl true
  def key, do: "gitlab"

  @impl true
  def adapter_module, do: SymphonyElixir.GitLab.Adapter

  @impl true
  def default_endpoint, do: "https://gitlab.com/api/v4"

  @impl true
  def api_key_env_var, do: "GITLAB_API_TOKEN"

  @impl true
  def assignee_env_var, do: "GITLAB_ASSIGNEE"

  @impl true
  def validate_config(tracker) when is_map(tracker) do
    cond do
      not is_binary(Map.get(tracker, :api_key) || Map.get(tracker, "api_key")) ->
        {:error, :missing_gitlab_api_token}

      not is_binary(Map.get(tracker, :project_slug) || Map.get(tracker, "project_slug")) ->
        {:error, :missing_gitlab_project_slug}

      true ->
        :ok
    end
  end
end
