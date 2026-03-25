defmodule SymphonyElixir.Installer.LaunchVerifier do
  @moduledoc false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_health_check_attempts 5
  @default_health_check_interval_ms 200

  @type deps :: %{
          resolve_tool: (String.t() -> String.t() | nil),
          get_env: (String.t() -> String.t() | nil),
          parse_generated_assets: ([map()] -> :ok | {:error, term()}),
          launch_command: ([String.t()] -> {:ok, term()} | {:error, term()}),
          process_running?: (term() -> boolean()),
          probe_health_surface: (String.t() -> :ok | {:error, term()}),
          sleep: (non_neg_integer() -> term())
        }

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      resolve_tool: &System.find_executable/1,
      get_env: &System.get_env/1,
      parse_generated_assets: &parse_generated_assets_runtime/1,
      launch_command: &launch_command_runtime/1,
      process_running?: &process_running_runtime?/1,
      probe_health_surface: &probe_health_surface_runtime/1,
      sleep: &:timer.sleep/1
    }
  end

  @spec verify(map(), deps()) :: {:ok, %{status: :verified}} | {:error, term()}
  def verify(config, deps \\ runtime_deps())

  @spec verify(map(), deps()) :: {:ok, %{status: :verified}} | {:error, term()}
  def verify(config, deps) when is_map(config) and is_map(deps) do
    with :ok <- validate_config(config),
         :ok <- verify_required_tools(config, deps),
         :ok <- verify_required_env(config, deps),
         :ok <- verify_generated_assets(config, deps),
         {:ok, _launch_handle} <- verify_launch_command(config, deps),
         :ok <- verify_health_surface(config, deps) do
      {:ok, %{status: :verified}}
    end
  end

  def verify(_config, _deps), do: {:error, {:launch_blocked, :invalid_config, :expected_map}}

  defp validate_config(config) do
    [
      fn -> validate_optional_string_list(config, :required_tools) end,
      fn -> validate_optional_string_list(config, :required_env) end,
      fn -> validate_optional_list(config, :generated_assets) end,
      fn -> validate_optional_command(config, :command) end,
      fn -> validate_optional_non_empty_string(config, :dashboard_url) end,
      fn -> validate_optional_positive_integer(config, :health_check_attempts) end,
      fn -> validate_optional_positive_integer(config, :health_check_interval_ms) end
    ]
    |> Enum.reduce_while(:ok, fn validator, :ok ->
      case validator.() do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_optional_string_list(config, key) when is_map(config) and is_atom(key) do
    case Map.fetch(config, key) do
      :error ->
        :ok

      {:ok, value} when is_list(value) ->
        validate_string_list(value, key)

      {:ok, _value} ->
        {:error, {:launch_blocked, :invalid_config, {key, :must_be_list_of_strings}}}
    end
  end

  defp validate_optional_list(config, key) when is_map(config) and is_atom(key) do
    case Map.fetch(config, key) do
      :error -> :ok
      {:ok, value} when is_list(value) -> :ok
      {:ok, _value} -> {:error, {:launch_blocked, :invalid_config, {key, :must_be_list}}}
    end
  end

  defp validate_optional_command(config, key) when is_map(config) and is_atom(key) do
    case Map.fetch(config, key) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, value} when is_list(value) ->
        validate_non_empty_string_list(value, key)

      {:ok, _value} ->
        {:error, {:launch_blocked, :invalid_config, {key, :must_be_non_empty_list_of_strings}}}
    end
  end

  defp validate_optional_non_empty_string(config, key) when is_map(config) and is_atom(key) do
    case Map.fetch(config, key) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {:launch_blocked, :invalid_config, {key, :must_be_non_empty_string}}}
        else
          :ok
        end

      {:ok, _value} ->
        {:error, {:launch_blocked, :invalid_config, {key, :must_be_non_empty_string}}}
    end
  end

  defp validate_optional_positive_integer(config, key) when is_map(config) and is_atom(key) do
    case Map.fetch(config, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      {:ok, _value} -> {:error, {:launch_blocked, :invalid_config, {key, :must_be_positive_integer}}}
    end
  end

  defp verify_required_tools(config, deps) do
    config
    |> Map.get(:required_tools, [])
    |> Enum.reduce_while(:ok, fn tool, :ok ->
      case deps.resolve_tool.(tool) do
        path when is_binary(path) and path != "" -> {:cont, :ok}
        _ -> {:halt, {:error, {:launch_blocked, :missing_tool, tool}}}
      end
    end)
  end

  defp verify_required_env(config, deps) do
    config
    |> Map.get(:required_env, [])
    |> Enum.reduce_while(:ok, fn env_name, :ok ->
      case deps.get_env.(env_name) do
        value when is_binary(value) ->
          verify_required_env_value(value, env_name)

        _ ->
          {:halt, {:error, {:launch_blocked, :missing_token, env_name}}}
      end
    end)
  end

  defp validate_string_list(values, key) when is_list(values) and is_atom(key) do
    if Enum.all?(values, &non_empty_string?/1) do
      :ok
    else
      {:error, {:launch_blocked, :invalid_config, {key, :must_be_list_of_strings}}}
    end
  end

  defp validate_non_empty_string_list([], key) when is_atom(key) do
    {:error, {:launch_blocked, :invalid_config, {key, :must_be_non_empty_list_of_strings}}}
  end

  defp validate_non_empty_string_list(values, key) when is_list(values) and is_atom(key) do
    if Enum.all?(values, &non_empty_string?/1) do
      :ok
    else
      {:error, {:launch_blocked, :invalid_config, {key, :must_be_non_empty_list_of_strings}}}
    end
  end

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp verify_required_env_value(value, env_name) when is_binary(value) do
    if String.trim(value) == "" do
      {:halt, {:error, {:launch_blocked, :missing_token, env_name}}}
    else
      {:cont, :ok}
    end
  end

  defp verify_generated_assets(config, deps) do
    generated_assets = Map.get(config, :generated_assets, [])

    case deps.parse_generated_assets.(generated_assets) do
      :ok -> :ok
      {:error, reason} -> {:error, {:launch_blocked, :generated_assets_invalid, reason}}
    end
  end

  defp verify_launch_command(config, deps) do
    case Map.get(config, :command) do
      command when is_list(command) and command != [] ->
        with {:ok, handle} <- deps.launch_command.(command),
             true <- deps.process_running?.(handle) do
          {:ok, handle}
        else
          {:error, reason} -> {:error, {:launch_blocked, :launch_failed, reason}}
          false -> {:error, {:launch_blocked, :launch_not_running, command}}
        end

      nil ->
        {:ok, nil}

      _invalid_command ->
        {:error, {:launch_blocked, :invalid_launch_command, :must_be_non_empty_list}}
    end
  end

  defp verify_health_surface(config, deps) do
    case Map.get(config, :dashboard_url) do
      nil ->
        :ok

      url when is_binary(url) ->
        attempts = normalize_positive_int(Map.get(config, :health_check_attempts), @default_health_check_attempts)
        interval_ms = normalize_positive_int(Map.get(config, :health_check_interval_ms), @default_health_check_interval_ms)
        probe_health_surface(url, attempts, interval_ms, deps)

      _ ->
        {:error, {:launch_blocked, :invalid_dashboard_url, :must_be_string}}
    end
  end

  defp probe_health_surface(url, attempts, interval_ms, deps) do
    Enum.reduce_while(1..attempts, nil, fn attempt, _last_result ->
      case deps.probe_health_surface.(url) do
        :ok ->
          {:halt, :ok}

        {:error, reason} when attempt < attempts ->
          _ = deps.sleep.(interval_ms)
          {:cont, reason}

        {:error, _reason} ->
          {:halt, {:error, {:launch_blocked, :health_unreachable, url}}}
      end
    end)
  end

  defp normalize_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_int(_value, default), do: default

  defp parse_generated_assets_runtime(generated_assets) when is_list(generated_assets) do
    Enum.reduce_while(generated_assets, :ok, fn asset, :ok ->
      case parse_generated_asset(asset) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_generated_assets_runtime(_generated_assets), do: {:error, :generated_assets_must_be_list}

  defp parse_generated_asset(%{path: path, kind: kind}) when is_binary(path) do
    case kind do
      :workflow -> validate_workflow_asset(path)
      "workflow" -> validate_workflow_asset(path)
      _ -> validate_existing_asset(path)
    end
  end

  defp parse_generated_asset(%{"path" => path, "kind" => kind}) when is_binary(path) do
    parse_generated_asset(%{path: path, kind: kind})
  end

  defp parse_generated_asset(_asset), do: {:error, :invalid_generated_asset_entry}

  defp validate_existing_asset(path) when is_binary(path) do
    if File.regular?(path) do
      :ok
    else
      {:error, {:generated_asset_missing, path}}
    end
  end

  defp validate_workflow_asset(path) when is_binary(path) do
    with {:ok, %{config: config}} <- Workflow.load(path),
         {:ok, _parsed_config} <- Schema.parse(config) do
      :ok
    else
      {:error, reason} -> {:error, {:workflow_asset_invalid, path, reason}}
    end
  end

  defp launch_command_runtime([program | args]) do
    executable = System.find_executable(program) || program

    case File.exists?(executable) or Path.type(program) != :absolute do
      true ->
        port =
          Port.open(
            {:spawn_executable, executable},
            [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
          )

        {:ok, port}

      false ->
        {:error, {:command_not_found, program}}
    end
  rescue
    ArgumentError ->
      {:error, {:command_not_found, program}}
  end

  defp launch_command_runtime(_command), do: {:error, :invalid_launch_command}

  defp process_running_runtime?(pid) when is_pid(pid), do: Process.alive?(pid)

  defp process_running_runtime?(port) when is_port(port) do
    case Port.info(port) do
      nil -> false
      _info -> true
    end
  end

  defp process_running_runtime?(_handle), do: false

  defp probe_health_surface_runtime(url) when is_binary(url) do
    case Req.get(url: url, retry: false, receive_timeout: 1_000, connect_options: [timeout: 1_000]) do
      {:ok, %Req.Response{status: status}} when status >= 200 and status < 300 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
