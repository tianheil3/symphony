defmodule SymphonyElixir.TrackerProviders.Memory do
  @moduledoc false

  @behaviour SymphonyElixir.TrackerProvider

  @impl true
  def key, do: "memory"

  @impl true
  def adapter_module, do: SymphonyElixir.Tracker.Memory

  @impl true
  def default_endpoint, do: nil

  @impl true
  def api_key_env_var, do: nil

  @impl true
  def assignee_env_var, do: nil

  @impl true
  def validate_config(_tracker), do: :ok
end
