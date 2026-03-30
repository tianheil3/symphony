defmodule SymphonyElixir.AgentConsole do
  @moduledoc """
  Maintains the shared tracker-dispatched agent console state, tmux session metadata,
  transcript files, and controlled operator commands.
  """

  alias SymphonyElixir.AgentConsole.{OperatorCommand, Tmux}
  alias SymphonyElixir.Linear.Issue

  @console_subdir Path.join(".symphony", "console")
  @state_file "state.json"
  @transcript_file "transcript.log"
  @events_file "events.ndjson"
  @commands_file "commands.ndjson"
  @control_script_file "operator-control.sh"
  @default_dashboard_base_path "/console"
  @default_control_base_url "http://127.0.0.1:4000"
  @restore_line_count 200

  @type metadata :: %{
          session_name: String.t(),
          attach_command: String.t(),
          web_path: String.t(),
          allowed_commands: [String.t()],
          pending_operator_notes: non_neg_integer(),
          state: String.t(),
          transcript_path: String.t(),
          events_path: String.t(),
          commands_path: String.t(),
          available: boolean()
        }

  @spec ensure_session(Issue.t(), Path.t(), keyword()) :: {:ok, metadata()} | {:error, term()}
  def ensure_session(%Issue{identifier: issue_identifier}, workspace, opts \\ [])
      when is_binary(issue_identifier) and is_binary(workspace) do
    console_dir = console_dir(workspace)
    session_name = session_name(issue_identifier)
    dashboard_base_path = Keyword.get(opts, :dashboard_base_path, @default_dashboard_base_path)
    control_base_url = Keyword.get(opts, :control_base_url, @default_control_base_url)
    control_script_path = Path.join(console_dir, @control_script_file)
    tmux_runner = Keyword.get(opts, :tmux_runner, Tmux.default_runner())

    ensure_artifacts(console_dir)
    ensure_control_script(control_script_path, control_base_url, issue_identifier)

    base_state =
      load_state(workspace)
      |> Map.merge(%{
        "issue_identifier" => issue_identifier,
        "session_name" => session_name,
        "cancel_requested" => false,
        "pending_operator_notes" => [],
        "state" => "running"
      })

    available =
      case Tmux.ensure_session(session_name, workspace, console_dir, control_script_path, tmux_runner) do
        :ok -> true
        {:error, _reason} -> false
      end

    state =
      base_state
      |> Map.put("available", available)
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())

    write_state(workspace, state)
    {:ok, metadata_for(workspace, state, dashboard_base_path)}
  end

  @spec submit_command(Path.t(), String.t()) ::
          {:ok, %{console: metadata(), output: String.t()}}
          | {:error, {:unsupported_command, String.t()}}
          | {:error, term()}
  def submit_command(workspace, raw_command) when is_binary(workspace) and is_binary(raw_command) do
    state = load_state(workspace)

    with {:ok, command} <- OperatorCommand.parse(raw_command) do
      append_jsonl(Path.join(console_dir(workspace), @commands_file), %{
        at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        raw: raw_command,
        parsed: command
      })

      apply_command(workspace, state, command)
    end
  end

  @spec prepare_next_turn(Path.t(), String.t()) ::
          {:continue, String.t(), metadata()} | {:cancel, metadata()}
  def prepare_next_turn(workspace, base_prompt)
      when is_binary(workspace) and is_binary(base_prompt) do
    state = load_state(workspace)

    cond do
      Map.get(state, "cancel_requested") == true ->
        updated_state =
          state
          |> Map.put("cancel_requested", false)
          |> Map.put("pending_operator_notes", [])
          |> Map.put("state", "completed")

        write_state(workspace, updated_state)
        {:cancel, metadata_for(workspace, updated_state)}

      true ->
        pending_notes = pending_operator_notes(state)

        if pending_notes != [] do
          updated_state =
            state
            |> Map.put("pending_operator_notes", [])
            |> Map.put("state", "running")

          write_state(workspace, updated_state)
          {:continue, append_operator_notes(base_prompt, pending_notes), metadata_for(workspace, updated_state)}
        else
          updated_state = Map.put(state, "state", "running")
          write_state(workspace, updated_state)
          {:continue, base_prompt, metadata_for(workspace, updated_state)}
        end
    end
  end

  @spec read_transcript(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def read_transcript(workspace, opts \\ []) when is_binary(workspace) do
    state = load_state(workspace)
    tmux_runner = Keyword.get(opts, :tmux_runner, Tmux.default_runner())
    transcript_path = Path.join(console_dir(workspace), @transcript_file)

    with true <- Map.get(state, "available", false),
         session_name when is_binary(session_name) <- Map.get(state, "session_name"),
         {:ok, transcript} <- Tmux.capture(session_name, @restore_line_count, tmux_runner) do
      {:ok, transcript}
    else
      _ ->
        File.read(transcript_path)
    end
  end

  @spec record_event(Path.t(), map()) :: :ok | {:error, term()}
  def record_event(workspace, event) when is_binary(workspace) and is_map(event) do
    events_path = Path.join(console_dir(workspace), @events_file)
    transcript_path = Path.join(console_dir(workspace), @transcript_file)

    append_jsonl(events_path, event)
    File.write(transcript_path, render_event(event) <> "\n", [:append])
  end

  @spec command_path(String.t()) :: String.t()
  def command_path(issue_identifier) when is_binary(issue_identifier) do
    "/api/v1/#{issue_identifier}/console/command"
  end

  @spec metadata(Path.t()) :: metadata()
  def metadata(workspace) when is_binary(workspace) do
    metadata_for(workspace, load_state(workspace))
  end

  defp apply_command(workspace, state, %{command: :help}) do
    {:ok, %{console: metadata_for(workspace, state), output: OperatorCommand.help_text()}}
  end

  defp apply_command(workspace, state, %{command: :status}) do
    console = metadata_for(workspace, state)

    {:ok,
     %{
       console: console,
       output:
         "state=#{console.state} pending_operator_notes=#{console.pending_operator_notes} attach_command=#{console.attach_command}"
     }}
  end

  defp apply_command(workspace, state, %{command: :continue}) do
    updated_state = Map.put(state, "state", "between_turns")
    write_state(workspace, updated_state)
    {:ok, %{console: metadata_for(workspace, updated_state), output: "Continuation queued."}}
  end

  defp apply_command(workspace, state, %{command: :explain}) do
    updated_state =
      enqueue_note(state, OperatorCommand.explain_note())
      |> Map.put("state", "operator_queued")

    write_state(workspace, updated_state)
    {:ok, %{console: metadata_for(workspace, updated_state), output: "Queued explain request for the next safe boundary."}}
  end

  defp apply_command(workspace, state, %{command: :prompt, note: note}) do
    updated_state =
      enqueue_note(state, note)
      |> Map.put("state", "operator_queued")

    write_state(workspace, updated_state)
    {:ok, %{console: metadata_for(workspace, updated_state), output: "Queued operator note for the next safe boundary."}}
  end

  defp apply_command(workspace, state, %{command: :cancel}) do
    updated_state =
      state
      |> Map.put("cancel_requested", true)
      |> Map.put("state", "operator_queued")

    write_state(workspace, updated_state)
    {:ok, %{console: metadata_for(workspace, updated_state), output: "Cancel requested for the next safe boundary."}}
  end

  defp append_operator_notes(base_prompt, pending_notes) when is_list(pending_notes) do
    note_block =
      pending_notes
      |> Enum.map_join("\n", &("- " <> &1))

    [base_prompt, "", "Operator notes:", note_block]
    |> Enum.join("\n")
  end

  defp enqueue_note(state, note) when is_binary(note) do
    pending_operator_notes = pending_operator_notes(state)
    Map.put(state, "pending_operator_notes", pending_operator_notes ++ [note])
  end

  defp pending_operator_notes(state) when is_map(state) do
    case Map.get(state, "pending_operator_notes") do
      notes when is_list(notes) -> Enum.filter(notes, &is_binary/1)
      _ -> []
    end
  end

  defp ensure_artifacts(console_dir) do
    File.mkdir_p!(console_dir)

    [@transcript_file, @events_file, @commands_file]
    |> Enum.each(fn filename ->
      path = Path.join(console_dir, filename)
      unless File.exists?(path), do: File.write!(path, "")
    end)
  end

  defp ensure_control_script(path, control_base_url, issue_identifier) do
    script = """
    #!/bin/sh
    set -eu

    control_url="#{control_base_url}#{command_path(issue_identifier)}"

    while true; do
      printf 'agent-console> '
      if ! IFS= read -r line; then
        exit 0
      fi

      if [ -z "$line" ]; then
        continue
      fi

      curl -fsS -X POST --data-urlencode "command=$line" "$control_url" || printf 'command failed\\n'
      printf '\\n'
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  defp metadata_for(workspace, state, dashboard_base_path \\ @default_dashboard_base_path) do
    issue_identifier = Map.get(state, "issue_identifier", Path.basename(workspace))
    session_name = Map.get(state, "session_name", session_name(issue_identifier))

    %{
      session_name: session_name,
      attach_command: "tmux attach -t #{session_name}",
      web_path: Path.join(dashboard_base_path, issue_identifier),
      allowed_commands: OperatorCommand.allowed_commands(),
      pending_operator_notes: length(pending_operator_notes(state)),
      state: Map.get(state, "state", "running"),
      transcript_path: Path.join(console_dir(workspace), @transcript_file),
      events_path: Path.join(console_dir(workspace), @events_file),
      commands_path: Path.join(console_dir(workspace), @commands_file),
      available: Map.get(state, "available", false)
    }
  end

  defp console_dir(workspace) when is_binary(workspace), do: Path.join(workspace, @console_subdir)

  defp load_state(workspace) do
    state_path = Path.join(console_dir(workspace), @state_file)

    case File.read(state_path) do
      {:ok, payload} ->
        case Jason.decode(payload) do
          {:ok, state} when is_map(state) -> state
          _ -> %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  defp write_state(workspace, state) when is_binary(workspace) and is_map(state) do
    payload =
      state
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
      |> Jason.encode!(pretty: true)

    File.write!(Path.join(console_dir(workspace), @state_file), payload <> "\n")
  end

  defp append_jsonl(path, payload) when is_binary(path) and is_map(payload) do
    File.write(path, Jason.encode!(payload) <> "\n", [:append])
  end

  defp render_event(%{event: event, payload: payload}) when is_map(payload),
    do: "#{event}: #{Jason.encode!(payload)}"

  defp render_event(%{event: event}), do: to_string(event)
  defp render_event(payload), do: Jason.encode!(payload)

  defp session_name(issue_identifier) do
    suffix =
      issue_identifier
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    "sym-" <> suffix
  end
end
