defmodule SymphonyElixir.Installer.SessionState do
  @moduledoc false

  @relative_dir ".symphony/install"
  @request_file "request.json"
  @state_file "state.json"
  @log_file "events.jsonl"

  @type paths_t :: %{
          dir: String.t(),
          request: String.t(),
          state: String.t(),
          log: String.t()
        }

  @spec relative_dir() :: String.t()
  def relative_dir, do: @relative_dir

  @spec paths(Path.t()) :: paths_t()
  def paths(repo_root) when is_binary(repo_root) do
    expanded_root = Path.expand(repo_root)
    install_dir = Path.join(expanded_root, relative_dir())

    %{
      dir: install_dir,
      request: Path.join(install_dir, @request_file),
      state: Path.join(install_dir, @state_file),
      log: Path.join(install_dir, @log_file)
    }
  end

  @spec ensure_dir(Path.t()) :: :ok | {:error, term()}
  def ensure_dir(repo_root) when is_binary(repo_root) do
    repo_root
    |> paths()
    |> Map.fetch!(:dir)
    |> File.mkdir_p()
  end

  @spec ensure_dir!(Path.t()) :: :ok
  def ensure_dir!(repo_root) when is_binary(repo_root) do
    repo_root
    |> paths()
    |> Map.fetch!(:dir)
    |> File.mkdir_p!()

    :ok
  end

  @spec load(Path.t()) :: {:ok, map() | nil} | {:error, term()}
  def load(repo_root) when is_binary(repo_root) do
    read_json_file(paths(repo_root).state, :state)
  end

  @spec write_state(Path.t(), map()) :: :ok | {:error, term()}
  def write_state(repo_root, state) when is_binary(repo_root) and is_map(state) do
    write_json_file(repo_root, paths(repo_root).state, state, :state)
  end

  def write_state(_repo_root, _state), do: {:error, {:invalid_session_state, :state_payload_must_be_map}}

  @spec write_request(Path.t(), map()) :: :ok | {:error, term()}
  def write_request(repo_root, request) when is_binary(repo_root) and is_map(request) do
    write_json_file(repo_root, paths(repo_root).request, request, :request)
  end

  def write_request(_repo_root, _request),
    do: {:error, {:invalid_session_state, :request_payload_must_be_map}}

  @spec append_log(Path.t(), map()) :: :ok | {:error, term()}
  def append_log(repo_root, event) when is_binary(repo_root) and is_map(event) do
    with :ok <- ensure_dir(repo_root),
         {:ok, encoded_event} <- Jason.encode(event),
         :ok <- File.write(paths(repo_root).log, encoded_event <> "\n", [:append]) do
      :ok
    else
      {:error, reason} -> {:error, {:session_log_write_failed, reason}}
    end
  end

  def append_log(_repo_root, _event), do: {:error, {:invalid_session_state, :event_payload_must_be_map}}

  defp write_json_file(repo_root, path, payload, file_type) do
    with :ok <- ensure_dir(repo_root),
         {:ok, encoded_payload} <- Jason.encode(payload, pretty: true),
         :ok <- File.write(path, encoded_payload <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, {session_write_error(file_type), reason}}
    end
  end

  defp session_write_error(:state), do: :state_write_failed
  defp session_write_error(:request), do: :request_write_failed

  defp read_json_file(path, file_type) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          {:ok, _payload} -> {:error, {session_read_error(file_type), :expected_map}}
          {:error, reason} -> {:error, {session_read_error(file_type), reason}}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {session_read_error(file_type), reason}}
    end
  end

  defp session_read_error(:state), do: :state_read_failed
end
