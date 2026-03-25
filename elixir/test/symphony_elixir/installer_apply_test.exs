defmodule SymphonyElixir.InstallerApplyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Installer.Inspector
  alias SymphonyElixir.Installer.Render

  test "inspect_target!/2 infers GitHub defaults for supported remotes" do
    target_root = temp_repo_root!("installer-inspector-github")

    deps = %{
      detect_git_remote: fn ^target_root -> "git@github.com:example/demo.git" end
    }

    assert {:ok, inspection} = Inspector.inspect_target!(target_root, deps)
    assert inspection.target_root == target_root
    assert inspection.remote_url == "git@github.com:example/demo.git"
    assert inspection.repo_name_default == Path.basename(target_root)
    assert inspection.tracker_provider_default_key == "linear"
    assert inspection.tracker_provider.module == SymphonyElixir.Installer.TrackerProviders.Linear
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
end
