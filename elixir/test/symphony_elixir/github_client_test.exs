defmodule SymphonyElixir.GitHubClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client

  setup do
    previous_request_fun = Application.get_env(:symphony_elixir, :github_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :github_request_fun)
      else
        Application.put_env(:symphony_elixir, :github_request_fun, previous_request_fun)
      end
    end)

    :ok
  end

  test "normalize_issue derives workflow state from labels" do
    tracker = %{
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done"],
      project_slug: "owner/repo"
    }

    issue =
      Client.normalize_issue_for_test(
        %{
          "number" => 17,
          "title" => "Fix regression",
          "body" => "Details",
          "state" => "open",
          "labels" => [%{"name" => "backend"}, %{"name" => "In Progress"}],
          "html_url" => "https://github.com/owner/repo/issues/17",
          "assignees" => [%{"login" => "alice"}],
          "created_at" => "2026-03-21T02:00:00Z",
          "updated_at" => "2026-03-21T02:05:00Z"
        },
        tracker
      )

    assert issue.id == "owner/repo#17"
    assert issue.identifier == "owner/repo#17"
    assert issue.state == "In Progress"
    assert issue.labels == ["backend", "in progress"]
  end

  test "normalize_issue ignores pull requests" do
    tracker = %{
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done"],
      project_slug: "owner/repo"
    }

    assert is_nil(
             Client.normalize_issue_for_test(
               %{
                 "number" => 17,
                 "state" => "open",
                 "pull_request" => %{"url" => "https://api.github.com/repos/owner/repo/pulls/17"}
               },
               tracker
             )
           )
  end

  test "issue update payload preserves non-workflow labels and original workflow label casing" do
    tracker = %{
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done"]
    }

    assert {:ok, payload} =
             Client.issue_update_payload_for_test(
               %{
                 "labels" => [%{"name" => "backend"}, %{"name" => "Todo"}],
                 "state" => "open"
               },
               "In Progress",
               tracker
             )

    assert payload["labels"] == ["backend", "In Progress"]
    assert payload["state"] == "open"
  end

  test "issue update payload closes terminal states" do
    tracker = %{
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done"]
    }

    assert {:ok, payload} =
             Client.issue_update_payload_for_test(
               %{
                 "labels" => [%{"name" => "backend"}, %{"name" => "In Progress"}],
                 "state" => "open"
               },
               "Done",
               tracker
             )

    assert payload["labels"] == ["backend", "Done"]
    assert payload["state"] == "closed"
  end

  test "fetch_candidate_issues paginates and filters by requested active state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_api_token: "token",
      tracker_project_slug: "owner/repo",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"]
    )

    page_one =
      Enum.map(1..100, fn number ->
        %{
          "number" => number,
          "title" => "issue-#{number}",
          "state" => "open",
          "labels" => [%{"name" => "Todo"}],
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "assignees" => []
        }
      end)

    page_two = [
      %{
        "number" => 101,
        "title" => "issue-101",
        "state" => "open",
        "labels" => [%{"name" => "In Progress"}],
        "html_url" => "https://github.com/owner/repo/issues/101",
        "assignees" => []
      }
    ]

    responses = [
      {:ok, %{status: 200, body: page_one}},
      {:ok, %{status: 200, body: page_two}}
    ]

    {:ok, agent} = Agent.start_link(fn -> responses end)

    Application.put_env(:symphony_elixir, :github_request_fun, fn _method, _path, _params, _headers ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {{:ok, %{status: 200, body: []}}, []}
      end)
    end)

    assert {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.id == "owner/repo#101"
    assert issue.state == "In Progress"
  end

  test "fetch_issue_states_by_ids drops 404 issues and keeps found issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_api_token: "token",
      tracker_project_slug: "owner/repo"
    )

    responses = [
      {:error, {:github_api_status, 404}},
      {:ok,
       %{
         status: 200,
         body: %{
           "number" => 2,
           "title" => "second",
           "state" => "open",
           "labels" => [%{"name" => "Todo"}],
           "html_url" => "https://github.com/owner/repo/issues/2",
           "assignees" => []
         }
       }}
    ]

    {:ok, agent} = Agent.start_link(fn -> responses end)

    Application.put_env(:symphony_elixir, :github_request_fun, fn _method, _path, _params, _headers ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, {:github_api_status, 404}}, []}
      end)
    end)

    assert {:ok, [issue]} = Client.fetch_issue_states_by_ids(["owner/repo#1", "owner/repo#2"])
    assert issue.id == "owner/repo#2"
  end

  test "create_comment reuses an existing Codex Workpad comment" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_api_token: "token",
      tracker_project_slug: "owner/repo"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn method, path, params, _headers ->
      send(parent, {:github_request, method, path, params})

      case {method, path} do
        {:get, "/repos/owner/repo/issues/42/comments"} ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"id" => 1001, "body" => "## Codex Workpad\n\nExisting body"},
               %{"id" => 1002, "body" => "Unrelated note"}
             ]
           }}

        {:patch, "/repos/owner/repo/issues/comments/1001"} ->
          {:ok, %{status: 200, body: %{"id" => 1001, "body" => params["body"]}}}

        {:post, "/repos/owner/repo/issues/42/comments"} ->
          flunk("expected existing workpad comment to be updated, not recreated")

        other ->
          flunk("unexpected GitHub request: #{inspect(other)}")
      end
    end)

    assert :ok =
             Client.create_comment(
               "owner/repo#42",
               "## Codex Workpad\n\nSymphony claimed this issue in state `In Progress`."
             )

    assert_receive {:github_request, :get, "/repos/owner/repo/issues/42/comments",
                    %{page: 1, per_page: 100}}

    assert_receive {:github_request, :patch, "/repos/owner/repo/issues/comments/1001",
                    %{body: "## Codex Workpad\n\nSymphony claimed this issue in state `In Progress`."}}

    refute_receive {:github_request, :post, _, _}
  end

  test "create_comment creates a new GitHub comment when no workpad exists" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_api_token: "token",
      tracker_project_slug: "owner/repo"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn method, path, params, _headers ->
      send(parent, {:github_request, method, path, params})

      case {method, path} do
        {:get, "/repos/owner/repo/issues/42/comments"} ->
          {:ok, %{status: 200, body: [%{"id" => 1002, "body" => "Unrelated note"}]}}

        {:post, "/repos/owner/repo/issues/42/comments"} ->
          {:ok, %{status: 201, body: %{"id" => 1003, "body" => params["body"]}}}

        other ->
          flunk("unexpected GitHub request: #{inspect(other)}")
      end
    end)

    assert :ok =
             Client.create_comment(
               "owner/repo#42",
               "## Codex Workpad\n\nSymphony claimed this issue in state `Todo`."
             )

    assert_receive {:github_request, :get, "/repos/owner/repo/issues/42/comments",
                    %{page: 1, per_page: 100}}

    assert_receive {:github_request, :post, "/repos/owner/repo/issues/42/comments",
                    %{body: "## Codex Workpad\n\nSymphony claimed this issue in state `Todo`."}}
  end
end
