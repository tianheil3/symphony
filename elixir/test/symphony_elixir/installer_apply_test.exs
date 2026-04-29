defmodule SymphonyElixir.InstallerApplyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Installer.Apply
  alias SymphonyElixir.Installer.Inspector
  alias SymphonyElixir.Installer.Render
  alias SymphonyElixir.Installer.SessionState
  alias SymphonyElixir.TestSupport

  test "inspect_target!/2 infers GitHub defaults for supported remotes" do
    target_root = temp_repo_root!("installer-inspector-github")

    deps = %{
      detect_git_remote: fn ^target_root -> "git@github.com:example/demo.git" end
    }

    assert {:ok, inspection} = Inspector.inspect_target!(target_root, deps)
    assert inspection.target_root == target_root
    assert inspection.remote_url == "git@github.com:example/demo.git"
    assert inspection.repo_name_default == Path.basename(target_root)
    assert inspection.tracker_provider_default_key == "github"
    assert inspection.tracker_provider.module == SymphonyElixir.Installer.TrackerProviders.GitHub
    assert inspection.forge_provider.key == "github"
    assert inspection.forge_provider.module == SymphonyElixir.Installer.ForgeProviders.GitHub
  end

  test "inspect_target!/2 returns explicit unsupported target tuple for non-GitHub remotes" do
    target_root = temp_repo_root!("installer-inspector-unsupported")
    remote_url = "https://gitlab.com/example/demo.git"

    deps = %{detect_git_remote: fn ^target_root -> remote_url end}

    assert {:error, {:unsupported_target_repo, ^remote_url, "GitHub ordinary repos only in v1"}} =
             Inspector.inspect_target!(target_root, deps)
  end

  test "inspect_target!/2 returns explicit unsupported target tuple when remote is missing" do
    target_root = temp_repo_root!("installer-inspector-no-remote")
    deps = %{detect_git_remote: fn ^target_root -> nil end}

    assert {:error, {:unsupported_target_repo, nil, "GitHub ordinary repos only in v1"}} =
             Inspector.inspect_target!(target_root, deps)
  end

  test "planned_artifacts/1 includes workflow and GitHub skill artifacts" do
    target_root = temp_repo_root!("installer-render")

    artifacts =
      target_root
      |> github_plan()
      |> Render.planned_artifacts()

    assert Enum.any?(artifacts, &String.ends_with?(&1.path, "WORKFLOW.md"))
    assert Enum.any?(artifacts, &String.ends_with?(&1.path, ".codex/skills/github/SKILL.md"))

    workflow_artifact =
      Enum.find(artifacts, fn artifact ->
        String.ends_with?(artifact.path, "WORKFLOW.md")
      end)

    assert workflow_artifact.content =~ "Forge provider: GitHub"
    assert workflow_artifact.content =~ "Validation command before handoff: mix test"
    assert workflow_artifact.content =~ "max_concurrent_agents: 5"
    assert workflow_artifact.content =~ "networkAccess: true"
    assert workflow_artifact.content =~ "Progress SLA"
    assert workflow_artifact.content =~ "Create or refresh `## Codex Workpad` within 5 minutes"
    assert workflow_artifact.content =~ "update the same workpad at least every 20 minutes"
  end

  test "planned_artifacts/1 renders starter profile with conservative real-project defaults" do
    target_root = temp_repo_root!("installer-render-starter-profile")

    artifacts =
      target_root
      |> github_plan()
      |> Map.merge(%{
        workflow_profile: "starter",
        hosted_review_flow?: false,
        human_review_polling?: false,
        skills: ["commit", "pull", "push"],
        validation_command: nil,
        merging_state: nil
      })
      |> Map.drop([:active_states, :terminal_states])
      |> Render.planned_artifacts()

    workflow = workflow_content_from_artifacts(artifacts)

    assert workflow =~ "Workflow profile: starter"
    assert workflow =~ "active_states: [\"Todo\", \"In Progress\"]"
    assert workflow =~ "max_concurrent_agents: 1"
    assert workflow =~ "max_turns: 10"
    assert workflow =~ "Run the most relevant validation for the current scope"
    assert workflow =~ "Create or update a PR/MR for code changes"
    assert workflow =~ "Do not auto-merge by default."
    refute workflow =~ "Merging"
    refute Enum.any?(artifacts, &String.ends_with?(&1.path, ".codex/skills/land/SKILL.md"))
  end

  test "planned_artifacts/1 renders review-gated profile without enabling land flow" do
    target_root = temp_repo_root!("installer-render-review-gated-profile")

    artifacts =
      target_root
      |> github_plan()
      |> Map.merge(%{
        workflow_profile: "review-gated",
        hosted_review_flow?: false,
        human_review_polling?: true,
        skills: ["commit", "pull", "push"],
        merging_state: nil
      })
      |> Map.drop([:active_states, :terminal_states])
      |> Render.planned_artifacts()

    workflow = workflow_content_from_artifacts(artifacts)

    assert workflow =~ "Workflow profile: review-gated"
    assert workflow =~ "active_states: [\"Todo\", \"In Progress\", \"Human Review\", \"Rework\"]"
    assert workflow =~ "max_concurrent_agents: 1"
    assert workflow =~ "max_turns: 12"
    assert workflow =~ "sweep all new PR review feedback"
    assert workflow =~ "Do not auto-merge by default."
    refute workflow =~ "Merging"
    refute workflow =~ "land"
    refute Enum.any?(artifacts, &String.ends_with?(&1.path, ".codex/skills/land/SKILL.md"))
  end

  test "planned_artifacts/1 omits optional agents and PR template artifacts when disabled" do
    target_root = temp_repo_root!("installer-render-optional-disabled")

    artifacts =
      target_root
      |> github_plan()
      |> Map.merge(%{create_agents?: false, create_pr_template?: false})
      |> Render.planned_artifacts()

    refute Enum.any?(artifacts, &String.ends_with?(&1.path, "AGENTS.md"))
    refute Enum.any?(artifacts, &String.ends_with?(&1.path, ".github/pull_request_template.md"))
  end

  test "run/2 writes request/state and launch_verified event on successful launch verification" do
    parent = self()
    repo_root = TestSupport.create_temp_git_repo!("installer-apply-run-success")
    workflow_path = Path.expand(Path.join(repo_root, "WORKFLOW.md"))
    launch_pid = spawn_sleeping_process()

    on_exit(fn ->
      if Process.alive?(launch_pid) do
        Process.exit(launch_pid, :kill)
      end
    end)

    manifest = %{
      target_repo: repo_root,
      durable_assets: %{
        "files" => %{
          "WORKFLOW.md" => "---\ntracker:\n  kind: linear\n---\nPrompt\n"
        }
      }
    }

    launch_verifier_deps = %{
      resolve_tool: fn _ -> "/opt/tools/fake" end,
      get_env: fn
        "GITHUB_TOKEN" -> "token"
        _ -> nil
      end,
      parse_generated_assets: fn assets ->
        send(parent, {:generated_assets, assets})
        :ok
      end,
      launch_command: fn _ -> {:ok, launch_pid} end,
      process_running?: &Process.alive?/1,
      probe_health_surface: fn _ -> :ok end,
      sleep: fn _ -> :ok end
    }

    assert :ok =
             Apply.run(
               manifest,
               required_env: ["GITHUB_TOKEN"],
               launch_verifier_deps: launch_verifier_deps
             )

    assert_received {:generated_assets, [%{kind: :workflow, path: ^workflow_path}]}
    assert %{"phase" => "verified"} = TestSupport.read_installer_state!(repo_root)

    assert Enum.any?(TestSupport.read_installer_events!(repo_root), fn event ->
             event["event"] == "launch_verified"
           end)
  end

  test "run/2 records failed state and launch_blocked event when launch verification fails" do
    repo_root = TestSupport.create_temp_git_repo!("installer-apply-run-failure")
    launch_pid = spawn_sleeping_process()

    on_exit(fn ->
      if Process.alive?(launch_pid) do
        Process.exit(launch_pid, :kill)
      end
    end)

    manifest = %{
      target_repo: repo_root,
      durable_assets: %{"files" => %{"WORKFLOW.md" => "placeholder"}}
    }

    launch_verifier_deps = %{
      resolve_tool: fn _ -> "/opt/tools/fake" end,
      get_env: fn _ -> nil end,
      parse_generated_assets: fn _ -> :ok end,
      launch_command: fn _ -> {:ok, launch_pid} end,
      process_running?: &Process.alive?/1,
      probe_health_surface: fn _ -> :ok end,
      sleep: fn _ -> :ok end
    }

    assert {:error, {:launch_blocked, :missing_token, "GITHUB_TOKEN"}} =
             Apply.run(
               manifest,
               required_env: ["GITHUB_TOKEN"],
               launch_verifier_deps: launch_verifier_deps
             )

    assert %{"phase" => "failed", "reason" => reason} = TestSupport.read_installer_state!(repo_root)
    assert reason =~ "{:launch_blocked, :missing_token, \"GITHUB_TOKEN\"}"

    assert Enum.any?(TestSupport.read_installer_events!(repo_root), fn event ->
             event["event"] == "launch_blocked"
           end)
  end

  test "run/2 emits resume_detected when previous session phase is apply_started" do
    repo_root = TestSupport.create_temp_git_repo!("installer-apply-run-resume")
    launch_pid = spawn_sleeping_process()

    on_exit(fn ->
      if Process.alive?(launch_pid) do
        Process.exit(launch_pid, :kill)
      end
    end)

    assert :ok = SessionState.write_state(repo_root, %{"phase" => "apply_started"})

    manifest = %{
      target_repo: repo_root,
      durable_assets: %{"files" => %{"WORKFLOW.md" => "placeholder"}}
    }

    launch_verifier_deps = %{
      resolve_tool: fn _ -> "/opt/tools/fake" end,
      get_env: fn
        "GITHUB_TOKEN" -> "token"
        _ -> nil
      end,
      parse_generated_assets: fn _ -> :ok end,
      launch_command: fn _ -> {:ok, launch_pid} end,
      process_running?: &Process.alive?/1,
      probe_health_surface: fn _ -> :ok end,
      sleep: fn _ -> :ok end
    }

    assert :ok =
             Apply.run(
               manifest,
               required_env: ["GITHUB_TOKEN"],
               launch_verifier_deps: launch_verifier_deps
             )

    assert Enum.any?(TestSupport.read_installer_events!(repo_root), fn event ->
             event["event"] == "resume_detected" and event["from_phase"] == "apply_started"
           end)
  end

  defp github_plan(target_root) do
    %{
      target_root: target_root,
      repo_name: "demo",
      remote_url: "git@github.com:example/demo.git",
      tracker_provider: %{key: "github", module: SymphonyElixir.Installer.TrackerProviders.GitHub},
      forge_provider: %{key: "github", display_name: "GitHub", module: SymphonyElixir.Installer.ForgeProviders.GitHub},
      project_slug: "example/demo",
      workspace_root: "~/code/demo-workspaces",
      after_create_command: "git clone --depth 1 git@github.com:example/demo.git .",
      codex_command: "codex app-server",
      validation_command: "mix test",
      vendor_gstack?: false,
      gstack_source_root: nil,
      gstack_ref: nil,
      gstack_target_root: Path.join([target_root, ".codex", "skills", "gstack"]),
      run_gstack_setup?: false,
      error_doc_path: "docs/agent-troubleshooting.md",
      hosted_review_flow?: true,
      human_review_polling?: false,
      create_agents?: true,
      create_pr_template?: true,
      project_requirements: nil,
      acceptance_criteria: nil,
      additional_instructions: nil,
      skills: ["commit", "pull", "push", "land"],
      active_states: ["Todo", "In Progress", "Rework", "Merging"],
      terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      human_review_state: "Human Review",
      rework_state: "Rework",
      merging_state: "Merging",
      done_state: "Done"
    }
  end

  defp workflow_content_from_artifacts(artifacts) do
    artifacts
    |> Enum.find(fn artifact -> String.ends_with?(artifact.path, "WORKFLOW.md") end)
    |> Map.fetch!(:content)
    |> IO.iodata_to_binary()
  end

  defp temp_repo_root!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-installer-apply-test-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    root
  end

  defp spawn_sleeping_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      after
        5_000 -> :ok
      end
    end)
  end
end
