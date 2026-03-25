defmodule SymphonyElixir.Installer.Descriptors do
  @moduledoc false

  @tracker_providers %{
    "github" => SymphonyElixir.Installer.TrackerProviders.GitHub
  }

  @forge_providers %{
    "github" => SymphonyElixir.Installer.ForgeProviders.GitHub,
    "none" => SymphonyElixir.Installer.ForgeProviders.Generic
  }

  @supported_v1_trackers Map.keys(@tracker_providers)
  @supported_v1_forges ["github", "none"]

  @spec tracker_provider(String.t() | nil) :: {:ok, module()} | {:error, term()}
  def tracker_provider(nil), do: {:error, :missing_tracker_provider}

  def tracker_provider(provider_key) when is_binary(provider_key) do
    normalized_key = normalize(provider_key)

    case Map.fetch(@tracker_providers, normalized_key) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:unsupported_tracker_provider, normalized_key}}
    end
  end

  def tracker_provider(_provider_key), do: {:error, :missing_tracker_provider}

  @spec forge_provider(String.t() | nil) :: {:ok, module()} | {:error, term()}
  def forge_provider(nil), do: {:error, :missing_forge_provider}

  def forge_provider(provider_key) when is_binary(provider_key) do
    normalized_key = normalize(provider_key)

    case Map.fetch(@forge_providers, normalized_key) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:unsupported_forge_provider, normalized_key}}
    end
  end

  def forge_provider(_provider_key), do: {:error, :missing_forge_provider}

  @spec supported_in_v1?(:tracker | :forge, String.t() | nil) :: :ok | {:error, term()}
  def supported_in_v1?(:tracker, provider_key) do
    normalized_key = normalize(provider_key)

    if normalized_key in @supported_v1_trackers do
      :ok
    else
      {:error, {:unsupported_tracker_provider, normalized_key}}
    end
  end

  def supported_in_v1?(:forge, provider_key) do
    normalized_key = normalize(provider_key)

    if normalized_key in @supported_v1_forges do
      :ok
    else
      {:error, {:unsupported_forge_provider, normalized_key}}
    end
  end

  def supported_in_v1?(provider_type, provider_key) do
    {:error, {:unsupported_provider_type, provider_type, normalize(provider_key)}}
  end

  @spec supported_v1_trackers() :: [String.t()]
  def supported_v1_trackers, do: @supported_v1_trackers

  @spec supported_v1_forges() :: [String.t()]
  def supported_v1_forges, do: @supported_v1_forges

  defp normalize(provider_key) when is_binary(provider_key) do
    provider_key
    |> String.trim()
    |> String.downcase()
  end

  defp normalize(provider_key), do: provider_key
end
