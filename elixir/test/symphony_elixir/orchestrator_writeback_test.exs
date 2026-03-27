defmodule SymphonyElixir.OrchestratorWritebackTest do
  use SymphonyElixir.TestSupport

  defmodule GitHubClientMock do
    def update_issue_state(issue_id, state_name) do
      send(self(), {:github_update_issue_state_called, issue_id, state_name})
      :ok
    end

    def create_comment(issue_id, body) do
      send(self(), {:github_create_comment_called, issue_id, body})
      :ok
    end
  end

  setup do
    previous_client_module = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, GitHubClientMock)

    on_exit(fn ->
      case previous_client_module do
        nil -> Application.delete_env(:symphony_elixir, :github_client_module)
        module -> Application.put_env(:symphony_elixir, :github_client_module, module)
      end
    end)

    :ok
  end

  test "dispatch writeback moves github Todo issues to In Progress and posts a workpad comment" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com",
      tracker_api_token: "token",
      tracker_project_slug: "owner/repo",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"]
    )

    issue = %Issue{
      id: "owner/repo#42",
      identifier: "owner/repo#42",
      title: "Dispatch writeback test",
      description: "Ensure orchestrator writes tracker progress on dispatch",
      state: "Todo",
      url: "https://example.com/owner/repo/issues/42"
    }

    updated_issue = Orchestrator.sync_issue_writeback_for_dispatch_for_test(issue)

    assert updated_issue.state == "In Progress"
    assert_receive {:github_update_issue_state_called, "owner/repo#42", "In Progress"}
    assert_receive {:github_create_comment_called, "owner/repo#42", body}
    assert body =~ "## Codex Workpad"
    assert body =~ "In Progress"
  end

  test "dispatch writeback is skipped for non-github trackers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: "token",
      tracker_project_slug: "project"
    )

    issue = %Issue{
      id: "issue-123",
      identifier: "MT-123",
      title: "Non github tracker",
      description: "No writeback expected",
      state: "Todo",
      url: "https://example.com/issue-123"
    }

    updated_issue = Orchestrator.sync_issue_writeback_for_dispatch_for_test(issue)

    assert updated_issue.state == "Todo"
    refute_receive {:github_update_issue_state_called, _, _}
    refute_receive {:github_create_comment_called, _, _}
  end
end
