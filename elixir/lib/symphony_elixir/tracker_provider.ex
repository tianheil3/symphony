defmodule SymphonyElixir.TrackerProvider do
  @moduledoc false

  @callback key() :: String.t()
  @callback adapter_module() :: module()
  @callback default_endpoint() :: String.t() | nil
  @callback api_key_env_var() :: String.t() | nil
  @callback assignee_env_var() :: String.t() | nil
  @callback validate_config(map()) :: :ok | {:error, term()}
end
