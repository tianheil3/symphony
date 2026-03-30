defmodule SymphonyElixir.AgentConsoleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentConsole

  test "ensure_session creates console artifacts and tmux attach metadata" do
    workspace = create_temp_dir!("agent-console-workspace")
    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "issue-console",
      identifier: "MT-321",
      title: "Shared console runtime",
      description: "Create shared tmux console metadata",
      state: "In Progress",
      url: "https://example.org/issues/MT-321",
      labels: ["backend"]
    }

    parent = self()

    tmux_runner = fn args ->
      send(parent, {:tmux, args})

      case args do
        ["has-session", "-t", "sym-mt-321"] -> {:error, :missing_session}
        _ -> {:ok, ""}
      end
    end

    assert {:ok, console} =
             AgentConsole.ensure_session(issue, workspace,
               dashboard_base_path: "/console",
               tmux_runner: tmux_runner
             )

    assert console.session_name == "sym-mt-321"
    assert console.attach_command == "tmux attach -t sym-mt-321"
    assert console.web_path == "/console/MT-321"
    assert console.allowed_commands == ["help", "status", "explain", "continue", "prompt <text>", "cancel"]
    assert console.pending_operator_notes == 0
    assert console.state == "running"

    console_dir = Path.join(workspace, ".symphony/console")
    assert File.exists?(Path.join(console_dir, "transcript.log"))
    assert File.exists?(Path.join(console_dir, "events.ndjson"))
    assert File.exists?(Path.join(console_dir, "commands.ndjson"))
    assert File.exists?(Path.join(console_dir, "state.json"))

    assert_receive {:tmux, ["has-session", "-t", "sym-mt-321"]}
    assert_receive {:tmux, ["new-session" | _]}
    assert_receive {:tmux, ["split-window" | _]}
  end

  test "submit_command queues explain and prompt notes for the next safe boundary" do
    workspace = create_temp_dir!("agent-console-queue")
    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "issue-queue",
      identifier: "MT-654",
      title: "Queue operator guidance",
      description: "Carry safe-boundary notes into the next turn",
      state: "In Progress",
      url: "https://example.org/issues/MT-654",
      labels: ["backend"]
    }

    assert {:ok, _console} = AgentConsole.ensure_session(issue, workspace, tmux_runner: fn _ -> {:ok, ""} end)

    assert {:ok, %{console: explain_console, output: explain_output}} =
             AgentConsole.submit_command(workspace, "explain")

    assert explain_console.pending_operator_notes == 1
    assert explain_output =~ "Queued"

    assert {:ok, %{console: prompt_console}} =
             AgentConsole.submit_command(workspace, "prompt Please rerun the focused shared-console tests")

    assert prompt_console.pending_operator_notes == 2

    assert {:continue, prompt, next_console} =
             AgentConsole.prepare_next_turn(workspace, "Continuation guidance:")

    assert prompt =~ "Operator notes"
    assert prompt =~ "completed work, remaining work, and the next step"
    assert prompt =~ "Please rerun the focused shared-console tests"
    assert next_console.pending_operator_notes == 0
    assert next_console.state == "running"
  end

  test "submit_command rejects raw shell input and cancel stops the next turn" do
    workspace = create_temp_dir!("agent-console-cancel")
    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "issue-cancel",
      identifier: "MT-777",
      title: "Cancel a queued continuation",
      description: "Prevent arbitrary stdin passthrough",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["backend"]
    }

    assert {:ok, _console} = AgentConsole.ensure_session(issue, workspace, tmux_runner: fn _ -> {:ok, ""} end)

    assert {:ok, %{output: help_output}} = AgentConsole.submit_command(workspace, "help")
    assert help_output =~ "prompt <text>"

    assert {:ok, %{output: status_output}} = AgentConsole.submit_command(workspace, "status")
    assert status_output =~ "state=running"

    assert {:error, {:unsupported_command, message}} =
             AgentConsole.submit_command(workspace, "bash -lc 'echo unsafe'")

    assert message =~ "Supported commands"

    assert {:ok, %{console: cancel_console, output: cancel_output}} =
             AgentConsole.submit_command(workspace, "cancel")

    assert cancel_console.state == "operator_queued"
    assert cancel_output =~ "Cancel requested"

    assert {:cancel, final_console} = AgentConsole.prepare_next_turn(workspace, "Continuation guidance:")
    assert final_console.state == "completed"
  end
end
