defmodule SymphonyElixir.InstallerIntegrationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Installer
  alias SymphonyElixir.Installer.Inspector
  alias SymphonyElixir.Installer.SessionState
  alias SymphonyElixir.TestSupport

  test "repo-first install reaches launch verified in a temp GitHub repo" do
    repo_root = TestSupport.create_temp_git_repo!("installer-integration-first-launch")
    workflow_path = Path.expand(Path.join(repo_root, "WORKFLOW.md"))
    launch_pid = spawn_sleeping_process()

    on_exit(fn ->
      if Process.alive?(launch_pid) do
        Process.exit(launch_pid, :kill)
      end
    end)

    assert {:ok, manifest_path} =
             repo_first_preflight_install(
               repo_root,
               %{
                 "durable_assets" => %{
                   "files" => %{
                     "WORKFLOW.md" => "---\ntracker:\n  kind: linear\n---\nPrompt\n"
                   }
                 }
               },
               required_tools: ["git", "gh"],
               required_env: ["GITHUB_TOKEN"],
               command: ["./bin/symphony", "./WORKFLOW.md"],
               dashboard_url: "http://127.0.0.1:4000/api/v1/state",
               launch_verifier_deps: successful_launch_verifier_deps(self(), launch_pid)
             )

    assert manifest_path == TestSupport.installer_manifest_input_path(repo_root)
    refute manifest_path == SessionState.paths(repo_root).request
    assert %{"target_repo" => ^repo_root} = TestSupport.read_installer_request!(repo_root)
    assert File.regular?(workflow_path)
    assert %{"phase" => "verified"} = TestSupport.read_installer_state!(repo_root)

    assert Enum.any?(TestSupport.read_installer_events!(repo_root), fn event ->
             event["event"] == "launch_verified"
           end)

    assert_received {:generated_assets_checked, [%{kind: :workflow, path: ^workflow_path}]}
  end

  test "partial failure rerun resumes from prior state, keeps durable assets, and appends session history" do
    repo_root = TestSupport.create_temp_git_repo!("installer-integration-rerun")
    workflow_path = Path.expand(Path.join(repo_root, "WORKFLOW.md"))

    first_launch_pid = spawn_sleeping_process()

    on_exit(fn ->
      if Process.alive?(first_launch_pid) do
        Process.exit(first_launch_pid, :kill)
      end
    end)

    assert {:error, {:launch_blocked, :missing_token, "GITHUB_TOKEN"}, manifest_path} =
             repo_first_preflight_install(
               repo_root,
               %{
                 "durable_assets" => %{
                   "files" => %{
                     "WORKFLOW.md" => "---\ntracker:\n  kind: linear\n---\nPrompt\n"
                   }
                 }
               },
               required_env: ["GITHUB_TOKEN"],
               launch_verifier_deps: missing_token_launch_verifier_deps(first_launch_pid)
             )

    assert manifest_path == TestSupport.installer_manifest_input_path(repo_root)
    refute manifest_path == SessionState.paths(repo_root).request
    assert %{"target_repo" => ^repo_root} = TestSupport.read_installer_request!(repo_root)
    assert File.regular?(workflow_path)
    assert %{"phase" => "failed", "reason" => reason} = TestSupport.read_installer_state!(repo_root)
    assert reason =~ ":missing_token"

    second_launch_pid = spawn_sleeping_process()

    on_exit(fn ->
      if Process.alive?(second_launch_pid) do
        Process.exit(second_launch_pid, :kill)
      end
    end)

    assert {:ok, ^manifest_path} =
             repo_first_preflight_install(
               repo_root,
               %{
                 "durable_assets" => %{
                   "files" => %{
                     "WORKFLOW.md" => "---\ntracker:\n  kind: linear\n---\nPrompt\n"
                   }
                 }
               },
               required_env: ["GITHUB_TOKEN"],
               launch_verifier_deps: successful_launch_verifier_deps(self(), second_launch_pid)
             )

    assert %{"phase" => "verified"} = TestSupport.read_installer_state!(repo_root)

    events = TestSupport.read_installer_events!(repo_root)

    assert Enum.any?(events, fn event -> event["event"] == "launch_blocked" end)

    assert Enum.any?(events, fn event ->
             event["event"] == "resume_detected" and event["from_phase"] == "failed"
           end)

    assert Enum.any?(events, fn event -> event["event"] == "launch_verified" end)
  end

  test "stale installer version fails before writing durable assets" do
    repo_root = TestSupport.create_temp_git_repo!("installer-integration-stale-version")
    workflow_path = Path.join(repo_root, "WORKFLOW.md")

    manifest_path =
      TestSupport.write_installer_manifest!(
        repo_root,
        %{
          "installer_version_range" => ">= 9.9.0",
          "durable_assets" => %{
            "files" => %{
              "WORKFLOW.md" => "---\ntracker:\n  kind: linear\n---\nPrompt\n"
            }
          }
        }
      )

    refute manifest_path == SessionState.paths(repo_root).request

    assert {:error, {:installer_upgrade_required, _installed_version, ">= 9.9.0"}} =
             Installer.install(manifest_path)

    refute File.exists?(workflow_path)
    refute File.exists?(SessionState.paths(repo_root).request)
    refute File.exists?(SessionState.paths(repo_root).state)
    refute File.exists?(SessionState.paths(repo_root).log)
  end

  test "repo-first preflight rejects unsupported remote before writing manifest input or installer state" do
    remote_url = "https://gitlab.com/example/demo.git"
    repo_root = TestSupport.create_temp_git_repo!("installer-integration-unsupported", remote_url)

    assert {:error, {:unsupported_target_repo, ^remote_url, "GitHub ordinary repos only in v1"}} =
             repo_first_preflight_install(repo_root)

    refute File.exists?(TestSupport.installer_manifest_input_path(repo_root))
    refute File.exists?(SessionState.paths(repo_root).request)
    refute File.exists?(Path.join(repo_root, "WORKFLOW.md"))
  end

  test "missing token returns a precise blocker after assets exist" do
    repo_root = TestSupport.create_temp_git_repo!("installer-integration-missing-token")
    workflow_path = Path.expand(Path.join(repo_root, "WORKFLOW.md"))

    launch_pid = spawn_sleeping_process()

    on_exit(fn ->
      if Process.alive?(launch_pid) do
        Process.exit(launch_pid, :kill)
      end
    end)

    assert {:error, {:launch_blocked, :missing_token, "GITHUB_TOKEN"}, manifest_path} =
             repo_first_preflight_install(
               repo_root,
               %{
                 "durable_assets" => %{
                   "files" => %{
                     "WORKFLOW.md" => "---\ntracker:\n  kind: linear\n---\nPrompt\n"
                   }
                 }
               },
               required_env: ["GITHUB_TOKEN"],
               launch_verifier_deps: missing_token_launch_verifier_deps(launch_pid)
             )

    assert manifest_path == TestSupport.installer_manifest_input_path(repo_root)
    refute manifest_path == SessionState.paths(repo_root).request
    assert %{"target_repo" => ^repo_root} = TestSupport.read_installer_request!(repo_root)
    assert File.regular?(workflow_path)
    assert %{"phase" => "failed", "reason" => reason} = TestSupport.read_installer_state!(repo_root)
    assert reason =~ "{:launch_blocked, :missing_token, \"GITHUB_TOKEN\"}"

    assert Enum.any?(TestSupport.read_installer_events!(repo_root), fn event ->
             event["event"] == "launch_blocked"
           end)
  end

  defp successful_launch_verifier_deps(parent, launch_pid) do
    %{
      resolve_tool: fn _tool -> "/opt/tools/fake" end,
      get_env: fn
        "GITHUB_TOKEN" -> "token"
        _other -> nil
      end,
      parse_generated_assets: fn assets ->
        send(parent, {:generated_assets_checked, assets})
        :ok
      end,
      launch_command: fn _command -> {:ok, launch_pid} end,
      process_running?: &Process.alive?/1,
      probe_health_surface: fn _url -> :ok end,
      sleep: fn _ms -> :ok end
    }
  end

  defp missing_token_launch_verifier_deps(launch_pid) do
    %{
      resolve_tool: fn _tool -> "/opt/tools/fake" end,
      get_env: fn _name -> nil end,
      parse_generated_assets: fn _assets -> :ok end,
      launch_command: fn _command -> {:ok, launch_pid} end,
      process_running?: &Process.alive?/1,
      probe_health_surface: fn _url -> :ok end,
      sleep: fn _ms -> :ok end
    }
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

  defp repo_first_preflight_install(repo_root, manifest_overrides \\ %{}, install_opts \\ [])
       when is_binary(repo_root) and is_map(manifest_overrides) and is_list(install_opts) do
    with {:ok, _inspection} <-
           Inspector.inspect_target!(repo_root, %{detect_git_remote: &TestSupport.detect_git_remote!/1}) do
      manifest_path = TestSupport.write_installer_manifest!(repo_root, manifest_overrides)

      case Installer.install(manifest_path, install_opts) do
        :ok -> {:ok, manifest_path}
        {:error, reason} -> {:error, reason, manifest_path}
      end
    end
  end
end
