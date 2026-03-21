defmodule SymphonyElixir.GitLabClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitLab.Client

  setup do
    previous_request_fun = Application.get_env(:symphony_elixir, :gitlab_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :gitlab_request_fun)
      else
        Application.put_env(:symphony_elixir, :gitlab_request_fun, previous_request_fun)
      end
    end)

    :ok
  end

  test "normalize_issue derives workflow state from labels" do
    tracker = %{
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done"],
      project_slug: "group/project"
    }

    issue =
      Client.normalize_issue_for_test(
        %{
          "iid" => 17,
          "title" => "Fix regression",
          "description" => "Details",
          "state" => "opened",
          "labels" => ["backend", "In Progress"],
          "web_url" => "https://gitlab.com/group/project/-/issues/17",
          "references" => %{"full" => "group/project#17"},
          "assignees" => [%{"username" => "alice"}],
          "created_at" => "2026-03-21T02:00:00Z",
          "updated_at" => "2026-03-21T02:05:00Z"
        },
        tracker
      )

    assert issue.id == "group/project#17"
    assert issue.identifier == "group/project#17"
    assert issue.state == "In Progress"
    assert issue.labels == ["backend", "in progress"]
  end

  test "issue update payload preserves non-workflow labels and original workflow label casing" do
    tracker = %{
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done"]
    }

    assert {:ok, payload} =
             Client.issue_update_payload_for_test(
               %{
                 "labels" => ["backend", "Todo"],
                 "state" => "opened"
               },
               "In Progress",
               tracker
             )

    assert payload["add_labels"] == "In Progress"
    assert payload["remove_labels"] == "Todo"
    assert payload["state_event"] == "reopen"
  end

  test "issue update payload closes terminal states" do
    tracker = %{
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done"]
    }

    assert {:ok, payload} =
             Client.issue_update_payload_for_test(
               %{
                 "labels" => ["backend", "In Progress"],
                 "state" => "opened"
               },
               "Done",
               tracker
             )

    assert payload["add_labels"] == "Done"
    assert payload["remove_labels"] == "In Progress"
    assert payload["state_event"] == "close"
  end

  test "fetch_candidate_issues paginates and filters by requested active state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: nil,
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"]
    )

    page_one =
      Enum.map(1..100, fn iid ->
        %{
          "iid" => iid,
          "title" => "issue-#{iid}",
          "state" => "opened",
          "labels" => ["Todo"],
          "references" => %{"full" => "group/project##{iid}"},
          "web_url" => "https://gitlab.com/group/project/-/issues/#{iid}",
          "assignees" => []
        }
      end)

    page_two = [
      %{
        "iid" => 101,
        "title" => "issue-101",
        "state" => "opened",
        "labels" => ["In Progress"],
        "references" => %{"full" => "group/project#101"},
        "web_url" => "https://gitlab.com/group/project/-/issues/101",
        "assignees" => []
      }
    ]

    responses = [
      {:ok, %{status: 200, body: page_one}},
      {:ok, %{status: 200, body: page_two}}
    ]

    {:ok, agent} = Agent.start_link(fn -> responses end)

    Application.put_env(:symphony_elixir, :gitlab_request_fun, fn _method, _path, _params, _headers ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {{:ok, %{status: 200, body: []}}, []}
      end)
    end)

    assert {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.id == "group/project#101"
    assert issue.state == "In Progress"
  end

  test "fetch_candidate_issues resolves assignee `me` via current user" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: nil,
      tracker_api_token: "token",
      tracker_project_slug: "group/project",
      tracker_assignee: "me",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"]
    )

    responses = [
      {:ok, %{status: 200, body: %{"username" => "alice"}}},
      {:ok,
       %{
         status: 200,
         body: [
           %{
             "iid" => 1,
             "title" => "first",
             "state" => "opened",
             "labels" => ["In Progress"],
             "references" => %{"full" => "group/project#1"},
             "web_url" => "https://gitlab.com/group/project/-/issues/1",
             "assignees" => [%{"username" => "alice"}]
           },
           %{
             "iid" => 2,
             "title" => "second",
             "state" => "opened",
             "labels" => ["In Progress"],
             "references" => %{"full" => "group/project#2"},
             "web_url" => "https://gitlab.com/group/project/-/issues/2",
             "assignees" => [%{"username" => "bob"}]
           }
         ]
       }},
      {:ok, %{status: 200, body: []}}
    ]

    {:ok, agent} = Agent.start_link(fn -> responses end)

    Application.put_env(:symphony_elixir, :gitlab_request_fun, fn _method, _path, _params, _headers ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {{:ok, %{status: 200, body: []}}, []}
      end)
    end)

    assert {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.id == "group/project#1"
  end

  test "fetch_issue_states_by_ids drops 404 issues and keeps found issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "gitlab",
      tracker_endpoint: nil,
      tracker_api_token: "token",
      tracker_project_slug: "group/project"
    )

    responses = [
      {:error, {:gitlab_api_status, 404}},
      {:ok,
       %{
         status: 200,
         body: %{
           "iid" => 2,
           "title" => "second",
           "state" => "opened",
           "labels" => ["Todo"],
           "references" => %{"full" => "group/project#2"},
           "web_url" => "https://gitlab.com/group/project/-/issues/2",
           "assignees" => []
         }
       }}
    ]

    {:ok, agent} = Agent.start_link(fn -> responses end)

    Application.put_env(:symphony_elixir, :gitlab_request_fun, fn _method, _path, _params, _headers ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, {:gitlab_api_status, 404}}, []}
      end)
    end)

    assert {:ok, [issue]} = Client.fetch_issue_states_by_ids(["group/project#1", "group/project#2"])
    assert issue.id == "group/project#2"
  end
end
