defmodule SymphonyElixir.Bootstrap.TrackerProvider do
  @moduledoc false

  @callback workflow_kind() :: String.t()
  @callback display_name() :: String.t()
  @callback required_secret_name() :: String.t()
  @callback project_slug_prompt() :: String.t()
  @callback related_skill_name() :: String.t()
  @callback related_skill_line(map()) :: String.t()
  @callback workpad_label() :: String.t()
  @callback initial_status_expectations(map()) :: [String.t()]
  @callback related_skill_artifacts(map()) :: [%{path: String.t(), content: String.t()}]
end
