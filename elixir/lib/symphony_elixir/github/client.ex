defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for polling candidate issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 100
  @workpad_heading "## Codex Workpad"

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker),
         {:ok, assignee_filter} <- assignee_filter() do
      fetch_repo_issues(tracker.project_slug, assignee_filter, state: "open")
      |> normalize_issues_for_requested_states(tracker.active_states)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker) do
      fetch_repo_issues(tracker.project_slug, nil, state: "all")
      |> normalize_issues_for_requested_states(state_names)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker) do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, &accumulate_issue_state/2)
      |> finalize_issue_state_results()
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, project_slug, number} <- parse_issue_id(issue_id),
         {:ok, response} <- create_or_update_comment(project_slug, number, body),
         %{"id" => _comment_id} <- response do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, raw_issue} <- fetch_raw_issue(issue_id),
         %{} <- raw_issue,
         {:ok, payload} <- issue_update_payload(raw_issue, state_name, tracker),
         {:ok, response} <- request(:patch, issue_path(issue_id), payload),
         %{"number" => _number} <- response do
      :ok
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :github_issue_not_found}
      _ -> {:error, :github_issue_update_failed}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, tracker, assignee_filter \\ nil)
      when is_map(issue) and is_map(tracker) do
    normalize_issue(issue, tracker, assignee_filter, Map.get(tracker, :project_slug) || Map.get(tracker, "project_slug"))
  end

  defp accumulate_issue_state(issue_id, {:ok, acc}) do
    case fetch_issue(issue_id) do
      {:ok, %Issue{} = issue} -> {:cont, {:ok, [issue | acc]}}
      {:ok, nil} -> {:cont, {:ok, acc}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finalize_issue_state_results({:ok, issues}), do: {:ok, Enum.reverse(issues)}
  defp finalize_issue_state_results({:error, reason}), do: {:error, reason}

  @doc false
  @spec issue_update_payload_for_test(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def issue_update_payload_for_test(raw_issue, state_name, tracker)
      when is_map(raw_issue) and is_binary(state_name) and is_map(tracker) do
    issue_update_payload(raw_issue, state_name, tracker)
  end

  defp validate_tracker_config(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_github_api_token}
      is_nil(tracker.project_slug) -> {:error, :missing_github_project_slug}
      true -> :ok
    end
  end

  defp fetch_repo_issues(project_slug, assignee_filter, opts) do
    state = Keyword.get(opts, :state, "all")
    fetch_repo_issues_page(project_slug, assignee_filter, state, 1, [])
  end

  defp fetch_repo_issues_page(project_slug, assignee_filter, state, page, acc) do
    params = %{
      state: state,
      per_page: @page_size,
      page: page
    }

    case request(:get, repo_issues_path(project_slug), params) do
      {:ok, issues} when is_list(issues) ->
        normalized =
          issues
          |> Enum.map(&normalize_issue(&1, Config.settings!().tracker, assignee_filter, project_slug))
          |> Enum.reject(&is_nil/1)

        updated_acc = acc ++ normalized

        if length(issues) < @page_size do
          {:ok, updated_acc}
        else
          fetch_repo_issues_page(project_slug, assignee_filter, state, page + 1, updated_acc)
        end

      {:ok, _unexpected} ->
        {:error, :github_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_issues_for_requested_states({:ok, issues}, requested_states) when is_list(issues) do
    normalized_states =
      requested_states
      |> Enum.map(&normalize_state_name/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issues, fn %Issue{state: state_name} ->
       MapSet.member?(normalized_states, normalize_state_name(state_name))
     end)}
  end

  defp normalize_issues_for_requested_states({:error, reason}, _requested_states), do: {:error, reason}

  defp fetch_issue(issue_id) when is_binary(issue_id) do
    with {:ok, project_slug, _number} <- parse_issue_id(issue_id),
         {:ok, raw_issue} <- fetch_raw_issue(issue_id) do
      case raw_issue do
        %{} = issue ->
          {:ok, normalize_issue(issue, Config.settings!().tracker, nil, project_slug)}

        nil ->
          {:ok, nil}
      end
    end
  end

  defp fetch_raw_issue(issue_id) when is_binary(issue_id) do
    with {:ok, project_slug, number} <- parse_issue_id(issue_id),
         {:ok, response} <- request(:get, issue_by_repo_path(project_slug, number), %{}) do
      case response do
        %{} = issue ->
          {:ok, issue}

        _ ->
          {:error, :github_unknown_payload}
      end
    else
      {:error, {:github_api_status, 404}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_update_payload(raw_issue, state_name, tracker) when is_map(raw_issue) do
    desired_state = normalize_state_name(state_name)
    workflow_labels = workflow_label_set(tracker)

    current_labels =
      raw_issue
      |> Map.get("labels", [])
      |> Enum.map(&label_name/1)
      |> Enum.reject(&is_nil/1)

    remaining_labels =
      Enum.reject(current_labels, fn label ->
        normalize_state_name(label) in workflow_labels
      end)

    labels =
      remaining_labels
      |> maybe_append_label(label_for_state(desired_state, state_name))

    payload =
      %{}
      |> maybe_put("labels", labels)
      |> maybe_put("state", github_issue_state(desired_state, tracker))

    if map_size(payload) == 0 do
      {:error, :github_issue_update_failed}
    else
      {:ok, payload}
    end
  end

  defp assignee_filter do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      "me" -> resolve_current_login()
      assignee when is_binary(assignee) -> {:ok, normalize_assignee(assignee)}
    end
  end

  defp resolve_current_login do
    case request(:get, "/user", %{}) do
      {:ok, %{"login" => login}} when is_binary(login) -> {:ok, normalize_assignee(login)}
      {:ok, _} -> {:error, :missing_github_viewer_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_issue(issue, tracker, assignee_filter, project_slug)
       when is_map(issue) and is_binary(project_slug) do
    if Map.has_key?(issue, "pull_request") do
      nil
    else
      labels =
        issue
        |> Map.get("labels", [])
        |> Enum.map(&normalize_label/1)
        |> Enum.reject(&is_nil/1)

      assignees = Map.get(issue, "assignees", [])

      if assigned_to_worker?(assignees, assignee_filter) do
        state_name = derive_issue_state(issue, tracker, labels)
        number = Map.get(issue, "number")

        %Issue{
          id: compose_issue_id(project_slug, number),
          identifier: compose_issue_id(project_slug, number),
          title: Map.get(issue, "title"),
          description: Map.get(issue, "body"),
          priority: nil,
          state: state_name,
          branch_name: nil,
          url: Map.get(issue, "html_url"),
          assignee_id: primary_assignee(assignees),
          blocked_by: [],
          labels: labels,
          assigned_to_worker: true,
          created_at: parse_datetime(Map.get(issue, "created_at")),
          updated_at: parse_datetime(Map.get(issue, "updated_at"))
        }
      else
        nil
      end
    end
  end

  defp normalize_issue(_issue, _tracker, _assignee_filter, _project_slug), do: nil

  defp derive_issue_state(issue, tracker, labels) do
    workflow_states =
      tracker.active_states ++ tracker.terminal_states

    Enum.find_value(workflow_states, fn state_name ->
      normalized_state = normalize_state_name(state_name)
      if normalized_state in labels, do: state_name
    end) ||
      built_in_state(Map.get(issue, "state"))
  end

  defp built_in_state("closed"), do: "Closed"
  defp built_in_state("open"), do: "Opened"
  defp built_in_state(_), do: "Opened"

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, assignee_filter) when is_binary(assignee_filter) and is_list(assignees) do
    Enum.any?(assignees, fn
      %{"login" => login} -> normalize_assignee(login) == assignee_filter
      _ -> false
    end)
  end

  defp assigned_to_worker?(_assignees, _assignee_filter), do: false

  defp primary_assignee([%{"login" => login} | _]) when is_binary(login), do: login
  defp primary_assignee([%{"id" => id} | _]) when is_integer(id), do: Integer.to_string(id)
  defp primary_assignee(_), do: nil

  defp normalize_assignee(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee(_value), do: nil

  defp normalize_label(%{"name" => value}) when is_binary(value), do: normalize_state_name(value)
  defp normalize_label(value) when is_binary(value), do: normalize_state_name(value)
  defp normalize_label(_value), do: nil

  defp label_name(%{"name" => value}) when is_binary(value), do: value
  defp label_name(value) when is_binary(value), do: value
  defp label_name(_value), do: nil

  defp normalize_state_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state_name(value), do: value |> to_string() |> normalize_state_name()

  defp workflow_label_set(tracker) do
    (tracker.active_states ++ tracker.terminal_states)
    |> Enum.map(&normalize_state_name/1)
    |> MapSet.new()
  end

  defp terminal_state_name?(state_name, tracker) do
    normalize_state_name(state_name) in Enum.map(tracker.terminal_states, &normalize_state_name/1)
  end

  defp github_issue_state(desired_state, tracker) do
    if terminal_state_name?(desired_state, tracker) or desired_state == "closed" do
      "closed"
    else
      "open"
    end
  end

  defp label_for_state("opened", _original_state_name), do: nil
  defp label_for_state("closed", _original_state_name), do: nil
  defp label_for_state(_desired_state, state_name), do: state_name

  defp maybe_append_label(labels, nil), do: labels
  defp maybe_append_label(labels, label), do: labels ++ [label]

  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp create_or_update_comment(project_slug, number, body) do
    if workpad_comment_body?(body) do
      case find_existing_workpad_comment_id(project_slug, number) do
        {:ok, comment_id} ->
          request(:patch, issue_comment_path(project_slug, comment_id), %{body: body})

        {:error, :github_workpad_comment_not_found} ->
          request(:post, issue_comments_path(project_slug, number), %{body: body})

        {:error, reason} ->
          {:error, reason}
      end
    else
      request(:post, issue_comments_path(project_slug, number), %{body: body})
    end
  end

  defp find_existing_workpad_comment_id(project_slug, number) do
    find_existing_workpad_comment_id(project_slug, number, 1)
  end

  defp find_existing_workpad_comment_id(project_slug, number, page) do
    case request(:get, issue_comments_path(project_slug, number), %{per_page: @page_size, page: page}) do
      {:ok, comments} when is_list(comments) ->
        case Enum.find_value(comments, &workpad_comment_id/1) do
          nil ->
            if length(comments) < @page_size do
              {:error, :github_workpad_comment_not_found}
            else
              find_existing_workpad_comment_id(project_slug, number, page + 1)
            end

          comment_id ->
            {:ok, comment_id}
        end

      {:ok, _unexpected} ->
        {:error, :github_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workpad_comment_id(%{"id" => comment_id, "body" => body}) do
    if workpad_comment_body?(body), do: comment_id, else: nil
  end

  defp workpad_comment_id(_comment), do: nil

  defp workpad_comment_body?(body) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.starts_with?(@workpad_heading)
  end

  defp workpad_comment_body?(_body), do: false

  defp request(method, path, params)
       when method in [:get, :post, :patch] and is_binary(path) and is_map(params) do
    with {:ok, headers} <- request_headers(),
         {:ok, response} <- request_executor().(method, path, params, headers) do
      case response do
        %{status: status, body: body} when status in 200..299 -> {:ok, body}
        %{status: status} -> {:error, {:github_api_status, status}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_executor do
    case Application.get_env(:symphony_elixir, :github_request_fun) do
      request_fun when is_function(request_fun, 4) ->
        request_fun

      _ ->
        &do_request/4
    end
  end

  defp do_request(method, path, params, headers) do
    req_opts =
      case method do
        :get -> [headers: headers, params: params]
        _ -> [headers: headers, json: params]
      end

    Config.settings!().tracker.endpoint
    |> Kernel.<>(path)
    |> then(fn url -> apply(Req, method, [url, req_opts]) end)
    |> case do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp request_headers do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) ->
        {:ok,
         [
           {"Authorization", "Bearer " <> token},
           {"Accept", "application/vnd.github+json"},
           {"Content-Type", "application/json"}
         ]}

      _ ->
        {:error, :missing_github_api_token}
    end
  end

  defp repo_issues_path(project_slug) do
    "/repos/" <> repo_path_component(project_slug) <> "/issues"
  end

  defp issue_by_repo_path(project_slug, number) do
    repo_issues_path(project_slug) <> "/" <> to_string(number)
  end

  defp issue_comments_path(project_slug, number) do
    issue_by_repo_path(project_slug, number) <> "/comments"
  end

  defp issue_comment_path(project_slug, comment_id) do
    "/repos/" <>
      repo_path_component(project_slug) <>
      "/issues/comments/" <> to_string(comment_id)
  end

  defp issue_path(issue_id) do
    case parse_issue_id(issue_id) do
      {:ok, project_slug, number} ->
        issue_by_repo_path(project_slug, number)

      _ ->
        raise ArgumentError, "invalid_github_issue_id: #{inspect(issue_id)}"
    end
  end

  defp parse_issue_id(issue_id) when is_binary(issue_id) do
    case String.split(issue_id, "#", parts: 2) do
      [project_slug, number] when project_slug != "" and number != "" -> {:ok, project_slug, number}
      _ -> {:error, :github_invalid_issue_id}
    end
  end

  defp compose_issue_id(project_slug, number) when is_binary(project_slug) do
    project_slug <> "#" <> to_string(number)
  end

  defp repo_path_component(project_slug) when is_binary(project_slug) do
    case String.split(project_slug, "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" ->
        URI.encode(owner, &URI.char_unreserved?/1) <>
          "/" <> URI.encode(repo, &URI.char_unreserved?/1)

      _ ->
        raise ArgumentError, "invalid_github_project_slug: #{inspect(project_slug)}"
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end
end
