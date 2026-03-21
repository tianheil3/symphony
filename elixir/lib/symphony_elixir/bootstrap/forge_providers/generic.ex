defmodule SymphonyElixir.Bootstrap.ForgeProviders.Generic do
  @moduledoc false

  @behaviour SymphonyElixir.Bootstrap.ForgeProvider

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
end
