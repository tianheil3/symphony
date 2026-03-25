defmodule SymphonyElixir.InstallerManifestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Installer.Manifest
  alias SymphonyElixir.Installer.Policy
  alias SymphonyElixir.Installer.SessionState

  test "parse/1 accepts v1 manifest and fills required defaults" do
    assert {:ok, manifest} =
             Manifest.parse(%{
               "schema_version" => 1,
               "installer_version_range" => ">= 0.1.0",
               "capabilities" => ["repo_first_bootstrap", "launch_verify_v1"],
               "target_repo" => "/tmp/repo"
             })

    assert manifest.schema_version == 1
    assert manifest.installer_version_range == ">= 0.1.0"
    assert manifest.capabilities == ["repo_first_bootstrap", "launch_verify_v1"]
    assert manifest.target_repo == "/tmp/repo"
    assert manifest.ephemeral_state_dir == SessionState.relative_dir()
    assert is_map(manifest.tooling_policy)
    assert is_map(manifest.durable_assets)
    assert is_map(manifest.machine_state)
  end

  test "parse/1 rejects invalid installer version range" do
    assert {:error, {:invalid_manifest, {:installer_version_range, "not-a-version-range"}}} =
             Manifest.parse(%{
               "schema_version" => 1,
               "installer_version_range" => "not-a-version-range",
               "capabilities" => ["repo_first_bootstrap"],
               "target_repo" => "/tmp/repo"
             })
  end

  test "ensure_compatible!/3 accepts matching installer version and capabilities" do
    assert {:ok, manifest} =
             Manifest.parse(%{
               "schema_version" => 1,
               "installer_version_range" => ">= 0.1.0",
               "capabilities" => ["repo_first_bootstrap", "launch_verify_v1"],
               "target_repo" => "/tmp/repo"
             })

    assert :ok =
             Manifest.ensure_compatible!(manifest, "0.1.0", [
               "repo_first_bootstrap",
               "launch_verify_v1"
             ])
  end

  test "ensure_compatible!/3 reports upgrade requirement for stale installer versions" do
    assert {:ok, manifest} =
             Manifest.parse(%{
               "schema_version" => 1,
               "installer_version_range" => ">= 0.2.0",
               "capabilities" => ["repo_first_bootstrap"],
               "target_repo" => "/tmp/repo"
             })

    assert {:error, {:installer_upgrade_required, "0.1.0", ">= 0.2.0"}} =
             Manifest.ensure_compatible!(manifest, "0.1.0", ["repo_first_bootstrap"])
  end

  test "ensure_compatible!/3 reports missing required capabilities" do
    assert {:ok, manifest} =
             Manifest.parse(%{
               "schema_version" => 1,
               "capabilities" => ["repo_first_bootstrap"],
               "target_repo" => "/tmp/repo"
             })

    assert {:error, {:missing_manifest_capabilities, ["launch_verify_v1"]}} =
             Manifest.ensure_compatible!(manifest, "0.1.0", [
               "repo_first_bootstrap",
               "launch_verify_v1"
             ])
  end

  test "tooling policy matrix distinguishes repo assets from machine-local state" do
    matrix = Policy.tooling_policy_matrix()

    assert matrix.installer_binary == :auto_install
    assert matrix.system_runtime == :prompt_before_act
    assert matrix.forge_cli == :verify_only
    assert matrix.repo_assets == :managed_repo_assets
    assert matrix.secrets == :user_provided
    assert matrix.machine_state.installer_cache_dir == "~/.cache/symphony"
    assert matrix.machine_state.version_cache_file == "~/.cache/symphony/installer-version.json"
  end

  test "classify_asset/1 classifies policy matrix assets" do
    assert {:ok, :installer_tooling} = Policy.classify_asset(:installer_binary)
    assert {:ok, :system_dependency} = Policy.classify_asset(:system_runtime)
    assert {:ok, :forge_tooling} = Policy.classify_asset(:forge_cli)
    assert {:ok, :repo_durable_asset} = Policy.classify_asset(:repo_assets)
    assert {:ok, :user_secret} = Policy.classify_asset(:secrets)
    assert {:ok, :machine_local_state} = Policy.classify_asset(:machine_state)
    assert {:error, {:unknown_asset_type, :unknown}} = Policy.classify_asset(:unknown)
  end

  test "parse_tooling_policy/1 rejects unknown atom policy values" do
    assert {:error, {:invalid_manifest, {:installer_binary, :unknown_policy_value}}} =
             Policy.parse_tooling_policy(%{installer_binary: :definitely_not_allowed})
  end

  test "parse/1 rejects machine-state paths inside repo-local install state directory" do
    assert {:error, {:invalid_manifest, {:machine_state, :must_be_outside_ephemeral_state_dir}}} =
             Manifest.parse(%{
               "schema_version" => 1,
               "capabilities" => ["repo_first_bootstrap"],
               "target_repo" => "/tmp/repo",
               "machine_state" => %{
                 "installer_cache_dir" => "/tmp/repo/.symphony/install/cache",
                 "version_cache_file" => "~/.cache/symphony/installer-version.json"
               }
             })
  end

  test "parse/1 rejects custom ephemeral state directory values in v1" do
    assert {:error, {:invalid_manifest, {:ephemeral_state_dir, :unsupported_in_v1}}} =
             Manifest.parse(%{
               "schema_version" => 1,
               "capabilities" => ["repo_first_bootstrap"],
               "target_repo" => "/tmp/repo",
               "ephemeral_state_dir" => ".symphony/custom-install-state"
             })
  end

  test "parse/1 accepts explicit default ephemeral state directory value" do
    assert {:ok, manifest} =
             Manifest.parse(%{
               "schema_version" => 1,
               "capabilities" => ["repo_first_bootstrap"],
               "target_repo" => "/tmp/repo",
               "ephemeral_state_dir" => SessionState.relative_dir()
             })

    assert manifest.ephemeral_state_dir == SessionState.relative_dir()
  end

  test "session state helpers keep state under .symphony/install" do
    repo_root = Path.join(System.tmp_dir!(), "symphony-installer-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_root)
    on_exit(fn -> File.rm_rf(repo_root) end)

    paths = SessionState.paths(repo_root)

    assert paths.dir == Path.join(Path.expand(repo_root), SessionState.relative_dir())
    assert paths.request == Path.join(paths.dir, "request.json")
    assert paths.state == Path.join(paths.dir, "state.json")
    assert paths.log == Path.join(paths.dir, "events.jsonl")
  end

  test "session state load/save helpers persist state and append event logs" do
    repo_root = Path.join(System.tmp_dir!(), "symphony-installer-state-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_root)
    on_exit(fn -> File.rm_rf(repo_root) end)

    assert {:ok, nil} = SessionState.load(repo_root)
    assert :ok = SessionState.write_state(repo_root, %{"phase" => "preflight"})
    assert {:ok, %{"phase" => "preflight"}} = SessionState.load(repo_root)
    assert :ok = SessionState.write_request(repo_root, %{"schema_version" => 1})
    assert :ok = SessionState.append_log(repo_root, %{"event" => "state_saved"})

    assert {:ok, log_contents} = File.read(SessionState.paths(repo_root).log)
    assert log_contents =~ "\"event\":\"state_saved\""
  end
end
