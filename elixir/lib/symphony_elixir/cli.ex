defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]
  @install_switches [manifest: :string]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          run_bootstrap: (String.t() -> :ok | {:error, String.t()}),
          run_install: (String.t() -> :ok | {:error, term()}),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        if one_shot_command?(args) do
          System.halt(0)
        else
          wait_for_shutdown()
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case args do
      [command | rest] when command in ["bootstrap", "init"] ->
        evaluate_bootstrap(rest, deps)

      ["install" | rest] ->
        evaluate_install(rest, deps)

      _ ->
        evaluate_workflow_command(args, deps)
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    [
      "Usage:",
      "  symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]",
      "  symphony install --manifest <path>",
      "  symphony bootstrap [target-repo-root]",
      "  symphony init [target-repo-root]"
    ]
    |> Enum.join("\n")
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      run_bootstrap: &SymphonyElixir.Bootstrap.run/1,
      run_install: &SymphonyElixir.Installer.install/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp evaluate_bootstrap([], deps), do: deps.run_bootstrap.(Path.expand("."))
  defp evaluate_bootstrap([target_root], deps), do: deps.run_bootstrap.(Path.expand(target_root))
  defp evaluate_bootstrap(_args, _deps), do: {:error, usage_message()}

  defp evaluate_install(args, deps) do
    case OptionParser.parse(args, strict: @install_switches) do
      {opts, [], []} ->
        case manifest_path_from_opts(opts) do
          {:ok, manifest_path} -> run_install(manifest_path, deps)
          {:error, _message} = error -> error
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp evaluate_workflow_command(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        evaluate_workflow_run(opts, Path.expand("WORKFLOW.md"), deps)

      {opts, [workflow_path], []} ->
        evaluate_workflow_run(opts, workflow_path, deps)

      _ ->
        {:error, usage_message()}
    end
  end

  defp evaluate_workflow_run(opts, workflow_path, deps) do
    with :ok <- require_guardrails_acknowledgement(opts),
         :ok <- maybe_set_logs_root(opts, deps),
         :ok <- maybe_set_server_port(opts, deps) do
      run(workflow_path, deps)
    end
  end

  defp manifest_path_from_opts(opts) do
    case Keyword.get_values(opts, :manifest) do
      [] ->
        {:error, usage_message()}

      values ->
        manifest_path = values |> List.last() |> String.trim()

        if manifest_path == "" do
          {:error, usage_message()}
        else
          {:ok, Path.expand(manifest_path)}
        end
    end
  end

  defp run_install(manifest_path, deps) do
    case deps.run_install.(manifest_path) do
      :ok ->
        :ok

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "Installer apply failed for manifest #{manifest_path}: #{inspect(reason)}"}
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp one_shot_command?(args) when is_list(args) do
    case args do
      [command | _rest] -> command in ["bootstrap", "init", "install"]
      _ -> false
    end
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
