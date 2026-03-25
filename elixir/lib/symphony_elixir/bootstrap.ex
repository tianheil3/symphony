defmodule SymphonyElixir.Bootstrap do
  @moduledoc """
  Interactive bootstrap flow for installing Symphony into another repository.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Installer.Inspector
  alias SymphonyElixir.Installer.Render

  @default_todo_state "Todo"
  @default_in_progress_state "In Progress"
  @default_human_review_state "Human Review"
  @default_rework_state "Rework"
  @default_merging_state "Merging"
  @default_done_state "Done"
  @default_error_doc_path "docs/agent-troubleshooting.md"
  @default_gstack_ref "main"
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", @default_done_state]
  @always_installed_skills ["commit", "pull"]

  @type deps :: %{
          command_available?: (String.t() -> boolean()),
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
      {:error, {:unsupported_target_repo, _remote_url, _reason} = error} -> {:error, error}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      cwd: &File.cwd!/0,
      command_available?: &(not is_nil(System.find_executable(&1))),
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
    Inspector.inspect_target!(target_root, deps)
  end

  defp build_plan(%{} = inspection, deps) do
    repo_name_default = inspection.repo_name_default
    remote_url = inspection.remote_url
    default_workspace_root = inspection.workspace_root_default
    default_after_create = inspection.after_create_default
    forge_provider = inspection.forge_provider

    with {:ok, tracker_provider} <- ask_tracker_provider(inspection, deps),
         {:ok, repo_name} <- ask_text("Repository name", repo_name_default, deps, required: true),
         {:ok, project_slug} <-
           ask_text(
             tracker_provider_module(%{tracker_provider: tracker_provider}).project_slug_prompt(),
             nil,
             deps,
             required: true
           ),
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

      active_states =
        build_active_states(
          hosted_review_flow?,
          human_review_polling?,
          human_review_state,
          rework_state,
          merging_state
        )

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

  defp ask_tracker_provider(inspection, deps) do
    default_key = inspection.tracker_provider_default_key

    case ask_text("Tracker provider (`linear`, `gitlab`, or `github`)", default_key, deps, required: true) do
      {:ok, key} ->
        normalized_key = String.downcase(String.trim(key))

        case Inspector.tracker_provider_lookup(normalized_key) do
          {:ok, provider} ->
            {:ok, provider}

          {:error, _reason} ->
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

  defp maybe_ask_gstack_source(false, _gstack_root, _deps), do: {:ok, nil}

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

  defp maybe_ask_pr_template(hosted_review_flow?, %{module: module} = forge_provider, deps) do
    cond do
      not hosted_review_flow? ->
        {:ok, false}

      module.pr_template_supported?(forge_provider) ->
        ask_yes_no("Create or overwrite `.github/pull_request_template.md`?", true, deps)

      true ->
        {:ok, false}
    end
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
    deps.say.("Forge support level: #{forge_support_level(plan.forge_provider)}")
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

    Render.planned_artifacts(plan)
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
    Render.planned_artifacts(plan)
    |> Enum.each(fn artifact ->
      artifact_dir = Path.dirname(artifact.path)
      deps.mkdir_p!.(artifact_dir)
      deps.write_file!.(artifact.path, artifact.content)
    end)

    maybe_install_gstack(plan, deps)
  rescue
    error in [File.Error] ->
      {:error, "Failed to write bootstrap files: #{Exception.message(error)}"}
  end

  defp verify_installation(plan, deps) do
    artifact_paths =
      Render.planned_artifacts(plan)
      |> Enum.map(& &1.path)

    with :ok <- verify_artifact_paths(artifact_paths, deps),
         :ok <- verify_workflow_file(plan),
         :ok <- verify_gstack_installation(plan, deps) do
      verify_hosted_review_tooling(plan, deps)
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
         {:ok, _parsed} <- Schema.parse(config) do
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

  defp verify_hosted_review_tooling(%{hosted_review_flow?: false}, _deps), do: :ok

  defp verify_hosted_review_tooling(%{forge_provider: %{key: "github"}} = plan, deps) do
    cond do
      not deps.command_available?.("gh") ->
        {:error, "Bootstrap verification failed for GitHub golden path; `gh` is not available in PATH."}

      plan.create_pr_template? and not deps.exists?.(Path.join(plan.target_root, ".github/pull_request_template.md")) ->
        {:error, "Bootstrap verification failed for GitHub golden path; PR template is missing."}

      true ->
        :ok
    end
  end

  defp verify_hosted_review_tooling(%{forge_provider: %{key: "gitlab"}}, deps) do
    if deps.command_available?.("glab") do
      :ok
    else
      {:error, "Bootstrap verification failed for GitLab review flow; `glab` is not available in PATH."}
    end
  end

  defp verify_hosted_review_tooling(_plan, _deps), do: :ok

  defp maybe_install_gstack(%{vendor_gstack?: false}, _deps), do: :ok

  defp maybe_install_gstack(plan, deps) do
    gstack_parent_dir = Path.dirname(plan.gstack_target_root)
    deps.mkdir_p!.(gstack_parent_dir)
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

  defp text_prompt(label, nil, true), do: "#{label}: "
  defp text_prompt(label, nil, false), do: "#{label} (optional): "
  defp text_prompt(label, default, _required?), do: "#{label} [#{default}]: "

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp tracker_provider_module(%{tracker_provider: %{module: module}}), do: module

  defp forge_support_level(%{key: "github"}), do: "recommended"
  defp forge_support_level(%{key: "gitlab"}), do: "preview"
  defp forge_support_level(_provider), do: "basic"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
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
            message = command_failure_message("git clone", status, output)

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
            message = command_failure_message("gstack setup", status, output)

            {:error, message}
        end
    end
  end

  defp maybe_append_git_ref(args, ref) when is_binary(ref) do
    trimmed = String.trim(ref)
    if trimmed == "", do: args, else: args ++ ["--branch", trimmed]
  end

  defp maybe_append_git_ref(args, _ref), do: args

  defp command_failure_message(command, status, output) do
    case String.trim(output) do
      "" -> "#{command} exited with status #{status}."
      text -> "#{command} exited with status #{status}: #{text}"
    end
  end

  defp detect_git_remote(target_root) when is_binary(target_root) do
    case System.find_executable("git") do
      nil ->
        nil

      git ->
        detect_git_remote_with(git, target_root)
    end
  end

  defp detect_git_remote_with(git, target_root) do
    case System.cmd(git, ["-C", target_root, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} -> normalize_remote_url(output)
      _ -> nil
    end
  end

  defp normalize_remote_url(output) do
    case String.trim(output) do
      "" -> nil
      remote_url -> remote_url
    end
  end
end
