defmodule SymphonyElixir.Installer.Inspector do
  @moduledoc false

  alias SymphonyElixir.Installer

  @default_gstack_repo_url "https://github.com/garrytan/gstack.git"
  @unsupported_target_message "GitHub ordinary repos only in v1"
  @legacy_tracker_providers %{
    "linear" => %{
      key: "linear",
      module: SymphonyElixir.Installer.TrackerProviders.Linear
    },
    "gitlab" => %{
      key: "gitlab",
      module: SymphonyElixir.Installer.TrackerProviders.GitLab
    }
  }

  @spec inspect_target!(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def inspect_target!(target_root, deps) when is_binary(target_root) and is_map(deps) do
    repo_name_default = Path.basename(target_root)
    remote_url = deps.detect_git_remote.(target_root)

    case unsupported_reason(remote_url) do
      nil ->
        tracker_provider_default_key = default_tracker_provider_key(remote_url)

        {:ok,
         %{
           target_root: target_root,
           repo_name_default: repo_name_default,
           remote_url: remote_url,
           tracker_provider_default_key: tracker_provider_default_key,
           tracker_provider: tracker_provider(tracker_provider_default_key),
           forge_provider: forge_provider("github"),
           workspace_root_default: default_workspace_root(repo_name_default),
           after_create_default: default_after_create_command(remote_url),
           gstack_repo_url_default: @default_gstack_repo_url
         }}

      unsupported_reason ->
        {:error, {:unsupported_target_repo, remote_url, unsupported_reason}}
    end
  end

  @spec tracker_provider_lookup(String.t()) :: {:ok, map()} | {:error, term()}
  def tracker_provider_lookup(key) when is_binary(key) do
    case Installer.Descriptors.tracker_provider(key) do
      {:ok, provider_module} ->
        {:ok, installer_tracker_provider(key, provider_module)}

      {:error, {:unsupported_tracker_provider, _unsupported_key}} ->
        case Map.fetch(@legacy_tracker_providers, key) do
          {:ok, provider} -> {:ok, provider}
          :error -> {:error, {:unsupported_tracker_provider, key}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_workspace_root(repo_name) do
    "~/" <> Path.join(["code", sanitized_repo_name(repo_name) <> "-workspaces"])
  end

  defp sanitized_repo_name(repo_name) when is_binary(repo_name) do
    repo_name
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      normalized -> normalized
    end
  end

  defp default_after_create_command(nil), do: "git clone --depth 1 <repo-url> ."
  defp default_after_create_command(remote_url), do: "git clone --depth 1 #{remote_url} ."

  defp default_tracker_provider_key(remote_url) when is_binary(remote_url) do
    case forge_key(remote_url) do
      "github" -> "linear"
      _ -> "linear"
    end
  end

  defp default_tracker_provider_key(_remote_url), do: "linear"

  defp unsupported_reason(remote_url) when is_binary(remote_url) do
    if forge_key(remote_url) == "github", do: nil, else: @unsupported_target_message
  end

  defp unsupported_reason(_remote_url), do: @unsupported_target_message

  defp tracker_provider(key) when is_binary(key) do
    case tracker_provider_lookup(key) do
      {:ok, provider} ->
        provider

      {:error, {:unsupported_tracker_provider, unsupported_key}} ->
        raise ArgumentError, "invalid_tracker_provider: #{unsupported_key}"
    end
  end

  defp installer_tracker_provider(key, provider_module) do
    %{
      key: key,
      module: provider_module
    }
  end

  defp forge_key(remote_url) when is_binary(remote_url) do
    normalized = String.downcase(String.trim(remote_url))
    if normalized != "" and String.contains?(normalized, "github.com"), do: "github", else: "none"
  end

  defp forge_provider(key) when is_binary(key) do
    {:ok, provider_module} = Installer.Descriptors.forge_provider(key)
    installer_forge_provider(key, provider_module)
  end

  defp installer_forge_provider(key, provider_module) do
    %{
      key: key,
      display_name: provider_module.display_name(),
      module: provider_module,
      supports_automated_pr_flow?: provider_module.supports_automated_pr_flow?(),
      automated_skill_names: provider_module.automated_skill_names()
    }
  end
end
