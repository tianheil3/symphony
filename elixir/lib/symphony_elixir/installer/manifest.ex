defmodule SymphonyElixir.Installer.Manifest do
  @moduledoc false

  alias SymphonyElixir.Installer.Policy
  alias SymphonyElixir.Installer.SessionState

  @current_schema_version 1

  @type t :: %{
          schema_version: pos_integer(),
          installer_version_range: String.t() | nil,
          capabilities: [String.t()],
          target_repo: String.t(),
          tooling_policy: Policy.matrix_t(),
          durable_assets: map(),
          ephemeral_state_dir: String.t(),
          machine_state: Policy.machine_state_t(),
          tracker: map(),
          forge: map()
        }

  @spec current_schema_version() :: pos_integer()
  def current_schema_version, do: @current_schema_version

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(manifest) when is_map(manifest) do
    with {:ok, schema_version} <- parse_schema_version(manifest),
         {:ok, installer_version_range} <- parse_installer_version_range(manifest),
         {:ok, capabilities} <- parse_capabilities(manifest),
         {:ok, target_repo} <- parse_non_empty_string(manifest, "target_repo", :target_repo, :required),
         {:ok, tooling_policy} <- parse_tooling_policy(manifest),
         {:ok, durable_assets} <- parse_optional_map(manifest, "durable_assets", :durable_assets, %{}),
         {:ok, ephemeral_state_dir} <- parse_ephemeral_state_dir(manifest),
         {:ok, tracker} <- parse_optional_map(manifest, "tracker", :tracker, %{}),
         {:ok, forge} <- parse_optional_map(manifest, "forge", :forge, %{}),
         {:ok, machine_state} <- parse_machine_state(manifest, tooling_policy),
         :ok <- ensure_machine_state_outside_ephemeral(machine_state, target_repo, ephemeral_state_dir) do
      {:ok,
       %{
         schema_version: schema_version,
         installer_version_range: installer_version_range,
         capabilities: capabilities,
         target_repo: target_repo,
         tooling_policy: tooling_policy,
         durable_assets: durable_assets,
         ephemeral_state_dir: ephemeral_state_dir,
         machine_state: machine_state,
         tracker: tracker,
         forge: forge
       }}
    end
  end

  def parse(_manifest), do: {:error, {:invalid_manifest, :not_a_map}}

  @spec ensure_compatible!(t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def ensure_compatible!(manifest, installer_version, required_capabilities)
      when is_map(manifest) and is_binary(installer_version) and is_list(required_capabilities) do
    :ok
    |> continue_if_ok(fn -> ensure_schema_compatible(manifest) end)
    |> continue_if_ok(fn -> ensure_installer_version(manifest, installer_version) end)
    |> continue_if_ok(fn -> ensure_capabilities(manifest, required_capabilities) end)
  end

  def ensure_compatible!(_manifest, _installer_version, _required_capabilities),
    do: {:error, {:invalid_manifest, :invalid_compatibility_input}}

  defp parse_schema_version(manifest) do
    case map_value(manifest, "schema_version", :schema_version) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      nil ->
        {:error, {:invalid_manifest, {:schema_version, :required}}}

      _ ->
        {:error, {:invalid_manifest, {:schema_version, :must_be_positive_integer}}}
    end
  end

  defp parse_installer_version_range(manifest) do
    case map_value(manifest, "installer_version_range", :installer_version_range) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        parse_installer_version_range_value(value)

      _ ->
        {:error, {:invalid_manifest, {:installer_version_range, :must_be_string}}}
    end
  end

  defp parse_installer_version_range_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      normalized -> parse_installer_requirement_value(normalized)
    end
  end

  defp parse_installer_requirement_value(normalized) when is_binary(normalized) do
    case Version.parse_requirement(normalized) do
      {:ok, _requirement} -> {:ok, normalized}
      :error -> {:error, {:invalid_manifest, {:installer_version_range, normalized}}}
    end
  end

  defp parse_capabilities(manifest) do
    case map_value(manifest, "capabilities", :capabilities) do
      values when is_list(values) ->
        normalize_capability_list(values)

      nil ->
        {:error, {:invalid_manifest, {:capabilities, :required}}}

      _ ->
        {:error, {:invalid_manifest, {:capabilities, :must_be_list_of_strings}}}
    end
  end

  defp parse_non_empty_string(manifest, string_key, atom_key, default) do
    case map_value(manifest, string_key, atom_key) do
      nil when default == :required ->
        {:error, {:invalid_manifest, {atom_key, :required}}}

      nil ->
        {:ok, default}

      value when is_binary(value) ->
        normalized = String.trim(value)

        if normalized == "" do
          {:error, {:invalid_manifest, {atom_key, :must_not_be_blank}}}
        else
          {:ok, normalized}
        end

      _ ->
        {:error, {:invalid_manifest, {atom_key, :must_be_string}}}
    end
  end

  defp parse_optional_map(manifest, string_key, atom_key, default) do
    case map_value(manifest, string_key, atom_key) do
      nil -> {:ok, default}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_manifest, {atom_key, :must_be_map}}}
    end
  end

  defp parse_ephemeral_state_dir(manifest) do
    default = SessionState.relative_dir()

    case map_value(manifest, "ephemeral_state_dir", :ephemeral_state_dir) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        normalized = String.trim(value)

        cond do
          normalized == "" ->
            {:error, {:invalid_manifest, {:ephemeral_state_dir, :must_not_be_blank}}}

          normalized == default ->
            {:ok, default}

          true ->
            {:error, {:invalid_manifest, {:ephemeral_state_dir, :unsupported_in_v1}}}
        end

      _ ->
        {:error, {:invalid_manifest, {:ephemeral_state_dir, :must_be_string}}}
    end
  end

  defp parse_tooling_policy(manifest) do
    manifest
    |> map_value("tooling_policy", :tooling_policy)
    |> Policy.parse_tooling_policy()
  end

  defp parse_machine_state(manifest, tooling_policy) do
    case map_value(manifest, "machine_state", :machine_state) do
      nil ->
        {:ok, tooling_policy.machine_state}

      state ->
        Policy.parse_machine_state(state)
    end
  end

  defp normalize_capability_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case normalize_capability(value) do
        {:ok, normalized} ->
          {:cont, {:ok, [normalized | acc]}}

        :error ->
          {:halt, {:error, {:invalid_manifest, {:capabilities, {:invalid_entry, index}}}}}
      end
    end)
    |> case do
      {:ok, normalized_reversed} ->
        normalized_reversed
        |> Enum.reverse()
        |> Enum.uniq()
        |> then(&{:ok, &1})

      error ->
        error
    end
  end

  defp normalize_capability(value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: :error, else: {:ok, normalized}
  end

  defp normalize_capability(_value), do: :error

  defp ensure_schema_compatible(%{schema_version: schema_version}) when schema_version == @current_schema_version,
    do: :ok

  defp ensure_schema_compatible(%{schema_version: schema_version}) when is_integer(schema_version) do
    {:error, {:unsupported_manifest_schema, schema_version, @current_schema_version}}
  end

  defp ensure_schema_compatible(_manifest), do: {:error, {:invalid_manifest, :missing_schema_version}}

  defp ensure_installer_version(%{installer_version_range: nil}, installer_version) do
    case Version.parse(installer_version) do
      {:ok, _version} -> :ok
      :error -> {:error, {:invalid_installer_version, installer_version}}
    end
  end

  defp ensure_installer_version(%{installer_version_range: requirement}, installer_version)
       when is_binary(requirement) do
    with {:ok, _parsed_version} <- parse_installer_version(installer_version),
         {:ok, parsed_requirement} <- parse_requirement(requirement) do
      if Version.match?(installer_version, parsed_requirement) do
        :ok
      else
        {:error, {:installer_upgrade_required, installer_version, requirement}}
      end
    end
  end

  defp ensure_installer_version(_manifest, installer_version), do: parse_installer_version(installer_version)

  defp parse_installer_version(installer_version) do
    case Version.parse(installer_version) do
      {:ok, _parsed} -> {:ok, installer_version}
      :error -> {:error, {:invalid_installer_version, installer_version}}
    end
  end

  defp parse_requirement(requirement) do
    case Version.parse_requirement(requirement) do
      {:ok, parsed_requirement} -> {:ok, parsed_requirement}
      :error -> {:error, {:invalid_manifest, {:installer_version_range, requirement}}}
    end
  end

  defp ensure_capabilities(manifest, required_capabilities) do
    with {:ok, manifest_capabilities} <- parse_manifest_capabilities(manifest),
         {:ok, required} <- normalize_capability_list(required_capabilities) do
      missing =
        required
        |> Enum.reject(&(&1 in manifest_capabilities))
        |> Enum.sort()

      if missing == [] do
        :ok
      else
        {:error, {:missing_manifest_capabilities, missing}}
      end
    end
  end

  defp parse_manifest_capabilities(%{capabilities: capabilities}) when is_list(capabilities),
    do: normalize_capability_list(capabilities)

  defp parse_manifest_capabilities(_manifest),
    do: {:error, {:invalid_manifest, :missing_capabilities}}

  defp ensure_machine_state_outside_ephemeral(machine_state, target_repo, ephemeral_state_dir) do
    ephemeral_root = Path.expand(ephemeral_state_dir, target_repo)

    machine_state_paths = [
      machine_state.installer_cache_dir,
      machine_state.version_cache_file
    ]

    if Enum.any?(machine_state_paths, &path_inside_ephemeral?(&1, target_repo, ephemeral_root)) do
      {:error, {:invalid_manifest, {:machine_state, :must_be_outside_ephemeral_state_dir}}}
    else
      :ok
    end
  end

  defp path_inside_ephemeral?(path, target_repo, ephemeral_root) do
    expanded_path =
      case path do
        "~" <> _rest -> Path.expand(path)
        _ -> Path.expand(path, target_repo)
      end

    expanded_path == ephemeral_root or String.starts_with?(expanded_path, ephemeral_root <> "/")
  end

  defp map_value(map, string_key, atom_key) do
    cond do
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      true -> nil
    end
  end

  defp continue_if_ok(:ok, next_fun) when is_function(next_fun, 0), do: next_fun.()
  defp continue_if_ok(error, _next_fun), do: error
end
