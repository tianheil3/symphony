defmodule SymphonyElixir.AgentConsole.OperatorCommand do
  @moduledoc """
  Parses the controlled operator command set for the shared agent console.
  """

  @help_text """
  Supported commands:
  - help
  - status
  - explain
  - continue
  - prompt <text>
  - cancel
  """

  @allowed_commands ["help", "status", "explain", "continue", "prompt <text>", "cancel"]
  @explain_note "Please explain completed work, remaining work, and the next step before continuing."

  @type command ::
          %{command: :help | :status | :explain | :continue | :cancel}
          | %{command: :prompt, note: String.t()}

  @spec allowed_commands() :: [String.t()]
  def allowed_commands, do: @allowed_commands

  @spec help_text() :: String.t()
  def help_text, do: String.trim(@help_text)

  @spec parse(String.t()) :: {:ok, command()} | {:error, {:unsupported_command, String.t()}}
  def parse(raw_command) when is_binary(raw_command) do
    trimmed = String.trim(raw_command)

    case trimmed do
      "help" -> {:ok, %{command: :help}}
      "status" -> {:ok, %{command: :status}}
      "explain" -> {:ok, %{command: :explain}}
      "continue" -> {:ok, %{command: :continue}}
      "cancel" -> {:ok, %{command: :cancel}}
      "" -> {:error, {:unsupported_command, help_text()}}
      _ -> parse_prompt(trimmed)
    end
  end

  @spec explain_note() :: String.t()
  def explain_note, do: @explain_note

  defp parse_prompt("prompt " <> note) do
    note = String.trim(note)

    if note == "" do
      {:error, {:unsupported_command, help_text()}}
    else
      {:ok, %{command: :prompt, note: note}}
    end
  end

  defp parse_prompt(_command), do: {:error, {:unsupported_command, help_text()}}
end
