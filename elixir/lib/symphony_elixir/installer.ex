defmodule SymphonyElixir.Installer do
  @moduledoc false

  alias SymphonyElixir.Installer.Apply
  alias SymphonyElixir.Installer.Manifest

  @required_capabilities ["repo_first_bootstrap", "launch_verify_v1"]
  @fallback_installer_version "0.1.0"

  @spec install(Path.t(), keyword()) :: :ok | {:error, term()}
  def install(manifest_path, opts \\ [])

  def install(manifest_path, opts) when is_binary(manifest_path) and is_list(opts) do
    expanded_manifest_path = Path.expand(manifest_path)

    with {:ok, manifest_data} <- load_manifest_data(expanded_manifest_path),
         {:ok, manifest} <- Manifest.parse(manifest_data),
         :ok <- Manifest.ensure_compatible!(manifest, installer_version(), @required_capabilities) do
      Apply.run(manifest, opts)
    else
      {:error, _reason} = error -> error
    end
  end

  def install(_manifest_path, _opts), do: {:error, {:invalid_manifest_path, :must_be_string}}

  defp load_manifest_data(manifest_path) when is_binary(manifest_path) do
    with {:ok, content} <- File.read(manifest_path),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      {:error, reason} ->
        {:error, {:manifest_read_failed, manifest_path, reason}}

      false ->
        {:error, {:manifest_decode_failed, manifest_path, :expected_map}}

      {:ok, _decoded_non_map} ->
        {:error, {:manifest_decode_failed, manifest_path, :expected_map}}
    end
  end

  defp installer_version do
    case Application.spec(:symphony_elixir, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> @fallback_installer_version
    end
  end
end
