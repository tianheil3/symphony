defmodule SymphonyElixir.Installer.Apply do
  @moduledoc false

  alias SymphonyElixir.Installer.LaunchVerifier
  alias SymphonyElixir.Installer.SessionState

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(manifest, opts \\ [])

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(%{target_repo: target_repo} = manifest, opts) when is_binary(target_repo) and is_list(opts) do
    with :ok <- ensure_target_repo(target_repo),
         :ok <- maybe_record_resume(target_repo),
         :ok <- SessionState.write_request(target_repo, manifest_to_request(manifest)),
         :ok <- SessionState.write_state(target_repo, %{"phase" => "apply_started"}),
         {:ok, written_paths} <- write_durable_assets(manifest),
         {:ok, %{status: :verified}} <- verify_launch(manifest, written_paths, opts),
         :ok <- SessionState.write_state(target_repo, %{"phase" => "verified"}),
         :ok <- SessionState.append_log(target_repo, %{"event" => "launch_verified"}) do
      :ok
    else
      {:error, reason} = error ->
        _ = SessionState.write_state(target_repo, %{"phase" => "failed", "reason" => inspect(reason)})
        _ = SessionState.append_log(target_repo, %{"event" => "launch_blocked", "reason" => inspect(reason)})
        error
    end
  end

  def run(_manifest, _opts), do: {:error, {:invalid_manifest, :target_repo_required}}

  defp maybe_record_resume(target_repo) when is_binary(target_repo) do
    case SessionState.load(target_repo) do
      {:ok, %{"phase" => prior_phase}} when prior_phase in ["apply_started", "failed"] ->
        case SessionState.write_state(target_repo, %{"phase" => "resuming", "from_phase" => prior_phase}) do
          :ok ->
            SessionState.append_log(target_repo, %{"event" => "resume_detected", "from_phase" => prior_phase})

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _state_or_nil} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_target_repo(target_repo) when is_binary(target_repo) do
    expanded_target_repo = Path.expand(target_repo)

    if File.dir?(expanded_target_repo) do
      :ok
    else
      {:error, {:target_repo_missing, expanded_target_repo}}
    end
  end

  defp manifest_to_request(manifest) when is_map(manifest) do
    manifest
    |> Map.new(fn {key, value} -> {to_string(key), normalize_request_value(value)} end)
  end

  defp normalize_request_value(value) when is_map(value) do
    value
    |> Map.new(fn {key, nested_value} -> {to_string(key), normalize_request_value(nested_value)} end)
  end

  defp normalize_request_value(value) when is_list(value), do: Enum.map(value, &normalize_request_value/1)
  defp normalize_request_value(value), do: value

  defp write_durable_assets(%{target_repo: target_repo, durable_assets: durable_assets}) do
    with {:ok, files} <- durable_asset_files(durable_assets),
         {:ok, reversed_paths} <- write_durable_asset_files(target_repo, files) do
      {:ok, Enum.reverse(reversed_paths)}
    end
  end

  defp write_durable_assets(%{target_repo: _target_repo}), do: {:ok, []}

  defp write_durable_asset_files(target_repo, files) when is_list(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc_paths} ->
      append_written_asset_path(target_repo, file, acc_paths)
    end)
  end

  defp append_written_asset_path(target_repo, {relative_path, content}, acc_paths) do
    case write_durable_asset(target_repo, relative_path, content) do
      {:ok, written_path} -> {:cont, {:ok, [written_path | acc_paths]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp durable_asset_files(durable_assets) when is_map(durable_assets) do
    unsupported_keys =
      durable_assets
      |> Map.keys()
      |> Enum.reject(&(&1 in ["files", :files]))

    files_key_count =
      Enum.count(
        [Map.has_key?(durable_assets, "files"), Map.has_key?(durable_assets, :files)],
        & &1
      )

    cond do
      unsupported_keys != [] ->
        {:error, {:invalid_durable_assets, {:unknown_keys, unsupported_keys}}}

      files_key_count > 1 ->
        {:error, {:invalid_durable_assets, {:files, :ambiguous_keys}}}

      map_size(durable_assets) == 0 ->
        {:ok, []}

      true ->
        files_value = Map.get(durable_assets, "files", Map.get(durable_assets, :files))
        normalize_durable_asset_files(files_value)
    end
  end

  defp durable_asset_files(_durable_assets), do: {:error, {:invalid_durable_assets, :must_be_map}}

  defp normalize_durable_asset_files(files) when is_map(files) do
    files
    |> Enum.reduce_while({:ok, []}, fn {path, content}, {:ok, acc} ->
      case normalize_durable_asset_file(path, content) do
        {:ok, normalized_entry} ->
          {:cont, {:ok, [normalized_entry | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized_entries} ->
        {:ok, Enum.reverse(normalized_entries)}

      {:error, reason} ->
        {:error, {:invalid_durable_assets, reason}}
    end
  end

  defp normalize_durable_asset_files(_files), do: {:error, {:invalid_durable_assets, {:files, :must_be_map}}}

  defp normalize_durable_asset_file(path, content) when is_binary(path) do
    normalized_path = String.trim(path)

    if normalized_path == "" do
      {:error, {:file_path, :must_not_be_blank}}
    else
      {:ok, {normalized_path, content}}
    end
  end

  defp normalize_durable_asset_file(_path, _content), do: {:error, {:file_path, :must_be_string}}

  defp write_durable_asset(target_repo, relative_path, content) when is_binary(relative_path) do
    expanded_repo = Path.expand(target_repo)

    expanded_path =
      relative_path
      |> String.trim()
      |> resolve_asset_path(expanded_repo)

    encoded_content =
      try do
        {:ok, IO.iodata_to_binary(content)}
      rescue
        ArgumentError -> {:error, :invalid_content}
      end

    with {:ok, binary_content} <- encoded_content,
         :ok <- ensure_path_within_repo(expanded_repo, expanded_path, relative_path),
         :ok <- File.mkdir_p(Path.dirname(expanded_path)),
         :ok <- File.write(expanded_path, binary_content) do
      {:ok, expanded_path}
    else
      {:error, reason} -> {:error, {:durable_asset_write_failed, relative_path, reason}}
    end
  end

  defp resolve_asset_path(path, expanded_repo) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _ -> Path.expand(Path.join(expanded_repo, path))
    end
  end

  defp ensure_path_within_repo(expanded_repo, expanded_path, original_path) do
    repo_prefix = expanded_repo <> "/"

    if expanded_path == expanded_repo or String.starts_with?(expanded_path, repo_prefix) do
      :ok
    else
      {:error, {:invalid_durable_asset_path, original_path}}
    end
  end

  defp verify_launch(manifest, written_paths, opts) do
    config =
      %{
        required_tools: Keyword.get(opts, :required_tools, []),
        required_env: Keyword.get(opts, :required_env, []),
        generated_assets: Keyword.get(opts, :generated_assets, generated_assets(manifest, written_paths)),
        command: Keyword.get(opts, :command),
        dashboard_url: Keyword.get(opts, :dashboard_url),
        health_check_attempts: Keyword.get(opts, :health_check_attempts, 5),
        health_check_interval_ms: Keyword.get(opts, :health_check_interval_ms, 200)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    launch_verifier_deps = Keyword.get(opts, :launch_verifier_deps, LaunchVerifier.runtime_deps())
    LaunchVerifier.verify(config, launch_verifier_deps)
  end

  defp generated_assets(%{target_repo: target_repo}, written_paths) do
    workflow_path = Path.expand(Path.join(target_repo, "WORKFLOW.md"))
    normalized_written_paths = Enum.map(written_paths, &Path.expand/1)

    cond do
      workflow_path in normalized_written_paths ->
        [%{path: workflow_path, kind: :workflow}]

      File.regular?(workflow_path) ->
        [%{path: workflow_path, kind: :workflow}]

      true ->
        []
    end
  end
end
