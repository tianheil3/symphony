defmodule SymphonyElixir.Installer.ForgeProviders.Generic do
  @moduledoc false

  @behaviour SymphonyElixir.Installer.ForgeProvider

  @impl true
  def key, do: "none"

  @impl true
  def display_name, do: "No forge detected"

  @impl true
  def automation_prompt(_provider), do: nil

  @impl true
  def automated_skill_names, do: []

  @impl true
  def related_skill_lines(_plan), do: []

  @impl true
  def status_lines(_plan), do: []

  @impl true
  def execution_flow_lines(_plan), do: []

  @impl true
  def skill_artifacts(_plan), do: []

  @impl true
  def release_skill_routing_line(_plan), do: nil

  @impl true
  def pr_template_supported?(_plan), do: false

  @impl true
  def supports_automated_pr_flow?, do: false
end
