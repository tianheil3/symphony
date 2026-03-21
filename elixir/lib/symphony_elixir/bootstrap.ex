defmodule SymphonyElixir.Bootstrap do
  @moduledoc """
  Interactive bootstrap flow for installing Symphony into another repository.
  """

  @default_todo_state "Todo"
  @default_in_progress_state "In Progress"
  @default_human_review_state "Human Review"
  @default_rework_state "Rework"
  @default_merging_state "Merging"
  @default_done_state "Done"
  @default_error_doc_path "docs/agent-troubleshooting.md"
  @default_gstack_repo_url "https://github.com/garrytan/gstack.git"
  @default_gstack_ref "main"
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", @default_done_state]
  @always_installed_skills ["commit", "pull"]
  @tracker_providers %{
    "linear" => %{
      key: "linear",
      module: SymphonyElixir.Bootstrap.TrackerProviders.Linear
    },
    "gitlab" => %{
      key: "gitlab",
      module: SymphonyElixir.Bootstrap.TrackerProviders.GitLab
    }
  }
  @forge_providers %{
    "github" => %{
      key: "github",
      display_name: "GitHub",
      module: SymphonyElixir.Bootstrap.ForgeProviders.GitHub,
      supports_automated_pr_flow?: true,
      automated_skill_names: ["push", "land"]
    },
    "gitlab" => %{
      key: "gitlab",
      display_name: "GitLab",
      module: SymphonyElixir.Bootstrap.ForgeProviders.GitLab,
      supports_automated_pr_flow?: true,
      automated_skill_names: ["push", "land"]
    },
    "gitea" => %{
      key: "gitea",
      display_name: "Gitea",
      module: SymphonyElixir.Bootstrap.ForgeProviders.Generic,
      supports_automated_pr_flow?: false,
      automated_skill_names: []
    },
    "none" => %{
      key: "none",
      display_name: "No forge detected",
      module: SymphonyElixir.Bootstrap.ForgeProviders.Generic,
      supports_automated_pr_flow?: false,
      automated_skill_names: []
    }
  }

  @type deps :: %{
          cwd: (-> String.t()),
          detect_git_remote: (String.t() -> String.t() | nil),
          dir?: (String.t() -> boolean()),
          exists?: (String.t() -> boolean()),
          install_gstack_from_github: (String.t(), String.t(), String.t() -> :ok | {:error, String.t()}),
          mkdir_p!: (String.t() -> term()),
          prompt: (String.t() -> String.t() | nil),
          remove_path!: (String.t() -> term()),
          run_gstack_setup: (String.t() -> :ok | {:error, String.t()}),
          say: (String.t() -> term()),
          write_file!: (String.t(), iodata() -> term())
        }

  @type inspection :: %{
          target_root: String.t(),
          repo_name_default: String.t(),
          remote_url: String.t() | nil,
          tracker_provider_default_key: String.t(),
          tracker_provider: map(),
          forge_provider: map(),
          workspace_root_default: String.t(),
          after_create_default: String.t(),
          gstack_repo_url_default: String.t()
        }

  @type plan :: %{
          target_root: String.t(),
          repo_name: String.t(),
          remote_url: String.t() | nil,
          tracker_provider: map(),
          forge_provider: map(),
          project_slug: String.t(),
          workspace_root: String.t(),
          after_create_command: String.t(),
          codex_command: String.t(),
          validation_command: String.t() | nil,
          vendor_gstack?: boolean(),
          gstack_source_root: String.t() | nil,
          gstack_ref: String.t() | nil,
          gstack_target_root: String.t(),
          run_gstack_setup?: boolean(),
          error_doc_path: String.t(),
          hosted_review_flow?: boolean(),
          human_review_polling?: boolean(),
          create_agents?: boolean(),
          create_pr_template?: boolean(),
          project_requirements: String.t() | nil,
          acceptance_criteria: String.t() | nil,
          additional_instructions: String.t() | nil,
          skills: [String.t()],
          active_states: [String.t()],
          terminal_states: [String.t()],
          human_review_state: String.t(),
          rework_state: String.t(),
          merging_state: String.t() | nil,
          done_state: String.t()
        }

  @spec run(String.t() | nil, deps()) :: :ok | {:error, String.t()}
  def run(target_root \\ nil, deps \\ runtime_deps()) do
    expanded_root =
      target_root
      |> default_target_root(deps)
      |> Path.expand()

    with :ok <- ensure_target_root(expanded_root, deps),
         {:ok, inspection} <- inspect_target(expanded_root, deps),
         {:ok, plan} <- build_plan(inspection, deps),
         :ok <- confirm_plan(plan, deps),
         :ok <- install_plan(plan, deps),
         :ok <- verify_installation(plan, deps) do
      deps.say.("")
      deps.say.("Symphony bootstrap complete.")
      deps.say.("Installed files under #{expanded_root}")
      :ok
    else
      {:error, :aborted} -> {:error, "Bootstrap cancelled."}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      cwd: &File.cwd!/0,
      detect_git_remote: &detect_git_remote/1,
      dir?: &File.dir?/1,
      exists?: &File.exists?/1,
      install_gstack_from_github: &install_gstack_from_github/3,
      mkdir_p!: &File.mkdir_p!/1,
      prompt: &IO.gets/1,
      remove_path!: &File.rm_rf!/1,
      run_gstack_setup: &run_gstack_setup/1,
      say: &IO.puts/1,
      write_file!: &File.write!/2
    }
  end

  defp default_target_root(nil, deps), do: deps.cwd.()
  defp default_target_root("", deps), do: deps.cwd.()
  defp default_target_root(target_root, _deps), do: target_root

  defp ensure_target_root(target_root, deps) do
    if deps.dir?.(target_root) do
      :ok
    else
      {:error, "Target repository root does not exist or is not a directory: #{target_root}"}
    end
  end

  defp inspect_target(target_root, deps) do
    repo_name_default = Path.basename(target_root)
    remote_url = deps.detect_git_remote.(target_root)

    {:ok,
     %{
       target_root: target_root,
       repo_name_default: repo_name_default,
       remote_url: remote_url,
       tracker_provider_default_key: default_tracker_provider_key(remote_url),
       tracker_provider: tracker_provider(default_tracker_provider_key(remote_url)),
       forge_provider: detect_forge_provider(remote_url),
       workspace_root_default: default_workspace_root(repo_name_default),
       after_create_default: default_after_create_command(remote_url),
       gstack_repo_url_default: @default_gstack_repo_url
     }}
  end

  defp build_plan(%{} = inspection, deps) do
    repo_name_default = inspection.repo_name_default
    remote_url = inspection.remote_url
    default_workspace_root = inspection.workspace_root_default
    default_after_create = inspection.after_create_default
    forge_provider = inspection.forge_provider

    with {:ok, tracker_provider} <- ask_tracker_provider(inspection, deps),
         {:ok, repo_name} <- ask_text("Repository name", repo_name_default, deps, required: true),
         {:ok, project_slug} <- ask_text(tracker_provider_module(%{tracker_provider: tracker_provider}).project_slug_prompt(), nil, deps, required: true),
         {:ok, workspace_root} <- ask_text("Workspace root", default_workspace_root, deps, required: true),
         {:ok, after_create_command} <-
           ask_text("Workspace bootstrap command", default_after_create, deps, required: true),
         {:ok, codex_command} <- ask_text("Codex command", "codex app-server", deps, required: true),
         {:ok, validation_command} <-
           ask_text("Validation command before handoff", nil, deps, required: false),
         {:ok, vendor_gstack?} <-
           ask_yes_no("Install the full `gstack` skill pack from GitHub into this repo?", true, deps),
         {:ok, gstack_source_root} <- maybe_ask_gstack_source(vendor_gstack?, inspection.gstack_repo_url_default, deps),
         {:ok, gstack_ref} <- maybe_ask_gstack_ref(vendor_gstack?, deps),
         {:ok, run_gstack_setup?} <- maybe_ask_gstack_setup(vendor_gstack?, deps),
         {:ok, hosted_review_flow?} <- ask_hosted_flow(forge_provider, deps),
         {:ok, human_review_polling?} <-
           ask_yes_no("Keep agents active in `Human Review` so they can poll for new comments?", false, deps),
         {:ok, create_agents?} <- ask_yes_no("Create or overwrite `AGENTS.md`?", true, deps),
         {:ok, create_pr_template?} <-
           maybe_ask_pr_template(hosted_review_flow?, forge_provider, deps),
         {:ok, project_requirements} <- ask_multiline("Project requirements", deps),
         {:ok, acceptance_criteria} <- ask_multiline("Default acceptance criteria", deps),
         {:ok, additional_instructions} <- ask_multiline("Additional autonomous instructions", deps) do
      human_review_state = @default_human_review_state
      rework_state = @default_rework_state
      merging_state = if(hosted_review_flow?, do: @default_merging_state, else: nil)
      done_state = @default_done_state
      active_states = build_active_states(hosted_review_flow?, human_review_polling?, human_review_state, rework_state, merging_state)
      skills = build_skill_list(forge_provider, hosted_review_flow?)

      {:ok,
       %{
         target_root: inspection.target_root,
         repo_name: repo_name,
         remote_url: remote_url,
         tracker_provider: tracker_provider,
         forge_provider: forge_provider,
         project_slug: project_slug,
         workspace_root: workspace_root,
         after_create_command: after_create_command,
         codex_command: codex_command,
         validation_command: blank_to_nil(validation_command),
         vendor_gstack?: vendor_gstack?,
         gstack_source_root: gstack_source_root,
         gstack_ref: gstack_ref,
         gstack_target_root: Path.join([inspection.target_root, ".codex", "skills", "gstack"]),
         run_gstack_setup?: run_gstack_setup?,
         error_doc_path: @default_error_doc_path,
         hosted_review_flow?: hosted_review_flow?,
         human_review_polling?: human_review_polling?,
         create_agents?: create_agents?,
         create_pr_template?: create_pr_template?,
         project_requirements: blank_to_nil(project_requirements),
         acceptance_criteria: blank_to_nil(acceptance_criteria),
         additional_instructions: blank_to_nil(additional_instructions),
         skills: skills,
         active_states: active_states,
         terminal_states: @default_terminal_states,
         human_review_state: human_review_state,
         rework_state: rework_state,
         merging_state: merging_state,
         done_state: done_state
       }}
    end
  end

  defp maybe_ask_gstack_source(false, _gstack_root, _deps), do: {:ok, nil}

  defp ask_tracker_provider(inspection, deps) do
    default_key = inspection.tracker_provider_default_key

    case ask_text("Tracker provider (`linear` or `gitlab`)", default_key, deps, required: true) do
      {:ok, key} ->
        normalized_key = String.downcase(String.trim(key))

        case Map.get(@tracker_providers, normalized_key) do
          %{} = provider ->
            {:ok, provider}

          nil ->
            deps.say.("Unsupported tracker provider: #{key}")
            ask_tracker_provider(inspection, deps)
        end

      other ->
        other
    end
  end

  defp maybe_ask_gstack_source(true, gstack_root, deps) do
    ask_text("gstack GitHub repo URL", gstack_root, deps, required: true)
  end

  defp maybe_ask_gstack_ref(false, _deps), do: {:ok, nil}

  defp maybe_ask_gstack_ref(true, deps) do
    ask_text("gstack git ref", @default_gstack_ref, deps, required: true)
  end

  defp maybe_ask_gstack_setup(false, _deps), do: {:ok, false}

  defp maybe_ask_gstack_setup(true, deps) do
    ask_yes_no("Run `gstack/setup --host codex` after vendoring?", true, deps)
  end

  defp ask_hosted_flow(%{module: module} = forge_provider, deps) do
    case module.automation_prompt(forge_provider) do
      prompt when is_binary(prompt) ->
        ask_yes_no(prompt, true, deps)

      _ ->
        ask_hosted_flow_without_automation(forge_provider, deps)
    end
  end

  defp ask_hosted_flow_without_automation(%{display_name: display_name}, deps) do
    deps.say.("")
    deps.say.("Detected forge provider: #{display_name}")
    deps.say.("Automated hosted review flow is not scaffolded for this forge yet; continuing without hosted review automation.")
    {:ok, false}
  end

  defp maybe_ask_pr_template(false, _deps), do: {:ok, false}

  defp maybe_ask_pr_template(true, %{module: module} = forge_provider, deps) do
    if module.pr_template_supported?(forge_provider) do
      ask_yes_no("Create or overwrite `.github/pull_request_template.md`?", true, deps)
    else
      {:ok, false}
    end
  end

  defp maybe_ask_pr_template(true, deps) do
    ask_yes_no("Create or overwrite `.github/pull_request_template.md`?", true, deps)
  end

  defp ask_text(label, default, deps, opts) do
    required? = Keyword.get(opts, :required, false)
    prompt = text_prompt(label, default, required?)

    case deps.prompt.(prompt) do
      nil ->
        {:error, :aborted}

      response ->
        value = response |> String.trim_trailing() |> String.trim()

        cond do
          value != "" ->
            {:ok, value}

          is_binary(default) and String.trim(default) != "" ->
            {:ok, String.trim(default)}

          required? ->
            deps.say.("#{label} is required.")
            ask_text(label, default, deps, opts)

          true ->
            {:ok, nil}
        end
    end
  end

  defp ask_yes_no(label, default, deps) do
    suffix = if(default, do: " [Y/n]: ", else: " [y/N]: ")

    case deps.prompt.(label <> suffix) do
      nil ->
        {:error, :aborted}

      response ->
        normalized =
          response
          |> String.trim_trailing()
          |> String.trim()
          |> String.downcase()

        cond do
          normalized == "" ->
            {:ok, default}

          normalized in ["y", "yes"] ->
            {:ok, true}

          normalized in ["n", "no"] ->
            {:ok, false}

          true ->
            deps.say.("Please answer `yes` or `no`.")
            ask_yes_no(label, default, deps)
        end
    end
  end

  defp ask_multiline(label, deps) do
    deps.say.("")
    deps.say.("#{label}:")
    deps.say.("Enter one or more lines, then finish with a single `.` on its own line.")
    deps.say.("Enter only `.` to skip this section.")

    collect_multiline([], deps)
  end

  defp collect_multiline(lines, deps) do
    case deps.prompt.("> ") do
      nil ->
        {:error, :aborted}

      response ->
        line = String.trim_trailing(response)

        case line do
          "." ->
            value =
              lines
              |> Enum.reverse()
              |> Enum.join("\n")
              |> String.trim()

            {:ok, blank_to_nil(value)}

          _ ->
            collect_multiline([line | lines], deps)
        end
    end
  end

  defp confirm_plan(plan, deps) do
    deps.say.("")
    deps.say.("Bootstrap plan")
    deps.say.("--------------")
    deps.say.("Target root: #{plan.target_root}")
    deps.say.("Repo name: #{plan.repo_name}")
    deps.say.("#{tracker_provider_module(plan).display_name()} project slug: #{plan.project_slug}")
    deps.say.("Workspace root: #{plan.workspace_root}")
    deps.say.("Tracker provider: #{tracker_provider_module(plan).display_name()}")
    deps.say.("Forge provider: #{plan.forge_provider.display_name}")
    deps.say.("Active states: #{Enum.join(plan.active_states, ", ")}")
    deps.say.("Terminal states: #{Enum.join(plan.terminal_states, ", ")}")
    deps.say.("Hosted review workflow: #{yes_no(plan.hosted_review_flow?)}")
    deps.say.("Human Review polling: #{yes_no(plan.human_review_polling?)}")
    deps.say.("Validation command: #{plan.validation_command || "(not configured)"}")
    deps.say.("Skills: #{Enum.join(plan.skills, ", ")}")
    deps.say.("Vendor gstack: #{yes_no(plan.vendor_gstack?)}")

    if plan.vendor_gstack? do
      deps.say.("gstack repo: #{plan.gstack_source_root}")
      deps.say.("gstack ref: #{plan.gstack_ref}")
      deps.say.("gstack target: #{plan.gstack_target_root}")
      deps.say.("Run gstack setup: #{yes_no(plan.run_gstack_setup?)}")
    end

    deps.say.("Error knowledge base: #{plan.error_doc_path}")

    required_states = required_tracker_states(plan)

    if required_states != [] do
      deps.say.("#{tracker_provider_module(plan).display_name()} status expectations: #{Enum.join(required_states, ", ")}")
    end

    deps.say.("")
    deps.say.("Files to create or overwrite:")

    planned_artifacts(plan)
    |> Enum.each(fn artifact ->
      action = if deps.exists?.(artifact.path), do: "update", else: "create"
      deps.say.("- #{action}: #{Path.relative_to(artifact.path, plan.target_root)}")
    end)

    if plan.vendor_gstack? do
      deps.say.("- vendor directory: #{Path.relative_to(plan.gstack_target_root, plan.target_root)}")
    end

    case ask_yes_no("Proceed with installation?", false, deps) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :aborted}
      {:error, _reason} = error -> error
    end
  end

  defp install_plan(plan, deps) do
    planned_artifacts(plan)
    |> Enum.each(fn artifact ->
      deps.mkdir_p!.(Path.dirname(artifact.path))
      deps.write_file!.(artifact.path, artifact.content)
    end)

    with :ok <- maybe_install_gstack(plan, deps) do
      :ok
    end
  rescue
    error in [File.Error] ->
      {:error, "Failed to write bootstrap files: #{Exception.message(error)}"}
  end

  defp verify_installation(plan, deps) do
    artifact_paths =
      planned_artifacts(plan)
      |> Enum.map(& &1.path)

    with :ok <- verify_artifact_paths(artifact_paths, deps),
         :ok <- verify_workflow_file(plan),
         :ok <- verify_gstack_installation(plan, deps) do
      :ok
    end
  end

  defp verify_artifact_paths(paths, deps) when is_list(paths) do
    missing =
      Enum.reject(paths, fn path ->
        deps.exists?.(path)
      end)

    case missing do
      [] -> :ok
      missing_paths -> {:error, "Bootstrap verification failed; missing files: #{Enum.join(missing_paths, ", ")}"}
    end
  end

  defp verify_workflow_file(plan) do
    workflow_path = Path.join(plan.target_root, "WORKFLOW.md")

    with {:ok, %{config: config}} <- SymphonyElixir.Workflow.load(workflow_path),
         {:ok, _parsed} <- SymphonyElixir.Config.Schema.parse(config) do
      :ok
    else
      {:error, reason} ->
        {:error, "Bootstrap verification failed for #{workflow_path}: #{inspect(reason)}"}
    end
  end

  defp verify_gstack_installation(%{vendor_gstack?: false}, _deps), do: :ok

  defp verify_gstack_installation(plan, deps) do
    required_paths = [
      plan.gstack_target_root,
      Path.join(plan.gstack_target_root, "README.md"),
      Path.join(plan.gstack_target_root, "setup")
    ]

    missing =
      Enum.reject(required_paths, fn path ->
        deps.exists?.(path)
      end)

    case missing do
      [] -> :ok
      missing_paths -> {:error, "Bootstrap verification failed for gstack install; missing paths: #{Enum.join(missing_paths, ", ")}"}
    end
  end

  defp maybe_install_gstack(%{vendor_gstack?: false}, _deps), do: :ok

  defp maybe_install_gstack(plan, deps) do
    deps.mkdir_p!.(Path.dirname(plan.gstack_target_root))
    deps.remove_path!.(plan.gstack_target_root)
    deps.install_gstack_from_github.(plan.gstack_source_root, plan.gstack_ref, plan.gstack_target_root)

    if plan.run_gstack_setup? do
      deps.run_gstack_setup.(plan.gstack_target_root)
    else
      :ok
    end
  rescue
    error in [File.Error] ->
      {:error, "Failed to vendor gstack: #{Exception.message(error)}"}
  end

  defp planned_artifacts(plan) do
    workflow = %{path: Path.join(plan.target_root, "WORKFLOW.md"), content: workflow_content(plan)}
    troubleshooting = %{
      path: Path.join(plan.target_root, plan.error_doc_path),
      content: troubleshooting_doc_content(plan)
    }

    common_skill_artifacts =
      plan.skills
      |> Enum.filter(&common_skill_name?/1)
      |> Enum.map(fn skill_name ->
        %{
          path: Path.join([plan.target_root, ".codex", "skills", skill_name, "SKILL.md"]),
          content: skill_content(skill_name, plan)
        }
      end)

    tracker_skill_artifacts = tracker_provider_module(plan).related_skill_artifacts(plan)

    forge_skill_artifacts =
      if plan.hosted_review_flow? do
        forge_provider_module(plan).skill_artifacts(plan)
      else
        []
      end

    base =
      [workflow, troubleshooting]
      |> maybe_append(plan.create_agents?, %{path: Path.join(plan.target_root, "AGENTS.md"), content: agents_content(plan)})
      |> maybe_append(plan.create_pr_template?, %{
        path: Path.join(plan.target_root, ".github/pull_request_template.md"),
        content: pull_request_template_content(plan)
      })

    (base ++ common_skill_artifacts ++ tracker_skill_artifacts ++ forge_skill_artifacts)
  end

  defp maybe_append(list, true, value), do: [value | list]
  defp maybe_append(list, false, _value), do: list

  defp workflow_content(plan) do
    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_provider_module(plan).workflow_kind())}",
        "  api_key: #{yaml_value("$" <> tracker_provider_module(plan).required_secret_name())}",
        "  project_slug: #{yaml_value(plan.project_slug)}",
        "  active_states: #{yaml_value(plan.active_states)}",
        "  terminal_states: #{yaml_value(plan.terminal_states)}",
        "polling:",
        "  interval_ms: 5000",
        "workspace:",
        "  root: #{yaml_value(plan.workspace_root)}",
        "hooks:",
        "  timeout_ms: 60000",
        hook_entry("after_create", plan.after_create_command),
        "agent:",
        "  max_concurrent_agents: 10",
        "  max_turns: 20",
        "codex:",
        "  command: #{yaml_value(plan.codex_command)}",
        "  approval_policy: \"never\"",
        "  thread_sandbox: \"workspace-write\"",
        "  turn_sandbox_policy:",
        "    type: \"workspaceWrite\"",
        "---",
        workflow_prompt(plan)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n") <> "\n"
  end

  defp workflow_prompt(plan) do
    [
      "You are working on a #{tracker_provider_module(plan).display_name()} ticket `{{ issue.identifier }}` in the `#{plan.repo_name}` repository.",
      "",
      "{% if attempt %}",
      "Continuation context:",
      "",
      "- This is retry attempt #{{ attempt }} because the ticket is still active.",
      "- Resume from the existing workspace and current `## Codex Workpad` comment.",
      "- Re-read new #{String.downcase(tracker_provider_module(plan).display_name())} comments and review feedback before making more changes.",
      "{% endif %}",
      "",
      "Issue context:",
      "Identifier: {{ issue.identifier }}",
      "Title: {{ issue.title }}",
      "Current status: {{ issue.state }}",
      "Labels: {{ issue.labels }}",
      "URL: {{ issue.url }}",
      "",
      "Description:",
      "{% if issue.description %}",
      "{{ issue.description }}",
      "{% else %}",
      "No description provided.",
      "{% endif %}",
      "",
      "Repository defaults:",
      "- Validation command before handoff: #{plan.validation_command || "No default validation command configured."}",
      "- Forge provider: #{plan.forge_provider.display_name}",
      "- Hosted review automation: #{bool_label(plan.hosted_review_flow?)}",
      "- Human Review polling: #{human_review_mode_label(plan)}",
      "- Error knowledge base: `#{plan.error_doc_path}`",
      gstack_defaults_line(plan),
      "",
      "Project requirements:",
      optional_markdown_text(plan.project_requirements, "No additional repository-wide requirements were configured."),
      "",
      "Default acceptance criteria:",
      optional_markdown_text(plan.acceptance_criteria, "No default repository-wide acceptance criteria were configured."),
      "",
      "Additional instructions:",
      optional_markdown_text(plan.additional_instructions, "No extra autonomous instructions were configured."),
      "",
      "Operating rules:",
      "1. This is an unattended orchestration session. Never ask a human to do follow-up work for you.",
      "2. Use exactly one persistent #{tracker_provider_module(plan).workpad_label()} named `## Codex Workpad` as the working plan, acceptance checklist, validation log, and blocker brief.",
      "3. Update the workpad before new work, after each meaningful milestone, and before every handoff.",
      "4. Reproduce or capture the baseline behavior before changing code.",
      "5. Every time you hit a meaningful error or discover a reusable fix, append it to `#{plan.error_doc_path}`.",
      "6. Before any handoff, run the required validation for the current scope and record the result in the workpad.",
      "7. Stop early only for true blockers such as missing auth, permissions, or secrets.",
      "8. Work only inside the provided repository copy.",
      "",
      "Related skills:"
    ]
    |> Kernel.++(gstack_skill_lines(plan))
    |> Kernel.++([
      tracker_provider_module(plan).related_skill_line(plan),
      "- `commit`: create clear commits when needed.",
      "- `pull`: merge the latest `origin/main` before final handoff or when conflicts appear."
    ])
    |> maybe_append_lines(plan.hosted_review_flow?, forge_provider_module(plan).related_skill_lines(plan))
    |> Kernel.++([
      "",
      "Skill routing:",
      skill_routing_discovery_line(plan),
      skill_routing_investigate_line(plan),
      skill_routing_qa_line(plan),
      skill_routing_review_line(plan),
      skill_routing_release_line(plan),
      "",
      "Status map:",
      "- `#{@default_todo_state}` -> move immediately to `#{@default_in_progress_state}` and begin execution.",
      "- `#{@default_in_progress_state}` -> implementation is actively underway.",
      status_line_for_human_review(plan),
      "- `#{plan.rework_state}` -> re-read all new human feedback, update the workpad, implement changes, and revalidate."
    ])
    |> maybe_append_lines(plan.hosted_review_flow?, forge_provider_module(plan).status_lines(plan))
    |> Kernel.++([
      "- `#{plan.done_state}` -> terminal state; stop.",
      "",
      "Execution flow:",
      "1. Determine the current issue state and follow the matching branch above.",
      "2. Find or create the single `## Codex Workpad` comment and keep it current in place.",
      "3. Keep `Plan`, `Acceptance Criteria`, `Validation`, and `Notes` sections accurate as reality changes.",
      "4. If the issue is `#{plan.rework_state}`, start by reading all new #{tracker_provider_module(plan).display_name()} comments and any review feedback before editing code.",
      gstack_workflow_line(4, plan),
      execution_flow_line_for_validation(plan)
    ])
    |> Kernel.++(provider_execution_flow_lines(plan))
    |> Kernel.++([
      final_workflow_line(plan)
    ])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp agents_content(plan) do
    sections =
      [
        "# Agent Guide",
        "",
        "## Operating Defaults",
        "",
        gstack_agents_line(plan),
        "- Treat the #{tracker_provider_module(plan).display_name()} issue and the `## Codex Workpad` comment as the source of truth during execution.",
        "- Keep scope tight and document blockers in the workpad instead of asking for manual follow-up work.",
        "- Before handoff, run #{plan.validation_command || "the most relevant validation for the current scope"} and record the result.",
        "- Re-read new human feedback before making more changes after a handoff or review cycle.",
        "- Every meaningful error and fix belongs in `#{plan.error_doc_path}`."
      ]
      |> maybe_append_section("## Project Requirements", plan.project_requirements)
      |> maybe_append_section("## Default Acceptance Criteria", plan.acceptance_criteria)
      |> maybe_append_section("## Additional Instructions", plan.additional_instructions)

    Enum.join(sections, "\n") <> "\n"
  end

  defp pull_request_template_content(plan) do
    validation_line =
      case plan.validation_command do
        nil -> "- [ ] Describe the validation run for this change"
        command -> "- [ ] `#{command}`"
      end

    criteria_lines =
      plan.acceptance_criteria
      |> checklist_lines("- [ ] Define the acceptance criteria for this PR")

    [
      "#### Context",
      "",
      "- Why is this change needed?",
      "",
      "#### Summary",
      "",
      "- What changed?",
      "- What is the user-visible outcome?",
      "",
      "#### Acceptance Criteria",
      "",
      criteria_lines,
      "",
      "#### Test Plan",
      "",
      validation_line,
      "- [ ] Any additional targeted checks for this change"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp skill_content("commit", _plan), do: commit_skill()
  defp skill_content("pull", _plan), do: pull_skill()

  defp commit_skill do
    """
    ---
    name: commit
    description:
      Create a well-formed git commit from current changes using session history for rationale and summary.
    ---

    # Commit

    ## Goals

    - Produce a commit that matches the actual code changes.
    - Use a conventional short subject and a wrapped explanatory body.
    - Include validation results or note when validation was not run.

    ## Steps

    1. Inspect `git status`, `git diff`, and `git diff --staged`.
    2. Stage only the intended files.
    3. Write a conventional commit subject in imperative mood.
    4. In the body, summarize what changed, why it changed, and which validation ran.
    5. Create the commit with a literal multi-line message.

    ## Output

    - One commit whose message reflects the staged change set.
    """
  end

  defp pull_skill do
    """
    ---
    name: pull
    description:
      Pull latest origin/main into the current branch with a merge-based update.
    ---

    # Pull

    ## Workflow

    1. Confirm the working tree is clean or commit first.
    2. Enable rerere locally when available.
    3. Run `git fetch origin`.
    4. Pull the remote branch with `git pull --ff-only origin $(git branch --show-current)`.
    5. Merge `origin/main` with `git -c merge.conflictstyle=zdiff3 merge origin/main`.
    6. Resolve conflicts carefully, rerun validation, and summarize the resolution.
    """
  end

  defp build_skill_list(%{module: module}, true) do
    automated_skill_names = module.automated_skill_names()
    @always_installed_skills ++ automated_skill_names
  end

  defp build_skill_list(_forge_provider, false), do: @always_installed_skills

  defp build_active_states(hosted_review_flow?, human_review_polling?, human_review_state, rework_state, merging_state) do
    base = [@default_todo_state, @default_in_progress_state, rework_state]
    base = if human_review_polling?, do: base ++ [human_review_state], else: base

    case {hosted_review_flow?, merging_state} do
      {true, state} when is_binary(state) -> base ++ [state]
      _ -> base
    end
  end

  defp required_tracker_states(plan), do: tracker_provider_module(plan).initial_status_expectations(plan)

  defp maybe_add_state(states, true, state) when is_binary(state), do: states ++ [state]
  defp maybe_add_state(states, _include?, _state), do: states

  defp text_prompt(label, nil, true), do: "#{label}: "
  defp text_prompt(label, nil, false), do: "#{label} (optional): "
  defp text_prompt(label, default, _required?), do: "#{label} [#{default}]: "

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp bool_label(true), do: "enabled"
  defp bool_label(false), do: "disabled"

  defp human_review_mode_label(%{human_review_polling?: true}), do: "active polling enabled"
  defp human_review_mode_label(_plan), do: "passive handoff only"

  defp status_line_for_human_review(%{human_review_polling?: true, human_review_state: human_review_state}) do
    "- `#{human_review_state}` -> do not make code changes unless new review feedback requires it; poll comments and review signals, then move to `#{@default_rework_state}` or the next handoff state."
  end

  defp status_line_for_human_review(%{human_review_state: human_review_state, hosted_review_flow?: true}) do
    "- `#{human_review_state}` -> passive human handoff; no agent runs in this state. Humans must move the issue to `#{@default_rework_state}` or `#{@default_merging_state}`."
  end

  defp status_line_for_human_review(%{human_review_state: human_review_state}) do
    "- `#{human_review_state}` -> passive human handoff; no agent runs in this state. Humans must move the issue to `#{@default_rework_state}` or `#{@default_done_state}`."
  end

  defp execution_flow_line_for_validation(%{validation_command: nil}) do
    "5. Run the most relevant validation for the current scope before any handoff."
  end

  defp execution_flow_line_for_validation(%{validation_command: command}) do
    "5. Run `#{command}` before any handoff and record the exact result."
  end

  defp provider_execution_flow_lines(%{hosted_review_flow?: true} = plan) do
    forge_provider_module(plan).execution_flow_lines(plan)
  end

  defp provider_execution_flow_lines(_plan) do
    ["6. Use tracker comments and state transitions as the primary handoff surface."]
  end

  defp maybe_append_lines(lines, true, extra), do: lines ++ extra
  defp maybe_append_lines(lines, false, _extra), do: lines

  defp maybe_append_section(lines, _heading, nil), do: lines

  defp maybe_append_section(lines, heading, body) do
    lines ++ ["", heading, "", body]
  end

  defp forge_provider_module(%{forge_provider: %{module: module}}), do: module
  defp tracker_provider_module(%{tracker_provider: %{module: module}}), do: module

  defp common_skill_name?(skill_name) when is_binary(skill_name) do
    skill_name in @always_installed_skills
  end

  defp gstack_defaults_line(%{vendor_gstack?: true, gstack_target_root: gstack_target_root}) do
    "- gstack vendored at `#{gstack_target_root}` and should be used at the appropriate lifecycle stage."
  end

  defp gstack_defaults_line(_plan), do: "- gstack is not vendored for this repo."

  defp gstack_skill_lines(%{vendor_gstack?: true}) do
    [
      "- `gstack /office-hours`: use before coding when the problem, wedge, or acceptance criteria are still fuzzy.",
      "- `gstack /plan-eng-review` and `/plan-design-review`: use after discovery to harden architecture, UX, and test coverage.",
      "- `gstack /investigate`: use when you hit a real bug or runtime error before attempting speculative fixes.",
      "- `gstack /qa` and `/browse`: use for UI, runtime, and end-to-end verification.",
      "- `gstack /review`, `/ship`, and `/document-release`: use before handoff or merge to harden code, publish safely, and refresh docs."
    ]
  end

  defp gstack_skill_lines(_plan), do: []

  defp gstack_workflow_line(step_number, %{vendor_gstack?: true}) do
    "#{step_number}a. Use gstack skills at the appropriate stage: `/office-hours` before coding ambiguous work, `/investigate` for real failures, `/qa` or `/browse` for runtime validation, `/review` before merge, and `/document-release` after shipped behavior changes."
  end

  defp gstack_workflow_line(_step_number, _plan), do: nil

  defp final_workflow_line(%{vendor_gstack?: true}) do
    "8. When work is complete, run any relevant final gstack skills (`/review`, `/ship`, `/document-release`) before moving the issue to the appropriate next state."
  end

  defp final_workflow_line(_plan) do
    "7. When work is complete, move the issue to the appropriate next state instead of posting a separate completion comment."
  end

  defp gstack_agents_line(%{vendor_gstack?: true}) do
    "- gstack is vendored in `.codex/skills/gstack`. Prefer `/office-hours`, `/plan-eng-review`, `/plan-design-review`, `/investigate`, `/qa`, `/browse`, `/review`, `/ship`, and `/document-release` at their matching workflow stages. Use `/browse` for web browsing instead of browser MCP helpers. If the gstack skills stop working, rerun `cd .codex/skills/gstack && ./setup --host codex`."
  end

  defp gstack_agents_line(_plan), do: "- Use the repo-local skills and workflow prompt as the primary operating contract."

  defp skill_routing_discovery_line(%{vendor_gstack?: true}) do
    "- Discovery / ambiguous scope: use `gstack /office-hours` before coding, then `gstack /plan-eng-review` or `/plan-design-review` before implementation."
  end

  defp skill_routing_discovery_line(_plan) do
    "- Discovery / ambiguous scope: update the workpad plan and clarify acceptance criteria before coding."
  end

  defp skill_routing_investigate_line(%{vendor_gstack?: true}) do
    "- Runtime bug / flaky failure / unclear root cause: use `gstack /investigate` before speculative fixes."
  end

  defp skill_routing_investigate_line(_plan) do
    "- Runtime bug / flaky failure / unclear root cause: reproduce first, then investigate before fixing."
  end

  defp skill_routing_qa_line(%{vendor_gstack?: true}) do
    "- UI or end-to-end validation: use `gstack /qa` or `/browse` and record the outcome in the workpad and `#{@default_error_doc_path}` when relevant."
  end

  defp skill_routing_qa_line(_plan) do
    "- UI or end-to-end validation: run the most direct runtime proof available for the changed behavior."
  end

  defp skill_routing_review_line(%{vendor_gstack?: true}) do
    "- Pre-merge hardening: use `gstack /review` after implementation and before final handoff."
  end

  defp skill_routing_review_line(_plan) do
    "- Pre-merge hardening: review the final diff, rerun validation, and make the handoff reviewer-ready."
  end

  defp skill_routing_release_line(%{vendor_gstack?: true, hosted_review_flow?: true} = plan) do
    forge_provider_module(plan).release_skill_routing_line(plan)
  end

  defp skill_routing_release_line(_plan) do
    "- Publish / docs refresh: attach the PR, keep docs current, and move the issue to the right handoff state."
  end

  defp optional_markdown_text(nil, fallback), do: fallback
  defp optional_markdown_text(text, _fallback), do: text

  defp checklist_lines(nil, fallback), do: fallback

  defp checklist_lines(text, _fallback) do
    text
    |> String.split(~r/\R/, trim: true)
    |> Enum.map_join("\n", fn line -> "- [ ] #{String.trim_leading(line, "- ")}" end)
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"
  defp yaml_value(values) when is_list(values), do: "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp troubleshooting_doc_content(plan) do
    [
      "# Agent Troubleshooting Knowledge Base",
      "",
      "Capture meaningful errors here so future agent runs can reuse the fix instead of rediscovering it.",
      "",
      "## How To Use",
      "",
      "- Add one entry per distinct failure pattern.",
      "- Record the symptom, the root cause, the fix or workaround, and how it was validated.",
      "- Update an existing entry when the same issue appears again.",
      "",
      "## Entry Template",
      "",
      "### YYYY-MM-DD - short title",
      "",
      "- Symptom:",
      "- Root cause:",
      "- Fix or workaround:",
      "- Validation:",
      "- Related files / commands:",
      "",
      "## Bootstrap Defaults",
      "",
      "- Validation command: #{plan.validation_command || "not configured"}",
      "- Tracker provider: #{tracker_provider_module(plan).display_name()}",
      "- Forge provider: #{plan.forge_provider.display_name}",
      "- Hosted review automation: #{bool_label(plan.hosted_review_flow?)}",
      "- gstack vendored: #{yes_no(plan.vendor_gstack?)}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp default_workspace_root(repo_name) do
    "~/" <> Path.join(["code", sanitized_repo_name(repo_name) <> "-workspaces"])
  end

  defp sanitized_repo_name(repo_name) when is_binary(repo_name) do
    repo_name
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      normalized -> normalized
    end
  end

  defp default_after_create_command(nil), do: "git clone --depth 1 <repo-url> ."
  defp default_after_create_command(remote_url), do: "git clone --depth 1 #{remote_url} ."

  defp default_tracker_provider_key(remote_url) when is_binary(remote_url) do
    case detect_forge_provider(remote_url) do
      %{key: "gitlab"} -> "gitlab"
      _ -> "linear"
    end
  end

  defp default_tracker_provider_key(_remote_url), do: "linear"

  defp tracker_provider(key) when is_binary(key) do
    Map.fetch!(@tracker_providers, key)
  end

  defp detect_forge_provider(remote_url) when is_binary(remote_url) do
    normalized = String.downcase(String.trim(remote_url))

    cond do
      String.contains?(normalized, "github.com") -> forge_provider("github")
      String.contains?(normalized, "gitlab") -> forge_provider("gitlab")
      String.contains?(normalized, "gitea") -> forge_provider("gitea")
      true -> forge_provider("none")
    end
  end

  defp detect_forge_provider(_remote_url), do: forge_provider("none")

  defp forge_provider(key) when is_binary(key) do
    Map.fetch!(@forge_providers, key)
  end

  defp install_gstack_from_github(repo_url, ref, target_root)
       when is_binary(repo_url) and is_binary(target_root) do
    case System.find_executable("git") do
      nil ->
        {:error, "Unable to install gstack automatically because `git` is not available in PATH."}

      git ->
        args =
          ["clone", "--depth", "1"]
          |> maybe_append_git_ref(ref)
          |> Kernel.++([repo_url, target_root])

        case System.cmd(git, args, stderr_to_stdout: true) do
          {_output, 0} ->
            :ok

          {output, status} ->
            message =
              output
              |> String.trim()
              |> case do
                "" -> "git clone exited with status #{status}."
                text -> "git clone exited with status #{status}: #{text}"
              end

            {:error, message}
        end
    end
  end

  defp run_gstack_setup(gstack_root) when is_binary(gstack_root) do
    case System.find_executable("bash") do
      nil ->
        {:error, "Unable to run gstack setup automatically because `bash` is not available in PATH."}

      bash ->
        case System.cmd(bash, ["setup", "--host", "codex"], cd: gstack_root, stderr_to_stdout: true) do
          {_output, 0} ->
            :ok

          {output, status} ->
            message =
              output
              |> String.trim()
              |> case do
                "" -> "gstack setup exited with status #{status}."
                text -> "gstack setup exited with status #{status}: #{text}"
              end

            {:error, message}
        end
    end
  end

  defp maybe_append_git_ref(args, ref) when is_binary(ref) do
    trimmed = String.trim(ref)
    if trimmed == "", do: args, else: args ++ ["--branch", trimmed]
  end

  defp maybe_append_git_ref(args, _ref), do: args

  defp detect_git_remote(target_root) when is_binary(target_root) do
    case System.find_executable("git") do
      nil ->
        nil

      git ->
        case System.cmd(git, ["-C", target_root, "remote", "get-url", "origin"], stderr_to_stdout: true) do
          {output, 0} ->
            case String.trim(output) do
              "" -> nil
              remote_url -> remote_url
            end

          _ ->
            nil
        end
    end
  end
end
