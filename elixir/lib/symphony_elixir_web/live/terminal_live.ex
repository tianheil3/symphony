defmodule SymphonyElixirWeb.TerminalLive do
  @moduledoc """
  Websocket-backed xterm-style console view for the shared tmux terminal session.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.AgentConsole
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(%{"issue_identifier" => issue_identifier}, _session, socket) do
    socket =
      socket
      |> assign(:issue_identifier, issue_identifier)
      |> assign(:command_output, nil)
      |> load_console()

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, load_console(socket)}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, load_console(socket)}
  end

  @impl true
  def handle_event("submit_command", %{"command" => command}, socket) do
    case socket.assigns[:workspace_path] do
      workspace_path when is_binary(workspace_path) ->
        case AgentConsole.submit_command(workspace_path, command) do
          {:ok, %{output: output}} ->
            ObservabilityPubSub.broadcast_update()

            {:noreply,
             socket
             |> assign(:command_output, output)
             |> load_console()}

          {:error, {:unsupported_command, message}} ->
            {:noreply, assign(socket, :command_output, message)}

          {:error, reason} ->
            {:noreply, assign(socket, :command_output, "console command failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, assign(socket, :command_output, "console unavailable")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Shared Console</p>
            <h1 class="hero-title"><%= @issue_identifier %></h1>
            <p class="hero-copy">
              Websocket xterm attach for the shared tmux console, with controlled operator commands instead of raw stdin passthrough.
            </p>
          </div>
        </div>
      </header>

      <%= if @console do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Attach</h2>
              <p class="section-copy">Local tmux and the web xterm page point at the same shared terminal session.</p>
            </div>
          </div>

          <div class="detail-stack">
            <span class="mono"><%= @console.attach_command %></span>
            <span class="muted">Pending operator notes: <%= @console.pending_operator_notes %></span>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Terminal</h2>
              <p class="section-copy">Restored with tmux capture-pane for reconnect-safe xterm rendering.</p>
            </div>
          </div>

          <pre class="code-panel xterm-screen"><%= @transcript %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Operator Commands</h2>
              <p class="section-copy">Allowed commands: <%= Enum.join(@console.allowed_commands, ", ") %></p>
            </div>
          </div>

          <form id="console-command-form" phx-submit="submit_command">
            <label class="metric-label" for="console-command-input">Command</label>
            <input id="console-command-input" name="command" type="text" class="code-panel" />
            <button type="submit" class="subtle-button">Send</button>
          </form>

          <%= if @command_output do %>
            <p class="metric-detail"><%= @command_output %></p>
          <% end %>
        </section>
      <% else %>
        <section class="error-card">
          <h2 class="error-title">Console unavailable</h2>
          <p class="error-copy">The shared tmux console has not been created for this issue yet.</p>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_console(socket) do
    issue_identifier = socket.assigns.issue_identifier

    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, %{workspace: %{path: workspace_path}, console: console}} when is_binary(workspace_path) and is_map(console) ->
        transcript =
          case AgentConsole.read_transcript(workspace_path) do
            {:ok, payload} -> payload
            {:error, _reason} -> ""
          end

        socket
        |> assign(:console, console)
        |> assign(:workspace_path, workspace_path)
        |> assign(:transcript, transcript)

      _ ->
        socket
        |> assign(:console, nil)
        |> assign(:workspace_path, nil)
        |> assign(:transcript, "")
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
