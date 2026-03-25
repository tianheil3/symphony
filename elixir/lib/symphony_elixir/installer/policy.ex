defmodule SymphonyElixir.Installer.Policy do
  @moduledoc false

  @type policy_value :: atom()
  @type machine_state_t :: %{
          installer_cache_dir: String.t(),
          version_cache_file: String.t()
        }
  @type matrix_t :: %{
          installer_binary: policy_value(),
          system_runtime: policy_value(),
          forge_cli: policy_value(),
          repo_assets: policy_value(),
          secrets: policy_value(),
          machine_state: machine_state_t()
        }

  @tooling_policy %{
    installer_binary: :auto_install,
    system_runtime: :prompt_before_act,
    forge_cli: :verify_only,
    repo_assets: :managed_repo_assets,
    secrets: :user_provided,
    machine_state: %{
      installer_cache_dir: "~/.cache/symphony",
      version_cache_file: "~/.cache/symphony/installer-version.json"
    }
  }

  @asset_classification %{
    installer_binary: :installer_tooling,
    system_runtime: :system_dependency,
    forge_cli: :forge_tooling,
    repo_assets: :repo_durable_asset,
    secrets: :user_secret,
    machine_state: :machine_local_state
  }

  @known_policy_values [
    :auto_install,
    :prompt_before_act,
    :verify_only,
    :managed_repo_assets,
    :user_provided
  ]

  @spec tooling_policy_matrix() :: matrix_t()
  def tooling_policy_matrix, do: @tooling_policy

  @spec machine_state() :: machine_state_t()
  def machine_state, do: @tooling_policy.machine_state

  @spec classify_asset(atom()) :: {:ok, atom()} | {:error, {:unknown_asset_type, atom()}}
  def classify_asset(asset_type) when is_atom(asset_type) do
    case Map.fetch(@asset_classification, asset_type) do
      {:ok, class} -> {:ok, class}
      :error -> {:error, {:unknown_asset_type, asset_type}}
    end
  end

  @spec parse_tooling_policy(map() | nil) :: {:ok, matrix_t()} | {:error, term()}
  def parse_tooling_policy(nil), do: {:ok, @tooling_policy}

  def parse_tooling_policy(policy) when is_map(policy) do
    with {:ok, installer_binary} <-
           parse_symbolic_value(policy, "installer_binary", :installer_binary, @tooling_policy.installer_binary),
         {:ok, system_runtime} <-
           parse_symbolic_value(policy, "system_runtime", :system_runtime, @tooling_policy.system_runtime),
         {:ok, forge_cli} <- parse_symbolic_value(policy, "forge_cli", :forge_cli, @tooling_policy.forge_cli),
         {:ok, repo_assets} <- parse_symbolic_value(policy, "repo_assets", :repo_assets, @tooling_policy.repo_assets),
         {:ok, secrets} <- parse_symbolic_value(policy, "secrets", :secrets, @tooling_policy.secrets),
         {:ok, machine_state} <- parse_machine_state_from_policy(policy) do
      {:ok,
       %{
         installer_binary: installer_binary,
         system_runtime: system_runtime,
         forge_cli: forge_cli,
         repo_assets: repo_assets,
         secrets: secrets,
         machine_state: machine_state
       }}
    end
  end

  def parse_tooling_policy(_policy), do: {:error, {:invalid_manifest, {:tooling_policy, :must_be_map}}}

  @spec parse_machine_state(map() | nil) :: {:ok, machine_state_t()} | {:error, term()}
  def parse_machine_state(nil), do: {:ok, machine_state()}

  def parse_machine_state(value) when is_map(value) do
    with {:ok, installer_cache_dir} <-
           parse_string_value(
             value,
             "installer_cache_dir",
             :installer_cache_dir,
             machine_state().installer_cache_dir
           ),
         {:ok, version_cache_file} <-
           parse_string_value(
             value,
             "version_cache_file",
             :version_cache_file,
             machine_state().version_cache_file
           ) do
      {:ok,
       %{
         installer_cache_dir: installer_cache_dir,
         version_cache_file: version_cache_file
       }}
    end
  end

  def parse_machine_state(_value), do: {:error, {:invalid_manifest, {:machine_state, :must_be_map}}}

  defp parse_symbolic_value(map, string_key, atom_key, default) do
    case map_value(map, string_key, atom_key) do
      nil ->
        {:ok, default}

      value when is_atom(value) ->
        parse_known_policy_value(value, atom_key)

      value when is_binary(value) ->
        parse_known_policy_string(value, atom_key)

      _other ->
        {:error, {:invalid_manifest, {atom_key, :must_be_string_or_atom}}}
    end
  end

  defp parse_string_value(map, string_key, atom_key, default) do
    case map_value(map, string_key, atom_key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        normalized = String.trim(value)

        if normalized == "" do
          {:error, {:invalid_manifest, {atom_key, :must_not_be_blank}}}
        else
          {:ok, normalized}
        end

      _other ->
        {:error, {:invalid_manifest, {atom_key, :must_be_string}}}
    end
  end

  defp parse_machine_state_from_policy(policy) do
    parse_machine_state(map_value(policy, "machine_state", :machine_state))
  end

  defp parse_known_policy_value(value, atom_key) do
    if value in @known_policy_values do
      {:ok, value}
    else
      {:error, {:invalid_manifest, {atom_key, :unknown_policy_value}}}
    end
  end

  defp parse_known_policy_string(value, atom_key) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    case normalized do
      "" ->
        {:error, {:invalid_manifest, {atom_key, :must_not_be_blank}}}

      _ ->
        normalized
        |> find_known_policy_value()
        |> maybe_known_policy_value(atom_key)
    end
  end

  defp find_known_policy_value(normalized) when is_binary(normalized) do
    Enum.find(@known_policy_values, &(Atom.to_string(&1) == normalized))
  end

  defp maybe_known_policy_value(nil, atom_key), do: {:error, {:invalid_manifest, {atom_key, :unknown_policy_value}}}
  defp maybe_known_policy_value(known_value, _atom_key), do: {:ok, known_value}

  defp map_value(map, string_key, atom_key) do
    cond do
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      true -> nil
    end
  end
end
