defmodule SymphonyElixir.TrackerProviders do
  @moduledoc false

  @providers %{
    "linear" => SymphonyElixir.TrackerProviders.Linear,
    "gitlab" => SymphonyElixir.TrackerProviders.GitLab,
    "memory" => SymphonyElixir.TrackerProviders.Memory
  }

  @spec provider(String.t() | nil) :: {:ok, module()} | {:error, term()}
  def provider(nil), do: {:error, :missing_tracker_kind}

  def provider(kind) when is_binary(kind) do
    case Map.fetch(@providers, kind) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  def provider(_kind), do: {:error, :missing_tracker_kind}

  @spec provider_module!(String.t() | nil) :: module()
  def provider_module!(kind) do
    case provider(kind) do
      {:ok, provider} -> provider
      {:error, reason} -> raise ArgumentError, "invalid_tracker_provider: #{inspect(reason)}"
    end
  end

  @spec supported_kinds() :: [String.t()]
  def supported_kinds, do: Map.keys(@providers)
end
