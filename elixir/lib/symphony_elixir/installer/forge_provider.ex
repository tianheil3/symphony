defmodule SymphonyElixir.Installer.ForgeProvider do
  @moduledoc false

  @callback key() :: String.t()
  @callback display_name() :: String.t()
  @callback automation_prompt(map()) :: String.t() | nil
  @callback automated_skill_names() :: [String.t()]
  @callback related_skill_lines(map()) :: [String.t()]
  @callback status_lines(map()) :: [String.t()]
  @callback execution_flow_lines(map()) :: [String.t()]
  @callback skill_artifacts(map()) :: [%{path: String.t(), content: String.t()}]
  @callback release_skill_routing_line(map()) :: String.t() | nil
  @callback pr_template_supported?(map()) :: boolean()
  @callback supports_automated_pr_flow?() :: boolean()
end
