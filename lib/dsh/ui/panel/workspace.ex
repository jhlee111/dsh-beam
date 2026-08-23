defmodule DshBeam.Ui.Panel.Workspace do
  @moduledoc """
  The workspace sidebar: lists the workspace's sessions (each a git worktree),
  creates new ones, switches the current session, and closes them. A session is
  the unit of the chat/todo/trajectory panes — switching rebinds `:session` to
  the selected worktree.
  """

  use DshBeam.Plugin
  import Phoenix.Component

  ui_slot(:sidebar, kind: :list, order: 10, component: {__MODULE__, :panel, []})

  def panel(assigns) do
    ~H"""
    <section>
      <h2>workspace</h2>

      <form class="workspace-form" phx-submit="workspace_create">
        <input type="hidden" name="repo" value={@workspace_repo} />
        <label class="muted">workspace folder</label>
        <div class="repo-picker">
          <code class="repo-path"><%= @workspace_repo %></code>
          <button type="button" phx-click="browse_dir">browse</button>
        </div>
        <label class="muted" for="ws-title">session title (optional)</label>
        <input type="text" name="title" id="ws-title" placeholder="e.g. my task" />
        <button type="submit" class="new-session-btn">+ new session</button>
      </form>

      <%= if @workspace_result do %>
        <p class="workspace-feedback muted"><%= result_label(@workspace_result) %></p>
      <% end %>

      <div class="workspace-list">
        <%= if @workspace_sessions == [] do %>
          <p class="muted empty-hint">
            no sessions yet — pick a workspace folder and press “+ new session”
          </p>
        <% end %>
        <%= for s <- @workspace_sessions do %>
          <div class="workspace-row">
            <span class={"pill state-#{if s.current, do: "active", else: "gone"}"}>
              <%= if s.current, do: "current", else: "idle" %>
            </span>
            <div class="workspace-meta">
              <code><%= s.title %></code>
              <span class="muted"><%= s.cwd %></span>
            </div>
            <div class="workspace-actions">
              <%= unless s.current do %>
                <button phx-click="workspace_switch" phx-value-session={s.session_key}>switch</button>
              <% end %>
              <button phx-click="workspace_close" phx-value-session={s.session_key}>close</button>
            </div>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  defp result_label({:ok, _session}), do: "session created"
  defp result_label(:ok), do: "session closed"
  defp result_label({:error, reason}), do: "error: " <> inspect(reason)
  defp result_label(other), do: inspect(other)
end
