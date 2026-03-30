defmodule SymphonyElixir.TerminalLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.AgentConsole

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "observability api exposes shared console metadata and accepts controlled operator commands" do
    {issue, workspace} = prepare_console_workspace("MT-HTTP")
    orchestrator_name = Module.concat(__MODULE__, :ConsoleApiOrchestrator)

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator_name, snapshot: snapshot_with_console(issue, workspace), refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]}}
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    [running_entry] = state_payload["running"]

    assert running_entry["console"] == %{
             "session_name" => "sym-mt-http",
             "attach_command" => "tmux attach -t sym-mt-http",
             "web_path" => "/console/MT-HTTP",
             "allowed_commands" => ["help", "status", "explain", "continue", "prompt <text>", "cancel"],
             "pending_operator_notes" => 0,
             "state" => "running",
             "available" => true
           }

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
    assert issue_payload["console"]["session_name"] == "sym-mt-http"

    console_payload = json_response(get(build_conn(), "/api/v1/MT-HTTP/console"), 200)
    assert console_payload["console"]["web_path"] == "/console/MT-HTTP"
    assert console_payload["transcript"] =~ "shared terminal output"

    command_payload =
      json_response(
        post(build_conn(), "/api/v1/MT-HTTP/console/command", %{"command" => "prompt Please explain the current retry plan"}),
        200
      )

    assert command_payload["console"]["pending_operator_notes"] == 1
    assert command_payload["output"] =~ "Queued operator note"
  end

  test "dashboard and terminal live surfaces render the shared console attach path" do
    {issue, workspace} = prepare_console_workspace("MT-LIVE")
    orchestrator_name = Module.concat(__MODULE__, :ConsoleLiveOrchestrator)

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator_name, snapshot: snapshot_with_console(issue, workspace), refresh: %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll"]}}
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _dashboard_view, dashboard_html} = live(build_conn(), "/")
    assert dashboard_html =~ "Open Console"
    assert dashboard_html =~ "tmux attach -t sym-mt-live"

    {:ok, terminal_view, terminal_html} = live(build_conn(), "/console/MT-LIVE")
    assert terminal_html =~ "Shared Console"
    assert terminal_html =~ "xterm"
    assert terminal_html =~ "shared terminal output"
    assert terminal_html =~ "prompt &lt;text&gt;"

    rendered =
      terminal_view
      |> form("#console-command-form", %{"command" => "explain"})
      |> render_submit()

    assert rendered =~ "Queued explain request"
    assert rendered =~ "Pending operator notes: 1"
  end

  defp prepare_console_workspace(issue_identifier) do
    workspace_root = create_temp_dir!("terminal-live")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    workspace = Path.join(workspace_root, issue_identifier)
    File.mkdir_p!(workspace)

    issue = %Issue{
      id: "issue-#{issue_identifier}",
      identifier: issue_identifier,
      title: "Terminal console test",
      description: "Exercise the shared console surface",
      state: "In Progress",
      url: "https://example.org/issues/#{issue_identifier}",
      labels: ["backend"]
    }

    assert {:ok, _console} =
             AgentConsole.ensure_session(issue, workspace, tmux_runner: fn _ -> {:ok, ""} end)

    File.write!(Path.join(workspace, ".symphony/console/transcript.log"), "shared terminal output\n")
    {issue, workspace}
  end

  defp snapshot_with_console(issue, workspace) do
    %{
      running: [
        %{
          issue_id: issue.id,
          identifier: issue.identifier,
          state: issue.state,
          session_id: "thread-live",
          turn_count: 3,
          codex_app_server_pid: nil,
          worker_host: nil,
          workspace_path: workspace,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}},
      polling: %{checking?: false, next_poll_in_ms: 1_000, poll_interval_ms: 30_000}
    }
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
