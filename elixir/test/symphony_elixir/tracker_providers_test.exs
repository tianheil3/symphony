defmodule SymphonyElixir.TrackerProvidersTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TrackerProviders

  test "provider lookup returns built-in providers" do
    assert {:ok, SymphonyElixir.TrackerProviders.GitHub} = TrackerProviders.provider("github")
    assert {:ok, SymphonyElixir.TrackerProviders.Linear} = TrackerProviders.provider("linear")
    assert {:ok, SymphonyElixir.TrackerProviders.GitLab} = TrackerProviders.provider("gitlab")
    assert {:ok, SymphonyElixir.TrackerProviders.Memory} = TrackerProviders.provider("memory")
  end

  test "provider lookup preserves current error shape for unsupported kinds" do
    assert {:error, :missing_tracker_kind} = TrackerProviders.provider(nil)
    assert {:error, {:unsupported_tracker_kind, "jira"}} = TrackerProviders.provider("jira")
  end

  test "supported_kinds exposes the current registry keys" do
    assert Enum.sort(TrackerProviders.supported_kinds()) == ["github", "gitlab", "linear", "memory"]
  end
end
