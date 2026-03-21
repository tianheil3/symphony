defmodule SymphonyElixir.BootstrapTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Bootstrap

  test "bootstrap installs workflow, agents guide, PR template, and GitHub skills" do
    target_root = temp_repo_root!("bootstrap-github")
    gstack_root = gstack_fixture_root!("gstack-pack")

    deps =
      deps_with_responses(
        [
          "\n",
          "\n",
          "demo-project\n",
          "\n",
          "\n",
          "\n",
          "make test\n",
          "\n",
          "\n",
          "\n",
          "\n",
          "\n",
          "\n",
          "\n",
          "\n",
          "Keep CI green.\n",
          ".\n",
          "Manual smoke test passes.\n",
          ".\n",
          ".\n",
          "y\n"
        ],
        git_remote: "git@github.com:example/demo.git",
        gstack_root: gstack_root,
        run_gstack_setup: fn vendored_root ->
          File.write!(Path.join(vendored_root, "SETUP_OK"), "ok")
          :ok
        end
      )

    assert :ok = Bootstrap.run(target_root, deps)

    workflow = File.read!(Path.join(target_root, "WORKFLOW.md"))
    agents = File.read!(Path.join(target_root, "AGENTS.md"))
    troubleshooting = File.read!(Path.join(target_root, "docs/agent-troubleshooting.md"))
    pr_template = File.read!(Path.join(target_root, ".github/pull_request_template.md"))
    push_skill = File.read!(Path.join([target_root, ".codex", "skills", "push", "SKILL.md"]))
    land_skill = File.read!(Path.join([target_root, ".codex", "skills", "land", "SKILL.md"]))
    vendored_gstack_readme = File.read!(Path.join([target_root, ".codex", "skills", "gstack", "README.md"]))

    assert workflow =~ "project_slug: \"demo-project\""
    assert workflow =~ "kind: \"linear\""
    assert workflow =~ "git clone --depth 1 git@github.com:example/demo.git ."
    assert workflow =~ "\"Human Review\""
    assert workflow =~ "\"Merging\""
    assert workflow =~ "Validation command before handoff: make test"
    assert workflow =~ "Forge provider: GitHub"
    assert workflow =~ "gstack vendored at"
    assert workflow =~ "Use gstack skills at the appropriate stage"
    assert workflow =~ "Keep CI green."
    assert workflow =~ "Manual smoke test passes."

    assert agents =~ "gstack is vendored in `.codex/skills/gstack`"
    assert troubleshooting =~ "Agent Troubleshooting Knowledge Base"
    assert agents =~ "Keep CI green."
    assert agents =~ "Manual smoke test passes."
    assert pr_template =~ "`make test`"
    assert push_skill =~ "Run `make test` before pushing."
    assert land_skill =~ "Confirm `make test` is green before merging."
    assert vendored_gstack_readme =~ "fixture gstack"
    assert File.exists?(Path.join([target_root, ".codex", "skills", "gstack", "SETUP_OK"]))
  end

  test "bootstrap can install a non-GitHub workflow without PR assets" do
    target_root = temp_repo_root!("bootstrap-local")

    deps =
      deps_with_responses(
        [
          "\n",
          "Custom Repo\n",
          "local-project\n",
          "~/code/custom-repo-workspaces\n",
          "git clone --depth 1 ssh://example/custom.git .\n",
          "codex app-server --model gpt-5.3-codex\n",
          "\n",
          "n\n",
          "n\n",
          "n\n",
          "No extra requirements.\n",
          ".\n",
          ".\n",
          ".\n",
          "y\n"
        ],
        git_remote: nil,
        gstack_root: nil
      )

    assert :ok = Bootstrap.run(target_root, deps)

    workflow = File.read!(Path.join(target_root, "WORKFLOW.md"))

    assert workflow =~ "project_slug: \"local-project\""
    assert workflow =~ "kind: \"linear\""
    assert workflow =~ "root: \"~/code/custom-repo-workspaces\""
    assert workflow =~ "codex app-server --model gpt-5.3-codex"
    assert workflow =~ "Forge provider: No forge detected"
    assert workflow =~ "gstack is not vendored for this repo."
    refute workflow =~ "\"Human Review\""
    refute workflow =~ "\"Merging\""

    assert File.exists?(Path.join([target_root, ".codex", "skills", "commit", "SKILL.md"]))
    assert File.exists?(Path.join([target_root, ".codex", "skills", "pull", "SKILL.md"]))
    assert File.exists?(Path.join([target_root, ".codex", "skills", "linear", "SKILL.md"]))
    refute File.exists?(Path.join([target_root, ".codex", "skills", "push", "SKILL.md"]))
    refute File.exists?(Path.join([target_root, ".codex", "skills", "land", "SKILL.md"]))
    refute File.exists?(Path.join([target_root, ".codex", "skills", "gstack"]))
    refute File.exists?(Path.join(target_root, "AGENTS.md"))
    refute File.exists?(Path.join(target_root, ".github/pull_request_template.md"))
  end

  test "bootstrap can scaffold a GitLab MR workflow" do
    target_root = temp_repo_root!("bootstrap-gitlab")

    deps =
      deps_with_responses(
        [
          "\n",
          "\n",
          "group/project\n",
          "\n",
          "\n",
          "\n",
          "mix test\n",
          "n\n",
          "y\n",
          "n\n",
          "n\n",
          "Track MR review notes.\n",
          ".\n",
          ".\n",
          ".\n",
          "y\n"
        ],
        git_remote: "https://gitlab.com/example/demo.git",
        gstack_root: nil
      )

    assert :ok = Bootstrap.run(target_root, deps)

    workflow = File.read!(Path.join(target_root, "WORKFLOW.md"))
    gitlab_skill = File.read!(Path.join([target_root, ".codex", "skills", "gitlab", "SKILL.md"]))
    push_skill = File.read!(Path.join([target_root, ".codex", "skills", "push", "SKILL.md"]))
    land_skill = File.read!(Path.join([target_root, ".codex", "skills", "land", "SKILL.md"]))

    assert workflow =~ "Forge provider: GitLab"
    assert workflow =~ "kind: \"gitlab\""
    assert workflow =~ "Hosted review automation: enabled"
    assert workflow =~ "merge request"
    assert gitlab_skill =~ "glab"
    assert push_skill =~ "GitLab merge request"
    assert push_skill =~ "glab mr"
    assert land_skill =~ "GitLab merge request"
    assert land_skill =~ "glab mr merge"
    refute File.exists?(Path.join([target_root, ".codex", "skills", "linear", "SKILL.md"]))
    refute File.exists?(Path.join(target_root, ".github/pull_request_template.md"))
  end

  defp deps_with_responses(responses, opts) when is_list(responses) and is_list(opts) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    on_exit(fn ->
      if Process.alive?(agent) do
        Agent.stop(agent)
      end
    end)

    git_remote = Keyword.get(opts, :git_remote)
    gstack_root = Keyword.get(opts, :gstack_root)
    install_gstack_from_github =
      Keyword.get(opts, :install_gstack_from_github, fn _repo_url, _ref, target_root ->
        if is_binary(gstack_root) do
          File.cp_r!(gstack_root, target_root)
        end

        :ok
      end)
    run_gstack_setup = Keyword.get(opts, :run_gstack_setup, fn _vendored_root -> :ok end)

    %{
      cwd: &File.cwd!/0,
      detect_git_remote: fn _target_root -> git_remote end,
      dir?: &File.dir?/1,
      exists?: &File.exists?/1,
      install_gstack_from_github: install_gstack_from_github,
      mkdir_p!: &File.mkdir_p!/1,
      prompt: fn _prompt ->
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {nil, []}
        end)
      end,
      remove_path!: &File.rm_rf!/1,
      run_gstack_setup: run_gstack_setup,
      say: fn _message -> :ok end,
      write_file!: &File.write!/2
    }
  end

  defp temp_repo_root!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-bootstrap-test-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    root
  end

  defp gstack_fixture_root!(suffix) do
    root = temp_repo_root!("gstack-fixture-" <> suffix)
    File.mkdir_p!(Path.join(root, "browse/dist"))
    File.write!(Path.join(root, "README.md"), "fixture gstack\n")
    File.write!(Path.join(root, "setup"), "#!/usr/bin/env bash\nexit 0\n")
    root
  end
end
