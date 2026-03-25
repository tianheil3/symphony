defmodule SymphonyElixir.InstallerDescriptorsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Installer.Descriptors

  test "resolves GitHub installer providers for tracker and forge" do
    assert {:ok, github_tracker} = Descriptors.tracker_provider("github")
    assert github_tracker.display_name() == "GitHub"

    assert {:ok, github_forge} = Descriptors.forge_provider("github")
    assert github_forge.automated_skill_names() == ["push", "land"]
  end

  test "returns unsupported tracker provider error for non-v1 tracker" do
    assert {:error, {:unsupported_tracker_provider, "gitlab"}} =
             Descriptors.supported_in_v1?(:tracker, "gitlab")
  end
end
