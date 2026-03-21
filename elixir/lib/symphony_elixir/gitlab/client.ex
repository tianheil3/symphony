defmodule SymphonyElixir.GitLab.Client do
  @moduledoc """
  Thin GitLab REST client for polling candidate issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 100

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker),
         {:ok, assignee_filter} <- assignee_filter() do
      fetch_project_issues(tracker.project_slug, assignee_filter, state: "opened")
      |> normalize_issues_for_requested_states(tracker.active_states)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker) do
      fetch_project_issues(tracker.project_slug, nil, state: "all")
      |> normalize_issues_for_requested_states(state_names)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker) do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
        case fetch_issue(issue_id) do
          {:ok, %Issue{} = issue} -> {:cont, {:ok, [issue | acc]}}
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, project_slug, iid} <- parse_issue_id(issue_id),
         {:ok, response} <-
           request(:post, issue_notes_path(project_slug, iid), %{body: body}),
         %{"body" => _note_body} <- response do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :gitlab_comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, raw_issue} <- fetch_raw_issue(issue_id),
         %{} <- raw_issue,
         {:ok, payload} <- issue_update_payload(raw_issue, state_name, tracker),
         {:ok, response} <- request(:put, issue_path(issue_id), payload),
         %{"iid" => _iid} <- response do
      :ok
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :gitlab_issue_not_found}
      _ -> {:error, :gitlab_issue_update_failed}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, tracker, assignee_filter \\ nil)
      when is_map(issue) and is_map(tracker) do
    normalize_issue(issue, tracker, assignee_filter)
  end

  @doc false
  @spec issue_update_payload_for_test(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def issue_update_payload_for_test(raw_issue, state_name, tracker) when is_map(raw_issue) and is_binary(state_name) and is_map(tracker) do
    issue_update_payload(raw_issue, state_name, tracker)
  end

  defp validate_tracker_config(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_gitlab_api_token}
      is_nil(tracker.project_slug) -> {:error, :missing_gitlab_project_slug}
      true -> :ok
    end
  end

  defp fetch_project_issues(project_slug, assignee_filter, opts) do
    state = Keyword.get(opts, :state, "all")
    fetch_project_issues_page(project_slug, assignee_filter, state, 1, [])
  end

  defp fetch_project_issues_page(project_slug, assignee_filter, state, page, acc) do
    params = %{
      state: state,
      per_page: @page_size,
      page: page
    }

    case request(:get, project_issues_path(project_slug), params) do
      {:ok, issues} when is_list(issues) ->
        normalized =
          issues
          |> Enum.map(&normalize_issue(&1, Config.settings!().tracker, assignee_filter))
          |> Enum.reject(&is_nil/1)

        updated_acc = acc ++ normalized

        if length(issues) < @page_size do
          {:ok, updated_acc}
        else
          fetch_project_issues_page(project_slug, assignee_filter, state, page + 1, updated_acc)
        end

      {:ok, _unexpected} ->
        {:error, :gitlab_unknown_payload}

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
    with {:ok, raw_issue} <- fetch_raw_issue(issue_id) do
      case raw_issue do
        %{} = issue ->
          {:ok, normalize_issue(issue, Config.settings!().tracker, nil)}

        nil ->
          {:ok, nil}
      end
    end
  end

  defp fetch_raw_issue(issue_id) when is_binary(issue_id) do
    with {:ok, project_slug, iid} <- parse_issue_id(issue_id),
         {:ok, response} <- request(:get, issue_by_project_path(project_slug, iid), %{}) do
      case response do
        %{} = issue ->
          {:ok, issue}

        _ ->
          {:error, :gitlab_unknown_payload}
      end
    else
      {:error, {:gitlab_api_status, 404}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_update_payload(raw_issue, state_name, tracker) when is_map(raw_issue) do
    desired_state = normalize_state_name(state_name)
    workflow_labels = workflow_label_set(tracker)
    current_labels =
      raw_issue
      |> Map.get("labels", [])
      |> Enum.filter(&is_binary/1)

    workflow_labels_to_remove =
      Enum.filter(current_labels, fn label ->
        normalize_state_name(label) in workflow_labels
      end)

    add_label =
      case desired_state do
        "opened" -> nil
        "closed" -> nil
        _ -> state_name
      end

    state_event =
      cond do
        terminal_state_name?(state_name, tracker) -> "close"
        active_state_name?(state_name, tracker) -> "reopen"
        desired_state == "closed" -> "close"
        desired_state == "opened" -> "reopen"
        true -> nil
      end

    payload =
      %{}
      |> maybe_put("add_labels", labels_payload(maybe_put_label([], add_label)))
      |> maybe_put("remove_labels", labels_payload(workflow_labels_to_remove))
      |> maybe_put("state_event", state_event)

    if map_size(payload) == 0 do
      {:error, :gitlab_issue_update_failed}
    else
      {:ok, payload}
    end
  end

  defp assignee_filter do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      "me" -> resolve_current_username()
      assignee when is_binary(assignee) -> {:ok, normalize_assignee(assignee)}
      _ -> {:ok, nil}
    end
  end

  defp resolve_current_username do
    case request(:get, "/user", %{}) do
      {:ok, %{"username" => username}} when is_binary(username) -> {:ok, normalize_assignee(username)}
      {:ok, _} -> {:error, :missing_gitlab_viewer_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_issue(issue, tracker, assignee_filter) when is_map(issue) do
    labels =
      issue
      |> Map.get("labels", [])
      |> Enum.map(&normalize_label/1)
      |> Enum.reject(&is_nil/1)

    assignees = Map.get(issue, "assignees", [])

    if assigned_to_worker?(assignees, assignee_filter) do
      state_name = derive_issue_state(issue, tracker, labels)
      project_slug = project_slug_from_issue(issue, tracker.project_slug)
      iid = Map.get(issue, "iid")

      %Issue{
        id: compose_issue_id(project_slug, iid),
        identifier: issue_identifier(issue, project_slug, iid),
        title: Map.get(issue, "title"),
        description: Map.get(issue, "description"),
        priority: nil,
        state: state_name,
        branch_name: nil,
        url: Map.get(issue, "web_url"),
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

  defp normalize_issue(_issue, _tracker, _assignee_filter), do: nil

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
  defp built_in_state("opened"), do: "Opened"
  defp built_in_state(_), do: "Opened"

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, assignee_filter) when is_binary(assignee_filter) and is_list(assignees) do
    Enum.any?(assignees, fn
      %{"username" => username} -> normalize_assignee(username) == assignee_filter
      _ -> false
    end)
  end

  defp assigned_to_worker?(_assignees, _assignee_filter), do: false

  defp primary_assignee([%{"username" => username} | _]), do: username
  defp primary_assignee([%{"id" => id} | _]) when is_integer(id), do: Integer.to_string(id)
  defp primary_assignee(_), do: nil

  defp normalize_assignee(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee(_value), do: nil

  defp normalize_label(value) when is_binary(value), do: normalize_state_name(value)
  defp normalize_label(_value), do: nil

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

  defp active_state_name?(state_name, tracker) do
    normalize_state_name(state_name) in Enum.map(tracker.active_states, &normalize_state_name/1)
  end

  defp maybe_put_label(labels, nil), do: labels
  defp maybe_put_label(labels, label), do: [label | labels]

  defp labels_payload(label_set) when is_list(label_set) do
    label_set
    |> Enum.join(",")
    |> case do
      "" -> nil
      labels -> labels
    end
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp request(method, path, params) when method in [:get, :post, :put] and is_binary(path) and is_map(params) do
    with {:ok, headers} <- request_headers(),
         {:ok, response} <- request_executor().(method, path, params, headers) do
      case response do
        %{status: status, body: body} when status in 200..299 -> {:ok, body}
        %{status: status} -> {:error, {:gitlab_api_status, status}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_executor do
    case Application.get_env(:symphony_elixir, :gitlab_request_fun) do
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
      {:ok, response} -> {:ok, response}
      {:error, reason} ->
        Logger.error("GitLab API request failed: #{inspect(reason)}")
        {:error, {:gitlab_api_request, reason}}
    end
  end

  defp request_headers do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) ->
        {:ok, [{"PRIVATE-TOKEN", token}, {"Content-Type", "application/json"}]}

      _ ->
        {:error, :missing_gitlab_api_token}
    end
  end

  defp project_issues_path(project_slug) do
    "/projects/" <> project_slug_component(project_slug) <> "/issues"
  end

  defp issue_by_project_path(project_slug, iid) do
    project_issues_path(project_slug) <> "/" <> to_string(iid)
  end

  defp issue_notes_path(project_slug, iid) do
    issue_by_project_path(project_slug, iid) <> "/notes"
  end

  defp issue_path(issue_id) do
    with {:ok, project_slug, iid} <- parse_issue_id(issue_id) do
      issue_by_project_path(project_slug, iid)
    else
      _ -> raise ArgumentError, "invalid_gitlab_issue_id: #{inspect(issue_id)}"
    end
  end

  defp parse_issue_id(issue_id) when is_binary(issue_id) do
    case String.split(issue_id, "#", parts: 2) do
      [project_slug, iid] when project_slug != "" and iid != "" -> {:ok, project_slug, iid}
      _ -> {:error, :gitlab_invalid_issue_id}
    end
  end

  defp compose_issue_id(project_slug, iid) when is_binary(project_slug) do
    project_slug <> "#" <> to_string(iid)
  end

  defp issue_identifier(issue, project_slug, iid) do
    get_in(issue, ["references", "relative"]) ||
      get_in(issue, ["references", "full"]) ||
      "#{project_slug}##{iid}"
  end

  defp project_slug_from_issue(issue, fallback_project_slug) do
    get_in(issue, ["references", "full"])
    |> case do
      full when is_binary(full) and full != "" ->
        case String.split(full, "#", parts: 2) do
          [project_slug, _iid] -> project_slug
          _ -> fallback_project_slug
        end

      _ ->
        fallback_project_slug
    end
  end

  defp project_slug_component(project_slug) when is_binary(project_slug) do
    URI.encode(project_slug, &URI.char_unreserved?/1)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end
end
