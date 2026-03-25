defmodule SymphonyElixir.InstallerLaunchVerifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Installer.Apply
  alias SymphonyElixir.Installer.LaunchVerifier

  test "verify/2 succeeds when all configured checks pass" do
    parent = self()
    launched_pid = spawn_sleeping_process()

    deps = %{
      resolve_tool: fn tool -> "/opt/tools/#{tool}" end,
      get_env: fn
        "GITHUB_TOKEN" -> "token"
        _other -> nil
      end,
      parse_generated_assets: fn assets ->
        send(parent, {:generated_assets_checked, assets})
        :ok
      end,
      launch_command: fn _command -> {:ok, launched_pid} end,
      process_running?: &Process.alive?/1,
      probe_health_surface: fn "http://127.0.0.1:4000" -> :ok end,
      sleep: fn _ms -> :ok end
    }

    config = %{
      required_tools: ["git", "gh"],
      required_env: ["GITHUB_TOKEN"],
      generated_assets: [%{path: "/tmp/WORKFLOW.md", kind: :workflow}],
      command: ["./bin/symphony", "./WORKFLOW.md"],
      dashboard_url: "http://127.0.0.1:4000"
    }

    assert {:ok, %{status: :verified}} = LaunchVerifier.verify(config, deps)
    assert_received {:generated_assets_checked, [%{path: "/tmp/WORKFLOW.md", kind: :workflow}]}
    Process.exit(launched_pid, :kill)
  end

  test "verify/2 returns a precise blocker when a required token is missing" do
    deps = %{
      resolve_tool: fn _tool -> "/opt/tools/fake" end,
      get_env: fn _name -> nil end,
      parse_generated_assets: fn _assets -> :ok end,
      launch_command: fn _command -> {:ok, spawn_sleeping_process()} end,
      process_running?: &Process.alive?/1,
      probe_health_surface: fn _url -> :ok end,
      sleep: fn _ms -> :ok end
    }

    assert {:error, {:launch_blocked, :missing_token, "GITHUB_TOKEN"}} =
             LaunchVerifier.verify(%{required_env: ["GITHUB_TOKEN"]}, deps)
  end

  test "verify/2 fails when a configured health surface never becomes reachable" do
    launched_pid = spawn_sleeping_process()

    deps = %{
      resolve_tool: fn _tool -> "/opt/tools/fake" end,
      get_env: fn _name -> "set" end,
      parse_generated_assets: fn _assets -> :ok end,
      launch_command: fn _command -> {:ok, launched_pid} end,
      process_running?: &Process.alive?/1,
      probe_health_surface: fn _url -> {:error, :econnrefused} end,
      sleep: fn _ms -> :ok end
    }

    assert {:error, {:launch_blocked, :health_unreachable, "http://127.0.0.1:4000"}} =
             LaunchVerifier.verify(
               %{
                 command: ["./bin/symphony", "./WORKFLOW.md"],
                 dashboard_url: "http://127.0.0.1:4000",
                 health_check_attempts: 3
               },
               deps
             )

    Process.exit(launched_pid, :kill)
  end

  test "verify/2 fails when a required tool cannot be resolved" do
    deps = %{
      resolve_tool: fn
        "git" -> "/opt/tools/git"
        _tool -> nil
      end,
      get_env: fn _name -> "set" end,
      parse_generated_assets: fn _assets -> :ok end,
      launch_command: fn _command -> {:ok, spawn_sleeping_process()} end,
      process_running?: &Process.alive?/1,
      probe_health_surface: fn _url -> :ok end,
      sleep: fn _ms -> :ok end
    }

    assert {:error, {:launch_blocked, :missing_tool, "gh"}} =
             LaunchVerifier.verify(%{required_tools: ["git", "gh"]}, deps)
  end

  test "verify/2 treats a 404 health surface as unreachable" do
    {dashboard_url, server_pid} = start_static_http_server(404)

    on_exit(fn ->
      if Process.alive?(server_pid) do
        Process.exit(server_pid, :kill)
      end
    end)

    assert {:error, {:launch_blocked, :health_unreachable, ^dashboard_url}} =
             LaunchVerifier.verify(
               %{dashboard_url: dashboard_url, health_check_attempts: 1},
               LaunchVerifier.runtime_deps()
             )
  end

  test "verify/2 rejects malformed required_env config shape" do
    assert {:error, {:launch_blocked, :invalid_config, {:required_env, :must_be_list_of_strings}}} =
             LaunchVerifier.verify(%{required_env: "GITHUB_TOKEN"}, LaunchVerifier.runtime_deps())
  end

  test "apply/2 fails fast when durable_assets files contract is malformed" do
    target_root = temp_repo_root!("installer-apply-invalid-durable-assets")

    manifest = %{
      target_repo: target_root,
      durable_assets: %{"files" => "WORKFLOW.md"}
    }

    launch_verifier_deps = %{
      resolve_tool: fn _ -> flunk("launch verifier should not run for malformed durable assets") end,
      get_env: fn _ -> flunk("launch verifier should not run for malformed durable assets") end,
      parse_generated_assets: fn _ -> flunk("launch verifier should not run for malformed durable assets") end,
      launch_command: fn _ -> flunk("launch verifier should not run for malformed durable assets") end,
      process_running?: fn _ -> flunk("launch verifier should not run for malformed durable assets") end,
      probe_health_surface: fn _ -> flunk("launch verifier should not run for malformed durable assets") end,
      sleep: fn _ -> flunk("launch verifier should not run for malformed durable assets") end
    }

    assert {:error, {:invalid_durable_assets, {:files, :must_be_map}}} =
             Apply.run(manifest, launch_verifier_deps: launch_verifier_deps)
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

  defp start_static_http_server(status_code) when is_integer(status_code) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listen_socket)

    server_pid =
      spawn(fn ->
        {:ok, client_socket} = :gen_tcp.accept(listen_socket, 5_000)
        _ = :gen_tcp.recv(client_socket, 0, 5_000)

        response =
          "HTTP/1.1 #{status_code} #{http_reason_phrase(status_code)}\r\n" <>
            "content-length: 0\r\nconnection: close\r\n\r\n"

        :ok = :gen_tcp.send(client_socket, response)
        :ok = :gen_tcp.close(client_socket)
        :ok = :gen_tcp.close(listen_socket)
      end)

    {"http://127.0.0.1:#{port}", server_pid}
  end

  defp http_reason_phrase(404), do: "Not Found"
  defp http_reason_phrase(200), do: "OK"
  defp http_reason_phrase(_status), do: "Status"

  defp temp_repo_root!(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-launch-verifier-test-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    root
  end
end
