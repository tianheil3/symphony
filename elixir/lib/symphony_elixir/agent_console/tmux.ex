defmodule SymphonyElixir.AgentConsole.Tmux do
  @moduledoc """
  Creates and restores the tmux-backed shared terminal session for an issue console.
  """

  @type runner :: ([String.t()] -> {:ok, String.t()} | {:error, term()})

  @spec ensure_session(String.t(), Path.t(), Path.t(), Path.t(), runner()) :: :ok | {:error, term()}
  def ensure_session(session_name, workspace, console_dir, control_script_path, runner)
      when is_binary(session_name) and is_binary(workspace) and is_binary(console_dir) and
             is_binary(control_script_path) and is_function(runner, 1) do
    case runner.(["has-session", "-t", session_name]) do
      {:ok, _output} ->
        :ok

      {:error, :missing_session} ->
        create_session(session_name, workspace, console_dir, control_script_path, runner)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec capture(String.t(), pos_integer(), runner()) :: {:ok, String.t()} | {:error, term()}
  def capture(session_name, line_count, runner)
      when is_binary(session_name) and is_integer(line_count) and line_count > 0 and
             is_function(runner, 1) do
    runner.(["capture-pane", "-pt", session_name, "-S", "-#{line_count}"])
  end

  @spec default_runner() :: runner()
  def default_runner do
    fn args -> run_tmux(args, System.find_executable("tmux")) end
  end

  defp run_tmux(_args, nil), do: {:error, :tmux_unavailable}

  defp run_tmux(args, tmux) do
    tmux
    |> System.cmd(args, stderr_to_stdout: true)
    |> tmux_result(args)
  end

  defp tmux_result({output, 0}, _args), do: {:ok, String.trim(output)}

  defp tmux_result({output, 1}, args) do
    if has_session_command?(args) do
      {:error, :missing_session}
    else
      {:error, {:tmux_failed, 1, String.trim(output)}}
    end
  end

  defp tmux_result({output, status}, _args), do: {:error, {:tmux_failed, status, String.trim(output)}}

  defp create_session(session_name, workspace, console_dir, control_script_path, runner) do
    transcript_path = Path.join(console_dir, "transcript.log")

    with {:ok, _} <-
           runner.([
             "new-session",
             "-d",
             "-s",
             session_name,
             "-c",
             workspace,
             "sh -lc 'touch #{shell_escape(transcript_path)} && tail -n 200 -F #{shell_escape(transcript_path)}'"
           ]),
         {:ok, _} <-
           runner.([
             "split-window",
             "-v",
             "-t",
             session_name,
             "-c",
             workspace,
             "sh #{shell_escape(control_script_path)}"
           ]) do
      :ok
    end
  end

  defp shell_escape(value) when is_binary(value) do
    escaped = String.replace(value, "'", "'\"'\"'")
    "'#{escaped}'"
  end

  defp has_session_command?(["has-session", "-t", _session_name]), do: true
  defp has_session_command?(_args), do: false
end
